import Foundation

/// One archived dictation, as the list needs to show it.
///
/// Split in two on purpose. The identity — which file, from when — comes out of
/// the **name** and costs one directory listing for the whole archive. The
/// contents — how long, what it said, whether it was already corrected — cost a
/// file read each, and are filled in afterwards. With 138 recordings the
/// difference is invisible; the cap is 100000, so the day it stops being
/// invisible is a day that arrives without warning.
struct DictationEntry: Identifiable, Hashable, Sendable {
    let wav: URL
    let started: Date

    /// Filled from the sidecar. Nil means *not read yet*, which is a different
    /// thing from *empty*: a row that has not been hydrated must not claim the
    /// dictation said nothing.
    var details: DictationDetails?

    var id: URL { wav }

    var isHydrated: Bool { details != nil }
}

/// What the sidecar says about one recording.
struct DictationDetails: Hashable, Sendable {
    var duration: Double?
    var language: String?
    /// What the app delivered, falling back to what it heard.
    var text: String
    /// A verbatim has been written down: this one is settled.
    var corrected: Bool
    /// The app itself flagged it as probably wrong (a redo, mostly).
    var suspect: Bool
    /// Marcata da riguardare: era entrata nell'allenamento senza la sua parola.
    /// Ha un default perché il campo è arrivato dopo, e i banchi che costruiscono
    /// un `DictationDetails` a mano non parlano di questa storia.
    var needsCheck: Bool = false
    /// When he settled it, read off the VERITÀ heading. Nil while unsettled.
    var settledAt: Date?
}

/// Which recordings the list is showing.
enum DictationFilter: String, CaseIterable, Sendable {
    case all, todo, done
}

/// Reading the archive as a list, and deciding what belongs in it.
///
/// Everything here is a pure function of things a test can hand it, except
/// `stems` and `details`, which touch the disk and do nothing else.
enum DictationIndex {

