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
    var requestMicrophone: (@escaping (Bool) -> Void) -> Void
    var requestAccessibility: () -> Void
    var openMicrophoneSettings: () -> Void
    var finish: () -> Void
}

/// First-run setup.
///
/// It exists for one failure in particular. Without it someone installs Kalamos,
/// presses the key, and *nothing happens* — macOS was never asked for
/// Accessibility — with no way to find out why. Every other question here is a
/// convenience; the permissions step is the reason.
///
/// The interface language is asked first, and everything after it is written in
/// that answer. Explaining an app in a language the reader may not have is a
/// strange way to begin.
struct OnboardingView: View {
    @ObservedObject var state: AppState
    let actions: OnboardingActions

    @State private var step = 0
    @State private var ui: Language = Self.systemLanguage
    @State private var micGranted = Permissions.microphoneAuthorized
    @State private var axGranted = Permissions.accessibilityTrusted(prompt: false)
    @State private var micRefused = false
    /// The idle timeout is the one setting on this screen that does NOT live on
    /// AppState, so nothing publishes a change and SwiftUI has no reason to redraw.
    /// Writing it straight to Tuning left the value changed and the tile unlit —
    /// indistinguishable, from the outside, from a page where nothing is clickable.
    @State private var idleSeconds = Tuning.idleUnloadRaw

    private let questionCount = 7
    private let permissionsStepIndex = 6
    private let poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(step < questionCount
                 ? t("Pagina \(step + 1) di \(questionCount)",
                     "Page \(step + 1) of \(questionCount)",
                     "Page \(step + 1) sur \(questionCount)")
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
        .frame(width: 540, height: 470, alignment: .topLeading)
        .background(Theme.paper)
        .onReceive(poll) { _ in
            guard step == permissionsStepIndex else { return }
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
        case 0: interfaceLanguageStep
        case 1: dictationLanguageStep
        case 2: triggerKeyStep
        case 3: triggerModeStep
        case 4: cleanupStep
        case 5: memoryStep
        case 6: permissionsStep
        default: doneStep
        }
    }

    /// First, because everything after it is written in the answer.
    private var interfaceLanguageStep: some View {
        question(t("Lingua delle impostazioni", "Settings language", "Langue des réglages"),
                 t("La lingua in cui detti si sceglie dopo.",
                   "The language you dictate in comes next.",
                   "La langue de dictée vient ensuite.")) {
            grid([(1, "Italiano", ""), (2, "English", ""), (3, "Français", "")],
                 selected: { ui == Self.language($0) },
                 pick: { ui = Self.language($0) })
        }
    }

    private var dictationLanguageStep: some View {
        question(t("In che lingua vuoi dettare?", "Which language do you dictate in?",
                   "Dans quelle langue dictez-vous ?"),
                 t("Sceglierla è più preciso che lasciarla indovinare a ogni frase.",
                   "Choosing one is more accurate than having it guessed every sentence.",
                   "La choisir est plus précis que la laisser deviner à chaque phrase.")) {
            grid([
                (1, "Italiano", ""),
                (2, "English", ""),
                (3, "Français", ""),
                (0, t("Automatico", "Detect it", "Automatique"),
                    t("se cambi lingua spesso", "if you switch often", "si vous changez souvent")),
            ], selected: { choice in
                choice == 0 ? state.autoDetectLanguage
                            : !state.autoDetectLanguage && state.defaultLanguage == Self.language(choice)
            }, pick: { choice in
                if choice == 0 {
                    state.autoDetectLanguage = true
                } else {
                    state.autoDetectLanguage = false
                    state.defaultLanguage = Self.language(choice)
                }
            })
        }
    }

    /// Right Control is deliberately absent: Apple keyboards have one Control key,
    /// on the left. Offering a key that does not exist on the hardware the app
    /// requires is worse than offering one fewer choice.
    private var triggerKeyStep: some View {
        question(t("Quale tasto avvia la dettatura?", "Which key starts dictation?",
                   "Quelle touche lance la dictée ?"),
                 t("Scegline uno che non usi già per altro.",
                   "Pick one you do not already use for something else.",
                   "Choisissez-en une que vous n’utilisez pas déjà.")) {
            grid([
                // Key names stay in English: that is what is printed on the keyboard.
                (0x36, "Right Command",
                       t("libero su quasi tutti i Mac", "free on most Macs",
                         "libre sur presque tous les Mac")),
                (0x3D, "Right Option",
                       t("se non lo usi per gli accenti", "if you do not type accents with it",
                         "si vous ne tapez pas d’accents avec")),
                (0x3F, "Fn / Globe",
                       t("se non l’hai rimappato", "unless you remapped it",
                         "sauf si vous l’avez remappée")),
            ], selected: { state.hotKeyCode == UInt16($0) },
               pick: { actions.applyTriggerKey(UInt16($0)) })
        }
    }

