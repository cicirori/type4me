import Cocoa

/// Monitors a text field after injection for user edits.
/// Uses AXObserver for GUI apps, clipboard polling for terminals.
/// All access must be on the main thread (AX callbacks, timers, NSWorkspace notifications).
@MainActor
final class CorrectionMonitor {

    struct Context {
        let injectedText: String
        let element: AXUIElement?
        let pid: pid_t
        let sessionId: String
    }

    private var observer: AXObserver?
    private var monitoredElement: AXUIElement?
    private var monitoredAppElement: AXUIElement?
    private var context: Context?
    private var onChange: ((String, String) -> Void)?

    // Track the latest edited text — diff fires on focus change, app switch, or idle timeout
    private var lastEditedText: String?

    // Idle timeout: stop monitoring after no changes
    private var idleTimer: DispatchSourceTimer?
    private let idleTimeout: TimeInterval = 30.0

    // Clipboard polling (terminal fallback)
    private var clipboardTimer: DispatchSourceTimer?
    private var lastClipboardChangeCount: Int = 0

    // App switch detection
    private var appSwitchObserver: NSObjectProtocol?

    private var hasFired = false

    // MARK: - Known terminal bundle IDs

    private static let terminalBundleIDs: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "io.alacritty",
        "net.kovidgoyal.kitty",
        "com.github.wez.wezterm",
    ]

    // MARK: - Public API

    func startMonitoring(context: Context, onChange: @escaping (String, String) -> Void) {
        stopMonitoring()
        self.context = context
        self.onChange = onChange
        self.hasFired = false

        let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        let isTerminal = Self.terminalBundleIDs.contains(bundleID)

        if !isTerminal, let element = context.element {
            startAXMonitoring(element: element, pid: context.pid)
        } else {
            startClipboardMonitoring()
        }

        startIdleTimer()
        observeAppSwitch()

        DebugFileLogger.log("correction monitor started (mode=\(isTerminal ? "clipboard" : "AX"), session=\(context.sessionId.prefix(8)))")
    }

    func stopMonitoring() {
        if let obs = observer {
            if let el = monitoredElement {
                AXObserverRemoveNotification(obs, el, kAXValueChangedNotification as CFString)
            }
            if let appEl = monitoredAppElement {
                AXObserverRemoveNotification(obs, appEl, kAXFocusedUIElementChangedNotification as CFString)
            }
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .commonModes)
        }
        observer = nil
        monitoredElement = nil
        monitoredAppElement = nil

        idleTimer?.cancel()
        idleTimer = nil
        clipboardTimer?.cancel()
        clipboardTimer = nil

        if let token = appSwitchObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
            appSwitchObserver = nil
        }

        lastEditedText = nil
        context = nil
        onChange = nil
    }

    // MARK: - AX Monitoring

    private func startAXMonitoring(element: AXUIElement, pid: pid_t) {
        var obs: AXObserver?
        let status = AXObserverCreate(pid, axCallback, &obs)
        guard status == .success, let obs else {
            DebugFileLogger.log("correction monitor: AXObserver creation failed, falling back to clipboard")
            startClipboardMonitoring()
            return
        }

        // Watch for value changes on the text field
        let addStatus = AXObserverAddNotification(obs, element, kAXValueChangedNotification as CFString, Unmanaged.passUnretained(self).toOpaque())
        guard addStatus == .success else {
            DebugFileLogger.log("correction monitor: AXObserver add notification failed, falling back to clipboard")
            startClipboardMonitoring()
            return
        }

        // Watch for focus changes on the app — triggers when user clicks/tabs away from the text field
        let appElement = AXUIElementCreateApplication(pid)
        AXObserverAddNotification(obs, appElement, kAXFocusedUIElementChangedNotification as CFString, Unmanaged.passUnretained(self).toOpaque())

        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .commonModes)
        observer = obs
        monitoredElement = element
        monitoredAppElement = appElement
    }

    fileprivate func handleAXValueChanged() {
        guard !hasFired, let ctx = context, let element = monitoredElement else { return }

        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success,
              let newText = value as? String
        else { return }

        let original = ctx.injectedText

        // Field cleared (e.g., Slack: user pressed Enter to send) — if we had edits, fire now
        if newText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let edited = lastEditedText, edited != original {
            hasFired = true
            DebugFileLogger.log("correction monitor: field cleared after edit, firing")
            onChange?(original, edited)
            stopMonitoring()
            return
        }

        guard newText != original else { return }

        lastEditedText = newText
        resetIdleTimer()
    }

    /// Focus moved away from the monitored text field — user is done editing.
    fileprivate func handleAXFocusChanged() {
        guard !hasFired, let ctx = context, let edited = lastEditedText else { return }
        let original = ctx.injectedText
        guard edited != original else { return }

        hasFired = true
        DebugFileLogger.log("correction monitor: focus left, firing immediately")
        onChange?(original, edited)
        stopMonitoring()
    }

    // MARK: - Clipboard Monitoring

    private func startClipboardMonitoring() {
        lastClipboardChangeCount = NSPasteboard.general.changeCount

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 1, repeating: 1.0)
        timer.setEventHandler { [weak self] in
            self?.checkClipboard()
        }
        timer.resume()
        clipboardTimer = timer
    }

    private func checkClipboard() {
        let currentCount = NSPasteboard.general.changeCount
        guard currentCount != lastClipboardChangeCount else { return }
        lastClipboardChangeCount = currentCount

        guard !hasFired, let ctx = context else { return }
        guard let clipText = NSPasteboard.general.string(forType: .string),
              !clipText.isEmpty
        else { return }

        let original = ctx.injectedText
        guard clipText != original else { return }

        // Check similarity — clipboard content should be a correction of the injected text
        guard textSimilarity(original, clipText) >= 0.3 else { return }

        // Clipboard change is itself the signal — fire immediately
        hasFired = true
        DebugFileLogger.log("correction monitor: clipboard correction detected")
        onChange?(original, clipText)
        stopMonitoring()
    }

    /// Character bigram Jaccard similarity
    private func textSimilarity(_ a: String, _ b: String) -> Double {
        let ba = Self.bigrams(a)
        let bb = Self.bigrams(b)
        let intersection = ba.intersection(bb).count
        let union = ba.union(bb).count
        return union > 0 ? Double(intersection) / Double(union) : 0
    }

    private static func bigrams(_ s: String) -> Set<String> {
        let chars = Array(s)
        guard chars.count >= 2 else {
            return Set(chars.map { String($0) })
        }
        var result = Set<String>()
        for i in 0..<(chars.count - 1) {
            result.insert(String(chars[i]) + String(chars[i + 1]))
        }
        return result
    }

    // MARK: - Idle Timer

    private func startIdleTimer() {
        idleTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + idleTimeout)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            // If user edited but never left the field, fire on idle timeout
            if !self.hasFired, let ctx = self.context, let edited = self.lastEditedText, edited != ctx.injectedText {
                self.hasFired = true
                DebugFileLogger.log("correction monitor: idle timeout with edits, firing")
                self.onChange?(ctx.injectedText, edited)
            } else {
                DebugFileLogger.log("correction monitor: idle timeout, no edits")
            }
            self.stopMonitoring()
        }
        timer.resume()
        idleTimer = timer
    }

    private func resetIdleTimer() {
        startIdleTimer()
    }

    // MARK: - App Switch

    private func observeAppSwitch() {
        guard let ctx = context else { return }
        let targetPID = ctx.pid
        appSwitchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self,
                  let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.processIdentifier != targetPID
            else { return }

            // If user edited and then switched apps, fire the diff
            if !self.hasFired, let edited = self.lastEditedText, edited != ctx.injectedText {
                self.hasFired = true
                DebugFileLogger.log("correction monitor: app switched with edits, firing")
                self.onChange?(ctx.injectedText, edited)
            } else {
                DebugFileLogger.log("correction monitor: app switched, no edits")
            }
            self.stopMonitoring()
        }
    }
}

// MARK: - AX C callback

private func axCallback(
    _ observer: AXObserver,
    _ element: AXUIElement,
    _ notification: CFString,
    _ refcon: UnsafeMutableRawPointer?
) {
    guard let refcon else { return }
    let monitor = Unmanaged<CorrectionMonitor>.fromOpaque(refcon).takeUnretainedValue()
    let name = notification as String
    // AX callbacks run on the main run loop; MainActor dispatch is safe here
    MainActor.assumeIsolated {
        if name == kAXFocusedUIElementChangedNotification as String {
            monitor.handleAXFocusChanged()
        } else {
            monitor.handleAXValueChanged()
        }
    }
}
