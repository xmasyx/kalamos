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
                // Right Control is absent on purpose: Apple keyboards have one
                // Control key, on the left.
                ChipRow(options: [
                    (UInt16(0x36), "Right Command", ""),
                    (UInt16(0x3D), "Right Option", ""),
                    (UInt16(0x3C), "Right Shift", ""),
                    (UInt16(0x3F), "Fn / Globe", ""),
                ], isOn: { draft.hotKeyCode == $0 }, pick: { draft.hotKeyCode = $0 })
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
            PrefRow(title: L.t("Impostazioni aggiuntive", "Additional settings",
                               "Réglages supplémentaires"),
                    note: L.t("Quattro dettagli sul testo che esce: come si attacca a quello che c'è già, e come comincia e come finisce.",
                              "Four details about the text that comes out: how it joins what is already there, and how it starts and ends.",
                              "Quatre détails sur le texte produit : comment il rejoint ce qui précède, et comment il commence et finit.")) {
                VStack(alignment: .leading, spacing: 9) {
                    PrefToggle(title: L.t("Metti uno spazio prima", "Add a space in front",
                                 "Ajouter une espace devant"), isOn: $draft.spaceBetweenDictations)

                    PrefToggle(title: L.t("Decidi la maiuscola da quello che c'è prima",
                                 "Decide the capital from what comes before",
                                 "Décider la majuscule d’après ce qui précède"), isOn: $draft.smartCapitalization)

                    PrefToggle(title: L.t("Comincia sempre in minuscolo", "Always start lowercase",
                                 "Toujours commencer en minuscule"), isOn: $draft.lowercaseFirstLetter)

                    PrefToggle(title: L.t("Togli il punto finale", "Drop the final full stop",
                                 "Retirer le point final"), isOn: $draft.removeTrailingPeriod)

                    Text(L.t("Le ultime due servono per le ricerche e per il terminale, dove la maiuscola e il punto sono rumore. Il punto interrogativo resta: quello vuol dire qualcosa.",
                             "The last two are for search fields and terminals, where a capital and a full stop are noise. A question mark stays: that one means something.",
                             "Les deux dernières servent aux recherches et au terminal. Le point d’interrogation reste : lui veut dire quelque chose."))
                        .font(Theme.font(11.5))
                        .foregroundStyle(Theme.inkFaded)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(L.t("Maiuscola dopo un punto, minuscola se stai finendo una frase. Dove l'app non lascia leggere quello che c'è prima del cursore — terminali, Electron — la maiuscola resta com'è.",
                             "A capital after a full stop, lowercase when you are still finishing a sentence. Where an app will not let Kalamos read what is before the cursor — terminals, Electron — the capital is left alone.",
                             "Majuscule après un point, minuscule si la phrase continue. Là où l’app ne laisse pas lire ce qui précède le curseur, la majuscule reste telle quelle."))
                        .font(Theme.font(11.5))
                        .foregroundStyle(Theme.inkFaded)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            PrefRow(title: L.t("Modello che ti ascolta", "The model that hears you",
                               "Le modèle qui vous écoute"),
                    note: L.t("Turbo è il compromesso giusto quasi sempre.",
                              "Turbo is the right trade-off almost always.",
                              "Turbo est le bon compromis presque toujours.")) {
                ChipRow(options: ModelCatalog.speech.map { ($0.id, $0.title, $0.note) },
                        isOn: { draft.whisperModel == $0 },
                        pick: { draft.whisperModel = $0 })
            }
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
                    note: L.t("Il modello locale mette la punteggiatura, toglie gli intercalari e chiude le frasi lasciate a metà.",
                              "The local model punctuates, drops filler and resolves half-finished sentences.",
                              "Le modèle local ponctue, retire les hésitations et termine les phrases.")) {
                ChipRow(options: [
                    (FormatterMode.localLLM, L.t("Modello locale", "Local model", "Modèle local"),
                     L.t("il migliore", "the best one", "le meilleur")),
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
                        .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.6)))
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
                    list(terms, empty: L.t("Nessuna parola, per ora.", "No words yet.",
                                           "Aucun mot pour l’instant.")) { term in
                        Text(term).font(Theme.font(12.5)).foregroundStyle(Theme.ink)
                    } remove: { Vocabulary.remove($0); reload() }
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
                    list(rules, empty: L.t("Nessuna correzione.", "No corrections.",
                                           "Aucune correction.")) { rule in
                        Text("\(rule.wrong)  →  \(rule.correct)")
                            .font(Theme.font(12.5)).foregroundStyle(Theme.ink)
                    } remove: { Corrections.remove(wrong: $0.wrong); reload() }
                }
            }
        }
        .onAppear(perform: reload)
    }

    private func reload() {
        terms = Vocabulary.terms
        rules = Corrections.rules
    }

    private func field(_ placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .font(Theme.font(12.5))
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.6)))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.rule, lineWidth: 1.5))
            .frame(maxWidth: 190)
    }

    /// One list shape for both, with the delete button on the row itself — the
    /// old menu made you click an entry to delete it, which is a destructive
    /// action hiding behind the gesture for selecting one.
    private func list<Item: Hashable, Row: View>(
        _ items: [Item], empty: String,
        @ViewBuilder row: @escaping (Item) -> Row,
        remove: @escaping (Item) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if items.isEmpty {
                Text(empty)
                    .font(Theme.font(11.5))
                    .foregroundStyle(Theme.inkFaded)
                    .padding(.vertical, 8)
            } else {
                ForEach(Array(items.enumerated()), id: \.element) { index, item in
                    HStack {
                        row(item)
                        Spacer(minLength: 8)
                        Button { remove(item) } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.inkFaded)
                                .padding(6)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(L.t("Togli", "Remove", "Retirer"))
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(index.isMultiple(of: 2) ? Color.white.opacity(0.45) : .clear)
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.25)))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.rule, lineWidth: 1.5))
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
                    ChipRow(options: [
                        (60, L.t("1 min", "1 min", "1 min"), ""),
                        (300, L.t("5 min", "5 min", "5 min"), ""),
                        (900, L.t("15 min", "15 min", "15 min"), ""),
                        (1800, L.t("30 min", "30 min", "30 min"), ""),
                        (0, L.t("Mai", "Never", "Jamais"), ""),
                    ], isOn: { draft.idleSeconds == $0 }, pick: { draft.idleSeconds = $0 })
                    Text(idleExplanation)
                        .font(Theme.font(11.5))
                        .foregroundStyle(Theme.pen)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            PrefRow(title: L.t("Edit Mode", "Edit Mode", "Edit Mode"),
                    note: L.t("Tieni premuto il tasto qui sotto e detta un'istruzione: Kalamos trasforma il testo che hai selezionato invece di scriverne di nuovo.",
                              "Hold the key below and speak an instruction: Kalamos transforms the text you selected instead of writing new text.",
                              "Maintenez la touche ci-dessous et dictez une instruction : Kalamos transforme le texte sélectionné.")) {
                VStack(alignment: .leading, spacing: 9) {
                    PrefToggle(title: L.t("Attivo", "On", "Actif"),
                               isOn: $draft.editModeEnabled)
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
