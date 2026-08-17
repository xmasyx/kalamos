import AppKit
import SwiftUI

/// The ⌃⌥V panel: your dictations, to listen to again and to put right.
///
/// Same paper, same buttons and the same window discipline as ⌃⌥K, for the same
/// reason: an app whose every other screen is its own would look borrowed on the
/// one screen that asks you for something.
///
/// It grew twice, and both times because it was asked a question it could not
/// answer. On 2026-08-15 it held a recording it would not play, so it could only
/// be used by someone who still remembered what he had said — the one case where
/// nobody needs it. The same afternoon it turned out it could only ever show the
/// *last* dictation, while the archive holds hundreds and the ones worth fixing
/// are rarely the most recent.
@MainActor
final class TruthWindow: NSObject, NSWindowDelegate {
    static let shared = TruthWindow()
    private var window: NSWindow?

    /// `initial` is the recording to open on, normally the last one. `save`
    /// receives the recording it belongs to, because in a list the selection
    /// moves and a verbatim written against the wrong file is worse than no
    /// verbatim at all.
    func show(initial: URL?, save: @escaping (URL, String, DictationArchive.TruthSource) -> Void) {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let hosting = NSHostingController(rootView: TruthBrowser(
            initial: initial,
            save: save,
            close: { [weak self] in self?.dismiss() }))

        // The window is a window, not a poster of the archive.
        //
        // `NSHostingController` sizes its window to the SwiftUI content's ideal
        // size by default, and a list of 138 rows has an ideal height of 138
        // rows: the first build opened a window **5218 points tall**, with the
        // scroll view inside it scrolling nothing. Turning the option off is
        // what makes `setContentSize` below mean anything.
        hosting.sizingOptions = []

        let w = NSWindow(contentViewController: hosting)
        w.title = L.t("Le tue dettature", "Your dictations", "Vos dictées")
        w.styleMask = [.titled, .closable, .resizable]
        w.titlebarAppearsTransparent = true
        w.backgroundColor = Theme.paperNS
        w.isMovableByWindowBackground = true
        w.isReleasedWhenClosed = false
        w.setContentSize(NSSize(width: 880, height: 560))
        w.contentMinSize = NSSize(width: 780, height: 460)
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

/// The archive, as a list that fills itself in.
///
/// Names arrive at once and contents arrive behind them, in blocks. The split is
/// not premature: one directory listing is O(1) gestures for the user, while the
/// contents are one file read each and the cap on this archive is 100000. The
/// version that read everything up front would be indistinguishable from this one
/// today, on 138 recordings, and would freeze the window for seconds on an
/// archive he has been told he can keep for a year.
/// How many rows go out per redraw. Publishing per file would repaint the list
/// once per file read; publishing only at the end would show an empty list for
/// as long as the whole archive takes to read.
private let hydrationChunk = 40

@MainActor
final class ArchiveStore: ObservableObject {
    @Published private(set) var entries: [DictationEntry] = []
    @Published private(set) var loading = false


    /// **The listing runs off the main thread too, and that is not caution.**
    /// Measured with `--bench-archivio` on a fake archive of the size the cap
    /// allows: enumerating the folder takes 1.7 s at 20000 recordings and
    /// **9.3 s at 100000**. On the main thread that is the window refusing to
    /// open, with no spinner, because the paint that would draw the spinner is
    /// queued behind it. Reading the contents costs another 12 s at that size,
    /// which is invisible: those arrive into a window that is already up.
    func load() {
        loading = true
        Task.detached(priority: .userInitiated) { [weak self] in
            let stems = DictationIndex.stems()
            await MainActor.run { self?.entries = stems }
            guard !stems.isEmpty else {
                await MainActor.run { self?.loading = false }
                return
            }

            var acc: [URL: DictationDetails] = [:]
            for (i, entry) in stems.enumerated() {
                acc[entry.wav] = DictationIndex.details(of: entry.wav)
                if acc.count >= hydrationChunk || i == stems.count - 1 {
                    let batch = acc
                    acc = [:]
                    await MainActor.run { self?.merge(batch) }
                }
            }
            await MainActor.run { self?.loading = false }
        }
    }

    /// Re-read one recording, after its verbatim has just been written.
    func refresh(_ wav: URL) {
        merge([wav: DictationIndex.details(of: wav)])
    }

    /// Take a recording out of the list, after it has been thrown away.
    ///
    /// The list is not re-read from disk: a full listing costs 9.3 s at the cap
    /// this archive allows, and the one thing that changed is already known here.
    func forget(_ wav: URL) {
        entries.removeAll { $0.wav == wav }
    }

    private func merge(_ batch: [URL: DictationDetails]) {
        for i in entries.indices {
            if let d = batch[entries[i].wav] { entries[i].details = d }
        }
    }

    /// Settled one way or the other: corrected, or read and confirmed as right.
    var settledCount: Int { entries.filter { $0.details?.corrected == true }.count }
}

/// List on the left, the recording under the ear on the right.
struct TruthBrowser: View {
    let initial: URL?
    let save: (URL, String, DictationArchive.TruthSource) -> Void
    let close: () -> Void

    @StateObject private var store = ArchiveStore()
    @State private var selection: URL?
    @State private var filter: DictationFilter = .all
    @State private var query = ""

    private var rows: [DictationEntry] {
        DictationIndex.visible(store.entries, filter: filter, query: query)
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 260)
                .background(Theme.paperEdge)

            Divider().overlay(Theme.rule)

            Group {
                if let selection {
                    TruthView(wav: selection,
                              blank: DictationIndex.isBlank(entry(selection)),
                              save: { verbatim, how in
                                  // **La successiva si calcola PRIMA di scrivere**
                                  // (sua richiesta, 2026-08-17: «quando confermo
                                  // deve passare alla nota successiva da
                                  // verificare, allo stesso modo di quando
                                  // elimino»).
                                  //
                                  // Prima, e non è prudenza: col filtro «Da
                                  // guardare» acceso, confermare toglie la riga
                                  // dall'elenco. Dopo il `refresh` questa riga non
                                  // è più fra le visibili, quindi non esiste più
                                  // nessun «dopo di lei» da cui partire, e la
                                  // selezione resterebbe su una riga sparita dalla
                                  // lista a sinistra — lo stesso vincolo che
                                  // l'eliminazione ha sempre avuto.
                                  let poi = DictationIndex.prossima(dopo: selection, in: rows)
                                  save(selection, verbatim, how)
                                  store.refresh(selection)
                                  // Nil vuol dire «era l'ultima»: si resta dov'è.
                                  // Saltare al principio dell'elenco sarebbe
                                  // perdere il posto proprio quando ha finito.
                                  if let poi { self.selection = poi }
                              },
                              discard: { discard(selection) },
                              close: close)
                        // A new recording is a new panel: without this the text
                        // field would keep the previous transcript, and the first
                        // thing he did would be to save one dictation's words
                        // onto another one's audio.
                        .id(selection)
                } else {
                    empty
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.paper)
        }
        .onAppear {
            store.load()
            selection = initial
        }
        // Opened from the menu rather than off a dictation, there is nothing to
        // land on until the list exists. Waiting for it here, instead of asking
        // the disk a second time, keeps the whole opening down to one listing.
        .onChange(of: store.entries) {
            if selection == nil { selection = store.entries.first?.wav }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 10) {
            PrefField(placeholder: L.t("Cerca nel testo", "Search the text", "Chercher dans le texte"),
                      text: $query)

            HStack(spacing: 6) {
                // "Da guardare", not "da correggere": the filter has never known
                // that a dictation is wrong, only that nobody has said either way.
                // The old label made an accusation the app could not support, and
                // turned an archive of good dictations into a list of chores.
                filterButton(.all, L.t("Tutte", "All", "Toutes"))
                filterButton(.todo, L.t("Da guardare", "To review", "À revoir"))
                filterButton(.done, L.t("Sistemate", "Settled", "Réglées"))
            }

            if rows.isEmpty {
                Text(store.loading
                     ? L.t("Sto leggendo l’archivio…", "Reading the archive…", "Lecture de l’archive…")
                     : L.t("Nessuna dettatura qui.", "No dictation here.", "Aucune dictée ici."))
                    .font(Theme.font(12))
                    .foregroundStyle(Theme.inkFaded)
                    .padding(.top, 6)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(rows) { entry in
                            // Il cestino è un `Button` dentro la riga, quindi si
                            // prende il proprio clic prima che arrivi al
                            // `onTapGesture` della riga: premerlo butta, premere
                            // altrove seleziona.
                            DictationRow(entry: entry, selected: entry.wav == selection,
                                         discard: { discard(entry.wav) })
                                .contentShape(Rectangle())
                                .onTapGesture { selection = entry.wav }
                        }
                    }
                }
                .scrollContentBackground(.hidden)
            }

            corpusFooter
        }
        .padding(14)
    }

    private func filterButton(_ f: DictationFilter, _ title: String) -> some View {
        Button { filter = f } label: {
            Text(title)
                .font(Theme.font(11.5, .medium))
                .foregroundStyle(filter == f ? Theme.paper : Theme.pen)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6)
                    .fill(filter == f ? Theme.pen : Theme.penWash))
                .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }

    /// What is set aside for training, and the way to set the rest aside now.
    ///
    /// It reports two numbers instead of one because they answer different
    /// questions: how much material exists, and how much of it has left the
    /// archive — which is the half that survives a prune.
    private var corpusFooter: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider().overlay(Theme.rule)
            Text(L.t("\(store.settledCount) sistemate · \(TrainingCorpus.exportedCount()) da parte per l’allenamento",
                     "\(store.settledCount) settled · \(TrainingCorpus.exportedCount()) set aside for training",
                     "\(store.settledCount) réglées · \(TrainingCorpus.exportedCount()) mises de côté"))
                .font(Theme.font(11))
                .foregroundStyle(Theme.inkFaded)
                .fixedSize(horizontal: false, vertical: true)

            // Stacked, not side by side: two labels of different lengths in one
            // row leave one button two lines tall and the other one, and the
            // eye reads the taller one as more important than it is.
            VStack(alignment: .leading, spacing: 6) {
                if !unsettled.isEmpty {
                    PrefButton(title: L.t("Conferma tutte (\(unsettled.count))",
                                          "Confirm all (\(unsettled.count))",
                                          "Tout confirmer (\(unsettled.count))")) { confirmVisible() }
                }
                // Shown only when there are any, like the button above it: a
                // count of zero on a button is a button that says the archive is
                // dirty when it is clean.
                if !blanks.isEmpty {
                    PrefButton(title: L.t("Elimina vuote (\(blanks.count))",
                                          "Delete the empty ones (\(blanks.count))",
                                          "Supprimer les vides (\(blanks.count))")) { discardBlanks() }
                }
                PrefButton(title: L.t("Mettile da parte", "Set them aside", "Mettre de côté")) {
                    let n = TrainingCorpus.export()
                    n > 0 ? Sounds.ok() : Sounds.no()
                }
            }
        }
    }

    /// The rows on screen that nobody has ruled on yet, and that have words to
    /// rule on. A recording that produced nothing cannot be confirmed as right.
    private var unsettled: [DictationEntry] {
        rows.filter { e in
            guard let d = e.details else { return false }
            return !d.corrected && !d.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// The rows on screen that produced no words at all.
    private var blanks: [DictationEntry] { DictationIndex.blanks(rows) }

    /// The entry behind a selection, so the panel on the right and the row on the
    /// left are reading the same fact. Falling back to an unhydrated entry rather
    /// than to nothing keeps "not read yet" distinct from "empty" all the way
    /// through — see `DictationIndex.isBlank`.
    private func entry(_ wav: URL) -> DictationEntry {
        store.entries.first { $0.wav == wav }
            ?? DictationEntry(wav: wav, started: Date(), details: nil)
    }

    /// Throw one recording away — the sound and its sidecar together — and move
    /// the selection off it.
    ///
    /// The selection has to move, and it is not a nicety: leaving it on a file
    /// that no longer exists leaves the right-hand panel reading a sidecar that
    /// has just been deleted, which shows an empty editor over an audio player
    /// with nothing to play.
    private func discard(_ wav: URL) {
        // Calcolata prima della cancellazione, per la stessa ragione del
        // salvataggio: dopo, la riga non è più in elenco e non c'è più nessun
        // «dopo di lei».
        //
        // **Andava al PRINCIPIO dell'elenco fino al 2026-08-17**, e lì è nata la
        // sua richiesta: chiedendo che «Conferma» facesse «lo stesso di quando
        // elimino», il comportamento da imitare si è rivelato sbagliato pure lui.
        // Adesso le tre strade leggono la stessa funzione.
        let poi = DictationIndex.dopoLEliminazione(di: wav, in: rows)
        DictationArchive.discard(wav)
        store.forget(wav)
        if selection == wav { selection = poi }
    }

    /// Confirm everything currently listed in one gesture.
    ///
    /// It exists because of what he said on 2026-08-15: *the ones I never
    /// corrected were the ones that were already right*. That is a true statement
    /// about his archive, and it is HIS to make — which is why the app cannot
    /// assume it on his behalf, and why this button asks before writing to a
    /// hundred sidecars. It also records itself as a bulk confirmation, because a
    /// sweep over a list is weaker evidence than a recording read one at a time,
    /// and whoever trains on this later is entitled to tell them apart.
    private func confirmVisible() {
        let batch = unsettled
        let alert = NSAlert()
        alert.messageText = L.t("Confermo \(batch.count) dettature come già giuste?",
                                "Confirm \(batch.count) dictations as already right?",
                                "Confirmer \(batch.count) dictées comme déjà justes ?")
        alert.informativeText = L.t(
            "Il testo che vedi diventa quello che avevi detto, per tutte quelle in elenco. Resta scritto che le hai confermate in blocco, non una per una.",
            "The text you see becomes what you said, for every dictation in the list. It is recorded as a bulk confirmation, not one by one.",
            "Le texte affiché devient ce que vous aviez dit, pour toutes celles de la liste. C’est enregistré comme confirmation groupée.")
        alert.addButton(withTitle: L.t("Conferma", "Confirm", "Confirmer"))
        alert.addButton(withTitle: L.t("Annulla", "Cancel", "Annuler"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        var done = 0, skipped = 0
        for e in batch {
            // The raw is the target: it is what the microphone produced, and a
            // fine-tune learns to produce it. The delivered text has been through
            // punctuation and vocabulary repair, so training on it would teach
            // the model to do work that already happens after it.
            guard let raw = DictationArchive.section("GREZZO", in: e.wav),
                  !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                skipped += 1
                continue
            }
            DictationArchive.recordTruth(e.wav, verbatim: raw, how: .confirmedInBulk)
            store.refresh(e.wav)
            done += 1
        }
        Log.write("verbatim ⌃⌥V: confermate in blocco \(done), saltate \(skipped) senza grezzo")
        TrainingCorpus.exportIfBatchFull()
        // Successo muto (sua richiesta, 2026-08-16): le spunte compaiono
        // sulle righe e il contatore sale, non serve altro. Suona solo il
        // fallimento, che non ha nessun segno visibile suo.
        if done == 0 { Sounds.no() }
    }

    /// Throw away every empty recording currently listed, after asking.
    ///
    /// It asks because it deletes, and deleting audio is the one thing in this
    /// window that cannot be undone — the sweep beside it only writes. The count
    /// in the question is the count on the button, which is the count of the rows
    /// he can see: a sweep that quietly reached rows hidden by a filter would be
    /// deleting things he never looked at.
    private func discardBlanks() {
        let batch = blanks
        guard !batch.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = L.t("Elimino \(batch.count) dettature vuote?",
                                "Delete \(batch.count) empty dictations?",
                                "Supprimer \(batch.count) dictées vides ?")
        alert.informativeText = L.t(
            "Sono quelle in cui il microfono si è aperto e non è stato scritto niente. Se ne va l'audio insieme al testo, e non si torna indietro.",
            "These are the ones where the microphone opened and nothing was written. The audio goes with the text, and it cannot be undone.",
            "Ce sont celles où le micro s’est ouvert sans que rien ne soit écrit. L’audio part avec le texte, sans retour possible.")
        alert.addButton(withTitle: L.t("Elimina", "Delete", "Supprimer"))
        alert.addButton(withTitle: L.t("Annulla", "Cancel", "Annuler"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        for e in batch { discard(e.wav) }
        Log.write("verbatim ⌃⌥V: eliminate \(batch.count) dettature vuote")
    }

    private var empty: some View {
        Text(L.t("Scegli una dettatura dall’elenco.",
                 "Pick a dictation from the list.",
                 "Choisissez une dictée dans la liste."))
            .font(Theme.font(13))
            .foregroundStyle(Theme.inkFaded)
    }
}

/// One line of the archive: when it was, how long, and what it said.
struct DictationRow: View {
    let entry: DictationEntry
    let selected: Bool
    /// Buttare questa riga. Passato dall'elenco e non fatto qui, così l'avanzamento
    /// della selezione resta uno solo per tutte e tre le eliminazioni.
    var discard: (() -> Void)?

    @State private var sotto = false

    /// **Il cestino compare solo sulle righe VUOTE** (sua richiesta, 2026-08-17),
    /// e la guardia è la stessa del resto del pannello: `isBlank` risponde `false`
    /// a una riga non ancora letta dal disco, quindi finché non si sa non si offre
    /// di cancellare. Una riga che sta ancora caricando non è una riga senza
    /// parole, ed è la distinzione che l'archivio intero è costruito per tenere.
    ///
    /// Al passaggio del mouse o sulla riga scelta, non sempre: in una lista lunga
    /// una colonna di cestini è rumore, e per giunta rumore che invita a un gesto
    /// distruttivo.
    private var mostraCestino: Bool {
        discard != nil && DictationIndex.isBlank(entry) && (sotto || selected)
    }

    private var preview: String {
        guard let details = entry.details else { return "…" }
        let text = details.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty
            ? L.t("(non ha scritto niente)", "(it wrote nothing)", "(rien n’a été écrit)")
            : text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(DictationIndex.when(entry.started))
                    .font(Theme.font(11.5, .semibold))
                    .foregroundStyle(selected ? Theme.pen : Theme.ink)
                Spacer()
                if entry.details?.suspect == true {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.inkFaded)
                }
                if entry.details?.corrected == true {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.pen)
                }
                if mostraCestino, let discard {
                    // Niente conferma: è una riga senza parole e l'audio è muto,
                    // quindi il costo di uno sbaglio è zero. L'azione in blocco del
                    // piede la conferma invece, perché lì le righe sono N e non si
                    // guardano una per una.
                    Button(action: discard) {
                        Image(systemName: "trash")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.inkFaded)
                            // Tutto il rettangolo, non il disegno: la regola dei
                            // bottoni (MacAppRules §3) vale anche per un'icona di
                            // dieci punti, dove anzi conta di più.
                            .frame(width: 20, height: 18)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(L.t("Butta questa registrazione", "Throw this recording away",
                              "Jeter cet enregistrement"))
                }
                Text(DictationIndex.lengthLabel(entry.details?.duration))
                    .font(Theme.font(10.5).monospacedDigit())
                    .foregroundStyle(Theme.inkFaded)
            }
            // Three states, not two. A row still loading says nothing yet; a
            // recording that produced no words at all — a decode that came back
            // empty, and there are a few in every archive — has to say so, or it
            // is a blank line the eye reads as a drawing bug.
            Text(preview)
                .font(Theme.font(11))
                .foregroundStyle(Theme.inkFaded)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 8).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 6)
            .fill(selected ? Theme.penWash : .clear))
        .onHover { sotto = $0 }
    }
}

