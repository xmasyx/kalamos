import AppKit
import SwiftUI

/// The ⌃⌥V panel: the last dictation, as it came out, for you to fix.
///
/// Same paper, same buttons and the same window discipline as ⌃⌥K, for the same
/// reason — an app whose every other screen is its own would look borrowed on
/// the one screen that asks you for something.
///
/// What makes it a different panel and not a wider `CorrectionWindow`: a
/// correction is two short words and can live on one line, while this is a whole
/// transcript that has to be readable and editable in place. The gesture is read
/// it, fix the words that are wrong, save.
@MainActor
final class TruthWindow: NSObject, NSWindowDelegate {
    static let shared = TruthWindow()
    private var window: NSWindow?

    func show(raw: String, save: @escaping (String) -> Void) {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let hosting = NSHostingController(rootView: TruthView(
            raw: raw,
            save: { [weak self] verbatim in
                save(verbatim)
                self?.dismiss()
            },
            cancel: { [weak self] in self?.dismiss() }))

        let w = NSWindow(contentViewController: hosting)
        w.title = L.t("Che cosa avevi detto", "What you actually said", "Ce que vous aviez dit")
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

/// One field, big enough to read a paragraph in.
struct TruthView: View {
    @State private var verbatim: String
    @FocusState private var focused: Bool

    /// What the app had written, kept so Save can tell an untouched panel from a
    /// corrected one. Saving a transcript nobody edited would archive a guess
    /// under the heading that means "this part is true".
    private let original: String

    let save: (String) -> Void
    let cancel: () -> Void

    init(raw: String, save: @escaping (String) -> Void, cancel: @escaping () -> Void) {
        _verbatim = State(initialValue: raw)
        original = raw
        self.save = save
        self.cancel = cancel
    }

    private var changed: Bool {
        verbatim.trimmingCharacters(in: .whitespacesAndNewlines)
            != original.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var ready: Bool {
        !verbatim.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && changed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text(L.t("Correggi le parole sbagliate, parola per parola",
                         "Fix the words it got wrong, word for word",
                         "Corrigez les mots erronés, mot à mot"))
                    .font(Theme.font(14, .semibold))
                    .foregroundStyle(Theme.ink)
                Text(L.t("Scrivi quello che avevi detto davvero, senza sistemare la forma: serve a insegnare, e resta su questo Mac.",
                         "Write what you actually said, without tidying it up: this is teaching material, and it stays on this Mac.",
                         "Écrivez ce que vous aviez réellement dit, sans corriger le style : c’est du matériel d’apprentissage, et il reste sur ce Mac."))
                    .font(Theme.font(12))
                    .foregroundStyle(Theme.inkFaded)
                    .fixedSize(horizontal: false, vertical: true)
            }

            TextEditor(text: $verbatim)
                .textEditorStyle(.plain)
                .scrollContentBackground(.hidden)
                .font(Theme.font(13))
                .foregroundStyle(Theme.ink)
                .focused($focused)
                .frame(height: 150)
                .padding(.horizontal, 8).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 7).fill(Theme.card))
                .overlay(RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(focused ? Theme.pen : Theme.rule, lineWidth: 1.5))

            HStack(spacing: 10) {
                Spacer()
                PrefButton(title: L.t("Annulla", "Cancel", "Annuler")) { cancel() }
                PrefButton(title: L.t("Salva", "Save", "Enregistrer"), filled: true) { commit() }
                    .opacity(ready ? 1 : 0.45)
                    .disabled(!ready)
            }
        }
        .padding(24)
        .frame(width: 520)
        .background(Theme.paper)
        .onAppear { focused = true }
        .onExitCommand { cancel() }
    }

    private func commit() {
        guard ready else { NSSound(named: "Funk")?.play(); return }
        save(verbatim.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
