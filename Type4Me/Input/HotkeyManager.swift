import Cocoa

typealias HotkeyStyle = ProcessingMode.HotkeyStyle

struct ModeBinding {
    let modeId: UUID
    let keyCode: CGKeyCode
    let modifiers: CGEventFlags        // .maskCommand etc. Used for regular-key bindings.
    let coModifierKeyCodes: Set<CGKeyCode>  // Specific modifier keyCodes that must be held (left/right aware).
    let style: HotkeyStyle
    let onStart: @Sendable () -> Void
    let onStop: @Sendable () -> Void

    /// Whether this binding is for a mouse button (encoded with high-bit keyCode).
    var isMouseButton: Bool { ModeBinding.isMouseKeyCode(Int(keyCode)) }

    /// The mouse button number (2=middle, 3+=side buttons). Only valid when isMouseButton is true.
    var mouseButtonNumber: Int { ModeBinding.mouseButtonNumber(from: Int(keyCode)) }

    // MARK: - Mouse Button Encoding
    //
    // Convention: keyCode = 0x8000 + buttonNumber.
    // Middle button (2) → 0x8002, Side button 3 → 0x8003, etc.
    // Keyboard keyCodes are 0–127, so no collision.
    // The encoded value fits in both Int and UInt16 (CGKeyCode).

    private static let mouseKeyCodeBase = 0x8000

    /// Encode a mouse button number as a keyCode (for storage in ProcessingMode.hotkeyCode).
    static func mouseKeyCode(for buttonNumber: Int) -> Int { mouseKeyCodeBase + buttonNumber }

    /// Decode a mouse keyCode back to a button number.
    static func mouseButtonNumber(from keyCode: Int) -> Int { keyCode - mouseKeyCodeBase }

    /// Check if a keyCode represents a mouse button.
    static func isMouseKeyCode(_ keyCode: Int) -> Bool { keyCode >= mouseKeyCodeBase }
}

final class HotkeyManager: NSObject {

    // MARK: - Configuration

    private var bindings: [ModeBinding] = []
    private var holdState: [UUID: Bool] = [:]
    private var toggleState: [UUID: Bool] = [:]
    private var wasModifierDown: [UUID: Bool] = [:]
    private var holdSafetyTimers: [UUID: Timer] = [:]
    /// Which toggle mode is currently active (recording). Only one can be active at a time.
    private var activeToggleModeId: UUID?

    /// Maximum hold duration before auto-stop (seconds).
    private let maxHoldDuration: TimeInterval = 120

    /// Track exactly which modifier keyCodes are currently held (distinguishes left/right).
    private var heldModifierKeyCodes: Set<CGKeyCode> = []

    /// Deferred modifier binding: when a modifier key matches a binding but
    /// another binding includes it as a co-modifier keyCode, defer briefly
    /// to see if the combo completes.
    private var deferredModifierBinding: ModeBinding?
    private var deferredModifierTimer: Timer?
    private let modifierDeferDelay: TimeInterval = 0.15

    // MARK: - State

    /// When true, all hotkey events pass through unhandled (used during hotkey recording).
    var isSuppressed = false

    /// When true, ESC key aborts active recording.
    var isESCAbortEnabled = true

    /// When true, LLM post-processing is in progress (ESC can also abort this).
    var isProcessing = false

    /// Reset all active recording/hold state.
    func resetActiveState() {
        activeToggleModeId = nil
        for key in toggleState.keys { toggleState[key] = false }
        for key in holdState.keys { holdState[key] = false }
        cancelDeferredModifierBinding()
    }

    /// Called when recording is stopped by a different mode's hotkey.
    var onCrossModeStop: ((UUID) -> Void)?

    /// Called when ESC is pressed during active recording or processing (abort).
    /// Returns true if the abort was handled (ESC should be swallowed).
    var onESCAbort: (() -> Bool)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var healthCheckTimer: Timer?
    fileprivate var lastEventTime: Date?

    // MARK: - Registration

    var bindingCount: Int { bindings.count }