/// One recording: listen to it, then write down what it should have said.
struct TruthView: View {
    let wav: URL
    /// Whether this recording produced no words at all. Handed in rather than
    /// worked out here, so the button on the right and the «(non ha scritto
    /// niente)» on the left cannot end up disagreeing about the same recording.
    let blank: Bool
    let save: (String, DictationArchive.TruthSource) -> Void
    let discard: () -> Void
    let close: () -> Void

    @State private var verbatim: String
    @State private var saved = false
    @FocusState private var focused: Bool

    /// Whether this recording had already been settled when the panel opened.
    private let settled: Bool

    /// Built empty and filled on appear, emptied again on close: the audio device
    /// is open for the length of the panel and not for the length of the app.
    @StateObject private var player = DictationPlayer()

    /// What the app had written, kept so Save can tell an untouched panel from a
    /// corrected one. Saving a transcript nobody edited would archive a guess
    /// under the heading that means "this part is true".
    private let original: String

    init(wav: URL,
         blank: Bool,
         save: @escaping (String, DictationArchive.TruthSource) -> Void,
         discard: @escaping () -> Void,
         close: @escaping () -> Void) {
        self.wav = wav
        self.blank = blank
        self.save = save
        self.discard = discard
        self.close = close
        // The verbatim already written wins over the raw text: coming back to a
        // dictation you have already settled must show what you settled on, not
        // the mistake you settled it against.
        let truth = DictationArchive.section("VERITÀ", in: wav)
        let start = truth ?? DictationArchive.section("GREZZO", in: wav) ?? ""
        _verbatim = State(initialValue: start)
        original = start
        settled = truth?.isEmpty == false
    }

