import SwiftUI

// MARK: - Dictation

struct DictationSection: View {
    @Binding var draft: SettingsDraft

    var body: some View {
        Group {
            PrefRow(title: L.t("Tasto per dettare", "Dictation key", "Touche de dictée"),
                    note: L.t("Scegline uno che non usi già per altro.",
                              "Pick one you do not already use for something else.",
                              "Choisissez-en une que vous n’utilisez pas déjà.")) {
                // One list, shared with setup. Two copies is what let Right Shift
                // exist here and not there.
                ChipRow(options: OnboardingChoices.triggerKeys.map {
                    ($0, HotkeyManager.displayName(for: $0), "")
                }, isOn: { draft.hotKeyCode == $0 }, pick: { draft.hotKeyCode = $0 })
            }

            PrefRow(title: L.t("Come si attiva", "How it starts", "Comment ça démarre"),
                    note: L.t("Tenere premuto è il modo preciso e non lascia mai il microfono aperto. Il doppio tocco serve per parlare a lungo.",
                              "Holding is the precise way and never leaves the microphone open. Double-tap is for talking at length.",
                              "Maintenir est le plus précis. Le double-appui sert à parler longtemps.")) {
                ChipRow(options: TriggerMode.allCases.map {
                    ($0, AppDelegate.modeTitle($0), "")
                }, isOn: { draft.triggerMode == $0 }, pick: { draft.triggerMode = $0 })
            }

            PrefRow(title: L.t("Lingua della dettatura", "Dictation language",
                               "Langue de la dictée"),
                    note: L.t("Sceglierla è più preciso che lasciarla indovinare a ogni frase.",
                              "Choosing one is more accurate than having it guessed every sentence.",
                              "La choisir est plus précis que la laisser deviner.")) {
                ChipRow(options: [("auto", L.t("Automatico", "Detect it", "Automatique"), "")]
                        + Language.allCases.map { ($0.rawValue, $0.displayName, "") },
                        isOn: { raw in
                            raw == "auto" ? draft.autoDetectLanguage
                                          : (!draft.autoDetectLanguage && draft.defaultLanguage.rawValue == raw)
                        }, pick: { raw in
                            if raw == "auto" { draft.autoDetectLanguage = true }
                            else if let lang = Language(rawValue: raw) {
                                draft.autoDetectLanguage = false
                                draft.defaultLanguage = lang
                            }
                        })
            }

            PrefRow(title: L.t("Traduzione istantanea", "Instant translation", "Traduction instantanée"),
                    note: L.t("Detti in una lingua e viene scritta un'altra. Stesso modello sul tuo Mac, niente esce da qui.",
                              "Dictate in one language and another is typed. Same model on your Mac; nothing leaves it.",
                              "Dictez dans une langue, une autre s’écrit. Même modèle local.")) {
                ChipRow(options: [("off", L.t("Disattivata", "Off", "Désactivée"), "")]
                        + Language.allCases.map { ($0.rawValue, $0.displayName, "") },
                        isOn: { raw in
                            raw == "off" ? !draft.translationEnabled
                                         : (draft.translationEnabled && draft.translationTarget.rawValue == raw)
                        }, pick: { raw in
                            if raw == "off" { draft.translationEnabled = false }
                            else if let lang = Language(rawValue: raw) {
                                draft.translationTarget = lang
                                draft.translationEnabled = true
                            }
                        })
            }

            // Named for what the block IS now, not for what it was when it held
            // only the two chaining switches: the last two are about how a
            // dictation starts and ends, which has nothing to do with chaining.
            // One short line each, not three.
            //
            // The long version answered every question a reader could have and
            // produced a wall — "troppo confusionario", and he was right: four
            // switches with a paragraph apiece is a page you skip rather than
            // read. The rule is a line that fits on one line.
            // The terminal line sits BETWEEN the pairs, not above all four: the
            // first two are for ordinary writing, the last two are for a shell
            // prompt and a search box. As a heading it was simply false, which he
            // said in as many words.
            PrefRow(title: L.t("Impostazioni aggiuntive", "Additional settings",
                               "Réglages supplémentaires")) {
                VStack(alignment: .leading, spacing: 12) {
                    PrefToggle(title: L.t("Metti uno spazio prima", "Add a space in front",
                                          "Ajouter une espace devant"),
                               note: L.t("Per attaccarla alla dettatura precedente.",
                                         "To join it to the previous dictation.",
                                         "Pour la joindre à la dictée précédente."),
                               isOn: $draft.spaceBetweenDictations)

                    PrefToggle(title: L.t("Decidi la maiuscola dal contesto",
                                          "Decide the capital from the context",
                                          "Décider la majuscule d’après le contexte"),
                               note: L.t("Maiuscola dopo un punto, minuscola a metà frase.",
                                         "A capital after a full stop, lowercase mid-sentence.",
                                         "Majuscule après un point, minuscule en milieu de phrase."),
                               isOn: $draft.smartCapitalization)

                    // A rule above it, because ink alone made it read as a new
                    // heading rather than a divider between two halves of the
                    // same block. The line does the separating; the sentence
                    // only says what the second half is for.
                    Rectangle()
                        .fill(Theme.rule)
                        .frame(height: 1)
                        .padding(.top, 8)

                    Text(L.t("Soprattutto per il terminale e i campi di ricerca.",
                             "Mostly for terminals and search fields.",
                             "Surtout pour le terminal et les champs de recherche."))
                        .font(Theme.font(12.5, .medium))
                        .foregroundStyle(Theme.ink)

                    PrefToggle(title: L.t("Comincia sempre in minuscolo", "Always start lowercase",
                                          "Toujours commencer en minuscule"),
                               note: L.t("Senza guardare cosa c'è prima.",
                                         "Without looking at what comes before.",
                                         "Sans regarder ce qui précède."),
                               isOn: $draft.lowercaseFirstLetter)

                    PrefToggle(title: L.t("Togli il punto finale", "Drop the final full stop",
                                          "Retirer le point final"),
                               note: L.t("Il punto interrogativo resta.", "A question mark stays.",
                                         "Le point d’interrogation reste."),
                               isOn: $draft.removeTrailingPeriod)
                }
            }

        }
    }
}

// MARK: - Trascrizione

/// **Le tre macchine in un posto solo** (2026-08-18, sua richiesta).
///
/// Chi ascolta (il motore e la sua taglia), chi punteggia, chi ripulisce. Il motore
/// arriva da «Dettatura», che è il gesto — il tasto, il modo, la lingua — e non il
/// meccanismo. Le altre righe erano già qui sotto il nome «Pulizia», che era il
/// nome di UNA delle tre e non del contenitore.
struct TranscriptionSection: View {
    @Binding var draft: SettingsDraft
    @ObservedObject var state: AppState