    /// Every recording on disk, newest first, identity only.
    ///
    /// Sorted by NAME like the pruning is, and for the same reason: the name
    /// carries the moment the recording started, and a file date survives
    /// neither a backup nor a copy.
    ///
    /// `in` is a parameter for one reason: the bench that decides whether this
    /// design survives 100000 recordings has to run the REAL function over a
    /// fake archive. A bench that reimplements the listing measures the
    /// reimplementation, and the two drift the first time one is edited.
    static func stems(in directory: URL = DictationArchive.directory) -> [DictationEntry] {
        let fm = FileManager.default
        guard let all = try? fm.contentsOfDirectory(at: directory,
                                                    includingPropertiesForKeys: nil)
        else { return [] }
        return all.filter { $0.pathExtension == "wav" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .compactMap { url in
                guard let d = date(fromStem: url.deletingPathExtension().lastPathComponent)
                else { return nil }
                return DictationEntry(wav: url, started: d, details: nil)
            }
    }

    /// **Una registrazione sola, già idratata**, per la riga che arriva mentre il
    /// pannello è aperto.
    ///
    /// Esiste per NON rileggere la cartella: un elenco completo costa 9,3 s al
    /// tetto che questo archivio permette, e la cosa cambiata è una sola ed è
    /// nota a chi la annuncia. Stessa lettura del nome di `stems`, così una voce
    /// arrivata a caldo e la stessa voce riletta domani all'apertura non possono
    /// differire.
    ///
    /// `nil` se il nome non è uno stamp dei nostri: la porta d'ingresso è la
    /// stessa di `stems`, e un file estraneo non entra nella lista da nessuna
    /// delle due strade.
    /// Il file deve esistere: fra l'annuncio e questa lettura ci può essere
    /// passata la potatura del tetto, e una riga che punta a un file sparito è
    /// peggio di una riga mancante — si può cliccare.
    /// **L'URL NON viene normalizzato, e chi lo consuma non deve confrontarlo per
    /// uguaglianza.** `contentsOfDirectory` restituisce percorsi risolti
    /// (`/private/var/…`), un URL costruito per composizione no (`/var/…`): stesso
    /// file, due stringhe diverse. `resolvingSymlinksInPath()` sembra la
    /// riparazione e non lo è — provato: non risolve niente se il file non esiste
    /// ancora, quindi darebbe un falso senso di sicurezza. L'identità in questo
    /// archivio è il **nome**, che porta il momento in cui la registrazione è
    /// cominciata ed è già l'ordinamento di `stems`. Il doppione che nasceva dal
    /// confronto fra URL l'ha trovato un test, non un ragionamento.
    static func entry(for wav: URL) -> DictationEntry? {
        guard wav.pathExtension == "wav",
              FileManager.default.fileExists(atPath: wav.path),
              let started = date(fromStem: wav.deletingPathExtension().lastPathComponent)
        else { return nil }
        return DictationEntry(wav: wav, started: started, details: details(of: wav))
    }

    /// `20260815-151553` → the moment it started. A file whose name is not a
    /// stamp is not one of ours and does not belong in the list.
    ///
    /// The shape is checked before the formatter sees the string, because
    /// `DateFormatter` is lenient in a way that bites here: on an EMPTY name it
    /// returns 1 January 2000 rather than nil, so a stray `.wav` would join the
    /// list as a recording made at the turn of the century.
    static func date(fromStem stem: String) -> Date? {
        guard stem.range(of: #"^\d{8}-\d{6}$"#, options: .regularExpression) != nil
        else { return nil }
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.date(from: stem)
    }

    /// Read one sidecar. Cheap enough per file, expensive enough over the whole
    /// archive to be worth doing off the main thread.
    static func details(of wav: URL) -> DictationDetails {
        let raw = DictationArchive.section("GREZZO", in: wav)
        let delivered = DictationArchive.section("CONSEGNATO", in: wav)
        let truth = DictationArchive.section("VERITÀ", in: wav)
        let header = (try? String(contentsOf: DictationArchive.sidecar(of: wav), encoding: .utf8)) ?? ""

        return DictationDetails(
            duration: duration(inHeader: header),
            language: language(inHeader: header),
            text: delivered ?? raw ?? "",
            corrected: truth?.isEmpty == false,
            suspect: header.contains("SOSPETTA:"),
            needsCheck: header.contains("DA VERIFICARE:"),
            settledAt: settledDate(inSidecar: header))
    }

    /// `VERITÀ (2026-08-15 22:52):` → that moment. The LAST heading wins,
    /// because a re-correction appends rather than rewriting.
    static func settledDate(inSidecar text: String) -> Date? {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        f.locale = Locale(identifier: "en_US_POSIX")
        var last: Date?
        var search = text[...]
        while let r = search.range(of: #"VERITÀ \((\d{4}-\d{2}-\d{2} \d{2}:\d{2})"#,
                                   options: .regularExpression) {
            let stamp = String(text[r].dropFirst("VERITÀ (".count))
            if let d = f.date(from: stamp) { last = d }
            search = text[r.upperBound...]
        }
        return last
    }

    /// `durata audio: 20.6s · microfono aperto: 20.7s`
    static func duration(inHeader header: String) -> Double? {
        guard let r = header.range(of: #"durata audio: ([0-9]+(\.[0-9]+)?)"#,
                                   options: .regularExpression) else { return nil }
        return Double(header[r].replacingOccurrences(of: "durata audio: ", with: ""))
    }

    /// `lingua: it`
    static func language(inHeader header: String) -> String? {
        guard let r = header.range(of: #"(?m)^lingua: ([a-z]{2})"#,
                                   options: .regularExpression) else { return nil }
        return String(header[r].dropFirst("lingua: ".count))
    }

    // MARK: what the list shows

    /// A settled dictation stays in «Tutte» this long after he settles it, then
    /// lives only under «Sistemate» (sua richiesta, 2026-08-16: «non che
    /// rimangano lì per tanto tempo»). A day, so the work of the sitting stays
    /// visible until the next one; the row is never lost, only filed.
    static let settledLinger: TimeInterval = 86400

    /// The rows that survive the filter and the search box.
    ///
    /// A row nobody has read yet is kept by the filter and dropped by a search:
    /// hiding an unread row would make the archive look smaller than it is while
    /// it loads, and matching one on text it does not have yet would make the
    /// search look broken as the answers appear behind it.
    static func visible(_ entries: [DictationEntry],
                        filter: DictationFilter,
                        query: String,
                        now: Date = Date()) -> [DictationEntry] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return entries.filter { e in
            guard passes(e, filter: filter) else { return false }
            // Filed away: settled more than a day ago. Only the catch-all view
            // hides them — «Sistemate» is exactly the drawer they get filed to,
            // and a search must keep finding them or the drawer is a hole.
            if filter == .all, q.isEmpty,
               let d = e.details, d.corrected,
               let when = d.settledAt, now.timeIntervalSince(when) > settledLinger {
                return false
            }
            guard !q.isEmpty else { return true }
            guard let text = e.details?.text else { return false }
            return text.lowercased().contains(q)
        }
    }

    // MARK: dove atterra la selezione quando una riga è finita

    /// **La riga dopo `wav`, fra quelle VISIBILI** — nil se era l'ultima.
    ///
    /// Sua richiesta, 2026-08-17: «quando confermo deve passare alla nota
    /// successiva da verificare, allo stesso modo di quando elimino». Sta qui e
    /// non dentro la finestra per due motivi. È l'unica definizione di
    /// «successiva» che l'app ha, quindi conferma, salvataggio ed eliminazione la
    /// leggono tutte da qui invece di averne una copia per bottone — due copie di
    /// «qual è la prossima» divergono al primo ritocco. Ed è pura, quindi si prova
    /// senza aprire una finestra.
    ///
    /// **Successiva fra le VISIBILI, non nell'archivio**: se lui lavora col filtro
    /// «Da guardare» acceso, la prossima da guardare è la prossima di
    /// quell'elenco. Saltare a una riga che non è sullo schermo sarebbe rispondere
    /// a una domanda che non ha fatto.
    ///
    /// **Va chiamata PRIMA che l'elenco si aggiorni.** Confermare una riga la fa
    /// uscire dal filtro «Da guardare», quindi dopo l'aggiornamento `wav` non è
    /// più fra le visibili e non c'è più nessun «dopo di lei» da calcolare — lo
    /// stesso vincolo che l'eliminazione ha sempre avuto.
    static func prossima(dopo wav: URL, in visibili: [DictationEntry]) -> URL? {
        guard let i = visibili.firstIndex(where: { $0.wav == wav }) else { return nil }
        let dopo = visibili.index(after: i)
        return dopo < visibili.endIndex ? visibili[dopo].wav : nil
    }

    /// La riga su cui atterrare quando quella corrente SPARISCE — l'eliminazione.
    ///
    /// Diversa da `prossima` in un punto solo, e il punto è che qui restare non è
    /// un'opzione: il file non c'è più. Sull'ultima riga si torna indietro di una
    /// invece di saltare al principio dell'elenco, che è quello che si faceva
    /// prima del 2026-08-17 e che lo spediva in cima dopo ogni cancellazione.
    static func dopoLEliminazione(di wav: URL, in visibili: [DictationEntry]) -> URL? {
        guard let i = visibili.firstIndex(where: { $0.wav == wav }) else { return nil }
        if let p = prossima(dopo: wav, in: visibili) { return p }
        return i > 0 ? visibili[i - 1].wav : nil
    }

    // MARK: buttarne tante in una volta

    /// **L'elenco senza un intero lotto, in una passata sola.**
    ///
    /// Nata dal blocco totale del 2026-08-18: «Elimina vuote» piantava l'app al
    /// punto che non rispondeva più nemmeno alla richiesta di terminare del
    /// sistema. Non era una riga lenta, era la forma — un ciclo che per OGNI riga
    /// da buttare ricalcolava l'elenco visibile e cercava la riga successiva,
    /// cioè O(B×N), e ridisegnava l'elenco B volte senza mai restituire il main
    /// thread al ciclo degli eventi.
    ///
    /// Qui l'insieme dei condannati si costruisce una volta e si scorre l'elenco
    /// una volta: O(N). Misurato su 2000 righe con 1000 vuote, la forma vecchia
    /// contro questa sta **oltre venti volte sopra** (`BulkDiscardTests`, che
    /// tiene la forma vecchia come polo negativo apposta).
    ///
    /// L'ordine sopravvive perché si filtra, non si ricostruisce.
    static func senza(_ lotto: [DictationEntry], in entries: [DictationEntry]) -> [DictationEntry] {
        guard !lotto.isEmpty else { return entries }
        let condannati = Set(lotto.map(\.wav.lastPathComponent))
        return entries.filter { !condannati.contains($0.wav.lastPathComponent) }
    }

    /// Dove va la selezione dopo che un intero lotto è sparito.
    ///
    /// Calcolata **una volta sola** per tutta l'operazione, che è l'altra metà
    /// della riparazione: la forma vecchia la ricalcolava a ogni giro, e a ogni
    /// giro la spostava su una riga che il giro dopo avrebbe buttato.
    ///
    /// Se la riga selezionata sopravvive al lotto, non si muove: spostare una
    /// selezione che non aveva motivo di spostarsi è un modo di rubare il posto a
    /// chi sta leggendo.
    static func dopoIlLotto(_ lotto: [DictationEntry], partendoDa corrente: URL?,
                            in entries: [DictationEntry]) -> URL? {
        let rimaste = senza(lotto, in: entries)
        guard let corrente else { return rimaste.first?.wav }
        if rimaste.contains(where: { $0.wav.lastPathComponent == corrente.lastPathComponent }) {
            return corrente
        }
        // La prima sopravvissuta DOPO quella che sparisce, altrimenti l'ultima
        // prima di lei: la stessa regola di `dopoLEliminazione`, applicata al
        // lotto invece che a una riga.
        guard let i = entries.firstIndex(where: { $0.wav.lastPathComponent == corrente.lastPathComponent })
        else { return rimaste.first?.wav }
        let condannati = Set(lotto.map(\.wav.lastPathComponent))
        if let dopo = entries[entries.index(after: i)...]
            .first(where: { !condannati.contains($0.wav.lastPathComponent) }) {
            return dopo.wav
        }
        return entries[..<i].last { !condannati.contains($0.wav.lastPathComponent) }?.wav
    }

    // MARK: le righe vuote, e chi può buttarle

    /// **Una riga che non ha scritto niente.**
    ///
    /// È la riga che nel pannello dice «(non ha scritto niente)»: il microfono si
    /// è aperto, l'audio è stato conservato e la trascrizione è tornata vuota.
    /// Fino al 2026-08-16 restavano lì per sempre, e chiedergli di correggerle
    /// significa chiedergli che cosa aveva detto in un momento in cui non c'era
    /// niente da leggere. Le ha chieste cancellabili due volte: la sua parola
    /// vince sulla prova che tenevamo (ISC-108).
    ///
    /// **Una riga non ancora letta dal disco NON è vuota**, e questa riga sola
    /// vale l'esistenza della funzione. `details == nil` significa «il contenuto
    /// non è ancora arrivato», e in un archivio di centomila registrazioni arriva
    /// a blocchi, dopo che la finestra è già aperta: confondere i due stati
    /// vorrebbe dire offrire un «elimina vuote (138)» a una lista che si sta
    /// ancora caricando, e cancellare l'archivio intero con un click.
    static func isBlank(_ e: DictationEntry) -> Bool {
        guard let d = e.details else { return false }
        return d.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Le vuote fra quelle passate — cioè fra quelle che ha davanti, non fra
    /// tutte quelle su disco. Il conteggio sul bottone e le righe che sparirebbero
    /// devono essere la stessa cosa, o il numero mente.
    static func blanks(_ entries: [DictationEntry]) -> [DictationEntry] {
        entries.filter(isBlank)
    }

    static func passes(_ e: DictationEntry, filter: DictationFilter) -> Bool {
        switch filter {
        case .all:  return true
        // Unread rows count as "to correct": the archive's default state is
        // uncorrected, so a row still loading is one of them until it says
        // otherwise. The opposite default would empty this filter on open.
        case .todo: return e.details?.corrected != true
        case .done: return e.details?.corrected == true
        }
    }

    /// `oggi 15:15` · `ieri 09:02` · `12 ago 23:31` — the three cases a person
    /// actually navigates by. The year is left out on purpose: the archive is
    /// walked from the top, and a date that reads like a filename is one more
    /// thing to decode.
    @MainActor
    static func when(_ date: Date, now: Date = Date(), calendar: Calendar = .current,
                     locale: Locale = .current) -> String {
        let time = DateFormatter()
        time.locale = locale
        time.dateFormat = "HH:mm"
        let clock = time.string(from: date)

        if calendar.isDate(date, inSameDayAs: now) {
            return L.t("oggi \(clock)", "today \(clock)", "aujourd’hui \(clock)")
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return L.t("ieri \(clock)", "yesterday \(clock)", "hier \(clock)")
        }
        let day = DateFormatter()
        day.locale = locale
        day.setLocalizedDateFormatFromTemplate("d MMM")
        return "\(day.string(from: date)) \(clock)"
    }

    /// `20,6 s`, and nothing at all when the sidecar never said.
    static func lengthLabel(_ seconds: Double?) -> String {
        guard let seconds, seconds > 0 else { return "" }
        return String(format: "%.0f s", seconds.rounded())
    }
}