    private var triggerModeStep: some View {
        question(t("Come vuoi attivare la dettatura?", "How do you want to start it?",
                   "Comment voulez-vous la lancer ?"),
                 t("Tenerlo premuto è il modo più preciso e non lascia mai il microfono aperto. Il doppio tocco serve quando devi parlare a lungo senza tenere il dito sul tasto.",
                   "Holding is the precise way, and never leaves the microphone open. Double-tap is for talking at length without keeping a finger down.",
                   "Maintenir est le plus précis et ne laisse jamais le micro ouvert. Le double-appui sert à parler longtemps sans garder le doigt appuyé.")) {
            grid([
                (0, t("Tieni premuto", "Hold to talk", "Maintenir"),
                    t("un tocco singolo non fa niente", "a single tap does nothing",
                      "un appui simple ne fait rien")),
                (1, t("Doppio tocco", "Double-tap", "Double-appui"),
                    t("a mani libere: tocchi di nuovo e il testo viene scritto",
                      "hands-free: tap again and the text is written",
                      "mains libres : réappuyez et le texte s’écrit")),
                (2, t("Entrambi", "Both", "Les deux"),
                    t("tieni premuto oppure tocca due volte", "hold, or double-tap",
                      "maintenir, ou double-appui")),
            ], selected: { state.triggerMode == Self.mode($0) },
               pick: { actions.applyTriggerMode(Self.mode($0)) })
        }
    }

    private var cleanupStep: some View {
        question(t("Vuoi che sistemi quello che dici?", "Should it tidy up what you say?",
                   "Doit-il corriger ce que vous dites ?"),
                 t("Il modello locale mette la punteggiatura, toglie gli intercalari e sistema le frasi lasciate a metà. Si scarica una volta sola, circa 4 GB, e non esce mai dal tuo Mac.",
                   "The local model adds punctuation, drops filler and resolves the sentences you abandon halfway. It downloads once, about 4 GB, and never leaves your Mac.",
                   "Le modèle local ponctue, retire les hésitations et résout les phrases abandonnées. Il se télécharge une fois, environ 4 Go, et ne quitte jamais votre Mac.")) {
            grid([
                (1, t("Sì, con il modello", "Yes, use the model", "Oui, avec le modèle"),
                    t("~4 GB, una volta sola", "~4 GB, once", "~4 Go, une seule fois")),
                (0, t("Solo punteggiatura", "Punctuation only", "Ponctuation seule"),
                    t("istantaneo, niente da scaricare", "instant, nothing to download",
                      "instantané, rien à télécharger")),
            ], selected: { state.formatterMode == ($0 == 1 ? .localLLM : .ruleBased) },
               pick: { state.formatterMode = $0 == 1 ? .localLLM : .ruleBased })
        }
    }

    private var memoryStep: some View {
        question(t("Quando deve liberare la memoria?", "When should it free the memory?",
                   "Quand doit-il libérer la mémoire ?"),
                 t("Mentre stanno in memoria i modelli occupano circa 6 GB, e per ricaricarsi ci mettono un secondo.",
                   "While loaded, the models hold about 6 GB, and take a second to come back.",
                   "En mémoire, les modèles occupent environ 6 Go et reviennent en une seconde.")) {
            grid([
                (300, t("Dopo 5 minuti", "After 5 minutes", "Après 5 minutes"),
                      t("se hai 8 o 16 GB di RAM", "on 8 or 16 GB of RAM", "avec 8 ou 16 Go de RAM")),
                (900, t("Dopo 15 minuti", "After 15 minutes", "Après 15 minutes"),
                      t("se detti spesso durante il giorno", "if you dictate through the day",
                        "si vous dictez toute la journée")),
                (0, t("Mai", "Never", "Jamais"),
                    t("da 32 GB in su: sempre pronta", "32 GB and up: always ready",
                      "à partir de 32 Go : toujours prête")),
            ], selected: { idleSeconds == $0 },
               pick: { seconds in
                   idleSeconds = seconds        // drives the redraw
                   Tuning.setIdleUnload(seconds)
               })
        }
    }

