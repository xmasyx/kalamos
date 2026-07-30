import SwiftUI
import AVFoundation

/// The side effects a setting change needs beyond writing it down.
///
/// Changing the trigger key means re-registering a global event tap; changing the
/// trigger mode means telling the live recogniser. That plumbing belongs to the
/// AppDelegate, which owns those objects — so setup asks for it rather than
/// reaching for it, and the menu and this screen cannot drift apart.
struct OnboardingActions {
    var applyTriggerKey: (UInt16) -> Void
    var applyTriggerMode: (TriggerMode) -> Void
    var openMicrophoneSettings: () -> Void
    var openAccessibilitySettings: () -> Void
    var finish: () -> Void
}

/// First-run setup: six questions, then you are done.
///
/// It exists for one failure in particular. Without it someone installs Kalamos,
/// presses the key, and *nothing happens* — macOS has not been asked for
/// Accessibility yet — with no way to find out why. Every other question here is a
/// convenience; the permissions step is the reason.
///
/// The language question comes first, and the rest of the flow is written in
/// whatever it answers. Explaining an app in a language the reader may not have is
/// a strange way to begin.
struct OnboardingView: View {
    @ObservedObject var state: AppState
    let actions: OnboardingActions

    @State private var step = 0
    @State private var ui: Language = Self.systemLanguage
    @State private var micGranted = Permissions.microphoneAuthorized
    @State private var axGranted = Permissions.accessibilityTrusted(prompt: false)

    private let questionCount = 6
    private let poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(step < questionCount
                 ? t("Passo \(step + 1) di \(questionCount)",
                     "Step \(step + 1) of \(questionCount)",
                     "Étape \(step + 1) sur \(questionCount)")
                 : t("Pronto", "Ready", "Prêt"))
                .font(Theme.font(11, .bold))
                .tracking(1.6)
                .foregroundStyle(Theme.pen)
                .padding(.bottom, 14)

