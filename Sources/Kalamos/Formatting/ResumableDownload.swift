import Foundation

/// Quanto è sceso, non solo quanta strada resta.
///
/// Il vecchio callback passava un `Double` e basta, e su un manifesto dove un
/// file solo vale il 98,5% dei byte una percentuale che non si muove è
/// indistinguibile da un blocco. I byte crudi viaggiano accanto alla frazione
/// perché «340 MB di 1,1 GB» dice che qualcosa sta succedendo anche quando la
/// percentuale, per un minuto intero, mostra lo stesso intero.
struct Avanzamento: Sendable {
    let frazione: Double
    let scaricati: Int
    let totale: Int
}

/// Cinque cause distinte, perché chiedono cinque cose diverse a chi legge.
///
/// Prima erano un `NSError` unico: una rete caduta e un file corrotto uscivano
/// dalla stessa porta col medesimo tono, e il messaggio diceva «scaricamento
/// incompleto» in entrambi i casi. Ma la rete si riprova e riprende da dove
/// stava, la corruzione va ributtata, il disco pieno va svuotato, e uno stato
/// HTTP inatteso non è un problema di chi scarica. Solo `.rete` è transitoria,
/// ed è l'unica che `scaricaConRitentativi` ritenta.
enum DownloadFailure: Error, LocalizedError, Sendable {
    case rete(nome: String, causa: String)
    case http(nome: String, stato: Int)
    case tagliaErrata(nome: String, ottenuti: Int, attesi: Int)
    case contenuto(nome: String, dettaglio: String)
    case disco(nome: String, causa: String)

    var errorDescription: String? {
        switch self {
        case .rete(let nome, let causa):
            return "\(nome): connessione interrotta (\(causa))."
        case .http(let nome, let stato):
            return "\(nome): il server ha risposto \(stato)."
        case .tagliaErrata(let nome, let ottenuti, let attesi):
            return "\(nome): \(ottenuti) byte invece di \(attesi); file incompleto o corrotto."
        case .contenuto(let nome, let dettaglio):
            return "\(nome): contenuto inatteso (\(dettaglio))."
        case .disco(let nome, let causa):
            return "\(nome): scrittura sul disco fallita (\(causa))."
        }
    }
}

/// I byte come li legge una persona, in unità SI da mille.
///
/// Non `ByteCountFormatter`: quello segue il locale di sistema, che su questa
/// macchina può non essere la lingua scelta nell'app, e sceglie da sé se usare
/// mille o 1024 — cioè può stampare «1,04 GB» accanto al bottone che promette
/// «1,1 GB». Qui la soglia e il separatore sono argomenti espliciti, quindi
/// verificabili senza cambiare le impostazioni del Mac.
enum ByteFormat {
    nonisolated static func stringa(_ n: Int, virgola: Bool) -> String {
        if n < 1_000 {
            return "\(n) B"
        } else if n < 1_000_000 {
            return "\(Int((Double(n) / 1_000).rounded())) KB"
        } else if n < 1_000_000_000 {
            return "\(Int((Double(n) / 1_000_000).rounded())) MB"
        } else {
            let valore = String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"),
                                 Double(n) / 1_000_000_000)
            return "\(virgola ? valore.replacingOccurrences(of: ".", with: ",") : valore) GB"
        }
    }
}

/// I callback della sessione sono seriali, ma il riavvio da zero imposto da un
/// server che ignora `Range` può produrre un numero più basso. Il lucchetto sta
/// qui, al confine condiviso da sessione e interfaccia, perché oltre il 98% dei
/// byte arriva da un solo file e un salto indietro sarebbe visibile.
final class MonotonicProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var ultimo: (frazione: Double, scaricati: Int)?

    func emetti(frazione: Double, scaricati: Int, totale: Int) -> Avanzamento? {
        lock.lock()
        defer { lock.unlock() }
        let limitata = min(max(frazione, 0), 1)
        if let ultimo, limitata <= ultimo.frazione {
            return nil
        } else {
            let valore = Avanzamento(frazione: limitata,
                                          scaricati: min(max(scaricati, 0), totale),
                                          totale: totale)
            ultimo = (valore.frazione, valore.scaricati)
            return valore
        }
    }
}

