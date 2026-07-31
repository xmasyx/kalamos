import AppKit
import SwiftUI

/// Hosts the setup flow in a real window.
///
/// Kalamos is an `LSUIElement` app: no Dock icon, no menu bar, normally no windows
/// at all. Such an app *can* show a window, but it does not reliably come to the
/// front or take keyboard focus — which for a setup screen is the difference
/// between "here is your first run" and a panel hidden behind the browser. So the
/// activation policy is switched to `.regular` for exactly as long as the window is
/// up, and put back afterwards. The Dock icon that appears meanwhile is not a leak;
/// on first run it is the only visible proof that the app you just installed exists.
@MainActor
final class OnboardingWindow: NSObject, NSWindowDelegate {
    static let shared = OnboardingWindow()
    private var window: NSWindow?

    func show(state: AppState, actions: OnboardingActions) {
        if let window {                       // already open — just surface it
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        // Wrap the caller's completion so the window always closes itself, however
        // the flow ends.
        var actions = actions
        let callerFinish = actions.finish
        actions.finish = { [weak self] in
            callerFinish()
            self?.dismiss()
        }

        let hosting = NSHostingController(
            rootView: OnboardingView(state: state, actions: actions))

        let w = NSWindow(contentViewController: hosting)
        w.title = "Welcome to Kalamos"
        w.styleMask = [.titled, .closable]
        w.titlebarAppearsTransparent = true
        w.backgroundColor = Theme.paperNS
        w.isMovableByWindowBackground = true
        w.isReleasedWhenClosed = false        // we hold the reference ourselves
        w.delegate = self
        w.center()
        window = w

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    /// Closing the window by any route — the button, the red dot, ⌘W — must leave
    /// the app back in its menu-bar-only life.
    func dismiss() {
        window?.delegate = nil
        window?.close()
        window = nil
        DispatchQueue.main.async { PreferencesWindow.restoreAccessoryPolicyIfIdle() }
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        // Not unconditionally `.accessory`: setup can be open on top of
        // Preferences (it is reachable from there), and the first window to close
        // must not push the other one behind every other app on the desk. The
        // check runs a turn later, when `isVisible` states a fact rather than an
        // intention.
        DispatchQueue.main.async { PreferencesWindow.restoreAccessoryPolicyIfIdle() }
    }
}
