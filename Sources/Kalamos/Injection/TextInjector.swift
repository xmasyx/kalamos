import AppKit
import ApplicationServices

/// Inserts text into whatever app is frontmost. Strategy: write to the
/// pasteboard and synthesize ⌘V, then restore the previous clipboard.
/// (CGEvent keystroke-typing fallback is Phase 2 — ISC-44.)
///
/// Requires Accessibility permission to post key events.
enum TextInjector {

    /// Bundle id of the app that will receive the text (for context-aware formatting).
    static func frontmostBundleID() -> String? {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }

    /// The text currently selected in the system-wide focused UI element, via
    /// Accessibility. nil when the focused app exposes no selection over AX
    /// (e.g. Electron/Chromium apps). Used by Edit Mode to capture the target
    /// text at the moment recording starts.
    static func selectedText() -> String? {
        let system = AXUIElementCreateSystemWide()
        var focused: AnyObject?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let element = focused else { return nil }
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element as! AXUIElement, kAXSelectedTextAttribute as CFString, &value) == .success
        else { return nil }
        let s = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (s?.isEmpty == false) ? s : nil
    }

    /// The characters immediately to the left of the cursor, as far back as
    /// `limit`, or nil when the focused app will not say.
    ///
    /// This is how "space between dictations" and "smart capitalization" know
    /// what they are continuing. Native apps answer; Electron and most terminals
    /// do not expose a selected range, and there the two settings degrade to
    /// their safe half rather than guessing.
    static func textBeforeCursor(limit: Int = 80) -> String? {
        let system = AXUIElementCreateSystemWide()
        var focused: AnyObject?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let element = focused else { return nil }
        let el = element as! AXUIElement

        var rangeValue: AnyObject?
        guard AXUIElementCopyAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success,
              let boxed = rangeValue, CFGetTypeID(boxed) == AXValueGetTypeID() else { return nil }
        var caret = CFRange()
        guard AXValueGetValue(boxed as! AXValue, .cfRange, &caret) else { return nil }

        let start = max(0, caret.location - limit)
        let length = caret.location - start
        guard length > 0 else { return "" }        // the cursor is at the very beginning

        var wanted = CFRange(location: start, length: length)
        guard let rangeArg = AXValueCreate(.cfRange, &wanted) else { return nil }
        var text: AnyObject?
        guard AXUIElementCopyParameterizedAttributeValue(
                el, kAXStringForRangeParameterizedAttribute as CFString, rangeArg, &text) == .success
        else { return nil }
        return text as? String
    }

    static func inject(_ text: String, mode: TextInsertionMode = .clipboard) {
        guard !text.isEmpty else { return }
        if mode == .typing {
            typeDirectly(text)
            return
        }
        let pb = NSPasteboard.general

        // Save current clipboard so we can restore it (ISC-43).
        let saved = pb.pasteboardItems?.compactMap { item -> (NSPasteboard.PasteboardType, Data)? in
            for type in item.types { if let d = item.data(forType: type) { return (type, d) } }
            return nil
        }

        pb.clearContents()
        pb.setString(text, forType: .string)

        paste()

        // Restore after a short delay so the paste completes first.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            pb.clearContents()
            if let saved, !saved.isEmpty {
                let item = NSPasteboardItem()
                for (type, data) in saved { item.setData(data, forType: type) }
                pb.writeObjects([item])
            }
        }
    }

    /// Type the text in as unicode key events, leaving the clipboard alone.
    ///
    /// `keyboardSetUnicodeString` sends characters rather than key codes, so it
    /// is independent of the keyboard layout and needs no pasteboard. Two details
    /// are not optional:
    ///
    ///  * **The flags are cleared.** The trigger key may still be physically
    ///    held when this runs, and a held Option or Command turns typed text into
    ///    shortcuts — a lesson this codebase already paid for once.
    ///  * **It goes out in small chunks.** A single event carrying a long string
    ///    is dropped or truncated by some apps; short bursts arrive intact.
    private static func typeDirectly(_ text: String) {
        let src = CGEventSource(stateID: .combinedSessionState)
        for chunk in Array(text).chunked(into: 16) {
            var utf16 = Array(String(chunk).utf16)
            for isDown in [true, false] {
                guard let event = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: isDown)
                else { continue }
                event.flags = []
                event.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
                event.post(tap: .cgAnnotatedSessionEventTap)
            }
        }
    }

    /// Synthesize ⌘V to the frontmost app.
    private static func paste() {
        let src = CGEventSource(stateID: .combinedSessionState)
        let vKey: CGKeyCode = 0x09   // kVK_ANSI_V
        let down = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cgAnnotatedSessionEventTap)
        up?.post(tap: .cgAnnotatedSessionEventTap)
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0 ..< Swift.min($0 + size, count)]) }
    }
}