/// Riceve dati invece di aspettare il file temporaneo di `download(from:)`: sul
/// peso dominante da 1,1 GB il byte ricevuto è l'unico evento abbastanza fine
/// da distinguere un trasferimento lento da uno fermo e da conservare alla caduta.
final class ResumableDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private static let passoEmissione = 1 << 20

    private let parziale: URL
    private let destinazione: URL
    private let attesi: Int
    private let nome: String
    private let onBytes: @Sendable (Int) -> Void
    private let lockConclusione = NSLock()

    private var presenti: Int
    private var ultimaEmissione: Int
    private var file: FileHandle?
    private var sessione: URLSession?
    private var continuazione: CheckedContinuation<Void, any Error>?
    private var conclusa = false
    private var fallimento: DownloadFailure?

    private init(parziale: URL, destinazione: URL, attesi: Int, nome: String,
                 presenti: Int, onBytes: @escaping @Sendable (Int) -> Void) {
        self.parziale = parziale
        self.destinazione = destinazione
        self.attesi = attesi
        self.nome = nome
        self.presenti = presenti
        self.ultimaEmissione = presenti
        self.onBytes = onBytes
    }

    static func scarica(
        da url: URL,
        verso dest: URL,
        attesi: Int,
        nome: String,
        onBytes: @escaping @Sendable (Int) -> Void
    ) async throws {
        let parziale = dest.appendingPathExtension("part")
        do {
            try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
        } catch {
            throw DownloadFailure.disco(nome: nome, causa: error.localizedDescription)
        }

        // Il `.part` lasciato da una caduta è la prova utile, non spazzatura: più
        // corto lo estende il `Range` qui sotto invece di ripagare quei byte, più
        // lungo non può che essere corrotto, esatto salta la rete del tutto.
        var giaPresenti = taglia(parziale) ?? 0
        if giaPresenti > attesi {
            do {
                try FileManager.default.removeItem(at: parziale)
                giaPresenti = 0
            } catch {
                throw DownloadFailure.disco(nome: nome, causa: error.localizedDescription)
            }
        } else if giaPresenti == attesi {
            onBytes(attesi)
            try installaParziale(parziale, verso: dest, attesi: attesi, nome: nome)
            return
        }

        // Un'emissione prima ancora di aprire la connessione: alla ripresa la
        // barra riparte da dove era, non da zero. Su un file mai cominciato non
        // serve, perché zero non è progresso.
        if giaPresenti > 0 {
            onBytes(giaPresenti)
        }

        var richiesta = URLRequest(url: url)
        if giaPresenti > 0 {
            richiesta.setValue("bytes=\(giaPresenti)-", forHTTPHeaderField: "Range")
        }

        let downloader = ResumableDownload(parziale: parziale, destinazione: dest,
                                           attesi: attesi, nome: nome,
                                           presenti: giaPresenti, onBytes: onBytes)
        try await withCheckedThrowingContinuation { continuation in
            downloader.avvia(richiesta, continuazione: continuation)
        }
    }

    static func scaricaConRitentativi(
        da url: URL,
        verso dest: URL,
        attesi: Int,
        nome: String,
        tentativi: Int = 3,
        onBytes: @escaping @Sendable (Int) -> Void
    ) async throws {
        precondition(tentativi > 0, "Il numero di tentativi deve essere positivo")
        for tentativo in 1...tentativi {
            do {
                try await scarica(da: url, verso: dest, attesi: attesi,
                                  nome: nome, onBytes: onBytes)
                return
            } catch let errore as DownloadFailure {
                if case .rete = errore, tentativo < tentativi {
                    let secondi = tentativo == 1 ? 1 : 3
                    try await Task.sleep(for: .seconds(secondi))
                } else {
                    throw errore
                }
            } catch {
                throw error
            }
        }
    }

    /// La misura precede qualunque rimozione della destinazione: così un file
    /// vecchio non viene sacrificato a un `.part` che non ha superato il cancello
    /// byte-per-byte.
    static func installaParziale(_ parziale: URL, verso dest: URL,
                                 attesi: Int, nome: String) throws {
        let ottenuti = taglia(parziale) ?? -1
        guard ottenuti == attesi else {
            throw DownloadFailure.tagliaErrata(nome: nome, ottenuti: ottenuti, attesi: attesi)
        }
        do {
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.moveItem(at: parziale, to: dest)
        } catch {
            throw DownloadFailure.disco(nome: nome, causa: error.localizedDescription)
        }
    }

    /// Il primo byte che il server dichiara di star spedendo, letto da
    /// `Content-Range: bytes <inizio>-<fine>/<totale>`. `nil` se l'intestazione
    /// manca o non ha quella forma, e `nil` non è mai uguale a un `presenti`
    /// valido: un 206 senza `Content-Range` viene rifiutato, non creduto.
    static func inizioContentRange(_ intestazione: String?) -> Int? {
        guard let intestazione else { return nil }
        let pulita = intestazione.trimmingCharacters(in: .whitespaces)
        guard pulita.lowercased().hasPrefix("bytes ") else { return nil }
        let intervallo = pulita.dropFirst("bytes ".count)
        guard let trattino = intervallo.firstIndex(of: "-") else { return nil }
        return Int(intervallo[intervallo.startIndex..<trattino])
    }

    private func inizioDi(_ risposta: HTTPURLResponse) -> Int? {
        Self.inizioContentRange(risposta.value(forHTTPHeaderField: "Content-Range"))
    }

    private static func taglia(_ url: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? nil
    }

    private func avvia(_ richiesta: URLRequest,
                       continuazione: CheckedContinuation<Void, any Error>) {
        lockConclusione.lock()
        self.continuazione = continuazione
        lockConclusione.unlock()

        let configurazione = URLSessionConfiguration.ephemeral
        configurazione.timeoutIntervalForRequest = 60
        // 1,1 GB su una linea lenta possono richiedere legittimamente ore; un
        // giorno lascia quel margine ma impedisce a una sessione muta di vivere
        // per sempre come un processo appeso.
        configurazione.timeoutIntervalForResource = 86_400
        let coda = OperationQueue()
        coda.maxConcurrentOperationCount = 1
        let sessione = URLSession(configuration: configurazione, delegate: self,
                                  delegateQueue: coda)
        self.sessione = sessione
        sessione.dataTask(with: richiesta).resume()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard let risposta = response as? HTTPURLResponse else {
            fallimento = .rete(nome: nome, causa: "risposta non HTTP")
            completionHandler(.cancel)
            return
        }

        do {
            if risposta.statusCode == 206 {
                // Il 206 da solo non basta: dice «ecco una porzione», non «ecco
                // LA porzione che hai chiesto». Se il primo byte spedito non è
                // quello che manca, accodarlo produrrebbe un file della taglia
                // giusta e del contenuto sbagliato — l'unico modo di far passare
                // il cancello dei byte con dati corrotti. La sorgente passa dal
                // 302 di huggingface.co a una CDN, e un `Range` che sopravvive
                // al reindirizzamento è un fatto da verificare, non da sperare.
                guard inizioDi(risposta) == presenti else {
                    fallimento = .contenuto(
                        nome: nome,
                        dettaglio: "il server riprende da \(inizioDi(risposta).map(String.init) ?? "?") invece che da \(presenti)")
                    completionHandler(.cancel)
                    return
                }
                try apriParziale(troncando: false)
                completionHandler(.allow)
            } else if risposta.statusCode == 200 {
                try apriParziale(troncando: true)
                presenti = 0
                ultimaEmissione = 0
                onBytes(0)
                completionHandler(.allow)
            } else {
                fallimento = .http(nome: nome, stato: risposta.statusCode)
                completionHandler(.cancel)
            }
        } catch {
            fallimento = .disco(nome: nome, causa: error.localizedDescription)
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive data: Data) {
        guard let file else {
            fallimento = .disco(nome: nome, causa: "file parziale non aperto")
            dataTask.cancel()
            return
        }
        do {
            try file.write(contentsOf: data)
            presenti += data.count
            emettiSeServe(forza: false)
        } catch {
            fallimento = .disco(nome: nome, causa: error.localizedDescription)
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didCompleteWithError error: (any Error)?) {
        var erroreChiusura: DownloadFailure?
        do {
            try file?.close()
        } catch {
            erroreChiusura = .disco(nome: nome, causa: error.localizedDescription)
        }
        file = nil
        emettiSeServe(forza: true)

        if let fallimento {
            concludi(.failure(fallimento))
        } else if let error {
            if let erroreRete = error as? URLError {
                concludi(.failure(DownloadFailure.rete(
                    nome: nome, causa: erroreRete.localizedDescription)))
            } else {
                concludi(.failure(DownloadFailure.disco(
                    nome: nome, causa: error.localizedDescription)))
            }
        } else if let erroreChiusura {
            concludi(.failure(erroreChiusura))
        } else {
            completaSenzaErroreDiSessione()
        }
    }

    /// `troncando` è la traduzione diretta dello stato HTTP: il 206 prosegue il
    /// parziale, il 200 dice che il server ha ignorato il `Range` e quei byte
    /// non sono più il prefisso di niente, quindi vanno azzerati.
    private func apriParziale(troncando: Bool) throws {
        if !FileManager.default.fileExists(atPath: parziale.path) {
            guard FileManager.default.createFile(atPath: parziale.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        let aperto = try FileHandle(forWritingTo: parziale)
        if troncando {
            try aperto.truncate(atOffset: 0)
        } else {
            try aperto.seekToEnd()
        }
        file = aperto
    }

    /// Una emissione ogni MiB, più una forzata alla fine. Sul peso da 1,1 GB
    /// fanno circa 1.066 eventi crescenti — abbastanza da rendere il movimento
    /// visibile a occhio, troppo pochi per svegliare SwiftUI a ogni pacchetto.
    private func emettiSeServe(forza: Bool) {
        if forza || presenti - ultimaEmissione >= Self.passoEmissione {
            onBytes(presenti)
            ultimaEmissione = presenti
        }
    }

    private func completaSenzaErroreDiSessione() {
        let finale = Self.taglia(parziale) ?? -1
        if finale == attesi {
            do {
                try Self.installaParziale(parziale, verso: destinazione,
                                          attesi: attesi, nome: nome)
                concludi(.success(()))
            } catch {
                concludi(.failure(error))
            }
        } else if finale < attesi {
            concludi(.failure(DownloadFailure.rete(
                nome: nome,
                causa: "trasferimento terminato a \(finale) byte su \(attesi)")))
        } else {
            do {
                try FileManager.default.removeItem(at: parziale)
                concludi(.failure(DownloadFailure.tagliaErrata(
                    nome: nome, ottenuti: finale, attesi: attesi)))
            } catch {
                concludi(.failure(DownloadFailure.disco(
                    nome: nome, causa: error.localizedDescription)))
            }
        }
    }

    private func concludi(_ risultato: Result<Void, any Error>) {
        lockConclusione.lock()
        guard !conclusa, let continuazione else {
            lockConclusione.unlock()
            return
        }
        conclusa = true
        self.continuazione = nil
        lockConclusione.unlock()

        sessione?.finishTasksAndInvalidate()
        continuazione.resume(with: risultato)
    }
}