    /// The step that justifies the whole flow — and the one that has to *ask*,
    /// not merely report. Showing a tick next to "Microphone" while never
    /// triggering the system prompt leaves someone staring at a screen that says
    /// everything is fine, in an app that cannot hear them.
    private var permissionsStep: some View {
        question(t("Ultimo passo: i permessi", "Last step: permissions",
                   "Dernière étape : les autorisations"),
                 t("Kalamos non può darseli da solo, li concede macOS. Il microfono serve a sentirti. L’accessibilità serve a due cose: accorgersi del tasto che premi anche quando sei in un’altra app, e scrivere lì il testo. Senza accessibilità il tasto non produce alcun effetto.",
                   "Kalamos cannot grant these to itself — macOS does. The microphone lets it hear you. Accessibility does two things: it lets Kalamos notice the key you press while you are in another app, and type the text there. Without Accessibility, pressing the key has no effect at all.",
                   "Kalamos ne peut pas se les accorder : c’est macOS. Le micro sert à vous entendre. L’accessibilité sert à détecter la touche depuis une autre app et à y écrire le texte. Sans elle, la touche n’a aucun effet.")) {
            VStack(alignment: .leading, spacing: 9) {
                permissionRow(
                    granted: micGranted,
                    title: t("Microfono", "Microphone", "Microphone"),
                    why: t("per sentirti", "to hear you", "pour vous entendre"),
                    button: micRefused
                        ? t("Apri Impostazioni", "Open Settings", "Ouvrir Réglages")
                        : t("Consenti", "Allow", "Autoriser"),
                    action: {
                        if micRefused { actions.openMicrophoneSettings() }
                        else {
                            actions.requestMicrophone { granted in
                                micGranted = granted
                                micRefused = !granted
                            }
                        }
                    })
                permissionRow(
                    granted: axGranted,
                    title: t("Accessibilità", "Accessibility", "Accessibilité"),
                    why: t("per leggere il tasto e scrivere nelle altre app",
                           "to read the key and type into other apps",
                           "pour lire la touche et écrire dans les autres apps"),
                    button: t("Consenti", "Allow", "Autoriser"),
                    action: actions.requestAccessibility)

                Text(t("Dopo aver acceso l’interruttore, il segno di spunta qui sopra può metterci un attimo.",
                       "After you flip the switch, the tick above can take a moment to catch up.",
                       "Après avoir activé l’interrupteur, la coche ci-dessus peut tarder un instant."))
                    .font(Theme.font(11.5))
                    .foregroundStyle(Theme.inkFaded)
            }
        }
    }

    private var doneStep: some View {
        question(t("Ecco fatto.", "That’s it.", "Voilà."), "") {
            VStack(alignment: .leading, spacing: 11) {
                Text(Self.howToUse(state.triggerMode,
                                   HotkeyManager.displayName(for: state.hotKeyCode), ui))
                    .font(Theme.font(15))
                    .foregroundStyle(Theme.ink)
                Text(t("Hai cambiato idea a metà frase? Premi Esc e la registrazione viene buttata via.",
                       "Changed your mind mid-sentence? Press Escape and the recording is thrown away.",
                       "Changé d’avis en cours de phrase ? Appuyez sur Échap, l’enregistrement est jeté."))
                    .font(Theme.font(13))
                    .foregroundStyle(Theme.inkFaded)
                Text(t("Quello che hai scelto lo ritrovi nell’icona in alto, insieme al vocabolario, alle correzioni e a Diagnostics… se qualcosa non va.",
                       "Everything you chose is in the menu-bar icon, along with the vocabulary, the correction rules, and Diagnostics… if anything misbehaves.",
                       "Vos choix se retrouvent dans l’icône de la barre de menus, avec le vocabulaire, les corrections et Diagnostics…"))
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
            // Fixed height, so the choices start at the same point on every page.
            // A header that grows with its own text drags the whole block up and
            // down as you go through, which reads as the window twitching.
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(Theme.font(21, .semibold))
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if !hint.isEmpty {
                    Text(hint)
                        .font(Theme.font(13))
                        .foregroundStyle(Theme.inkFaded)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(height: Self.headerHeight, alignment: .topLeading)

            content()
        }
    }

    /// Tall enough for a title plus three lines of hint — the longest page — so no
    /// page has to push the choices down to fit.
    private static let headerHeight: CGFloat = 104

    private func grid(_ items: [(Int, String, String)],
                      selected: @escaping (Int) -> Bool,
                      pick: @escaping (Int) -> Void) -> some View {
        // The placeholder line under a title exists only to keep tiles the same
        // height when SOME of them carry a note. When none do, it just pushes every
        // title off centre in its own box.
        let anyNotes = items.contains { !$0.2.isEmpty }

        func tile(_ item: (Int, String, String)) -> some View {
            choice(title: item.1, note: item.2, showsNoteLine: anyNotes,
                   on: selected(item.0)) { pick(item.0) }
        }

        return Group {
            if items.count == 3 {
                // Two up, one centred below. A third tile stretched across the full
                // width shouts louder than the two above it, and a third tile parked
                // bottom-left reads as a grid that ran out of items — the pyramid is
                // the only arrangement of three that looks chosen.
                VStack(spacing: 10) {
                    HStack(spacing: 10) { tile(items[0]); tile(items[1]) }
                    HStack(spacing: 0) {
                        Spacer(minLength: 0)
                        tile(items[2]).frame(width: Self.columnWidth)
                        Spacer(minLength: 0)
                    }
                }
            } else {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10),
                                    GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    ForEach(items, id: \.0) { tile($0) }
                }
            }
        }
    }