    func registerBindings(_ newBindings: [ModeBinding]) {
        bindings = newBindings
        holdState = [:]
        toggleState = [:]
        wasModifierDown = [:]
        heldModifierKeyCodes = []
        holdSafetyTimers.values.forEach { $0.invalidate() }
        holdSafetyTimers = [:]
        cancelDeferredModifierBinding()
    }

    // MARK: - Start / Stop

    @discardableResult
    func start() -> Bool {
        let eventMask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.otherMouseDown.rawValue)
            | (1 << CGEventType.otherMouseUp.rawValue)

        let userInfo = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: hotkeyCallback,
            userInfo: userInfo
        ) else {
            return false
        }

        eventTap = tap
        lastEventTime = nil

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        startHealthCheck()
        return true
    }

    func stop() {
        healthCheckTimer?.invalidate()
        healthCheckTimer = nil
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        lastEventTime = nil
        holdState = [:]
        toggleState = [:]
        wasModifierDown = [:]
        heldModifierKeyCodes = []
        holdSafetyTimers.values.forEach { $0.invalidate() }
        holdSafetyTimers = [:]
        cancelDeferredModifierBinding()
    }

    // MARK: - Health check

    private func startHealthCheck() {
        healthCheckTimer?.invalidate()
        healthCheckTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            guard let self, let tap = self.eventTap else { return }
            if !CGEvent.tapIsEnabled(tap: tap) {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            if let lastEvent = self.lastEventTime,
               Date().timeIntervalSince(lastEvent) > 30 {
                self.reinstallTap()
            }
        }
    }

    private func reinstallTap() {
        stop()
        _ = start()
    }

    // MARK: - Event handling

    fileprivate func handleEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        lastEventTime = Date()

        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            recoverStuckHolds()
            return Unmanaged.passUnretained(event)
        }

        if isSuppressed {
            return Unmanaged.passUnretained(event)
        }

        // MARK: Mouse button events (otherMouseDown/Up = middle + side buttons)
        if type == .otherMouseDown || type == .otherMouseUp {
            let buttonNumber = Int(event.getIntegerValueField(.mouseEventButtonNumber))

            for binding in bindings {
                guard binding.isMouseButton, binding.mouseButtonNumber == buttonNumber else { continue }

                switch binding.style {
                case .hold:
                    if type == .otherMouseDown {
                        handleBindingEvent(binding: binding, pressed: true)
                    } else {
                        handleBindingEvent(binding: binding, pressed: false)
                    }
                case .toggle:
                    if type == .otherMouseDown {
                        let id = binding.modeId
                        if let activeId = activeToggleModeId, activeId != id {
                            toggleState[activeId] = false
                            activeToggleModeId = nil
                            onCrossModeStop?(id)
                        } else {
                            let isOn = toggleState[id] ?? false
                            toggleState[id] = !isOn
                            if !isOn {
                                activeToggleModeId = id
                                binding.onStart()
                            } else {
                                activeToggleModeId = nil
                                binding.onStop()
                            }
                        }
                    }
                }
                return nil  // Swallow matched mouse button events
            }

            return Unmanaged.passUnretained(event)
        }

        // MARK: Keyboard events
        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))

        // ── Modifier keys: use held-keyCode tracking ──
        if type == .flagsChanged && isModifierKeyCode(keyCode) {
            let pressed = isModifierPressed(keyCode: keyCode, flags: event.flags)

            // Update held set
            if pressed {
                heldModifierKeyCodes.insert(keyCode)
            } else {
                heldModifierKeyCodes.remove(keyCode)
            }

            if pressed {
                return handleModifierPressed(keyCode: keyCode, event: event)
            } else {
                return handleModifierReleased(keyCode: keyCode, event: event)
            }
        }

        // ── Regular keys ──
        for binding in bindings {
            // Skip mouse button bindings in the keyboard path
            guard !binding.isMouseButton else { continue }
            guard binding.keyCode == keyCode else { continue }
            guard !isModifierKeyCode(keyCode) else { continue }

            let requiredMods = normalizedModifierFlags(binding.modifiers)
            let currentMods = normalizedModifierFlags(event.flags)
            guard currentMods == requiredMods else { continue }

            // If binding specifies exact co-modifier keyCodes, verify they're held (left/right aware)
            if !binding.coModifierKeyCodes.isEmpty {
                guard binding.coModifierKeyCodes.isSubset(of: heldModifierKeyCodes) else { continue }
            }

            cancelDeferredModifierBinding()

            switch binding.style {
            case .hold:
                if type == .keyDown {
                    let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat)
                    if isRepeat != 0 { return nil }
                    handleBindingEvent(binding: binding, pressed: true)
                } else if type == .keyUp {
                    handleBindingEvent(binding: binding, pressed: false)
                }
            case .toggle:
                if type == .keyDown {
                    let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat)
                    if isRepeat != 0 { return nil }
                    let id = binding.modeId
                    if let activeId = activeToggleModeId, activeId != id {
                        toggleState[activeId] = false
                        activeToggleModeId = nil
                        onCrossModeStop?(id)
                    } else {
                        let isOn = toggleState[id] ?? false
                        toggleState[id] = !isOn
                        if !isOn {
                            activeToggleModeId = id
                            binding.onStart()
                        } else {
                            activeToggleModeId = nil
                            binding.onStop()
                        }
                    }
                }
            }
            return nil
        }

        // ── ESC abort ──
        if isESCAbortEnabled && type == .keyDown && keyCode == 53 {
            cancelDeferredModifierBinding()
            let isRecording = activeToggleModeId != nil || holdState.values.contains(true)
            let shouldAbort = isRecording || isProcessing
            if shouldAbort {
                if onESCAbort?() == true {
                    return nil
                }
                isProcessing = false
                resetActiveState()
            }
        }

        return Unmanaged.passUnretained(event)
    }

    // MARK: - Modifier Press

    /// A modifier key was pressed. Find the best matching binding using held keyCodes.
    private func handleModifierPressed(keyCode: CGKeyCode, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Try to find a combo binding whose full key set is now satisfied.
        // Prefer bindings with MORE coModifierKeyCodes (more specific).
        let comboMatch = bindings
            .filter { binding in
                isModifierKeyCode(binding.keyCode)
                    && !binding.coModifierKeyCodes.isEmpty
                    && heldModifierKeyCodes.contains(binding.keyCode)
                    && binding.coModifierKeyCodes.isSubset(of: heldModifierKeyCodes)
                    && !isModifierBindingActive(binding)
            }
            .max(by: { $0.coModifierKeyCodes.count < $1.coModifierKeyCodes.count })

        if let combo = comboMatch {
            cancelDeferredModifierBinding()
            DebugFileLogger.log("hotkey combo matched: keyCodes=\(heldModifierKeyCodes.sorted())")
            handleBindingEvent(binding: combo, pressed: true)
            return Unmanaged.passUnretained(event)
        }

        // Try to find a simple (no co-modifiers) binding for this keyCode.
        if let simple = bindings.first(where: {
            $0.keyCode == keyCode
                && isModifierKeyCode($0.keyCode)
                && $0.coModifierKeyCodes.isEmpty
                && !isModifierBindingActive($0)
                && otherModifierFlags(for: keyCode, flags: event.flags) == normalizedModifierFlags($0.modifiers)
        }) {
            // Check if any combo binding includes this keyCode — if so, defer.
            if shouldDeferModifierBinding(forKeyCode: keyCode) {
                DebugFileLogger.log("hotkey deferred keyCode=\(keyCode)")
                deferModifierBinding(simple)
                return Unmanaged.passUnretained(event)
            }

            DebugFileLogger.log("hotkey immediate keyCode=\(keyCode)")
            handleBindingEvent(binding: simple, pressed: true)
            return Unmanaged.passUnretained(event)
        }

        return Unmanaged.passUnretained(event)
    }

    // MARK: - Modifier Release

    private func handleModifierReleased(keyCode: CGKeyCode, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Release any active binding that uses this keyCode
        for binding in bindings where binding.keyCode == keyCode && isModifierKeyCode(binding.keyCode) {
            if isModifierBindingActive(binding) {
                handleBindingEvent(binding: binding, pressed: false)
                return Unmanaged.passUnretained(event)
            }
        }

        // Also release combo bindings whose co-modifier was released
        for binding in bindings where isModifierKeyCode(binding.keyCode) && binding.coModifierKeyCodes.contains(keyCode) {
            if isModifierBindingActive(binding) {
                handleBindingEvent(binding: binding, pressed: false)
                return Unmanaged.passUnretained(event)
            }
        }

        // Key released before defer timer — fire immediately then release
        if let deferred = deferredModifierBinding, deferred.keyCode == keyCode {
            fireDeferredModifierBinding()
            handleBindingEvent(binding: deferred, pressed: false)
            return Unmanaged.passUnretained(event)
        }

        return Unmanaged.passUnretained(event)
    }

    // MARK: - Binding dispatch

    private func handleBindingEvent(binding: ModeBinding, pressed: Bool) {
        let id = binding.modeId

        switch binding.style {
        case .hold:
            let wasHolding = holdState[id] ?? false
            if pressed && !wasHolding {
                holdState[id] = true
                startSafetyTimer(for: binding)
                binding.onStart()
            } else if !pressed && wasHolding {
                holdState[id] = false
                cancelSafetyTimer(for: id)
                binding.onStop()
            }

        case .toggle:
            let wasDown = wasModifierDown[id] ?? false
            if pressed && !wasDown {
                wasModifierDown[id] = true
                if let activeId = activeToggleModeId, activeId != id {
                    // Cross-mode stop via modifier key
                    toggleState[activeId] = false
                    activeToggleModeId = nil
                    onCrossModeStop?(id)
                } else {
                    let isOn = toggleState[id] ?? false
                    toggleState[id] = !isOn
                    if !isOn {
                        activeToggleModeId = id
                        binding.onStart()
                    } else {
                        activeToggleModeId = nil
                        binding.onStop()
                    }
                }
            } else if !pressed {
                wasModifierDown[id] = false
            }
        }
    }

    // MARK: - Safety Timer

    private func startSafetyTimer(for binding: ModeBinding) {
        cancelSafetyTimer(for: binding.modeId)
        let id = binding.modeId
        holdSafetyTimers[id] = Timer.scheduledTimer(
            timeInterval: maxHoldDuration,
            target: self,
            selector: #selector(handleHoldSafetyTimer(_:)),
            userInfo: id,
            repeats: false
        )
    }

    private func cancelSafetyTimer(for id: UUID) {
        holdSafetyTimers[id]?.invalidate()
        holdSafetyTimers[id] = nil
    }

    @objc
    private func handleHoldSafetyTimer(_ timer: Timer) {
        guard let id = timer.userInfo as? UUID else { return }
        guard holdState[id] == true else { return }
        guard let binding = bindings.first(where: { $0.modeId == id }) else { return }
        holdState[id] = false
        binding.onStop()
    }

    // MARK: - Stuck Hold Recovery

    private func recoverStuckHolds() {
        let currentFlags = CGEventSource.flagsState(.combinedSessionState)

        for binding in bindings where binding.style == .hold {
            let id = binding.modeId
            guard holdState[id] == true else { continue }

            // Mouse buttons: no API to query current state, rely on mouseUp events instead.
            // Safety timer will catch truly stuck mouse holds.
            if binding.isMouseButton { continue }

            let stillDown: Bool
            if isModifierKeyCode(binding.keyCode) {
                stillDown = isModifierPressed(keyCode: binding.keyCode, flags: currentFlags)
            } else {
                stillDown = CGEventSource.keyState(.combinedSessionState, key: binding.keyCode)
            }

            if !stillDown {
                holdState[id] = false
                cancelSafetyTimer(for: id)
                binding.onStop()
            }
        }
    }

    // MARK: - Helpers

    private func isModifierKeyCode(_ keyCode: CGKeyCode) -> Bool {
        [54, 55, 56, 58, 59, 60, 61, 62, 63].contains(keyCode)
    }

    private func normalizedModifierFlags(_ flags: CGEventFlags) -> CGEventFlags {
        flags.intersection([.maskCommand, .maskShift, .maskAlternate, .maskControl])
    }

    private func modifierEventFlag(for keyCode: CGKeyCode) -> CGEventFlags? {
        switch keyCode {
        case 54, 55: return .maskCommand
        case 56, 60: return .maskShift
        case 58, 61: return .maskAlternate
        case 59, 62: return .maskControl
        case 63: return .maskSecondaryFn
        default: return nil
        }
    }

    private func otherModifierFlags(for keyCode: CGKeyCode, flags: CGEventFlags) -> CGEventFlags {
        var mods = normalizedModifierFlags(flags)
        if let ownFlag = modifierEventFlag(for: keyCode) {
            mods.remove(ownFlag)
        }
        return mods
    }

    private func isModifierBindingActive(_ binding: ModeBinding) -> Bool {
        switch binding.style {
        case .hold:
            return holdState[binding.modeId] ?? false
        case .toggle:
            return wasModifierDown[binding.modeId] ?? false
        }
    }

    private func isModifierPressed(keyCode: CGKeyCode, flags: CGEventFlags) -> Bool {
        switch keyCode {
        case 54, 55: return flags.contains(.maskCommand)
        case 56, 60: return flags.contains(.maskShift)
        case 58, 61: return flags.contains(.maskAlternate)
        case 59, 62: return flags.contains(.maskControl)
        case 63: return flags.contains(.maskSecondaryFn)
        default: return false
        }
    }

    // MARK: - Deferred Modifier Binding

    /// Returns true if any combo binding includes this keyCode as a co-modifier.
    private func shouldDeferModifierBinding(forKeyCode keyCode: CGKeyCode) -> Bool {
        bindings.contains { other in
            isModifierKeyCode(other.keyCode)
                && other.coModifierKeyCodes.contains(keyCode)
        }
    }

    private func deferModifierBinding(_ binding: ModeBinding) {
        deferredModifierBinding = binding
        deferredModifierTimer?.invalidate()
        deferredModifierTimer = Timer.scheduledTimer(withTimeInterval: modifierDeferDelay, repeats: false) { [weak self] _ in
            self?.fireDeferredModifierBinding()
        }
    }

    private func fireDeferredModifierBinding() {
        guard let binding = deferredModifierBinding else { return }
        deferredModifierBinding = nil
        deferredModifierTimer?.invalidate()
        deferredModifierTimer = nil

        // If a combo mode is active and its combo includes this key,
        // pressing this key alone should stop it — not cross-mode switch.
        // e.g., Translation started via RightCmd+RightOption, pressing RightCmd alone stops it.
        if let activeId = activeToggleModeId, activeId != binding.modeId,
           let activeBinding = bindings.first(where: { $0.modeId == activeId }),
           activeBinding.coModifierKeyCodes.contains(binding.keyCode) {
            DebugFileLogger.log("hotkey deferred → stop active combo mode")
            toggleState[activeId] = false
            activeToggleModeId = nil
            wasModifierDown[activeId] = false
            activeBinding.onStop()
            return
        }

        DebugFileLogger.log("hotkey deferred fired keyCode=\(binding.keyCode)")
        handleBindingEvent(binding: binding, pressed: true)
    }

    private func cancelDeferredModifierBinding() {
        deferredModifierBinding = nil
        deferredModifierTimer?.invalidate()
        deferredModifierTimer = nil
    }
}

// MARK: - C callback

private func hotkeyCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let manager = Unmanaged<HotkeyManager>.fromOpaque(userInfo).takeUnretainedValue()
    return manager.handleEvent(type: type, event: event)
}
