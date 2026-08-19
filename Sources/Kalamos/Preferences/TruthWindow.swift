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
    /// **`self` non entra mai nel lavoro di sfondo, ed è un vincolo del
    /// compilatore, non uno stile.** Questa classe è isolata al MainActor:
    /// catturarla dentro un `Task.detached` e poi passarla a `MainActor.run`
    /// significa *spedire* un valore non-Sendable attraverso il confine di
    /// isolamento. Swift 6.3 in locale lo accetta, il compilatore del runner
    /// no — e il rilascio v1.5.0 è morto lì, con quattro `sending 'self' risks
    /// causing data races`. La forma qui sotto non ha quel problema per
    /// costruzione: il lavoro fuori dal main thread lo fanno due funzioni
    /// `nonisolated static` che prendono e restituiscono solo dati `Sendable`,
    /// e il `self` resta sempre dalla parte del MainActor.
    func load() {
        loading = true
        Task { [weak self] in
            let stems = await Self.listing()
            guard let self else { return }
            self.entries = stems
            guard !stems.isEmpty else {
                self.loading = false
                return
            }

            var start = 0
            while start < stems.count {
                let end = min(start + hydrationChunk, stems.count)
                self.merge(await Self.hydrate(Array(stems[start..<end])))
                start = end
            }
            self.loading = false
        }
    }

    /// L'elenco della cartella, fuori dal main thread: 9,3 s a 100000 registrazioni.
    private nonisolated static func listing() async -> [DictationEntry] {
        await Task.detached(priority: .userInitiated) { DictationIndex.stems() }.value
    }

    /// I contenuti di un blocco, fuori dal main thread. Un `Task.detached` per
    /// blocco di `hydrationChunk`, non per file: a 100000 registrazioni sono
    /// 2500 task invece di 100000.
    private nonisolated static func hydrate(_ slice: [DictationEntry]) async -> [URL: DictationDetails] {
        await Task.detached(priority: .userInitiated) {
            var acc: [URL: DictationDetails] = [:]
            for entry in slice { acc[entry.wav] = DictationIndex.details(of: entry.wav) }
            return acc
        }.value
    }

    /// Re-read one recording, after its verbatim has just been written.
    func refresh(_ wav: URL) {
        merge([wav: DictationIndex.details(of: wav)])
    }

    /// Riempi la lista senza toccare il disco, per i test.
    ///
    /// Iniettabile per un motivo solo, lo stesso di `onDrag` nel pannello
    /// dell'onda: la prova dell'inserimento deve girare su un archivio finto in
    /// una cartella temporanea, e un test che scrivesse nell'archivio vero
    /// riempirebbe di spazzatura le sue dettature per controllare una riga.
    func adotta(_ voci: [DictationEntry]) { entries = voci }

    /// **Una dettatura è arrivata mentre il pannello era aperto.**
    ///
    /// Tre proprietà, e ognuna è un difetto evitato:
    ///
    /// · **Non rilegge la cartella.** L'elenco completo costa 9,3 s al tetto di
    ///   100000 che questo archivio permette. La cosa cambiata è una sola e chi
    ///   annuncia sa quale, quindi si costruisce quella riga e basta — stesso
    ///   motivo per cui `forget` toglie una riga invece di ricaricare.
    ///
    /// · **È idempotente.** Lo stesso URL può arrivare due volte: una dettatura
    ///   ridetta viene marcata quando è già in lista. Se c'è già, si aggiorna al
    ///   suo posto; non si inserisce un doppione e non si sposta la riga.
    ///
    /// · **Non ruba il posto.** L'inserimento tocca solo `entries`. La selezione
    ///   vive fuori di qui e non viene nominata, quindi una riga che arriva mentre
    ///   lui sta riascoltando o correggendo non gli sposta niente sotto le mani.
    ///
    /// L'ordine è quello di `stems`: per nome decrescente, cioè la più recente in
    /// cima. Non si assume che la nuova arrivata sia la più recente — si inserisce
    /// dove il nome dice, così una registrazione recuperata da un backup finisce
    /// al posto giusto invece che in testa.
    /// L'identità qui è il **nome del file**, non l'URL: in questo archivio il
    /// nome porta il momento in cui la registrazione è cominciata, ed è già
    /// l'ordinamento di `stems`. Confrontare due `URL` per uguaglianza è fragile
    /// — lo stesso file arriva come `/var/…` o `/private/var/…` a seconda di come
    /// è stato costruito, e il doppione che ne esce l'ha trovato un test.
    func arrived(_ wav: URL) {
        guard let entry = DictationIndex.entry(for: wav) else { return }
        let nome = entry.wav.lastPathComponent
        if let i = entries.firstIndex(where: { $0.wav.lastPathComponent == nome }) {
            entries[i].details = entry.details
            return
        }
        let posto = entries.firstIndex {
            $0.wav.lastPathComponent < nome
        } ?? entries.count
        entries.insert(entry, at: posto)
    }

    /// Take a recording out of the list, after it has been thrown away.
    ///
    /// The list is not re-read from disk: a full listing costs 9.3 s at the cap
    /// this archive allows, and the one thing that changed is already known here.
    func forget(_ wav: URL) {
        entries.removeAll { $0.wav == wav }
    }

    /// **Un intero lotto in una mutazione sola.**
    ///
    /// `forget` chiamata in un ciclo ripubblica `entries` a ogni giro, cioè
    /// ridisegna l'elenco una volta per riga buttata. È metà del blocco totale
    /// del 2026-08-18; l'altra metà era il ricalcolo quadratico. Qui l'elenco
    /// cambia una volta e la vista si ridisegna una volta.
    func dimentica(_ lotto: [DictationEntry]) {
        guard !lotto.isEmpty else { return }
        entries = DictationIndex.senza(lotto, in: entries)
    }

    /// Un lotto di contenuti aggiornati, in una pubblicazione sola.
    ///
    /// `merge` scorre già tutto l'elenco per ogni chiamata: chiamarla una volta
    /// per riga costa O(B×N) e ridisegna B volte. Con tutto il lotto insieme è
    /// O(N) e un ridisegno. Stessa lezione di `dimentica`.
    func aggiorna(_ batch: [URL: DictationDetails]) {
        guard !batch.isEmpty else { return }
        merge(batch)
    }

    private func merge(_ batch: [URL: DictationDetails]) {
        for i in entries.indices {
            if let d = batch[entries[i].wav] { entries[i].details = d }
        }
    }

    /// Settled one way or the other: corrected, or read and confirmed as right.
    var settledCount: Int { entries.filter { $0.details?.corrected == true }.count }

    /// Marcate da riguardare e non ancora sistemate. Scende mentre lui lavora,
    /// quindi è un numero che finisce a zero e poi sparisce dal piede.
    var checkCount: Int {
        entries.filter { $0.details?.needsCheck == true && $0.details?.corrected != true }.count
    }
}