            content
            Spacer(minLength: 20)
            footer
        }
        .padding(28)
        .frame(width: 540, height: 452, alignment: .topLeading)
        .background(Theme.paper)
        .onReceive(poll) { _ in
            guard step == 5 else { return }   // only while the permissions step is up
            micGranted = Permissions.microphoneAuthorized
            axGranted = Permissions.accessibilityTrusted(prompt: false)
        }
    }

    /// The flow's own language. Set by the first question; defaults to whatever the
    /// Mac is already set to, so even the first screen usually reads correctly.
    private static var systemLanguage: Language {
        switch Locale.preferredLanguages.first?.prefix(2).lowercased() {
        case "it": return .italian
        case "fr": return .french
        default:   return .english
        }
    }

    private func t(_ it: String, _ en: String, _ fr: String) -> String {
        switch ui {
        case .italian: return it
        case .french:  return fr
        case .english: return en
        }
    }

    // MARK: Steps

    @ViewBuilder private var content: some View {
        switch step {
        case 0: languageStep
        case 1: triggerKeyStep
        case 2: triggerModeStep
        case 3: cleanupStep
        case 4: memoryStep
        case 5: permissionsStep
        default: doneStep
        }
    }

    /// First, because everything after it is written in the answer.
    private var languageStep: some View {
        question(t("In che lingua detti?", "Which language do you dictate in?",
                   "Dans quelle langue dictez-vous ?"),
                 t("Sceglila anche se ne parli più di una: fissarla è più preciso che farla indovinare a ogni frase.",
                   "Pick one even if you speak several: fixing the language is more accurate than having it guessed at every sentence.",
                   "Choisissez-en une même si vous en parlez plusieurs : fixer la langue est plus précis que la faire deviner à chaque phrase.")) {
            grid([
                (1, "Italiano", ""),
                (2, "English", ""),
                (3, "Français", ""),
                (0, t("Riconoscila da sola", "Detect it automatically", "La détecter"),
                    t("se cambi lingua di continuo", "if you switch languages all day",
                      "si vous changez souvent")),
            ], selected: { choice in
                choice == 0 ? state.autoDetectLanguage
                            : !state.autoDetectLanguage && state.defaultLanguage == Self.language(choice)
            }, pick: { choice in
                if choice == 0 {
                    state.autoDetectLanguage = true
                } else {
                    state.autoDetectLanguage = false
                    state.defaultLanguage = Self.language(choice)
                    ui = Self.language(choice)
                }
            })
        }
    }

    private var triggerKeyStep: some View {
        question(t("Quale tasto avvia la dettatura?", "Which key starts dictation?",
                   "Quelle touche lance la dictée ?"),
                 t("Scegline uno che non usi già per altro.",
                   "Pick one you do not already use for something else.",
                   "Choisissez-en une que vous n'utilisez pas déjà.")) {
            grid([
                (0x36, t("Comando destro", "Right Command", "Commande droite"),
                       t("libero su quasi tutti i Mac", "free on most Macs", "libre sur presque tous les Mac")),
                (0x3D, t("Opzione destra", "Right Option", "Option droite"),
                       t("se non la usi per gli accenti", "if you do not type accents with it",
                         "si vous ne tapez pas d'accents avec")),
                (0x3F, "Fn / Globe", t("se non è rimappato", "unless it is remapped",
                                       "sauf s'il est remappé")),
                (0x3E, t("Controllo destro", "Right Control", "Contrôle droit"),
                       t("raro sui portatili", "rare on laptops", "rare sur les portables")),
            ], selected: { state.hotKeyCode == UInt16($0) },
               pick: { actions.applyTriggerKey(UInt16($0)) })
        }
    }

    /// Three genuine modes. There used to be two, with hands-free tucked under
    /// hold-to-talk as though it were an afterthought — and "hold only" did not
    /// exist at all, so the key could always be double-tapped into an open
    /// microphone whether you wanted that or not.
    private var triggerModeStep: some View {
        question(t("Come vuoi usarlo?", "How do you want to use it?",
                   "Comment voulez-vous l'utiliser ?"),
                 t("Tenerlo premuto è preciso e non lascia mai il microfono aperto. Il doppio tocco serve per parlare a lungo senza tenere il dito giù.",
                   "Holding is precise and never leaves the microphone open. Double-tap is for talking at length without keeping a finger down.",
                   "Maintenir est précis et ne laisse jamais le micro ouvert. Le double-appui sert à parler longtemps sans garder le doigt appuyé.")) {
            grid([
                (0, t("Tieni premuto", "Hold to talk", "Maintenir"),
                    t("un tocco non fa nulla", "a tap does nothing", "un appui ne fait rien")),
                (1, t("Doppio tocco", "Double-tap", "Double-appui"),
                    t("a mani libere, ritocchi per fermare", "hands-free, tap again to stop",
                      "mains libres, réappuyez pour arrêter")),
                (2, t("Tutti e due", "Both", "Les deux"),
                    t("tieni premuto, o doppio tocco", "hold, or double-tap", "maintenir, ou double-appui")),
            ], selected: { state.triggerMode == Self.mode($0) },
               pick: { actions.applyTriggerMode(Self.mode($0)) })
        }
    }

    private var cleanupStep: some View {
        question(t("Deve sistemare quello che dici?", "Should it tidy up what you say?",
                   "Doit-il corriger ce que vous dites ?"),
                 t("Il modello locale mette la punteggiatura, toglie gli intercalari e risolve le frasi che lasci a metà. Si scarica una volta, circa 4 GB, e non esce mai dal tuo Mac.",
                   "The local model adds punctuation, drops filler and resolves the sentences you abandon halfway. It downloads once, about 4 GB, and never leaves your Mac.",
                   "Le modèle local ponctue, retire les hésitations et résout les phrases abandonnées. Il se télécharge une fois, environ 4 Go, et ne quitte jamais votre Mac.")) {
            grid([
                (1, t("Sì, usa il modello", "Yes, use the model", "Oui, utiliser le modèle"),
                    t("~4 GB, una volta sola", "~4 GB, once", "~4 Go, une seule fois")),
                (0, t("Solo regole", "Rules only", "Règles seulement"),
                    t("istantaneo, niente da scaricare", "instant, nothing to download",
                      "instantané, rien à télécharger")),
            ], selected: { state.formatterMode == ($0 == 1 ? .localLLM : .ruleBased) },
               pick: { state.formatterMode = $0 == 1 ? .localLLM : .ruleBased })
        }
    }

    /// One minute is gone: it reloaded the model constantly for a saving nobody
    /// noticed. What is left are the three answers that correspond to real
    /// situations, and the situations are spelled out.
    private var memoryStep: some View {
        question(t("Quando deve restituire la memoria?", "When should it give the memory back?",
                   "Quand doit-il rendre la mémoire ?"),
                 t("I modelli occupano circa 6 GB mentre sono carichi, e si ricaricano in un secondo.",
                   "The models hold about 6 GB while loaded, and reload in about a second.",
                   "Les modèles occupent environ 6 Go une fois chargés, et se rechargent en une seconde.")) {
            grid([
                (300, t("Dopo 5 minuti", "After 5 minutes", "Après 5 minutes"),
                      t("con 8 o 16 GB di RAM", "on 8 or 16 GB of RAM", "avec 8 ou 16 Go de RAM")),
                (900, t("Dopo 15 minuti", "After 15 minutes", "Après 15 minutes"),
                      t("se detti spesso nella giornata", "if you dictate through the day",
                        "si vous dictez toute la journée")),
                (0, t("Mai", "Never", "Jamais"),
                    t("da 32 GB in su: sempre pronto", "32 GB and up: always ready",
                      "à partir de 32 Go : toujours prêt")),
            ], selected: { Tuning.idleUnloadRaw == $0 }, pick: { Tuning.setIdleUnload($0) })
        }
    }

    private var permissionsStep: some View {
        question(t("Due permessi, e funziona", "Two permissions, and it works",
                   "Deux autorisations, et c'est prêt"),
                 t("Li concede macOS, non Kalamos. Senza il secondo il tasto non fa assolutamente nulla — ed è il motivo per cui quasi tutti pensano che sia rotto.",
                   "macOS grants these, not Kalamos. Without the second one the key does nothing at all — which is why most people think it is broken.",
                   "C'est macOS qui les accorde, pas Kalamos. Sans la seconde, la touche ne fait rien du tout.")) {
            VStack(alignment: .leading, spacing: 9) {
                permissionRow(granted: micGranted,
                              title: t("Microfono", "Microphone", "Microphone"),
                              why: t("per sentirti", "to hear you", "pour vous entendre"),
                              action: actions.openMicrophoneSettings)
                permissionRow(granted: axGranted,
                              title: t("Accessibilità", "Accessibility", "Accessibilité"),
                              why: t("per leggere il tasto e scrivere nelle altre app",
                                     "to read the hot key and type into other apps",
                                     "pour lire la touche et écrire dans les autres apps"),
                              action: actions.openAccessibilitySettings)
                Text(t("L'interruttore può metterci un momento a fare effetto.",
                       "The switch may take a moment to register.",
                       "L'interrupteur peut mettre un instant à prendre effet."))
                    .font(Theme.font(11.5))
                    .foregroundStyle(Theme.inkFaded)
            }
        }
    }

    private var doneStep: some View {
        question(t("Ecco fatto.", "That's it.", "Voilà."), "") {
            VStack(alignment: .leading, spacing: 11) {
                Text(Self.howToUse(state.triggerMode,
                                   HotkeyManager.displayName(for: state.hotKeyCode), ui))
                    .font(Theme.font(15))
                    .foregroundStyle(Theme.ink)
                Text(t("Cambiato idea a metà frase? Premi Esc e la registrazione viene buttata.",
                       "Changed your mind mid-sentence? Press Escape and the recording is thrown away.",
                       "Changé d'avis en cours de phrase ? Appuyez sur Échap et l'enregistrement est jeté."))
                    .font(Theme.font(13))
                    .foregroundStyle(Theme.inkFaded)
                Text(t("Tutto quello che hai scelto sta nell'icona in alto, insieme al vocabolario, alle correzioni e a Diagnostics… se qualcosa non va.",
                       "Everything you chose is in the menu-bar icon, along with the vocabulary, the correction rules, and Diagnostics… if anything misbehaves.",
                       "Tout cela se retrouve dans l'icône de la barre de menus, avec le vocabulaire, les corrections et Diagnostics…"))
                    .font(Theme.font(13))
                    .foregroundStyle(Theme.inkFaded)
            }
        }
    }

    // MARK: Pieces

    private func question<Content: View>(
        _ title: String, _ hint: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(Theme.font(21, .semibold))
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            if !hint.isEmpty {
                Text(hint)
                    .font(Theme.font(13))
                    .foregroundStyle(Theme.inkFaded)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
            }
            content().padding(.top, 18)
        }
    }

    private func grid(_ items: [(Int, String, String)],
                      selected: @escaping (Int) -> Bool,
                      pick: @escaping (Int) -> Void) -> some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10),
                            GridItem(.flexible(), spacing: 10)], spacing: 10) {
            ForEach(items, id: \.0) { value, title, note in
                choice(title: title, note: note, on: selected(value)) { pick(value) }
            }
        }
    }

    private func choice(title: String, note: String, on: Bool,
                        act: @escaping () -> Void) -> some View {
        Button(action: act) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Theme.font(13.5, .medium)).foregroundStyle(Theme.ink)
                // Always present, even when empty: without it a tile with a note is
                // taller than one without, and a row of choices that do not line up
                // reads as a mistake rather than as a set.
                Text(note.isEmpty ? " " : note)
                    .font(Theme.font(11.5))
                    .foregroundStyle(Theme.inkFaded)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, minHeight: 34, alignment: .topLeading)
            .padding(.horizontal, 13).padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 8)
                .fill(on ? Theme.penWash : Color.white.opacity(0.55)))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .strokeBorder(on ? Theme.pen : Theme.rule, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(note.isEmpty ? title : "\(title), \(note)")
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
    }

    private func permissionRow(granted: Bool, title: String, why: String,
                               action: @escaping () -> Void) -> some View {
        HStack(spacing: 11) {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(granted ? Theme.pen : Theme.rule)
                .font(.system(size: 16))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(Theme.font(13.5, .medium)).foregroundStyle(Theme.ink)
                Text(why).font(Theme.font(11.5)).foregroundStyle(Theme.inkFaded)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if !granted {
                Button(t("Apri", "Open", "Ouvrir"), action: action)
                    .font(Theme.font(12, .medium))
                    .buttonStyle(.plain)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Theme.penWash))
                    .foregroundStyle(Theme.pen)
            }
        }
        .padding(.horizontal, 13).padding(.vertical, 11)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.55)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.rule, lineWidth: 1.5))
    }

    private var footer: some View {
        HStack {
            HStack(spacing: 5) {
                ForEach(0..<questionCount, id: \.self) { i in
                    Circle()
                        .fill(i == step ? Theme.pen : Theme.rule)
                        .frame(width: 6, height: 6)
                }
            }
            Spacer()
            if step > 0 {
                Button(t("Indietro", "Back", "Retour")) { step -= 1 }
                    .buttonStyle(.plain)
                    .font(Theme.font(13, .medium))
                    .foregroundStyle(Theme.inkFaded)
                    .padding(.trailing, 6)
                    .accessibilityLabel(t("Indietro", "Back", "Retour"))
            }
            let label = step < questionCount
                ? t("Avanti", "Continue", "Continuer")
                : t("Inizia a dettare", "Start dictating", "Commencer")
            Button(label) {
                if step < questionCount { step += 1 } else { actions.finish() }
            }
            .buttonStyle(.plain)
            .font(Theme.font(13, .semibold))
            .foregroundStyle(Theme.paper)
            .padding(.horizontal, 20).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 7).fill(Theme.pen))
            .keyboardShortcut(.defaultAction)
            .accessibilityLabel(label)
        }
    }

    // MARK: Mapping

    private static func language(_ choice: Int) -> Language {
        switch choice {
        case 1: return .italian
        case 3: return .french
        default: return .english
        }
    }

    private static func mode(_ choice: Int) -> TriggerMode {
        switch choice {
        case 0: return .hold
        case 1: return .doubleTap
        default: return .both
        }
    }

    private static func howToUse(_ mode: TriggerMode, _ key: String, _ ui: Language) -> String {
        switch (mode, ui) {
        case (.doubleTap, .italian): return "Tocca due volte \(key) e parla. Ritocca per fermare."
        case (.doubleTap, .french):  return "Appuyez deux fois sur \(key) et parlez. Réappuyez pour arrêter."
        case (.doubleTap, .english): return "Double-tap \(key) and speak. Tap again to stop."
        case (.hold, .italian): return "Tieni premuto \(key) e parla. Lascia, e il testo compare dove sei."
        case (.hold, .french):  return "Maintenez \(key) et parlez. Relâchez, le texte apparaît au curseur."
        case (.hold, .english): return "Hold \(key) and speak. Release, and the text lands at your cursor."
        case (.both, .italian): return "Tieni premuto \(key) e parla — oppure toccalo due volte per le mani libere."
        case (.both, .french):  return "Maintenez \(key) et parlez — ou appuyez deux fois pour les mains libres."
        case (.both, .english): return "Hold \(key) and speak — or double-tap it to go hands-free."
        }
    }
}
