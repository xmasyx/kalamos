import AppKit
import SwiftUI

/// The ⌃⌥K panel — paper, ink and the app's own buttons.
///
/// It began as an `NSAlert`, which was the fast way to get a modal with Enter
/// and Escape already wired. It also looked like a system error dialog: grey
/// sheet, system font, a stock app icon, two grey buttons. Everything else the
/// app shows is written on Kalamos's paper, so the one screen you reach a dozen
/// times a day was the one that looked borrowed.
///
/// Same window discipline as setup and Preferences: `.regular` while it is up so
/// an `LSUIElement` app can actually take the keyboard, back to `.accessory`
/// when nothing of ours is left on screen.
@MainActor
final class CorrectionWindow: NSObject, NSWindowDelegate {
    static let shared = CorrectionWindow()
    private var window: NSWindow?

    /// `heard` is the half we could read off the screen; it may be empty.
    /// `written` is only ever filled by the `--correzione` probe, so the state
    /// where the Add button is live can be photographed.
    func show(heard: String, written: String = "", add: @escaping (String, String) -> Void) {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let hosting = NSHostingController(rootView: CorrectionView(
            heard: heard, written: written,
            add: { [weak self] wrong, correct in
                add(wrong, correct)
                self?.dismiss()
            },
            cancel: { [weak self] in self?.dismiss() }))

        let w = NSWindow(contentViewController: hosting)
        w.title = L.t("Aggiungi una correzione", "Add a correction", "Ajouter une correction")
        w.styleMask = [.titled, .closable]
        w.titlebarAppearsTransparent = true
        w.backgroundColor = Theme.paperNS
        w.isMovableByWindowBackground = true
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.center()
        window = w

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    func dismiss() {
        window?.delegate = nil
        window?.close()
        window = nil
        DispatchQueue.main.async { PreferencesWindow.restoreAccessoryPolicyIfIdle() }
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        DispatchQueue.main.async { PreferencesWindow.restoreAccessoryPolicyIfIdle() }
    }
}

/// Two fields and a sentence. Nothing else belongs on this screen.
struct CorrectionView: View {
    @State private var wrong: String
    @State private var correct: String
    /// Which field the cursor starts in: the half we do NOT already know.
    @FocusState private var focus: Field?
    private let startedFilled: Bool

    let add: (String, String) -> Void
    let cancel: () -> Void

    enum Field { case wrong, correct }

    init(heard: String, written: String = "",
         add: @escaping (String, String) -> Void, cancel: @escaping () -> Void) {
        _wrong = State(initialValue: heard)
        _correct = State(initialValue: written)
        startedFilled = !heard.isEmpty
        self.add = add
        self.cancel = cancel
    }

    private var ready: Bool {
        !wrong.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !correct.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text(L.t("Quando sente questa, scrive quest'altra",
                         "When it hears this, it writes that",
                         "Quand il entend ceci, il écrit cela"))
                    .font(Theme.font(14, .semibold))
                    .foregroundStyle(Theme.ink)
                Text(L.t("Vale dalla prossima dettatura. Il testo già scritto non cambia.",
                         "Applies from the next dictation on. Text already written does not change.",
                         "S’applique dès la prochaine dictée. Le texte déjà écrit ne change pas."))
                    .font(Theme.font(12))
                    .foregroundStyle(Theme.inkFaded)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                field(L.t("sente…", "hears…", "entend…"), text: $wrong, which: .wrong)
                Text("→").font(Theme.font(14)).foregroundStyle(Theme.inkFaded)
                field(L.t("…scrive", "…writes", "…écrit"), text: $correct, which: .correct)
            }

            HStack(spacing: 10) {
                Spacer()
                PrefButton(title: L.t("Annulla", "Cancel", "Annuler")) { cancel() }
                PrefButton(title: L.t("Aggiungi", "Add", "Ajouter"), filled: true) { commit() }
                    .opacity(ready ? 1 : 0.45)
                    .disabled(!ready)
            }
        }
        .padding(24)
        .frame(width: 460)
        .background(Theme.paper)
        .onAppear { focus = startedFilled ? .correct : .wrong }
        // Escape closes it. A panel you can only leave with the mouse is a panel
        // that interrupts twice.
        .onExitCommand { cancel() }
    }

    private func commit() {
        guard ready else { NSSound(named: "Funk")?.play(); return }
        add(wrong.trimmingCharacters(in: .whitespacesAndNewlines),
            correct.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Same field as Preferences — and `onSubmit`, so Enter finishes the job from
    /// either half instead of only from the button.
    private func field(_ placeholder: String, text: Binding<String>, which: Field) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .font(Theme.font(13))
            .focused($focus, equals: which)
            .onSubmit {
                if which == .wrong && correct.isEmpty { focus = .correct } else { commit() }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 7).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 7)
                .strokeBorder(focus == which ? Theme.pen : Theme.rule, lineWidth: 1.5))
            .frame(maxWidth: .infinity)
    }
}