    private var changed: Bool {
        verbatim.trimmingCharacters(in: .whitespacesAndNewlines)
            != original.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var ready: Bool {
        !verbatim.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && changed
    }

    /// You can confirm a transcript that has words in it and has not been settled
    /// already. Confirming twice would append a second identical verbatim, and
    /// confirming an empty one would archive a blank as the truth.
    private var confirmable: Bool {
        !settled && !verbatim.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var stateNote: String? {
        if saved { return L.t("Salvata.", "Saved.", "Enregistrée.") }
        if settled { return L.t("Già sistemata.", "Already settled.", "Déjà réglée.") }
        return nil
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

            if player.isLoaded { TruthPlayerStrip(player: player) }

            TextEditor(text: $verbatim)
                .textEditorStyle(.plain)
                .scrollContentBackground(.hidden)
                .font(Theme.font(13))
                .foregroundStyle(Theme.ink)
                .focused($focused)
                .frame(maxHeight: .infinity)
                .padding(.horizontal, 8).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 7).fill(Theme.card))
                .overlay(RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(focused ? Theme.pen : Theme.rule, lineWidth: 1.5))

            HStack(spacing: 10) {
                if let note = stateNote {
                    Text(note)
                        .font(Theme.font(12))
                        .foregroundStyle(Theme.pen)
                }
                Spacer()
                PrefButton(title: L.t("Chiudi", "Close", "Fermer")) { close() }

                // The two ways out of this panel, and only ever one of them is
                // live: you either changed the words or you did not. Until today
                // the second case had no button at all, so a dictation that had
                // come out right could not be told apart from one nobody had
                // read — and the whole archive looked unjudged.
                if changed {
                    PrefButton(title: L.t("Salva", "Save", "Enregistrer"), filled: true) {
                        commit(.corrected)
                    }
                    .opacity(ready ? 1 : 0.45)
                    .disabled(!ready)
                } else if blank {
                    // **Elimina al posto di Conferma, e non è una terza via.**
                    //
                    // Su una registrazione che non ha scritto niente «Conferma»
                    // non ha senso: confermerebbe il nulla come ciò che aveva
                    // detto. Fino a oggi era lì, spento, e una riga che offre
                    // solo un bottone spento è una riga senza uscita — le teneva
                    // per sempre. Le ha chieste cancellabili due volte
                    // (2026-08-16); la sua parola vince sulla prova che
                    // tenevamo (ISC-108).
                    //
                    // Resta possibile scriverci dentro che cosa aveva detto: nel
                    // momento in cui tocca il testo `changed` diventa vero e
                    // ricompare «Salva». Cancellare è la via d'uscita, non
                    // l'unica.
                    PrefButton(title: L.t("Elimina", "Delete", "Supprimer"),
                               filled: true) { discard() }
                } else {
                    // «Conferma», non «Era giusta» (sua richiesta, 2026-08-16):
                    // un bottone dice l'azione che compie, non il giudizio che
                    // implica — e «era giusta» giudicava al posto suo.
                    PrefButton(title: L.t("Conferma", "Confirm", "Confirmer"),
                               filled: true) { commit(.confirmed) }
                        .opacity(confirmable ? 1 : 0.45)
                        .disabled(!confirmable)
                }
            }
        }
        .padding(24)
        .onAppear { focused = true; player.load(wav) }
        .onDisappear { player.unload() }
        .onExitCommand { close() }
    }

    private func commit(_ how: DictationArchive.TruthSource) {
        let text = verbatim.trimmingCharacters(in: .whitespacesAndNewlines)
        guard how == .corrected ? ready : confirmable else {
            Sounds.no()
            return
        }
        save(text, how)
        saved = true
    }
}