    var body: some View {
        Group {
            PrefRow(title: L.t("Motore che ti ascolta", "The engine that hears you",
                               "Le moteur qui vous écoute"),
                    note: L.t("Whisper indovina meglio i nomi che non gli hai insegnato e ti lascia scegliere la taglia del modello. Parakeet scarica 461 MB invece di 1,5 GB e risponde prima.",
                              "Whisper guesses better at names you have not taught it, and lets you pick the model size. Parakeet downloads 461 MB instead of 1.5 GB and answers sooner.",
                              "Whisper devine mieux les noms que vous ne lui avez pas appris et laisse choisir la taille du modèle. Parakeet télécharge 461 Mo au lieu de 1,5 Go et répond plus vite.")) {
                ChipRow(options: SpeechEngine.allCases.map { ($0.rawValue, $0.title, $0.note) },
                        isOn: { draft.speechEngine.rawValue == $0 },
                        pick: { draft.speechEngine = SpeechEngine(rawValue: $0) ?? .whisper })
            }

            PrefRow(title: L.t("Modello che ti ascolta", "The model that hears you",
                               "Le modèle qui vous écoute"),
                    note: L.t("Turbo è il compromesso giusto quasi sempre.",
                              "Turbo is the right trade-off almost always.",
                              "Turbo est le bon compromis presque toujours.")) {
                ChipRow(options: ModelCatalog.speech.map { ($0.id, $0.title, $0.note) },
                        isOn: { draft.whisperModel == $0 },
                        pick: { draft.whisperModel = $0 })
                    // Parakeet ships as a single model, so the variants below
                    // belong to Whisper. Dimmed rather than hidden: a row that
                    // disappears reads as a bug, a row that greys out reads as
                    // "not for this choice".
                    .opacity(draft.speechEngine == .whisper ? 1 : 0.4)
                    .disabled(draft.speechEngine != .whisper)
            }

            CleanupSection(draft: $draft, state: state)
        }
    }
}

// MARK: - Cleanup

struct CleanupSection: View {
    @Binding var draft: SettingsDraft
    /// Read-only here: the live download progress, which belongs to the app and
    /// not to anything the window is deciding.
    @ObservedObject var state: AppState

