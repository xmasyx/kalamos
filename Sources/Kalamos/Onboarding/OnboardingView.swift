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
    /// Writing the engine and the two model ids down is not enough: the live
    /// engine has to be told, or the choice only takes effect at the next launch.
    /// Same reason the trigger key is applied through here rather than assigned.
    var applyRecommendation: (Recommendation) -> Void
    var requestMicrophone: (@escaping (Bool) -> Void) -> Void
    var requestAccessibility: () -> Void
    var openMicrophoneSettings: () -> Void
    var finish: () -> Void
}

/// Where each page of setup sits, and what accepting the proposal skips.
///
/// Pulled out of the view so it can be tested: "accepting makes setup shorter"
/// is a claim about a sequence of integers, and a claim nobody can check is one
/// that quietly stops being true the next time a page is inserted.
enum OnboardingFlow {
    static let machine = 1
    /// The last page the machine did NOT decide. After it come the two it did.
    static let lastAsked = 4
    static let permissions = 7
    static let questionCount = 8

    /// The pages the machine decides for you: cleanup model, and when the memory
    /// is freed. Both are answered by the amount of RAM.
    static let decided = [5, 6]

    static func next(from step: Int, accepted: Bool) -> Int {
        (step == lastAsked && accepted) ? permissions : step + 1
    }

    static func previous(from step: Int, accepted: Bool) -> Int {
        (step == permissions && accepted) ? lastAsked : step - 1
    }
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

    @State private var step = Self.probeStep
    /// Only ever set by `--scatta --onboarding --passo=<n>`. A screen nobody can
    /// photograph past its first page is a screen whose later pages are checked by
    /// reading the source, which is how a list running off the bottom of a window
    /// stayed a diagnosis instead of something somebody saw.
    static var probeStep = 0
    /// True once "that's fine" was pressed: the two pages the machine already
    /// decided are then skipped, so accepting the proposal makes setup SHORTER
    /// rather than adding a page to it.
    @State private var acceptedProfile = false
    /// Read once. Nothing here changes while the window is up, and re-reading it
    /// per redraw would put a `sysctl` behind every keystroke.
    private let machine = MachineProfile.current
    /// Read straight from the settings, never copied into a `@State`. The copy is
    /// what made the first question pointless: whatever you chose here died with
    /// the window, and the menu bar stayed in English.
    private var ui: Language { state.uiLanguage }
    @State private var micGranted = Permissions.microphoneAuthorized
    @State private var axGranted = Permissions.accessibilityTrusted(prompt: false)
    @State private var micRefused = false
    /// The idle timeout is the one setting on this screen that does NOT live on
    /// AppState, so nothing publishes a change and SwiftUI has no reason to redraw.
    /// Writing it straight to Tuning left the value changed and the tile unlit —
    /// indistinguishable, from the outside, from a page where nothing is clickable.
    @State private var idleSeconds = Tuning.idleUnloadRaw

    private let questionCount = OnboardingFlow.questionCount
    private let permissionsStepIndex = OnboardingFlow.permissions
    private let machineStepIndex = OnboardingFlow.machine
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

    private func t(_ it: String, _ en: String, _ fr: String) -> String {
        L.t(it, en, fr)
    }

    // MARK: Steps

    @ViewBuilder private var content: some View {
        switch step {
        case 0: interfaceLanguageStep
        case 1: machineStep
        case 2: dictationLanguageStep
        case 3: triggerKeyStep
        case 4: triggerModeStep
        case 5: cleanupStep
        case 6: memoryStep
        case 7: permissionsStep
        default: doneStep
        }
    }

    /// Move on, skipping what the machine already decided for someone who said the
    /// proposal was fine.
    private func advance() { step = OnboardingFlow.next(from: step, accepted: acceptedProfile) }
    private func retreat() { step = OnboardingFlow.previous(from: step, accepted: acceptedProfile) }

