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

    static func inject(_ text: String) {
        guard !text.isEmpty else { return }
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