/// Listen to it again, right where you are asked what you said.
///
/// The panel used to ask for the verbatim of a recording it was holding and
/// would not play, so it only worked when you still remembered — which is the
/// one case where you do not need it. On 2026-08-15 a dictation came out with
/// 0.67 seconds no engine could read, and there was nothing in the app that
/// could tell him what he had said.
struct TruthPlayerStrip: View {
    @ObservedObject var player: DictationPlayer

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Button { player.toggle() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Theme.paper)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(Theme.pen))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut("p", modifiers: .command)

                ScrubBar(fraction: player.fraction) { player.seek(toFraction: $0) }

                Text(player.clock)
                    .font(Theme.font(11.5, .medium).monospacedDigit())
                    .foregroundStyle(Theme.inkFaded)

                // Three speeds and not a toggle (sua richiesta, 2026-08-16).
                // «Lento» said what the button did, not what it would do: with
                // one button you have to press it to find out where you are, and
                // with three the current speed is simply visible.
                ForEach(Playback.speeds, id: \.self) { rate in
                    PrefButton(title: Playback.speedLabel(rate),
                               filled: player.rate == rate) { player.rate = rate }
                }
            }

            if player.puòSpingere { volume }

            Text(L.t("Trascina la barra fino al punto che non torna, e con ⌘P riascolti senza lasciare la tastiera.",
                     "Drag the bar to the part that came out wrong; ⌘P plays it again without leaving the keyboard.",
                     "Faites glisser la barre jusqu’au passage erroné ; ⌘P le rejoue sans quitter le clavier."))
                .font(Theme.font(11.5))
                .foregroundStyle(Theme.inkFaded)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// **Il volume oltre l'originale: quattro pastiglie e basta** (sua parola,
    /// 2026-08-17 pomeriggio: «togli lo 0%, togli anche la barra con i più e
    /// meno — teniamo semplicemente volume audio +25% +50 +75 +100»). Lo slider
    /// e il numero in dB del mattino sono stati tolti su quella riga; la
    /// matematica sotto (`Guadagno.quote`, con lo zero dentro) non si muove,
    /// perché sonda e test misurano le quote, non i bottoni.
    ///
    /// Le pastiglie leggono `player.quotaAccesa`: un solo stato, come prima.
    /// Il ritorno al suono nudo, senza la pastiglia 0%, è il ri-clic su quella
    /// accesa — la pastiglia si comporta da interruttore, non da radio a cui
    /// manca una stazione.
    private var volume: some View {
        HStack(spacing: 12) {
            Text(L.t("Volume audio", "Audio volume", "Volume audio"))
                .font(Theme.font(11.5, .medium))
                .foregroundStyle(Theme.inkFaded)
                .lineLimit(1)
                .fixedSize()

            ForEach(Guadagno.quote.filter { $0 > 0 }, id: \.self) { q in
                PrefButton(title: "+\(q)%", filled: player.quotaAccesa == q) {
                    let già = player.quotaAccesa == q
                    player.imposta(dB: già ? 0
                                           : Guadagno.dB(perQuota: q, spazio: player.spazioDB))
                }
            }
        }
    }
}

/// The playhead, drawn out of the same three colours as everything else.
///
/// A `Slider` was the short way and it was wrong twice over: it arrives with the
/// system's tint and metrics inside a paper-and-ink window, and its knob is the
/// only thing you can grab, while what you want here is to land on a syllable by
/// pointing at it.
struct ScrubBar: View {
    let fraction: Double
    let seek: (Double) -> Void

    var body: some View {
        GeometryReader { geo in
            let w = max(geo.size.width, 1)
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.rule).frame(height: 4)
                Capsule().fill(Theme.pen).frame(width: w * Playback.clamp(fraction), height: 4)
                Circle()
                    .fill(Theme.pen)
                    .frame(width: 11, height: 11)
                    .offset(x: w * Playback.clamp(fraction) - 5.5)
            }
            .frame(height: geo.size.height, alignment: .center)
            // The whole strip is the target, knob included: a 11-point circle is
            // not something anybody hits on the first try.
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { seek(Playback.clamp($0.location.x / w)) })
        }
        .frame(height: 18)
    }
}
