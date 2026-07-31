import AppKit
import SwiftUI

/// Hosts Preferences in a real window.
///
/// Same two problems as the setup window, and the same answers. Kalamos is an
/// `LSUIElement` app, so it has to become `.regular` for the window to come
/// forward and take the keyboard, and go back to `.accessory` afterwards or it
/// stays in the Dock forever — a bug Otium shipped and then found with a probe,
/// not with its eyes, because nothing about it looks wrong.
///
/// One thing setup did not need: a ceiling on the height. A window sized from
/// its content can be born taller than the screen, get centred, and leave its
/// own bottom edge below the desk. The limit is the *visible* frame, already net
/// of the menu bar and the Dock.
@MainActor
final class PreferencesWindow: NSObject, NSWindowDelegate {
    static let shared = PreferencesWindow()
    private var window: NSWindow?

    func show(state: AppState, actions: PreferencesActions) {
        if let window {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let hosting = NSHostingController(
            rootView: PreferencesView(state: state, actions: actions))
        let wanted = hosting.view.fittingSize
        let limit = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame.size
            ?? NSSize(width: 1200, height: 800)
        let size = NSSize(width: min(max(wanted.width, 720), limit.width - 40),
                          height: min(max(wanted.height, 520), limit.height - 40))

        let w = NSWindow(contentViewController: hosting)
        w.title = L.t("Preferenze di Kalamos", "Kalamos Preferences", "Préférences de Kalamos")
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        w.titlebarAppearsTransparent = true
        w.backgroundColor = NSColor(Theme.paper)
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.setContentSize(size)
        w.center()
        window = w

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        // The notification arrives BEFORE the window goes away, so the decision
        // has to be taken on the next turn of the loop, when `isVisible` tells
        // the truth instead of the intention.
        DispatchQueue.main.async { Self.restoreAccessoryPolicyIfIdle() }
    }

    /// Back to the menu bar — but only once nothing else of ours is on screen.
    /// Setup and Preferences can be open at the same time, and the one that
    /// closes first must not send the other's window to the back of the world.
    static func restoreAccessoryPolicyIfIdle() {
        let stillUp = NSApp.windows.contains {
            $0.isVisible && $0.canBecomeMain && !($0 is NSPanel)
        }
        if !stillUp { NSApp.setActivationPolicy(.accessory) }
    }
}
