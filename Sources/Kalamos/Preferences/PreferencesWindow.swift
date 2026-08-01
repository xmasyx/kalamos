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

    func show(state: AppState, actions: PreferencesActions,
              openAt: PreferencesView.Section = .dictation) {
        if let window {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
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
        // Goes away when Kalamos is not the app you are using.
        //
        // Reported 2026-08-01: open Preferences while a terminal is full-screen,
        // click back on the terminal, and the window is still there — sitting on
        // top of a full-screen app that is supposed to own the whole screen.
        // Nothing is floating: the window is level 0 with no collection
        // behaviour set, measured. That is just what macOS does — a window shown
        // while another app is full-screen is placed INTO that space, and once
        // there it stays above its host until the space changes.
        //
        // For an app with a Dock icon that would be wrong; for a menu-bar app it
        // is the ordinary answer, and the one the platform gives us. Coming back
        // is the menu-bar item, or the Dock icon that exists while the window is
        // open (the policy is `.regular` for exactly that stretch).
        w.hidesOnDeactivate = true
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