/// List on the left, the recording under the ear on the right.
struct TruthBrowser: View {
    let initial: URL?
    let save: (URL, String, DictationArchive.TruthSource) -> Void
    let close: () -> Void

    /// Quanto sono larghi i tre bottoni in fondo alla barra laterale, tutti e
    /// tre uguali.
    ///
    /// Tarata sul più largo — «Conferma tutte» con il numero — e con lo spazio
    /// per **tre cifre**, che è quanto basta per sempre: non ci saranno mai mille
    /// dettature da confermare in una volta. Il numero fisso serve proprio a
    /// questo, che il bordo destro non balli mentre il contatore cambia.
    static let larghezzaBottoniCorpus: CGFloat = 176

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
        // Dettando col pannello aperto, la riga compare da sola. Prima l'elenco
        // si leggeva una volta in `onAppear` e nessuno lo avvisava più: la
        // dettatura nuova si vedeva solo richiudendo e riaprendo.
        .onReceive(NotificationCenter.default.publisher(for: DictationArchive.didArchive)) { note in
            if let wav = note.object as? URL { store.arrived(wav) }
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

            // Solo finché ce ne sono: una riga che dice «0 da verificare» è
            // rumore permanente per un lavoro che finisce.
            if store.checkCount > 0 {
                Text(L.t("\(store.checkCount) da verificare ◌", "\(store.checkCount) to check ◌",
                         "\(store.checkCount) à vérifier ◌"))
                    .font(Theme.font(11))
                    .foregroundStyle(Theme.pen)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Stacked, not side by side: two labels of different lengths in one
            // row leave one button two lines tall and the other one, and the
            // eye reads the taller one as more important than it is.
            //
            // **Larghezza unica per tutti e tre** (sua richiesta, 2026-08-18): è
            // la regola di casa dei selettori — le voci hanno la stessa larghezza
            // dentro un controllo e fra controlli vicini — applicata a una colonna
            // di bottoni, dove tre bordi destri diversi si vedono come un difetto
            // di allineamento anche quando ogni bottone preso da solo è giusto.
            //
            // Tarata su «Conferma tutte» col numero, che è il più largo, e
            // dimensionata per **tre cifre**: sua indicazione esplicita, non
            // avendo mai mille dettature da confermare in una volta. Così il
            // bordo non balla quando il contatore passa da 9 a 10 a 100.
            VStack(alignment: .leading, spacing: 6) {
                if !unsettled.isEmpty {
                    PrefButton(title: L.t("Conferma tutte (\(unsettled.count))",
                                          "Confirm all (\(unsettled.count))",
                                          "Tout confirmer (\(unsettled.count))"),
                               width: Self.larghezzaBottoniCorpus) { confirmVisible() }
                }
                // Shown only when there are any, like the button above it: a
                // count of zero on a button is a button that says the archive is
                // dirty when it is clean.
                if !blanks.isEmpty {
                    PrefButton(title: L.t("Elimina vuote (\(blanks.count))",
                                          "Delete the empty ones (\(blanks.count))",
                                          "Supprimer les vides (\(blanks.count))"),
                               width: Self.larghezzaBottoniCorpus) { discardBlanks() }
                }
                // **«Archivia» è sua proposta del 2026-08-18**, e la riserva resta
                // sua da sciogliere: questa finestra si chiama «Le tue dettature»
                // ed È l'archivio, quindi un bottone «Archivia» dentro l'archivio
                // può leggersi come «mettile dove già stanno». Quello che fa
                // davvero è staccarne una copia per l'allenamento, che sopravvive
                // alla potatura — il verbo giusto è più vicino a «metti da parte»
                // che ad «archivia». Applicata la sua parola; se all'uso suona
                // ambigua, la riserva è scritta qui.
                PrefButton(title: L.t("Archivia", "Archive", "Archiver"),
                           width: Self.larghezzaBottoniCorpus) {
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

        // **Stessa forma di «Elimina vuote», stessa riparazione**, e questa non è
        // arrivata da una segnalazione: è uscita dalla passata sui fratelli del
        // blocco totale del 2026-08-18. Il ciclo di prima faceva, per OGNI riga,
        // una lettura del sidecar, una scrittura, e una `store.refresh` che
        // ripubblica l'elenco — e `refresh` scorre `entries` per intero, quindi
        // anche qui si pagava O(B×N) più 2B accessi al disco sul main thread.
        // Non si piantava come l'altro perché le righe da confermare sono in
        // genere meno delle vuote, il che rende il difetto più raro, non più
        // piccolo.
        //
        // Adesso il disco lo tocca un task fuori dal main thread, e l'elenco si
        // aggiorna una volta sola con tutto il lotto.
        let files = batch.map(\.wav)
        Task.detached(priority: .userInitiated) {
            var aggiornate: [URL: DictationDetails] = [:]
            var done = 0, skipped = 0
            for wav in files {
                // The raw is the target: it is what the microphone produced, and a
                // fine-tune learns to produce it. The delivered text has been through
                // punctuation and vocabulary repair, so training on it would teach
                // the model to do work that already happens after it.
                guard let raw = DictationArchive.section("GREZZO", in: wav),
                      !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    skipped += 1
                    continue
                }
                DictationArchive.recordTruth(wav, verbatim: raw, how: .confirmedInBulk)
                aggiornate[wav] = DictationIndex.details(of: wav)
                done += 1
            }
            let esito = (done: done, skipped: skipped, dettagli: aggiornate)
            await MainActor.run {
                store.aggiorna(esito.dettagli)
                Log.write("verbatim ⌃⌥V: confermate in blocco \(esito.done), saltate \(esito.skipped) senza grezzo")
                TrainingCorpus.exportIfBatchFull()
                // Successo muto (sua richiesta, 2026-08-16): le spunte compaiono
                // sulle righe e il contatore sale, non serve altro. Suona solo il
                // fallimento, che non ha nessun segno visibile suo.
                if esito.done == 0 { Sounds.no() }
            }
        }
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

        // **Un'operazione in blocco tocca l'elenco UNA volta sola**, e questa
        // riga è la riparazione di un blocco totale segnalato dal campo il
        // 2026-08-18: premendo questo bottone l'app smetteva di rispondere, e non
        // usciva nemmeno dalla richiesta di terminare del sistema. Quel dettaglio
        // È la diagnosi — un'app che non risponde non riceve nemmeno il «termina»
        // gentile, quindi il main thread non tornava MAI al ciclo degli eventi.
        //
        // Prima era `for e in batch { discard(e.wav) }`, e ogni giro ricalcolava
        // l'elenco visibile (O(n), con la ricerca dentro), cercava la riga
        // successiva (O(n)) e ripubblicava `entries`, cioè ridisegnava. Con B
        // vuote su N righe: O(B×N) più B ridisegni più 2B cancellazioni su disco,
        // tutto di fila senza respirare. Misurato sul solo calcolo, 2000 righe con
        // 1000 vuote: **853 ms contro 1 ms** (`BulkDiscardTests`, che tiene la
        // forma vecchia come polo negativo).
        //
        // Adesso: la selezione si calcola una volta, l'elenco si muta una volta, e
        // il disco lo tocca un task fuori dal main thread — l'unica parte che
        // resta lenta, e l'unica che non ha bisogno di essere guardata.
        let nuovaSelezione = DictationIndex.dopoIlLotto(batch, partendoDa: selection,
                                                        in: store.entries)
        store.dimentica(batch)
        selection = nuovaSelezione

        let files = batch.map(\.wav)
        Task.detached(priority: .utility) {
            for wav in files { DictationArchive.discard(wav) }
            await MainActor.run {
                Log.write("verbatim ⌃⌥V: eliminate \(files.count) dettature vuote")
            }
        }
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
                // Un cerchio tratteggiato, non il triangolo delle sospette: le
                // due dicono cose diverse — «probabilmente è andata storta» e
                // «è stata usata per l'allenamento senza il tuo sì» — e riusare
                // il segnale che oggi è affidabile lo renderebbe illeggibile.
                // Sparisce quando la riga è sistemata: il marchio resta scritto
                // nel file, ma smette di chiedere qualcosa.
                if entry.details?.needsCheck == true, entry.details?.corrected != true {
                    Image(systemName: "circle.dashed")
                        .font(.system(size: 9.5))
                        .foregroundStyle(Theme.pen)
                        .help(L.t("Era finita nell’allenamento senza il tuo sì — guardala",
                                  "It went into training without your yes — take a look",
                                  "Elle est entrée dans l’entraînement sans votre accord"))
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

    /// Quanto è larga una pastiglia di velocità, uguale per tutte e quattro.
    ///
    /// Tarata su «1,25×», che è la più lunga. Quattro pastiglie in questo spazio
    /// stanno più strette di quanto stessero le tre di ieri, ed è voluto: sua
    /// richiesta di tenere **lo stesso ingombro** della fila, perché la larghezza
    /// del cursore del volume qui sotto è definita su quell'ingombro.
    static let larghezzaPastigliaVelocità: CGFloat = 46

    /// La colonna del tempo, e quindi anche quella dell'etichetta «Volume audio»
    /// che ci va **esattamente sotto** (sua richiesta, 2026-08-18). Larga quanto
    /// serve alla più lunga delle due, `0:00 / 0:00` e «Volume audio».
    static let larghezzaColonnaTempo: CGFloat = 92

    /// L'ingombro della fila delle velocità: quattro pastiglie e tre spazi.
    ///
    /// Il cursore del volume è largo esattamente così — sua richiesta: «lunga
    /// tanto quanto lo spazio che va dal bottone iniziale 0,5 fino alla fine del
    /// bottone 1,5». Derivata invece che scritta a mano, così aggiungendo una
    /// quinta velocità le due file restano allineate da sole invece di divergere
    /// in silenzio.
    static var ingombroVelocità: CGFloat {
        let n = CGFloat(Playback.speeds.count)
        return n * larghezzaPastigliaVelocità + (n - 1) * 12
    }

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

                // Larghezza fissa, e non solo perché le cifre ballano: è la
                // colonna sotto cui va incolonnata «Volume audio» (sua richiesta,
                // 2026-08-18), e una colonna che cambia larghezza col contenuto
                // non è una colonna.
                Text(player.clock)
                    .font(Theme.font(11.5, .medium).monospacedDigit())
                    .foregroundStyle(Theme.inkFaded)
                    .frame(width: Self.larghezzaColonnaTempo, alignment: .leading)

                // Four speeds and not a toggle (sue richieste, 2026-08-16 e
                // 2026-08-18). «Lento» said what the button did, not what it
                // would do: with one button you have to press it to find out
                // where you are, and with four the current speed is simply
                // visible.
                //
                // **Larghezza unica, tarata sulla più lunga**, e non è pignoleria:
                // «0,5×» e «1,25×» hanno lunghezze diverse, e a larghezza naturale
                // la fila esce sfrangiata e si porta dietro il bordo di colonna su
                // cui è appoggiato il cursore del volume qui sotto. È la regola di
                // casa dei selettori: le voci hanno la stessa larghezza dentro un
                // controllo e fra controlli vicini.
                ForEach(Playback.speeds, id: \.self) { rate in
                    PrefButton(title: Playback.speedLabel(rate),
                               filled: player.rate == rate,
                               width: Self.larghezzaPastigliaVelocità) { player.rate = rate }
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

    /// **Il volume oltre l'originale: un cursore, non più quattro pastiglie**
    /// (sua richiesta del 2026-08-18: «i pulsanti là occupano un sacco di spazio,
    /// mettiamo solamente la barra che si muove»).
    ///
    /// Le pastiglie `+25/50/75/100` sono diventate le tacchette della barra, che
    /// restano cliccabili: non si è perso niente e si è guadagnato lo spazio.
    /// Sparisce anche il problema che aveva sollevato il giorno prima — non
    /// c'era modo di tornare al volume base se non ricliccando la pastiglia
    /// accesa, un gesto che nessuno vede — perché ora il volume base è
    /// semplicemente l'estremo sinistro della barra.
    ///
    /// **La casella del valore è in sola lettura, e la storia della decisione
    /// vale più della decisione.** Lui l'aveva chiesta editabile il 17; il 18,
    /// dopo aver scartato il magnete perché «non è un lavoro di fino, devo
    /// semplicemente essere in grado di sentirlo», ha applicato la stessa logica
    /// al campo e l'ha tolto: digitare un numero è un gesto preciso per un
    /// bisogno dichiarato impreciso. Larghezza fissa e cifre monospaziate, perché
    /// un numero che cambia larghezza fa ballare quello che ha accanto.
    private var volume: some View {
        // **Incolonnata sulla riga di sopra, non allineata a sinistra**, ed è la
        // sua richiesta del 18/08: «Volume audio» esattamente sotto il tempo, e la
        // barra lunga quanto la fila delle velocità. Lo `Spacer` in testa spinge
        // il gruppo a destra finché le due colonne coincidono, e i due ingombri
        // sono costanti condivise: le righe non possono scollarsi.
        //
        // La barra e la lettura insieme stanno nell'ingombro delle velocità,
        // quindi il bordo destro è lo stesso per entrambe le file — la regola di
        // casa per cui tutti i comandi di una pagina finiscono sullo stesso bordo.
        HStack(spacing: 12) {
            Spacer(minLength: 0)

            Text(L.t("Volume audio", "Audio volume", "Volume audio"))
                .font(Theme.font(11.5, .medium))
                .foregroundStyle(Theme.inkFaded)
                .lineLimit(1)
                .frame(width: Self.larghezzaColonnaTempo, alignment: .leading)

            GainBar(quota: quotaCorrente, accesa: player.quotaAccesa) { q in
                player.imposta(dB: Guadagno.dB(perQuota: Int((q * 100).rounded()),
                                               spazio: player.spazioDB))
            }
            .frame(width: Self.ingombroVelocità - Self.larghezzaLettura - 12)

            Text("+\(Int((quotaCorrente * 100).rounded()))%")
                .font(Theme.font(11.5, .medium).monospacedDigit())
                .foregroundStyle(Theme.inkFaded)
                .frame(width: Self.larghezzaLettura, alignment: .trailing)
        }
    }

    /// La casella della percentuale: larghezza fissa perché un numero che cambia
    /// larghezza fa ballare la barra che ha accanto. Tarata su «+100%».
    static let larghezzaLettura: CGFloat = 44

    /// Dove sta la manopola, 0…1. Il margine di questo file è il fondo scala: a
    /// margine zero non c'è niente da spingere e la barra sta a sinistra invece
    /// di dividere per zero.
    private var quotaCorrente: Double {
        guard player.spazioDB > 0 else { return 0 }
        return Playback.clamp(Double(player.guadagnoDB / player.spazioDB))
    }
}

/// **Il cursore del volume**, disegnato sulla forma di `ScrubBar` e non su uno
/// `Slider`, per la stessa ragione: un controllo di sistema porta il colore e le
/// proporzioni di qualcun altro dentro una pagina di carta e inchiostro.
///
/// Sostituisce le quattro pastiglie `+25/50/75/100` (sua richiesta del
/// 2026-08-18: «i pulsanti occupano un sacco di spazio»). Quello che le pastiglie
/// facevano non è andato perso: sono diventate **tacchette cliccabili**.
///
/// Tre decisioni prese con lui, e il perché di ognuna:
///
/// · **Niente magnete.** Gliel'avevo proposto sul 50 e l'ha scartato: «chi se ne
///   frega se 47, non è un lavoro di fino, devo semplicemente essere in grado di
///   sentirlo». Aveva ragione, ed è una lezione di progettazione — magnete e
///   tacchette servivano a conservare una capacità delle pastiglie (tornare su un
///   valore tondo) che non era un bisogno, era un effetto collaterale del fatto
///   che le pastiglie erano discrete.
/// · **Le tacchette restano, e si cliccano.** Sono scorciatoie, non calamite: ci
///   clicchi e ci salti, ma non ti afferrano mentre trascini.
/// · **La percentuale è lineare nei decibel** senza che questo cursore faccia
///   niente, perché `Guadagno.dB(perQuota:spazio:)` è `spazio × q / 100`: la
///   manopola a metà barra è davvero il 50%, e non mente mai.
///
/// Il fondo scala è lo spazio di QUEL file (`spazioDB`), cioè «più forte
/// possibile senza rovinarlo», non un numero fisso.
struct GainBar: View {
    /// 0…1, dove 1 è tutto il margine disponibile del file.
    let quota: Double
    /// La tacchetta su cui si è **esattamente**, o `nil` se si sta in mezzo a due.
    ///
    /// Viene da `Guadagno.quota(perDB:spazio:)`, scritta quando le pastiglie erano
    /// bottoni, con questo commento: *«nil è un'informazione e va disegnata come
    /// tale: tirando lo slider fra due pastiglie non deve restarne accesa una che
    /// mente sul valore vero»*. Era una funzione scritta per uno slider mesi prima
    /// che lo slider esistesse, e qui fa finalmente il mestiere per cui era nata.
    let accesa: Int?
    let imposta: (Double) -> Void

    /// Le stesse quote delle pastiglie di ieri (`Guadagno.quote` = 0, 25, 50, 75,
    /// 100), importate e non ricopiate: il giorno che cambiano, cambiano qui.
    private var tacche: [Int] { Guadagno.quote }

    var body: some View {
        GeometryReader { geo in
            let w = max(geo.size.width, 1)
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.rule).frame(height: 4)

                // Le tacchette stanno SOTTO il riempimento e la manopola: sono
                // punti di riferimento, non comandi che competono con lo stato.
                ForEach(tacche, id: \.self) { q in
                    Capsule()
                        .fill(q == accesa ? Theme.pen : Theme.rule)
                        .frame(width: 2, height: q == accesa ? 12 : 9)
                        .offset(x: w * (Double(q) / 100) - 1)
                }

                Capsule().fill(Theme.pen).frame(width: w * Playback.clamp(quota), height: 4)
                Circle()
                    .fill(Theme.pen)
                    .frame(width: 11, height: 11)
                    .offset(x: w * Playback.clamp(quota) - 5.5)
            }
            .frame(height: geo.size.height, alignment: .center)
            // Tutta la striscia è il bersaglio, manopola compresa: un cerchio da
            // 11 punti non lo prende nessuno al primo colpo. Stessa regola del
            // bottone che si clicca tutto e non solo dove c'è scritto.
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { imposta(Playback.clamp($0.location.x / w)) }
                .onEnded { g in
                    // **Il clic su una tacchetta ci va esatto; il trascinamento
                    // non viene mai afferrato.** Sono due gesti diversi e vanno
                    // distinti qui, non con un magnete: un magnete agirebbe anche
                    // mentre trascini, ed è precisamente la cosa che rende un
                    // cursore fastidioso quando vuoi un valore in mezzo.
                    //
                    // Un clic è un trascinamento che non si è mosso. Sotto i tre
                    // punti è la mano ferma, non un'intenzione di spostarsi.
                    let fermo = abs(g.translation.width) < 3 && abs(g.translation.height) < 3
                    guard fermo else { return }
                    let q = Playback.clamp(g.location.x / w) * 100
                    if let tacca = Guadagno.taccaVicina(a: q, larghezza: w, tacche: tacche) {
                        imposta(Double(tacca) / 100)
                    }
                }
            )
        }
        .frame(height: 18)
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