    /// One column of the two-column grid, for the tile at the point of the pyramid.
    /// Derived from the fixed window: 540 wide, 28 of padding each side, 10 between
    /// the columns. If the window size changes, this changes with it.
    private static let columnWidth: CGFloat = (540 - 28 * 2 - 10) / 2

    private func choice(title: String, note: String, showsNoteLine: Bool, on: Bool,
                        act: @escaping () -> Void) -> some View {
        Button(action: act) {
            VStack(spacing: 3) {
                Text(title).font(Theme.font(14, .medium)).foregroundStyle(Theme.ink)
                if showsNoteLine {
                    Text(note.isEmpty ? " " : note)
                        .font(Theme.font(11.5))
                        .foregroundStyle(Theme.inkFaded)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .multilineTextAlignment(.center)
            // One size for every choice on every page. Tiles that grow to fit their
            // own text make each page a slightly different shape, and flipping
            // through seven of them turns into a series of small jumps.
            .frame(maxWidth: .infinity,
                   minHeight: Self.tileHeight, maxHeight: Self.tileHeight)
            .padding(.horizontal, 12)
            .background(RoundedRectangle(cornerRadius: 8)
                .fill(on ? Theme.penWash : Color.white.opacity(0.55)))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .strokeBorder(on ? Theme.pen : Theme.rule, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(note.isEmpty ? title : "\(title), \(note)")
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
    }

    /// Every tile, on every page.
    private static let tileHeight: CGFloat = 58

    private func permissionRow(granted: Bool, title: String, why: String,
                               button: String, action: @escaping () -> Void) -> some View {
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
                Button(button, action: action)
                    .font(Theme.font(12, .medium))
                    .buttonStyle(.plain)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Theme.penWash))
                    .foregroundStyle(Theme.pen)
                    .accessibilityLabel("\(button), \(title)")
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
        case (.doubleTap, .italian): return "Tocca due volte \(key) e parla. Tocca di nuovo e il testo viene scritto dove hai il cursore."
        case (.doubleTap, .french):  return "Appuyez deux fois sur \(key) et parlez. Réappuyez et le texte s’écrit au curseur."
        case (.doubleTap, .english): return "Double-tap \(key) and speak. Tap again and the text is written at your cursor."
        case (.hold, .italian): return "Tieni premuto \(key) e parla. Quando lasci, il testo compare dove hai il cursore."
        case (.hold, .french):  return "Maintenez \(key) et parlez. En relâchant, le texte apparaît au curseur."
        case (.hold, .english): return "Hold \(key) and speak. Release, and the text lands at your cursor."
        case (.both, .italian): return "Tieni premuto \(key) e parla, oppure toccalo due volte per andare a mani libere."
        case (.both, .french):  return "Maintenez \(key) et parlez, ou appuyez deux fois pour les mains libres."
        case (.both, .english): return "Hold \(key) and speak — or double-tap it to go hands-free."
        }
    }
}
