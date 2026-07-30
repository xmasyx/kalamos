import AppKit

/// Installs a global `CGEventTap` for the configured key and feeds its
/// down/up events into a `GestureRecognizer`. Supports BOTH regular keys
/// (keyDown/keyUp) and modifier keys like Right Option (flagsChanged) — the
/// default trigger is a modifier, which is ideal for push-to-talk because it
/// doesn't conflict with normal typing.
///
/// Requires Accessibility permission (see `Permissions`).
final class HotkeyManager {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var pollTimer: Timer?

    private let recognizer: GestureRecognizer
    private var keyCode: UInt16

    var onAction: ((DictationAction) -> Void)? {
        get { recognizer.onAction }
        set { recognizer.onAction = newValue }
    }

    /// Fired on the global "learn selected word" shortcut (⌃⌥L).
    var onLearn: (() -> Void)?

    init(keyCode: UInt16, recognizer: GestureRecognizer = GestureRecognizer()) {
        self.keyCode = keyCode
        self.recognizer = recognizer
    }

    /// Modifier keyCodes → the flag that is set while they're held.
    static let modifierMasks: [UInt16: CGEventFlags] = [
        0x37: .maskCommand, 0x36: .maskCommand,        // L/R Command
        0x38: .maskShift,   0x3C: .maskShift,          // L/R Shift
        0x3A: .maskAlternate, 0x3D: .maskAlternate,    // L/R Option
        0x3B: .maskControl, 0x3E: .maskControl,        // L/R Control
        0x3F: .maskSecondaryFn,                        // Fn / Globe
    ]

    static func displayName(for keyCode: UInt16) -> String {
        switch keyCode {
        case 0x3D: return "Right Option"
        case 0x3A: return "Left Option"
        case 0x36: return "Right Command"
        case 0x37: return "Left Command"
        case 0x3E: return "Right Control"
        case 0x3B: return "Left Control"
        case 0x3C: return "Right Shift"
        case 0x3F: return "Fn / Globe"
        case 0x31: return "Space"
        default:   return "key \(keyCode)"
        }
    }

    private var modifierMask: CGEventFlags? { Self.modifierMasks[keyCode] }

    @discardableResult
    func start() -> Bool {
        var mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        if modifierMask != nil { mask |= (1 << CGEventType.flagsChanged.rawValue) }

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            let mgr = Unmanaged<HotkeyManager>.fromOpaque(refcon!).takeUnretainedValue()
            return mgr.handle(type: type, event: event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return false
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            self?.recognizer.tick(at: ProcessInfo.processInfo.systemUptime)
        }
        return true
    }

    func stop() {
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let src = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes) }
        pollTimer?.invalidate()
        pollTimer = nil
        eventTap = nil
        runLoopSource = nil
    }

    func updateKeyCode(_ newCode: UInt16) { keyCode = newCode }

    /// Forward the trigger mode to the recognizer (menu, setup, launch).
    func setMode(_ mode: TriggerMode) { recognizer.setMode(mode) }

    /// Temporarily enable/disable the tap — used while posting synthetic ⌘C so
    /// our own active tap can't interfere with the events we inject.
    func setTapEnabled(_ on: Bool) {
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: on) }
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let now = ProcessInfo.processInfo.systemUptime

        // Escape while recording = discard it. Checked before every other branch
        // so it works with both trigger styles, and above all hands-free, where
        // there was previously no way to abandon a dictation you had changed your
        // mind about. Swallowed ONLY when something was actually cancelled, so
        // Escape keeps its normal job in every other situation.
        if type == .keyDown, code == 0x35 {   // kVK_Escape
            return recognizer.cancel() ? nil : Unmanaged.passUnretained(event)
        }

        // Global "learn selected word" shortcut: Control+Option+L (works in any
        // app — the handler copies the selection via the clipboard).
        if type == .keyDown, code == 0x25,   // kVK_ANSI_L
           event.flags.contains(.maskControl), event.flags.contains(.maskAlternate) {
            onLearn?()
            return nil   // consume
        }

        // Modifier-key trigger (default): use flagsChanged. Never consume — a
        // bare modifier does nothing in other apps, and consuming it would
        // corrupt system modifier state.
        if let modifierMask {
            if type == .flagsChanged, code == keyCode {
                if event.flags.contains(modifierMask) { recognizer.keyDown(at: now) }
                else { recognizer.keyUp(at: now) }
            } else if type == .keyDown, code != keyCode {
                // A normal key pressed while the trigger is held → it's a
                // shortcut or a capital letter, not dictation. Abort.
                recognizer.abort()
            }
            return Unmanaged.passUnretained(event)
        }

        // Regular-key trigger.
        guard modifierMask == nil, code == keyCode else {
            return Unmanaged.passUnretained(event)
        }
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        switch type {
        case .keyDown where !isRepeat: recognizer.keyDown(at: now)
        case .keyUp: recognizer.keyUp(at: now)
        default: break
        }
        // Swallow the key only while a dictation gesture is active.
        switch recognizer.state {
        case .idle, .awaitingSecondTap, .holdingAborted: return Unmanaged.passUnretained(event)
        case .holding, .toggleListening: return nil
        }
    }
}