    /// First, because everything after it is written in the answer.
    private var interfaceLanguageStep: some View {
        question(t("Lingua delle impostazioni", "Settings language", "Langue des réglages"),
                 t("La lingua in cui detti si sceglie dopo.",
                   "The language you dictate in comes next.",
                   "La langue de dictée vient ensuite.")) {
            grid([(1, "Italiano", ""), (2, "English", ""), (3, "Français", "")],
                 selected: { ui == Self.language($0) },
                 pick: { state.uiLanguage = Self.language($0) })
        }
    }

    /// What this Mac is, and what Kalamos would like to do about it.
    ///
    /// The page exists because the two that follow it were asking questions the
    /// computer can answer — the memory page printed the rule ("if you have 8 or
    /// 16 GB") and left the arithmetic to the reader.
    ///
    /// **Only facts, never a prediction.** Chip, memory, cores and free space are
    /// read from the machine; the reason under each proposal is one of those
    /// numbers. No timing appears here: the seconds this app quotes anywhere were
    /// measured on one Mac, and printing them next to somebody else's would be
    /// inventing them (ISC-152).
    private var machineStep: some View {
        question(t("Il tuo Mac", "Your Mac", "Votre Mac"),
                 t("Ho guardato la macchina e ho scelto di conseguenza. Puoi cambiare tutto, adesso o più tardi.",
                   "I looked at the machine and chose accordingly. You can change all of it, now or later.",
                   "J’ai regardé la machine et choisi en conséquence. Tout reste modifiable, maintenant ou plus tard.")) {
            VStack(alignment: .leading, spacing: 8) {
                Text(machineFacts)
                    .font(Theme.font(12, .medium))
                    .foregroundStyle(Theme.ink)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Theme.card))
                    .overlay(RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(Theme.rule, lineWidth: 1.5))

                proposalRow(t("Ascolto", "Listening", "Écoute"), engineProposal)
                proposalRow(t("Pulizia", "Tidy-up", "Nettoyage"), cleanupProposal)
                proposalRow(t("Memoria", "Memory", "Mémoire"), memoryProposal)

                HStack(spacing: 8) {
                    Button {
                        acceptedProfile = true
                        applyProposal()
                        advance()
                    } label: {
                        Text(t("Va bene così", "That’s fine", "Très bien"))
                            .font(Theme.font(13, .semibold))
                            .foregroundStyle(Theme.paper)
                            .padding(.horizontal, 18).padding(.vertical, 8)
                            .background(RoundedRectangle(cornerRadius: 7).fill(Theme.pen))
                            .contentShape(RoundedRectangle(cornerRadius: 7))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(t("Va bene così", "That’s fine", "Très bien"))

                    Button {
                        acceptedProfile = false
                        applyProposal()
                        advance()
                    } label: {
                        Text(t("Scelgo io", "I’ll choose", "Je choisis"))
                            .font(Theme.font(13, .medium))
                            .foregroundStyle(Theme.pen)
                            .padding(.horizontal, 18).padding(.vertical, 8)
                            .background(RoundedRectangle(cornerRadius: 7).fill(Theme.penWash))
                            .contentShape(RoundedRectangle(cornerRadius: 7))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(t("Scelgo io", "I’ll choose", "Je choisis"))
                }
                .padding(.top, 2)
            }
        }
    }

    /// The proposal for this machine. Computed rather than stored: it depends on
    /// nothing that changes while the window is open, and a stored copy is one
    /// more thing that can go stale.
    private var suggestion: Recommendation { Recommendation.recommended(for: machine) }

    /// Write the proposal down — on either button, because "I'll choose" means
    /// *see the pages*, not *start from nothing*: they open with the proposal
    /// already selected and you disagree with it if you want to.
    ///
    /// Nothing applies it on its own. Opening setup and closing it here leaves
    /// every setting exactly as it was, which is what makes this a proposal
    /// rather than something done to you while you read (ISC-153).
    private func applyProposal() {
        actions.applyRecommendation(suggestion)
        // The idle timeout is the one setting that does not live on AppState, so
        // the memory page's tile is lit from this copy and has to be told too.
        idleSeconds = suggestion.idleUnloadSeconds
    }

