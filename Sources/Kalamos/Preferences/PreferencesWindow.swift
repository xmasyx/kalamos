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
    private var deactivation: NSObjectProtocol?

    func show(state: AppState, actions: PreferencesActions,
              openAt: PreferencesView.Section = .dictation) {
        if let window {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            // **Si riapre sempre sulla PRIMA sezione, mai sull'ultima lasciata**
            // (sua richiesta del 19/08, «importante»). La finestra veniva solo
            // riportata davanti, e con lei restava selezionata la sezione di
            // prima: chi riapre le Preferenze si aspetta il posto da cui si
            // comincia, non quello dove aveva finito ieri.
            //
            // Il contenuto si ricostruisce da capo invece di essere ripristinato
            // a mano: la sezione vive in uno `@State` dentro `PreferencesView`, e
            // SwiftUI conserva lo stato finché la vista ha la stessa identità.
            // Assegnare un controller NUOVO è l'unico modo per cui quell'`@State`
            // riparte dal suo valore iniziale, che è `openAt`.
            window.contentViewController = NSHostingController(
                rootView: PreferencesView(state: state, actions: actions, openAt: openAt))
            window.makeKeyAndOrderFront(nil)
            return
        }

        let hosting = NSHostingController(
            rootView: PreferencesView(state: state, actions: actions, openAt: openAt))
        let wanted = hosting.view.fittingSize
        let limit = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame.size
            ?? NSSize(width: 1200, height: 800)
        let size = NSSize(width: min(max(wanted.width, 780), limit.width - 40),
                          height: min(max(wanted.height, 520), limit.height - 40))

        let w = NSWindow(contentViewController: hosting)
        w.title = L.t("Preferenze di Kalamos", "Kalamos Preferences", "Préférences de Kalamos")
        // It goes BEHIND, like any other window. It does not go away.
        //
        // This was `true` from 2026-08-01 to 2026-08-02, and that was too blunt
        // by half. The report it answered was specific: open Preferences while a
        // terminal is full-screen, click back on the terminal, and the window is
        // still there — sitting on top of a full-screen app that is supposed to
        // own the whole screen. macOS places a window shown during someone's
        // full-screen space INTO that space, and there it stays above its host.
        //
        // `hidesOnDeactivate` fixed that case and broke the ordinary one: click
        // any other app, in any normal window, and the settings you were reading
        // vanished. "I wanted it to stay open, it should simply go to the back"
        // — his words, 2026-08-02. So the flag is off, and the disappearing act
        // is now scoped to the only situation that asked for it, below.
        w.hidesOnDeactivate = false
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        w.titlebarAppearsTransparent = true
        w.backgroundColor = Theme.paperNS
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.setContentSize(size)
        w.center()
        window = w

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        // One line per opening, and it is the evidence for the line above: if a
        // refactor ever un-sets `hidesOnDeactivate`, the window quietly goes back
        // to sitting on top of full-screen apps and nothing else would say so.
        Log.write("preferences window: level=\(w.level.rawValue)"
                  + " hidesOnDeactivate=\(w.hidesOnDeactivate)")

        // The narrow version of what the flag used to do bluntly: step out of the
        // way ONLY when this window is sitting inside another app's full-screen
        // space. Everywhere else it stays where you left it.
        deactivation = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.hideIfInsideAFullScreenSpace() }
            }
    }

    /// Whether the window is currently living in a space with no menu bar, which
    /// is what someone else's full-screen space looks like from in here.
    ///
    /// A heuristic, and named as one: AppKit will not say whose space a window is
    /// in. In an ordinary space the menu bar eats the top of `visibleFrame`; in a
    /// full-screen space it does not. The cost of it being wrong is that the
    /// window stays visible when it might have stepped aside — the old behaviour,
    /// not a new failure.
    private func hideIfInsideAFullScreenSpace() {
        guard let window, window.isVisible, let screen = window.screen else { return }
        let menuBarInset = screen.frame.maxY - screen.visibleFrame.maxY
        guard menuBarInset < 1 else { return }
        Log.write("preferences window: inside a full-screen space — stepping aside")
        window.orderOut(nil)
    }

    func windowWillClose(_ notification: Notification) {
        if let deactivation { NotificationCenter.default.removeObserver(deactivation) }
        deactivation = nil
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