    var body: some View {
        Group {
            PrefRow(title: L.t("Cosa fa al testo", "What it does to the text",
                               "Ce qu’il fait au texte"),
                    note: L.t("Whisper punteggia già da solo quasi sempre. Il modello locale serve sui discorsi lunghi detti di filato, dove la punteggiatura non arriva e le frasi restano a metà.",
                              "Whisper already punctuates most of the time. The local model earns its seconds on long unbroken speech, where the punctuation never arrives and sentences stay half-finished.",
                              "Whisper ponctue déjà la plupart du temps. Le modèle local sert sur les longs passages dits d’une traite, où la ponctuation n’arrive pas.")) {
                ChipRow(options: [
                    (FormatterMode.adaptive, L.t("Solo quando serve", "Only when needed", "Seulement si besoin"),
                     L.t("consigliato", "recommended", "recommandé")),
                    (FormatterMode.localLLM, L.t("Modello locale", "Local model", "Modèle local"),
                     L.t("sempre", "always", "toujours")),
                    (FormatterMode.ruleBased, L.t("Solo punteggiatura", "Punctuation only", "Ponctuation seule"),
                     L.t("istantaneo", "instant", "instantané")),
                    (FormatterMode.off, L.t("Niente", "Nothing", "Rien"),
                     L.t("testo grezzo", "raw text", "texte brut")),
                ], isOn: { draft.formatterMode == $0 }, pick: { draft.formatterMode = $0 })
            }

            PrefRow(title: L.t("Modello di pulizia", "Cleanup model", "Modèle de nettoyage"),
                    note: automaticNote) {
                VStack(alignment: .leading, spacing: 10) {
                    ChipRow(options: ModelCatalog.cleanup.map { ($0.id, $0.title, $0.note) },
                            isOn: { draft.cleanupModelID == $0 },
                            pick: { draft.cleanupModelID = $0 })
                    // The same download the floating panel shows, for whoever is
                    // already in here when it starts.
                    if case .downloading(_, let fraction) = state.status {
                        VStack(alignment: .leading, spacing: 5) {
                            if let fraction {
                                ProgressView(value: min(max(fraction, 0), 1))
                            } else {
                                ProgressView()
                            }
                            Text(L.statusLine(state.status))
                                .font(Theme.font(11.5))
                                .foregroundStyle(Theme.inkFaded)
                        }
                        .progressViewStyle(.linear)
                        .tint(Theme.pen)
                    }
                }
            }

            PunctuationModelRow()

            PrefRow(title: L.t("Quando il modello viene scartato", "When the model is refused",
                               "Quand le modèle est écarté"),
                    note: L.t("Kalamos confronta quello che il modello restituisce con quello che hai detto, e se ha cambiato le tue parole lo butta e usa la pulizia a regole. Succede in silenzio: questo lo rende visibile.",
                              "Kalamos compares what the model returns with what you said, and throws it away if your words changed, falling back to the rule-based pass. That happens silently: this makes it visible.",
                              "Kalamos compare ce que le modèle renvoie avec ce que vous avez dit et l’écarte si vos mots ont changé. Cela se produit en silence : ceci le rend visible.")) {
                VStack(alignment: .leading, spacing: 7) {
                    PrefToggle(title: L.t("Dimmelo quando succede", "Tell me when it happens",
                                 "Me le dire quand ça arrive"), isOn: $draft.notifyCleanupRejected)
                    Text(L.t("Compare per qualche secondo nel menu, e la dettatura resta segnata con ⚠︎ fra le recenti.",
                             "It shows for a few seconds in the menu, and the dictation stays marked with ⚠︎ in the recent list.",
                             "Cela s’affiche quelques secondes dans le menu, et la dictée reste marquée ⚠︎."))
                        .font(Theme.font(11.5)).foregroundStyle(Theme.inkFaded)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            PrefRow(title: L.t("Istruzioni per il modello", "Instructions for the model",
                               "Instructions pour le modèle"),
                    note: L.t("Avanzato. Lascia vuoto per le istruzioni di Kalamos, che sono tarate su punteggiatura e fedeltà. Quello che scrivi qui le sostituisce; il vocabolario resta comunque applicato.",
                              "Advanced. Leave empty for Kalamos's own instructions, tuned for punctuation and fidelity. What you write replaces them; the vocabulary still applies.",
                              "Avancé. Laissez vide pour les instructions de Kalamos. Ce que vous écrivez les remplace ; le vocabulaire s’applique toujours.")) {
                VStack(alignment: .leading, spacing: 9) {
                    // No Save of its own any more: the prompt is a setting like
                    // the others, and two different ways of confirming a change
                    // in one window is one too many.
                    TextEditor(text: $draft.cleanupPrompt)
                        .font(.system(size: 12, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .frame(height: 130)
                        .background(RoundedRectangle(cornerRadius: 7).fill(Theme.card))
                        .overlay(RoundedRectangle(cornerRadius: 7)
                            .strokeBorder(Theme.rule, lineWidth: 1.5))
                    PrefButton(title: L.t("Ripristina le istruzioni di Kalamos",
                                          "Restore Kalamos's instructions",
                                          "Rétablir les instructions de Kalamos")) {
                        draft.cleanupPrompt = ""
                    }
                }
            }
        }
    }

    /// Said once, where the choice was made for you. Silence would leave someone
    /// wondering why they have the model they have.
    private var automaticNote: String {
        let recommended = ModelCatalog.recommendedCleanupID()
        let ram = Int((Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824).rounded())
        guard draft.cleanupModelID == recommended else {
            return L.t("L'hai scelto tu. Kalamos avrebbe usato \(ModelCatalog.cleanupTitle(for: recommended)) per un Mac da \(ram) GB.",
                       "Your choice. Kalamos would have used \(ModelCatalog.cleanupTitle(for: recommended)) on a \(ram) GB Mac.",
                       "Votre choix. Kalamos aurait utilisé \(ModelCatalog.cleanupTitle(for: recommended)) sur un Mac de \(ram) Go.")
        }
        return L.t("Scelto per il tuo Mac: hai \(ram) GB di memoria. Puoi cambiarlo quando vuoi.",
                   "Chosen for your Mac: you have \(ram) GB of memory. Change it whenever you like.",
                   "Choisi pour votre Mac : vous avez \(ram) Go de mémoire. Modifiable à tout moment.")
    }
}

// MARK: - Words & corrections

struct WordsSection: View {
    @State private var terms: [String] = []
    @State private var rules: [CorrectionRule] = []
    @State private var newTerm = ""
    @State private var heard = ""
    @State private var written = ""
    /// ISC-113 — ⌘Z on the two lists.
    ///
    /// The bin next to every word deleted immediately and for ever: one click
    /// too many and a term you taught it months ago was gone with no appeal.
    /// This is the window's own undo manager, so ⌘Z and the Edit menu both
    /// reach it, and so does ⇧⌘Z to put the deletion back.
    @Environment(\.undoManager) private var undoManager


    var body: some View {
        Group {
            PrefRow(title: L.t("Parole tue", "Your words", "Vos mots"),
                    note: L.t("Nomi, termini, grafie particolari che Kalamos deve scrivere sempre giuste. Puoi anche selezionare una parola ovunque e premere ⌃⌥L.",
                              "Names, terms and spellings Kalamos should always get right. You can also select a word anywhere and press ⌃⌥L.",
                              "Noms et graphies que Kalamos doit toujours écrire correctement. Vous pouvez aussi sélectionner un mot et faire ⌃⌥L.")) {
                VStack(alignment: .leading, spacing: 9) {
                    HStack(spacing: 8) {
                        field(L.t("Aggiungi una parola", "Add a word", "Ajouter un mot"), text: $newTerm)
                        PrefButton(title: L.t("Aggiungi", "Add", "Ajouter"), filled: true) {
                            let value = newTerm.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !value.isEmpty else { return }
                            Vocabulary.add(value)
                            newTerm = ""
                            reload()
                        }
                    }
                    // Scritto senza chiusure in coda: `startEditing` è un valore,
                    // non una chiusura, e in Swift non può seguirle.
                    PrefList(
                        items: terms,
                        empty: L.t("Nessuna parola, per ora.", "No words yet.",
                                   "Aucun mot pour l’instant."),
                        row: { term in
                            Text(term).font(Theme.font(12.5)).foregroundStyle(Theme.ink)
                        },
                        remove: { term in
                            undoably(L.t("Togli \(term)", "Remove \(term)", "Retirer \(term)")) {
                                Vocabulary.remove(term)
                            }
                        },
                        editText: { $0 },
                        commitEdit: { term, nuovo in
                            // Niente da annullare se non è cambiato niente: un ⌘Z
                            // che ripristina una lista identica consuma un passo di
                            // undo e sembra rotto.
                            guard nuovo.trimmingCharacters(in: .whitespacesAndNewlines) != term
                            else { return }
                            undoably(L.t("Modifica \(term)", "Edit \(term)", "Modifier \(term)")) {
                                Vocabulary.rename(term, to: nuovo)
                            }
                        }
                    )
                }
            }

            PrefRow(title: L.t("Correzioni", "Corrections", "Corrections"),
                    note: L.t("Una parola che sente sempre sbagliata: qui scrivi cosa sente e cosa deve scrivere.",
                              "A word it keeps hearing wrong: write what it hears and what it should type.",
                              "Un mot mal entendu : ce qu’il entend, et ce qu’il doit écrire.")) {
                VStack(alignment: .leading, spacing: 9) {
                    HStack(spacing: 8) {
                        field(L.t("sente…", "hears…", "entend…"), text: $heard)
                        Text("→").foregroundStyle(Theme.inkFaded)
                        field(L.t("…scrive", "…writes", "…écrit"), text: $written)
                        PrefButton(title: L.t("Aggiungi", "Add", "Ajouter"), filled: true) {
                            let from = heard.trimmingCharacters(in: .whitespacesAndNewlines)
                            let to = written.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !from.isEmpty, !to.isEmpty else { return }
                            Corrections.add(wrong: from, correct: to)
                            heard = ""; written = ""
                            reload()
                        }
                    }
                    PrefList(
                        items: rules,
                        empty: L.t("Nessuna correzione.", "No corrections.",
                                   "Aucune correction."),
                        row: { rule in
                            Text("\(rule.wrong)  →  \(rule.correct)")
                                .font(Theme.font(12.5)).foregroundStyle(Theme.ink)
                        },
                        remove: { rule in
                            undoably(L.t("Togli la correzione", "Remove correction",
                                         "Retirer la correction")) {
                                Corrections.remove(wrong: rule.wrong)
                            }
                        },
                        editText: Corrections.line,
                        commitEdit: { rule, edited in
                            guard let nuova = Corrections.parse(edited), nuova != rule else { return }
                            undoably(L.t("Modifica la correzione", "Edit correction",
                                         "Modifier la correction")) {
                                Corrections.replace(rule, with: nuova)
                            }
                        }
                    )
                }
            }
        }
        .onAppear(perform: reload)
        // An undo changes UserDefaults from outside this view, so nothing would
        // redraw without being told.
        .onReceive(NotificationCenter.default.publisher(for: UndoBridge.changed)) { _ in
            reload()
        }
    }

    private func reload() {
        terms = Vocabulary.terms
        rules = Corrections.rules
    }

    /// Do it, and register how to put both lists back exactly as they were.
    ///
    /// A SNAPSHOT of both lists, not "add the word again": `Vocabulary.add`
    /// appends, so re-adding a word deleted from the middle would return it to
    /// the bottom — the same words in a different order, which is not what was
    /// there. One snapshot also covers the case of deleting from both lists.
    ///
    /// The undo handler registers its own inverse, which is what makes ⇧⌘Z work
    /// and what lets you walk back through a whole run of deletions.
    private func undoably(_ name: String, _ change: () -> Void) {
        let beforeTerms = Vocabulary.terms
        let beforeRules = Corrections.rules
        change()
        reload()
        register(name, terms: beforeTerms, rules: beforeRules)
    }

    private func register(_ name: String, terms: [String], rules: [CorrectionRule]) {
        guard let undoManager else { return }
        undoManager.setActionName(name)
        undoManager.registerUndo(withTarget: UndoBridge.shared) { _ in
            MainActor.assumeIsolated {
                UndoBridge.restore(terms: terms, rules: rules, with: undoManager)
            }
        }
    }

    private func field(_ placeholder: String, text: Binding<String>) -> some View {
        PrefField(placeholder: placeholder, text: text)
    }

    /// One list shape for both, with the delete button on the row itself — the
    /// old menu made you click an entry to delete it, which is a destructive
    /// action hiding behind the gesture for selecting one.
    private func list<Item: Hashable, Row: View>(
        _ items: [Item], empty: String,
        @ViewBuilder row: @escaping (Item) -> Row,
        remove: @escaping (Item) -> Void,
        editText: ((Item) -> String)? = nil,
        commitEdit: ((Item, String) -> Void)? = nil,
        startEditing: Item? = nil
    ) -> some View {
        PrefList(items: items, empty: empty, row: row, remove: remove,
                 editText: editText, commitEdit: commitEdit, startEditing: startEditing)
    }
}

/// A list that grows with its contents, then stops growing and scrolls ALONE.
///
/// ISC-112 said the rows ran off the bottom of the window "with no way to reach
/// them". That was read out of the source and never reproduced, and it was
/// wrong: this section sits inside the Preferences page's own scroll view, so a
/// long list was always reachable by scrolling the page. What the ceiling really
/// buys is that the Corrections box stays on screen next to the words instead of
/// being pushed a page and a half down by a vocabulary that keeps growing —
/// which it now does from the menu bar, without this window ever being open.
///
/// The ceiling brought its own bug, and one gesture in real use found it: with
/// the pointer over the list, reaching the last row handed the wheel to the page
/// underneath and the whole window took off. AppKit calls that scroll chaining
/// and does it by design; `ContainedScroll` is the whole answer to it.
private struct PrefList<Item: Hashable, Row: View>: View {
    let items: [Item]
    let empty: String
    @ViewBuilder let row: (Item) -> Row
    let remove: (Item) -> Void
    /// Modifica in linea, quando la voce si sa scrivere su una riga.
    ///
    /// Restava `nil` sulle Correzioni perché sono una coppia e un campo solo non
    /// saprebbe quale metà sta cambiando. **Sbagliato, e lui l'ha fatto notare il
    /// 2026-08-12**: la riga già si legge `sente → scrive`, quindi il campo unico
    /// sa benissimo quale metà è quale, e si torna alla coppia con `Corrections.parse`.
    /// Il vero difetto era che una correzione sbagliata si poteva solo cancellare
    /// e riscrivere per intero.
    var editText: ((Item) -> String)? = nil
    var commitEdit: ((Item, String) -> Void)? = nil
    /// Riga da aprire già in modifica al primo disegno.
    ///
    /// Oggi nessuno la passa. È rimasta perché è il gancio che servirebbe a
    /// `--scatta` per fotografare la riga MENTRE la modifichi, che il 2026-08-05
    /// è stato l'unico stato rotto e l'unico che nessuno poteva guardare. Il
    /// tentativo di collegarla alla sonda quel giorno non ha funzionato e non è
    /// stato lasciato a metà: o si fa funzionare, o non c'è.
    var startEditing: Item? = nil
    @State private var editing: Item?
    @State private var draft: String
    @FocusState private var focused: Bool

    /// Lo stato iniziale si costruisce QUI, non in `onAppear`.
    ///
    /// Scritto in `onAppear` non funzionava e per due motivi insieme: la riga non
    /// si apriva, e il riquadro si accorciava da sei righe a quattro, perché
    /// `ContainedScroll` misura l'altezza al primo disegno e una mutazione di
    /// stato durante quel disegno la fa misurare sul contenuto sbagliato. Trovato
    /// fotografando il pannello intero, che è l'unica ragione per cui si sapeva.
    init(items: [Item], empty: String, @ViewBuilder row: @escaping (Item) -> Row,
         remove: @escaping (Item) -> Void,
         editText: ((Item) -> String)? = nil,
         commitEdit: ((Item, String) -> Void)? = nil,
         startEditing: Item? = nil) {
        self.items = items
        self.empty = empty
        self.row = row
        self.remove = remove
        self.editText = editText
        self.commitEdit = commitEdit
        self.startEditing = startEditing
        let apri = startEditing.flatMap { items.contains($0) ? $0 : nil }
        _editing = State(initialValue: apri)
        _draft = State(initialValue: apri.flatMap { editText?($0) } ?? "")
    }

    /// Un bottone di riga: icona, area cliccabile tutta, nessun testo.
    ///
    /// `contentShape` non è decorazione — senza, le parti trasparenti del
    /// riempimento non vengono colpite e il bottone si clicca solo sul disegno
    /// dell'icona. È la stessa regola che è già costata due volte in questa app.
    @ViewBuilder
    private func rowButton(_ icon: String, _ label: String,
                           strong: Bool = false, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: strong ? .semibold : .regular))
                .foregroundStyle(strong ? Theme.pen : Theme.inkFaded)
                .padding(6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    /// Six rows. A row measures 38 points (photographed, not assumed), so this
    /// is high enough that an ordinary list never scrolls and low enough that a
    /// long one cannot push what sits below it out of the window.
    private let cap: CGFloat = 228

    var body: some View {
        ContainedScroll(cap: cap) {
            VStack(alignment: .leading, spacing: 0) {
                if items.isEmpty {
                    Text(empty)
                        .font(Theme.font(11.5))
                        .foregroundStyle(Theme.inkFaded)
                        .padding(.vertical, 8)
                } else {
                    ForEach(Array(items.enumerated()), id: \.element) { index, item in
                        HStack {
                            if editing == item, let commitEdit {
                                TextField("", text: $draft)
                                    .textFieldStyle(.plain)
                                    .font(Theme.font(12.5))
                                    .foregroundStyle(Theme.ink)
                                    .focused($focused)
                                    .onSubmit { commitEdit(item, draft); editing = nil }
                                    .onExitCommand { editing = nil }
                                Spacer(minLength: 8)
                                // Due bottoni veri, e non solo Invio.
                                //
                                // La prima versione si chiudeva con Invio, Esc o
                                // perdendo il fuoco, e dal campo **non si usciva**
                                // (segnalato da lui, 2026-08-05). Il campo vive
                                // dentro un `NSScrollView` ospitato, e lì il tasto
                                // Invio non arriva all'azione di conferma di
                                // SwiftUI. Una conferma che dipende dal routing di
                                // un tasto è una conferma che qualche volta non
                                // c'è: un bottone che si vede non ha quel modo di
                                // fallire. Invio resta, come scorciatoia.
                                rowButton("checkmark", L.t("Conferma", "Confirm", "Confirmer"),
                                          strong: true) {
                                    commitEdit(item, draft); editing = nil
                                }
                                rowButton("xmark", L.t("Annulla", "Cancel", "Annuler")) {
                                    editing = nil
                                }
                            } else {
                                row(item)
                                Spacer(minLength: 8)
                                if let editText, commitEdit != nil {
                                    rowButton("pencil", L.t("Modifica", "Edit", "Modifier")) {
                                        draft = editText(item)
                                        editing = item
                                        focused = true
                                    }
                                }
                                // Il cestino sparisce mentre modifichi: tre icone
                                // in fila, di cui una distruttiva accanto a
                                // «conferma», è un clic sbagliato che cancella la
                                // parola che stavi correggendo.
                                rowButton("trash", L.t("Togli", "Remove", "Retirer")) {
                                    remove(item)
                                }
                            }
                        }
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(index.isMultiple(of: 2) ? Theme.card.opacity(0.75) : .clear)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(RoundedRectangle(cornerRadius: 7).fill(Theme.card.opacity(0.45)))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.rule, lineWidth: 1.5))
    }
}

// MARK: - A scroll view that keeps the wheel to itself

/// Grows with its content up to `cap`, then scrolls — and never hands the wheel
/// to the scroll view underneath it.
///
/// SwiftUI has no modifier for this on macOS (there is no `overscroll-behavior`
/// here), so the box is a real `NSScrollView` with SwiftUI hosted inside it. The
/// height comes from `sizeThatFits`, which asks the hosted content how tall it
/// wants to be at the offered width and clamps the answer. That is a question
/// about the content only — nothing reads back a height this view has already
/// imposed, so there is no loop to converge.
private struct ContainedScroll<Content: View>: NSViewRepresentable {
    let cap: CGFloat
    @ViewBuilder let content: () -> Content

    /// A second copy of the content, hosted in NO window and NO hierarchy, whose
    /// only job is to answer "how tall at this width?".
    ///
    /// The first attempt measured the live view: set its width constraint, force
    /// `layoutSubtreeIfNeeded`, read the height. That is a layout pass started
    /// from inside a layout pass, and AppKit kills the process for it — the
    /// window never even opened. Measuring a detached copy asks the same question
    /// with nothing running underneath it.
    @MainActor final class Measurer {
        let view: NSHostingView<Content>
        init(_ content: Content) { view = NSHostingView(rootView: content) }

        func height(atWidth width: CGFloat) -> CGFloat {
            view.frame.size.width = width
            return view.fittingSize.height
        }
    }

    func makeCoordinator() -> Measurer { Measurer(content()) }

    func makeNSView(context: Context) -> NoChainScrollView {
        let scroll = NoChainScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        // No rubber band. Elasticity is what makes a list that is already at its
        // end feel like it still has somewhere to go.
        scroll.verticalScrollElasticity = .none
        scroll.horizontalScrollElasticity = .none

        let host = NSHostingView(rootView: content())
        host.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = host
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            host.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
        ])
        return scroll
    }

    func updateNSView(_ scroll: NoChainScrollView, context: Context) {
        (scroll.documentView as? NSHostingView<Content>)?.rootView = content()
        context.coordinator.view.rootView = content()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NoChainScrollView,
                      context: Context) -> CGSize? {
        let width = proposal.width ?? nsView.frame.width
        guard width > 0 else { return nil }
        return CGSize(width: width,
                      height: min(context.coordinator.height(atWidth: width), cap))
    }
}

/// The one behaviour this whole file exists to change.
///
/// AppKit chains by design: when a scroll view cannot move any further it hands
/// the event up the responder chain, and the enclosing one takes over. Inside a
/// settings page that reads as a bug — you reach the last word and the entire
/// window takes off under your pointer.
///
/// So at the limit the event is EATEN rather than forwarded. Two exceptions keep
/// it from becoming a dead zone: a list short enough to need no scrolling passes
/// everything through, and a horizontal gesture is never ours.
final class NoChainScrollView: NSScrollView {

    override func scrollWheel(with event: NSEvent) {
        // `documentVisibleRect` is in the flipped coordinates of the hosted
        // SwiftUI view: y grows downward, so minY == 0 is the first row.
        let swallow = Self.swallows(contentHeight: documentView?.bounds.height ?? 0,
                                    visibleHeight: contentView.bounds.height,
                                    offsetY: documentVisibleRect.minY,
                                    deltaY: event.scrollingDeltaY,
                                    deltaX: event.scrollingDeltaX)
        if swallow { return }
        super.scrollWheel(with: event)
    }

    /// Eat this wheel event, or let AppKit have it?
    ///
    /// Pulled out of `scrollWheel` because it is the only interesting thing in
    /// this class and an `NSEvent` cannot be built in a test. As a pure function
    /// of five numbers it is checkable, and `NoChainScrollTests` checks it at
    /// every edge — including the two that would make it feel broken: a short
    /// list must never swallow (the page would freeze under the pointer), and at
    /// the bottom, scrolling back UP must never swallow (you could not return).
    static func swallows(contentHeight: CGFloat, visibleHeight: CGFloat,
                         offsetY: CGFloat, deltaY: CGFloat, deltaX: CGFloat) -> Bool {
        // Nothing of ours to scroll → the page should still work under the
        // pointer. Without this, hovering a two-word list would freeze the window.
        guard contentHeight > visibleHeight + 0.5 else { return false }
        // Sideways is not our gesture.
        guard abs(deltaY) >= abs(deltaX) else { return false }

        let atTop = offsetY <= 0.5
        let atBottom = offsetY + visibleHeight >= contentHeight - 0.5
        return (deltaY > 0 && atTop) || (deltaY < 0 && atBottom)
    }
}

// MARK: - Advanced

struct AdvancedSection: View {
    @Binding var draft: SettingsDraft
    /// Only the two buttons that do something now instead of deciding something.
    let actions: PreferencesActions

    var body: some View {
        Group {
            PrefRow(title: L.t("Lingua di Kalamos", "Kalamos's language", "Langue de Kalamos"),
                    note: L.t("La lingua in cui è scritto il menu e questa finestra. Non è la lingua in cui detti.",
                              "The language the menu and this window are written in. Not the one you dictate in.",
                              "La langue du menu et de cette fenêtre. Pas celle de la dictée.")) {
                ChipRow(options: Language.allCases.map { ($0, $0.displayName, "") },
                        isOn: { draft.uiLanguage == $0 },
                        pick: { draft.uiLanguage = $0 })
            }

            PrefRow(title: L.t("Come entra il testo", "How the text gets in",
                               "Comment le texte arrive"),
                    note: L.t("Gli appunti restano il modo più veloce e funziona ovunque, ma per un attimo la tua copia diventa la dettatura. Scrivendo carattere per carattere gli appunti non si toccano.",
                              "The clipboard is the fastest way and works everywhere, but for a moment your copy becomes the dictation. Typing it in character by character never touches the clipboard.",
                              "Le presse-papiers est le plus rapide, mais un instant votre copie devient la dictée. En tapant caractère par caractère, il n’est jamais touché.")) {
                VStack(alignment: .leading, spacing: 7) {
                    ChipRow(options: [
                        (TextInsertionMode.clipboard, L.t("Appunti", "Clipboard", "Presse-papiers"),
                         L.t("istantaneo", "instant", "instantané")),
                        (TextInsertionMode.typing, L.t("Scritto a mano", "Typed in", "Tapé"),
                         L.t("non tocca gli appunti", "leaves the clipboard alone",
                             "ne touche pas le presse-papiers")),
                    ], isOn: { draft.insertionMode == $0 }, pick: { draft.insertionMode = $0 })
                    Text(L.t("In ogni caso il testo resta nelle trascrizioni recenti, quindi con «Copia l'ultima» lo recuperi comunque.",
                             "Either way the text stays in the recent transcriptions, so \"Copy Last\" always gets it back.",
                             "Dans les deux cas le texte reste dans les transcriptions récentes."))
                        .font(Theme.font(11.5)).foregroundStyle(Theme.inkFaded)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            PrefRow(title: L.t("Quando liberare la memoria", "When to free the memory",
                               "Quand libérer la mémoire"),
                    note: L.t("Mentre stanno in memoria i modelli occupano circa 6 GB. Rileggerli dal disco costa qualche secondo, soprattutto quello di pulizia.",
                              "While loaded, the models hold about 6 GB. Reading them back off the disk costs a few seconds, the cleanup one most of all.",
                              "En mémoire, les modèles occupent environ 6 Go. Les relire depuis le disque coûte quelques secondes, surtout celui de nettoyage.")) {
                // Every chip is a bare number, and the sentence underneath
                // describes whichever one is chosen.
                //
                // "Mai" used to carry its own note, and a note on one chip out of
                // five makes that chip taller than its neighbours and stretches
                // the row — reported 2026-07-31. Showing the note only while
                // selected would have been worse: the row would change shape
                // under the click that selected it. This way the geometry never
                // moves AND every option gets explained, not just the last one.
                VStack(alignment: .leading, spacing: 8) {
                    // Four, on one line, and one of them is a field.
                    //
                    // It was five — 1, 5, 15, 30, Mai — which wrapped and left
                    // "Mai" alone on a second row looking like an afterthought.
                    // His two doubts about which to drop were both right and
                    // pulled opposite ways: one minute is aggressive enough to
                    // make you pay a reload for stepping away to read something,
                    // and thirty is so close to never that it barely earns a
                    // slot. So both go, and neither is lost: whatever number you
                    // want, you type it. A preset is a shortcut, not a menu of
                    // the only allowed answers. (2026-08-01.)
                    ChipRow(options: [
                        (300, L.t("5 min", "5 min", "5 min"), ""),
                        (900, L.t("15 min", "15 min", "15 min"), ""),
                        (0, L.t("Mai", "Never", "Jamais"), ""),
                        (Self.customIdle, L.t("Scegli tu", "Your own", "Au choix"), ""),
                    ], isOn: { value in
                        value == Self.customIdle
                            ? !Self.idlePresets.contains(draft.idleSeconds)
                            : draft.idleSeconds == value
                    }, pick: { value in
                        // Landing on the field must not change the setting under
                        // the click: an install that already reads 30 min keeps
                        // 30 min, and the field opens showing it.
                        guard value == Self.customIdle else { draft.idleSeconds = value; return }
                        if Self.idlePresets.contains(draft.idleSeconds) { draft.idleSeconds = 1800 }
                    })
                    if !Self.idlePresets.contains(draft.idleSeconds) {
                        HStack(spacing: 8) {
                            PrefField(placeholder: "30", text: Binding(
                                get: { String(max(1, draft.idleSeconds / 60)) },
                                set: { typed in
                                    // Digits only, and never zero: zero is "Mai",
                                    // which is a chip. A field that can silently
                                    // become another chip's value is a field that
                                    // lies about what is selected.
                                    let digits = typed.filter(\.isNumber).prefix(4)
                                    let minutes = max(1, min(1440, Int(digits) ?? 1))
                                    draft.idleSeconds = minutes * 60
                                }))
                            .frame(maxWidth: 90)
                            Text(L.t("minuti", "minutes", "minutes"))
                                .font(Theme.font(12.5))
                                .foregroundStyle(Theme.inkFaded)
                        }
                    }
                    Text(idleExplanation)
                        .font(Theme.font(11.5))
                        .foregroundStyle(Theme.pen)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            PrefRow(title: L.t("Edit Mode", "Edit Mode", "Edit Mode"),
                    note: L.t("Tieni premuto il tasto qui sotto e detta un'istruzione: Kalamos trasforma il testo che hai selezionato invece di scriverne di nuovo.",
                              "Hold the key below and speak an instruction: Kalamos transforms the text you selected instead of writing new text.",
                              "Maintenez la touche ci-dessous et dictez une instruction : Kalamos transforme le texte sélectionné."),
                    toggle: $draft.editModeEnabled) {
                VStack(alignment: .leading, spacing: 9) {
                    if draft.editModeEnabled {
                        ChipRow(options: [
                            (UInt16(0x3F), "Fn / Globe", ""),
                            (UInt16(0x3D), "Right Option", ""),
                            (UInt16(0x3C), "Right Shift", ""),
                        ], isOn: { draft.editModeKeyCode == $0 },
                           pick: { draft.editModeKeyCode = $0 })
                        if draft.editModeKeyCode == draft.hotKeyCode {
                            Text(L.t("Questo è lo stesso tasto della dettatura, quindi Edit Mode resta spento. Scegline un altro.",
                                     "That is the dictation key, so Edit Mode stays off. Pick another one.",
                                     "C’est la touche de dictée : Edit Mode reste inactif. Choisissez-en une autre."))
                                .font(Theme.font(11.5))
                                .foregroundStyle(Theme.pen)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }

            PrefRow(title: L.t("All'accensione del Mac", "When the Mac starts",
                               "Au démarrage du Mac")) {
                PrefToggle(title: L.t("Avvia Kalamos al login", "Launch Kalamos at login",
                                      "Lancer Kalamos à l’ouverture"),
                           isOn: $draft.launchAtLogin)
            }

            PrefRow(title: L.t("Se qualcosa non va", "If something misbehaves",
                               "Si quelque chose cloche")) {
                HStack(spacing: 9) {
                    PrefButton(title: L.t("Diagnostica…", "Diagnostics…", "Diagnostic…")) {
                        actions.showDiagnostics()
                    }
                    PrefButton(title: L.t("Rifai la configurazione…", "Run setup again…",
                                          "Refaire la configuration…")) {
                        actions.rerunOnboarding()
                    }
                }
            }
        }
    }

    /// The values that have a chip of their own. Anything else is "Scegli tu",
    /// and the two tests — which chip is lit, whether the field shows — both
    /// read this one list, so they cannot disagree about what a preset is.
    static let idlePresets = [300, 900, 0]
    /// Not a duration: the sentinel the fourth chip carries. Negative so it can
    /// never collide with a real number of seconds.
    static let customIdle = -1

    /// One line, same height whatever is chosen, describing the current choice.
    private var idleExplanation: String {
        guard draft.idleSeconds > 0 else {
            return L.t("I modelli restano in memoria e sono pronti già dall'avvio.",
                       "The models stay in memory and are ready from launch.",
                       "Les modèles restent en mémoire, prêts dès le lancement.")
        }
        let minutes = draft.idleSeconds / 60
        // "un secondo" was a number nobody had measured, and he caught it. On
        // this Mac the cleanup model comes back in 4–5 seconds with the file
        // still warm in the page cache, and its own code puts a cold load at
        // 10–30. "Qualche secondo" is the honest shape of that.
        return L.t("Dopo \(minutes) minut\(minutes == 1 ? "o" : "i") senza dettare la memoria si libera. La dettatura successiva costa qualche secondo in più, il tempo di rileggere i modelli.",
                   "After \(minutes) minute\(minutes == 1 ? "" : "s") without dictating the memory is freed. The next dictation costs a few seconds more, while the models are read back.",
                   "Après \(minutes) minute\(minutes == 1 ? "" : "s") sans dicter, la mémoire est libérée. La dictée suivante coûte quelques secondes de plus, le temps de relire les modèles.")
    }
}

// MARK: - Onda

/// The wave, and the four decisions it comes with.
///
/// **This section applies immediately and has no place in `SettingsDraft`,
/// deliberately.** Everything else in this window is a decision with a cost —
/// re-registering a global event tap, throwing away a loaded model — so it waits
/// for **Applica**. A colour has no cost, and a colour you cannot see land is a
/// colour you cannot choose: the preview above the pills has to change the
/// instant you touch one, or you are picking from names. The precedent inside
/// this window is the vocabulary, which is entries rather than settings and
/// likewise never waits.
///
/// The consequence is that the footer keeps saying "tutto applicato" while you
/// work here, and that is true: there is nothing pending, because it is already
/// done.
struct WaveSection: View {
    @ObservedObject var state: AppState

    var body: some View {
        Group {
            PrefRow(title: L.t("L'onda mentre detti", "The wave while you dictate",
                               "L'onde pendant la dictée"),
                    note: L.t("Compare quando il microfono si apre e sparisce quando la dettatura finisce. Segue la tua voce: non ascolta niente in più, guarda l'audio che Kalamos sta già registrando.",
                              "It appears when the microphone opens and goes away when the dictation ends. It follows your voice from the audio Kalamos is already recording — nothing extra is listened to.",
                              "Elle apparaît quand le micro s'ouvre et disparaît à la fin de la dictée. Elle suit votre voix à partir de l'audio déjà enregistré."),
                    toggle: $state.waveEnabled) {
                preview
            }

            PrefRow(title: L.t("Come si apre e si chiude la pillola",
                               "How the pill opens and closes",
                               "Comment la pastille s'ouvre et se ferme"),
                    note: L.t("Vale solo quando l'onda sta fuori dal notch. La chiusura è l'apertura al contrario, sempre.",
                              "Only when the wave sits outside the notch. Closing is opening in reverse, always.",
                              "Uniquement hors du notch. La fermeture est l'ouverture à l'envers, toujours.")) {
                ChipRow(options: AperturaPillola.allCases.map { ($0.rawValue, $0.titolo, $0.nota) },
                        isOn: { state.aperturaPillola.rawValue == $0 },
                        pick: { state.aperturaPillola = AperturaPillola(rawValue: $0) ?? .corrente })
            }

            PrefRow(title: L.t("Colore dell'onda", "Wave colour", "Couleur de l'onde")) {
                TintRow(tints: WavePalette.wave, selection: $state.waveTint)
            }

            PrefRow(title: L.t("Colore della pillola", "Pill colour", "Couleur de la pastille")) {
                VStack(alignment: .leading, spacing: 12) {
                    TintRow(tints: WavePalette.shell, selection: $state.waveShellTint)
                    PrefToggle(title: L.t("Disegna la pillola dietro l'onda",
                                          "Draw the pill behind the wave",
                                          "Dessiner la pastille derrière l'onde"),
                               note: L.t("Senza pillola resta solo l'onda, sospesa sullo schermo. La trascini lo stesso: si prende da tutta la sua area, anche dove non c'è niente di dipinto. Appesa al notch la pillola non serve, perché lì il guscio è nero e continua l'hardware.",
                                         "With no pill only the wave is left, floating on the screen. You can still drag it: the whole of its area is the handle, painted or not. Hanging from the notch the pill is not used, because there the shell is black and continues the hardware.",
                                         "Sans pastille il ne reste que l'onde, suspendue à l'écran. Vous pouvez toujours la déplacer : toute sa surface sert de poignée. Sous l'encoche la pastille ne sert pas : la coque y est noire et prolonge le matériel."),
                               isOn: $state.waveShell)
                }
            }

            PrefRow(title: L.t("Dove compare", "Where it appears", "Où elle apparaît"),
                    note: L.t("Appesa al notch sta in cima allo schermo. Come isoletta diventa una pillola piccola che trascini dove vuoi, e trascinarla è il modo di scegliere il punto: la prendi da qualunque punto della pillola.",
                              "Hanging from the notch it sits at the top of the screen. As a floating island it becomes a small pill you drag where you like, and dragging it is how the spot gets chosen: grab it anywhere on the pill.",
                              "Sous l'encoche, elle reste en haut de l'écran. En îlot, elle devient une petite pastille que vous faites glisser où vous voulez : attrapez-la n'importe où.")) {
                ChipRow(options: [
                    (WavePosition.notch, L.t("Dal notch", "From the notch", "Sous l'encoche"), ""),
                    (WavePosition.bubble, L.t("Isoletta", "Floating island", "Îlot"), ""),
                ], isOn: { state.wavePosition == $0 }, pick: { state.wavePosition = $0 })
            }
        }
    }

    /// The island as it will actually appear — same wave, same shell, **same
    /// shape**, alive and in the colours currently chosen.
    ///
    /// Not a swatch of colour next to a label: the thing being decided is a
    /// moving picture on a dark ground, and a square of flat blue says nothing
    /// about how it will read. `WaveformView` is the SAME view the island draws,
    /// not a copy of it, so a preview cannot show something the island does not.
    ///
    /// The shape follows the position for the same reason, and it is why the
    /// preview changes size: hanging from the notch the island is a band, free of
    /// it the island is a small pill, and a preview that kept drawing a band for both
    /// would be showing him a shape the app stopped having on 2026-08-16. The wave
    /// inside the pill is laid out by `BubbleGeometry` — the island's own
    /// arithmetic, called with the smaller diameter rather than copied with
    /// numbers chosen by eye.
    @ViewBuilder
    private var preview: some View {
        if posizione == .notch { notchPreview } else { bubblePreview }
    }

    /// La forma da mostrare, con la sonda che può scavalcare l'impostazione.
    ///
    /// Stessa ragione di `WaveIsland.probePosition`, che questo campo È: una
    /// sonda che dovesse SCRIVERE `wavePosition` per fotografare l'anteprima
    /// lascerebbe la sua Kalamos configurata da chi ha scattato per ultimo. Senza
    /// questa riga l'anteprima della pillola non era fotografabile affatto, e
    /// l'unica pagina che la mostra si sarebbe giudicata leggendo il sorgente.
    private var posizione: WavePosition {
        WaveIsland.probePosition ?? state.wavePosition
    }

    private var notchPreview: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: 10)
            WaveformView(livello: 0.55,
                         tinta: WaveTint.color(from: state.waveTint),
                         attiva: state.waveEnabled)
                // The same proportions as the island, at 300×92 instead of
                // 400×128. The caption came off the island on 2026-08-16 and had
                // to come off here in the same breath: this preview says in its
                // own comment that it cannot show something the island does not,
                // and a preview left behind is a picture of last week's app.
                .frame(height: 52)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 5)
        .frame(width: 300, height: Self.previewHeight)
        .background {
            UnevenRoundedRectangle(cornerRadii: .init(bottomLeading: 20, bottomTrailing: 20),
                                   style: .continuous)
                .fill(.black)
        }
        .modifier(PreviewFrame(enabled: state.waveEnabled))
    }

    /// The pill, at the size it really is.
    ///
    /// **Not scaled to the row's height like the notch band is**, and that is the
    /// point of the whole change: what he asked for is a SMALL island, so a
    /// preview that blew it up to 92 points would be answering the question
    /// "what shape" while hiding the question "how big". Drawn at its own 150×40
    /// inside a box as tall as the other preview, it is the only preview in this
    /// window that is life-size, because size is the thing being decided.
    private var bubblePreview: some View {
        ZStack {
            if state.waveShell {
                Capsule(style: .continuous)
                    .fill(WaveTint.color(from: state.waveShellTint).opacity(0.94))
            } else {
                // No shell means the wave floats on the desktop, and the preview
                // has to say so: nothing at all on paper would read as a white
                // pill, which is the one thing that never happens on screen.
                Capsule(style: .continuous).fill(Theme.ink.opacity(0.10))
                    .overlay(Capsule(style: .continuous)
                        .strokeBorder(Theme.rule,
                                      style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])))
            }
            WaveformView(livello: 0.55,
                         tinta: WaveTint.color(from: state.waveTint),
                         attiva: state.waveEnabled,
                         profilo: BubbleGeometry.profile(box: previewWave,
                                                         in: BubbleGeometry.size))
                .frame(width: previewWave.width, height: previewWave.height)
        }
        .frame(width: BubbleGeometry.width, height: BubbleGeometry.height)
        .clipShape(Capsule(style: .continuous))
        // The row keeps the height the band preview has, so flipping the chip
        // does not make the page jump; the pill simply sits in the middle of it,
        // small, which is what it is.
        .frame(height: Self.previewHeight)
        .modifier(PreviewFrame(enabled: state.waveEnabled))
    }

    /// One height for both shapes, so flipping the chip does not make the row
    /// jump.
    private static let previewHeight: CGFloat = 92

    private var previewWave: CGSize {
        BubbleGeometry.waveSize(in: BubbleGeometry.size)
    }
}

/// What every preview of the island shares: dimmed when the wave is off, and hard
/// left like every other row on the page.
///
/// Centred, the block floated with its own title flush left two lines above it,
/// and on a pane where everything else starts at the same margin one centred block
/// reads as adrift rather than as featured (MacAppRules §2, check 2).
private struct PreviewFrame: ViewModifier {
    let enabled: Bool

    func body(content: Content) -> some View {
        content
            .opacity(enabled ? 1 : 0.45)
            // **Al CENTRO della riga, non a sinistra** (sua richiesta,
            // 2026-08-16), e vale per tutt'e due le forme perché tutt'e due
            // passano di qui: la banda del notch è larga 300 punti e la pillola
            // 150, quindi centrarne una sola le farebbe saltare da una parte
            // all'altra scambiando il chip — lo stesso ballo che `previewHeight`
            // esiste già per impedire sull'altro asse.
            //
            // **È l'unica riga che serviva, e ci sono arrivato per esclusione.**
            // Prima ho aggiunto un modificatore sopra le due anteprime, prima con
            // `maxWidth: .infinity` e poi con due spaziatori, e la fotografia ha
            // detto no tutte e due le volte: quale che fosse l'involucro, dentro
            // c'era già questo `frame` a tutta larghezza che le inchiodava al
            // bordo sinistro. Un contenitore che allinea non si scavalca da fuori.
            .frame(maxWidth: .infinity, alignment: .center)
    }
}

/// A row of colour pills, one tap and it is done.
///
/// The system colour panel was the alternative and is the wrong material twice
/// over: it hides every colour behind a click, and it arrives wearing macOS's
/// livery inside a window that has its own (MacAppRules §2). Same reason
/// `ChipRow` exists instead of a `Picker`.
///
/// `selection` is the `"r g b a"` string the setting is stored as, so the
/// comparison is textual and the persistence stays readable with `defaults read`.
struct TintRow: View {
    let tints: [(name: String, color: Color)]
    @Binding var selection: String

    var body: some View {
        HStack(spacing: 10) {
            ForEach(tints, id: \.name) { tint in
                let value = WaveTint.string(from: tint.color)
                let chosen = Self.sameColour(value, selection)
                Button { selection = value } label: {
                    Circle()
                        .fill(tint.color)
                        .frame(width: 22, height: 22)
                        .overlay {
                            if chosen {
                                // Two rings, not one: a white ring vanishes on the
                                // pearl pill and an ink ring vanishes on the black
                                // one, so the mark carries both and is visible on
                                // every colour in the row.
                                Circle().strokeBorder(.white, lineWidth: 2)
                                Circle().strokeBorder(Theme.ink.opacity(0.6), lineWidth: 0.5)
                            } else {
                                // A full point at a quarter opacity, not half a
                                // point at fifteen percent: on the night face the
                                // dark pills sit on a dark page, and a ring that
                                // faint stopped being an edge — Petrolio, Bosco and
                                // Grafite were three smudges (seen in the dark
                                // photograph, 2026-08-16).
                                Circle().strokeBorder(Theme.ink.opacity(0.25), lineWidth: 1)
                            }
                        }
                        // The whole disc, not the pixel you aimed at.
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(tint.name)
                .accessibilityLabel(tint.name)
                .accessibilityAddTraits(chosen ? [.isButton, .isSelected] : .isButton)
            }
            Spacer(minLength: 0)
        }
    }

    /// Two `"r g b a"` strings are the same colour when every channel agrees to
    /// the hundredth: the `Color → NSColor → sRGB` round trip shaves the third
    /// decimal, and comparing the strings exactly would light no pill at all.
    ///
    /// `nonisolated` because it is arithmetic on two strings: a `View` is
    /// main-actor by inheritance, and a pure helper that comes along for the ride
    /// drags every caller — the test included — onto the main actor for nothing.
    nonisolated static func sameColour(_ a: String, _ b: String) -> Bool {
        let x = a.split(separator: " ").compactMap { Double($0) }
        let y = b.split(separator: " ").compactMap { Double($0) }
        guard x.count == 4, y.count == 4 else { return false }
        return zip(x, y).allSatisfy { abs($0 - $1) < 0.01 }
    }
}