    private var machineFacts: String {
        let core = t("core", "cores", "cœurs")
        let free = t("liberi sul disco", "free on disk", "libres sur le disque")
        return "\(machine.chipName) · \(machine.memoryGB) GB · \(machine.coreSummary) \(core) · \(machine.freeDiskGB) GB \(free)"
    }

    /// One line of the proposal: what it is about, what was chosen, and the number
    /// that chose it. The reason is not decoration — a choice made for you in
    /// silence is one you cannot disagree with.
    private func proposalRow(_ label: String, _ value: (String, String)) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .font(Theme.font(11.5, .bold))
                .tracking(0.8)
                .foregroundStyle(Theme.pen)
                .frame(width: 74, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(value.0).font(Theme.font(13.5, .medium)).foregroundStyle(Theme.ink)
                Text(value.1).font(Theme.font(11.5)).foregroundStyle(Theme.inkFaded)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private var engineProposal: (String, String) {
        let gb = machine.memoryGB
        switch (suggestion.engine, suggestion.constraint) {
        case (.parakeet, .verySmallMemory):
            return ("Parakeet", t("più leggero, 461 MB invece di 1,5 GB, e hai \(gb) GB di memoria",
                                  "lighter, 461 MB instead of 1.5 GB, and you have \(gb) GB of memory",
                                  "plus léger, 461 Mo au lieu de 1,5 Go, et vous avez \(gb) Go de mémoire"))
        case (.parakeet, _):
            return ("Parakeet", t("461 MB: sul disco restano \(machine.freeDiskGB) GB",
                                  "461 MB: you have \(machine.freeDiskGB) GB left on disk",
                                  "461 Mo : il reste \(machine.freeDiskGB) Go sur le disque"))
        default:
            return ("Whisper Turbo", t("1,5 GB, scaricati una volta sola",
                                       "1.5 GB, downloaded once",
                                       "1,5 Go, téléchargés une seule fois"))
        }
    }

    private var cleanupProposal: (String, String) {
        let gb = machine.memoryGB
        guard suggestion.formatterMode == .localLLM else {
            let why = suggestion.constraint == .tightDisk
                ? t("sul disco non ci starebbe: hai \(machine.freeDiskGB) GB",
                    "it would not fit: \(machine.freeDiskGB) GB left on disk",
                    "il n’y tiendrait pas : \(machine.freeDiskGB) Go restants")
                : t("con \(gb) GB di memoria il modello starebbe stretto",
                    "on \(gb) GB of memory the model would be squeezed",
                    "avec \(gb) Go de mémoire le modèle serait à l’étroit")
            return (t("Solo punteggiatura", "Punctuation only", "Ponctuation seule"), why)
        }
        let title = ModelCatalog.cleanupTitle(for: suggestion.cleanupModelID)
        let why = suggestion.constraint == .tightMemory
            ? t("il modello piccolo, perché hai \(gb) GB di memoria",
                "the small model, because you have \(gb) GB of memory",
                "le petit modèle, car vous avez \(gb) Go de mémoire")
            : t("hai \(gb) GB di memoria, ci sta comodo",
                "you have \(gb) GB of memory, it fits comfortably",
                "vous avez \(gb) Go de mémoire, il y tient à l’aise")
        return (title, why)
    }

    /// The name of the tile this proposal points at, in the words printed ON that
    /// tile. Written separately from the sentence below on purpose: the first
    /// version of this page recommended "Always ready" while the tile it meant was
    /// called "Never", so the advice pointed at a choice that did not exist by
    /// that name. Seen in the screenshot, not in the source.
    private var memoryTileName: String {
        switch suggestion.idleUnloadSeconds {
        case 0:   return t("Mai", "Never", "Jamais")
        case 900: return t("Dopo 15 minuti", "After 15 minutes", "Après 15 minutes")
        default:  return t("Dopo 5 minuti", "After 5 minutes", "Après 5 minutes")
        }
    }

    private var memoryProposal: (String, String) {
        let gb = machine.memoryGB
        switch suggestion.idleUnloadSeconds {
        case 0:
            return (t("Mai liberata", "Never freed", "Jamais libérée"),
                    t("con \(gb) GB conviene tenere i modelli in memoria, sempre pronti",
                      "with \(gb) GB it is worth keeping the models loaded and ready",
                      "avec \(gb) Go, autant garder les modèles en mémoire, toujours prêts"))
        case 900:
            return (t("Liberata dopo 15 minuti", "Freed after 15 minutes", "Libérée après 15 minutes"),
                    t("hai \(gb) GB: pronta durante la giornata, libera la sera",
                      "you have \(gb) GB: ready through the day, free by the evening",
                      "vous avez \(gb) Go : prête la journée, libre le soir"))
        default:
            return (t("Liberata dopo 5 minuti", "Freed after 5 minutes", "Libérée après 5 minutes"),
                    t("con \(gb) GB è meglio restituirla presto al resto del Mac",
                      "with \(gb) GB it is better to give it back to the rest of the Mac",
                      "avec \(gb) Go, mieux vaut la rendre vite au reste du Mac"))
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
                 t("Il modello locale mette la punteggiatura, toglie gli intercalari e sistema le frasi lasciate a metà. Si scarica una volta sola e non esce mai dal tuo Mac.",
                   "The local model adds punctuation, drops filler and resolves the sentences you abandon halfway. It downloads once and never leaves your Mac.",
                   "Le modèle local ponctue, retire les hésitations et résout les phrases abandonnées. Il se télécharge une fois et ne quitte jamais votre Mac.")) {
            VStack(alignment: .leading, spacing: 12) {
                grid([
                    (1, t("Sì, con il modello", "Yes, use the model", "Oui, avec le modèle"),
                        t("\(modelSize), una volta sola", "\(modelSize), once",
                          "\(modelSize), une seule fois")),
                    (0, t("Solo punteggiatura", "Punctuation only", "Ponctuation seule"),
                        t("istantaneo, niente da scaricare", "instant, nothing to download",
                          "instantané, rien à télécharger")),
                ], selected: { state.formatterMode == ($0 == 1 ? .localLLM : .ruleBased) },
                   pick: { state.formatterMode = $0 == 1 ? .localLLM : .ruleBased })

                // Which model, decided by the machine instead of asked. Said out
                // loud: a choice made for you in silence is one you cannot
                // disagree with. Nobody installing a dictation app knows their RAM.
                Text(recommendedNote(cleanupProposal.0))
                    .font(Theme.font(11.5))
                    .foregroundStyle(Theme.inkFaded)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The cleanup model this Mac was given, and how big its download is — the
    /// number in the tile used to be a hardcoded "~4 GB", which is the 7B's size
    /// and simply wrong on a Mac that got the 3B.
    private var chosenModel: ModelChoice {
        ModelCatalog.cleanup.first { $0.id == state.cleanupModelID }
            ?? ModelCatalog.cleanup[0]
    }

    private var modelSize: String {
        // "~4.3 GB · default" → "~4.3 GB"
        chosenModel.note.split(separator: "·").first?
            .trimmingCharacters(in: .whitespaces) ?? "~4 GB"
    }

    /// The line under a grid whose right answer the machine already worked out.
    /// The recommended tile is the lit one, so this says WHICH and leaves the
    /// disagreeing to the reader.
    private func recommendedNote(_ what: String) -> String {
        t("Consigliato per il tuo Mac: \(what). Si cambia quando vuoi.",
          "Recommended for your Mac: \(what). Change it whenever you like.",
          "Recommandé pour votre Mac : \(what). Modifiable à tout moment.")
    }

    private var memoryStep: some View {
        question(t("Quando deve liberare la memoria?", "When should it free the memory?",
                   "Quand doit-il libérer la mémoire ?"),
                 t("Mentre stanno in memoria i modelli occupano circa 6 GB, e per tornare ci mettono qualche secondo.",
                   "While loaded, the models hold about 6 GB, and take a few seconds to come back.",
                   "En mémoire, les modèles occupent environ 6 Go et reviennent en quelques secondes.")) {
            VStack(alignment: .leading, spacing: 12) {
                // The notes no longer quote the RAM thresholds. They used to print
                // the rule — "on 8 or 16 GB" — and leave the reader to look up
                // their own machine and apply it, which is the arithmetic the
                // previous page now does for them.
                grid([
                    (300, t("Dopo 5 minuti", "After 5 minutes", "Après 5 minutes"),
                          t("torna pronta in qualche secondo", "a few seconds to come back",
                            "quelques secondes pour revenir")),
                    (900, t("Dopo 15 minuti", "After 15 minutes", "Après 15 minutes"),
                          t("se detti spesso durante il giorno", "if you dictate through the day",
                            "si vous dictez toute la journée")),
                    (0, t("Mai", "Never", "Jamais"),
                        t("sempre pronta, sempre in memoria", "always ready, always loaded",
                          "toujours prête, toujours en mémoire")),
                ], selected: { idleSeconds == $0 },
                   pick: { seconds in
                       idleSeconds = seconds        // drives the redraw
                       Tuning.setIdleUnload(seconds)
                   })

                Text(recommendedNote(memoryTileName))
                    .font(Theme.font(11.5))
                    .foregroundStyle(Theme.inkFaded)
                    .fixedSize(horizontal: false, vertical: true)
            }
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
        func tile(_ item: (Int, String, String)) -> some View {
            choice(title: item.1, note: item.2, on: selected(item.0)) { pick(item.0) }
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

    private func choice(title: String, note: String, on: Bool,
                        act: @escaping () -> Void) -> some View {
        Button(action: act) {
            VStack(spacing: 3) {
                Text(title).font(Theme.font(14, .medium)).foregroundStyle(Theme.ink)
                // Only when there is something to say. A blank reserved line used
                // to keep tiles the same height, back when they sized themselves —
                // the fixed height below does that now, and the leftover placeholder
                // was pushing every note-less title above the centre of its own box.
                if !note.isEmpty {
                    Text(note)
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
                   minHeight: Self.tileHeight, maxHeight: Self.tileHeight,
                   alignment: .center)
            .padding(.horizontal, 12)
            .background(RoundedRectangle(cornerRadius: 8)
                .fill(on ? Theme.penWash : Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .strokeBorder(on ? Theme.pen : Theme.rule, lineWidth: 1.5))
            .contentShape(RoundedRectangle(cornerRadius: 8))
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
                Button(action: action) {
                    Text(button)
                        .font(Theme.font(12, .medium))
                        .foregroundStyle(Theme.pen)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.penWash))
                        .contentShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(button), \(title)")
            }
        }
        .padding(.horizontal, 13).padding(.vertical, 11)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.card))
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
                Button { retreat() } label: {
                    Text(t("Indietro", "Back", "Retour"))
                        .font(Theme.font(13, .medium))
                        .foregroundStyle(Theme.inkFaded)
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.trailing, 2)
                .accessibilityLabel(t("Indietro", "Back", "Retour"))
            }
            // The machine page carries its own two buttons, and they are the
            // choice: a third one in the corner saying "Continue" would be a way
            // past the question that answers nothing.
            if step != machineStepIndex {
            let label = step < questionCount
                ? t("Avanti", "Continue", "Continuer")
                : t("Inizia a dettare", "Start dictating", "Commencer")
            Button {
                if step < questionCount { advance() } else { actions.finish() }
            } label: {
                // Everything that makes this look like a button lives INSIDE the
                // label. Applied outside, the padding and the filled rectangle are
                // decoration behind a button the size of its text — so the blue area
                // looks pressable and is not. contentShape then guarantees the whole
                // rounded rectangle is hit-tested, background or not.
                Text(label)
                    .font(Theme.font(13, .semibold))
                    .foregroundStyle(Theme.paper)
                    .padding(.horizontal, 20).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Theme.pen))
                    .contentShape(RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
            .accessibilityLabel(label)
            }
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
        case (.singleTap, .italian): return "Tocca \(key) e parla. Toccalo di nuovo e il testo viene scritto dove hai il cursore."
        case (.singleTap, .french):  return "Appuyez sur \(key) et parlez. Réappuyez et le texte s’écrit au curseur."
        case (.singleTap, .english): return "Tap \(key) and speak. Tap again and the text is written at your cursor."
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
