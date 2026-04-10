import Cocoa

/// Orchestrates post-injection correction detection.
/// After text is injected, monitors the target text field for edits,
/// then uses LLM to extract ASR error correction pairs.
@MainActor
final class AutoCorrectionManager {

    static let shared = AutoCorrectionManager()

    private let monitor = CorrectionMonitor()
    private let extractor = CorrectionExtractor()
    private var extractionTask: Task<Void, Never>?

    /// Called on main thread with extracted corrections.
    var onCorrectionsFound: (([CorrectionExtractor.Correction]) -> Void)?

    private init() {}

    // MARK: - Public API

    /// Begin monitoring the focused text field for user edits.
    /// Call this after successful text injection.
    func beginTracking(injectedText: String, sessionId: String) {
        // Default is enabled (nil means not yet set → treat as true)
        if UserDefaults.standard.object(forKey: "tf_autoCorrectionEnabled") != nil
            && !UserDefaults.standard.bool(forKey: "tf_autoCorrectionEnabled") { return }

        // Stop the monitor but let any in-progress LLM extraction finish
        monitor.stopMonitoring()

        let (element, pid) = captureFocusedElement()

        let context = CorrectionMonitor.Context(
            injectedText: injectedText,
            element: element,
            pid: pid,
            sessionId: sessionId
        )

        monitor.startMonitoring(context: context) { [weak self] original, edited in
            self?.handleEditDetected(original: original, edited: edited)
        }
    }

    /// Cancel any active monitoring and pending LLM calls.
    func cancelTracking() {
        monitor.stopMonitoring()
        extractionTask?.cancel()
        extractionTask = nil
    }

    // MARK: - Focused Element Capture

    private func captureFocusedElement() -> (AXUIElement?, pid_t) {
        let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0

        guard AXIsProcessTrusted() else { return (nil, pid) }

        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, 0.5)
        var focusedValue: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        )
        guard status == .success, let focusedValue else { return (nil, pid) }

        let element = unsafeDowncast(focusedValue, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(element, 0.5)
        return (element, pid)
    }

    // MARK: - Edit Handling

    private func handleEditDetected(original: String, edited: String) {
        DebugFileLogger.log("auto-correction: edit detected, invoking LLM")
        extractionTask?.cancel()
        extractionTask = Task { [weak self] in
            guard let self else { return }
            do {
                let corrections = try await self.extractor.extract(original: original, edited: edited)
                if Task.isCancelled {
                    DebugFileLogger.log("auto-correction: task cancelled after LLM returned")
                    return
                }
                if corrections.isEmpty {
                    DebugFileLogger.log("auto-correction: LLM returned no corrections")
                    return
                }

                DebugFileLogger.log("auto-correction: found \(corrections.count) corrections")
                for c in corrections {
                    DebugFileLogger.log("  \"\(c.wrong)\" → \"\(c.correct)\"")
                }

                await MainActor.run {
                    self.onCorrectionsFound?(corrections)
                }
            } catch CorrectionExtractor.ExtractionError.skipped {
                DebugFileLogger.log("auto-correction: pre-filter skipped")
            } catch CorrectionExtractor.ExtractionError.noLLMConfigured {
                DebugFileLogger.log("auto-correction: no LLM configured, skipping")
            } catch {
                DebugFileLogger.log("auto-correction: extraction failed: \(error.localizedDescription)")
            }
        }
    }
}
