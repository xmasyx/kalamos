import Foundation

/// Le due regole di riparazione del parlato, misurate sul banco sintetico
/// (`kalamos-punteggiatura/sintetico/`, REFERTO-SINTETICO.md) e portate qui
/// parola per parola:
///
/// · R-min — via i filler puri (ehm, uhm, mmm e varianti), che in italiano non
///   sono mai parole. Niente altro: «cioè», «allora», «tipo» NON si toccano.
/// · R-agg — R-min più le autocorrezioni col trucco della ripetizione: la
///   riparazione RIPETE l'attacco di ciò che ritratta («la grammatica anzi la
///   punteggiatura»). Senza ripetizione con contenuto la regola non tocca:
///   è ciò che salva «non è male, anzi è ottimo» e «no, aspetta un attimo».
///
/// I numeri del banco: richiamo 87,6% sulle rimozioni dovute con ZERO parole
/// legittime perse, ZERO falsi sul polo negativo, ZERO aggiunte — contro il
/// 70,1% dell'LLM con 64 parole perse. Sull'archivio vero delle dettature la
/// regola non toglie NIENTE (0 rimozioni misurate): il principale detta pulito,
/// queste regole esistono per chi non lo fa.
enum SpeechRepairs {

    /// **L'unica lista di filler italiani dell'app**, e il fatto che sia una
    /// sola è la riparazione, non un dettaglio di stile.
    ///
    /// Fino al 2026-08-18 ce n'erano DUE che dicevano il contrario:
    /// questa, misurata, e quella di `RuleBasedFormatter`, che cancellava
    /// «cioè», «tipo», «insomma», «praticamente», «diciamo» con una
    /// sostituzione cieca. Vinceva la seconda perché gira nel percorso a
    /// regole, e due sue dettature vere sono uscite mutilate: «Allora diciamo
    /// che il 15…» → «Allora che il 15…», «…perché? cioè noi abbiamo…» →
    /// «…perché? Noi abbiamo…».
    ///
    /// Il censimento sul suo archivio (174 righe) aveva già la risposta:
    /// «ok» 9, «allora» 8, «tipo» 3, «diciamo» 2, «cioè» 1, tenute il **100%**
    /// delle volte. Qui restano solo i suoni che in italiano non sono mai
    /// parole, e `RuleBasedFormatter` legge di qui invece di avere una copia.
    static let fillerPuri: Set<String> = [
        "ehm", "ehmm", "eh", "uhm", "uhmm", "mmm", "mmh", "ehh", "uhh",
    ]

    /// I marcatori di autocorrezione, **dal più lungo al più corto**.
    ///
    /// L'ordine è la riparazione del 2026-08-18: «anzi no» è il modo in cui lo
    /// dice davvero, e con «anzi» secco provato per primo l'ancora andava a
    /// cercare la ripetizione partendo da «no» — una parola che non era stata
    /// detta prima, quindi non trovava niente e non toccava nulla. È la stessa
    /// regola del più-lungo-per-primo che la tabella dei comandi parlati aveva
    /// già imparato per «punto e virgola» contro «virgola».
    private static let marcatori: [[String]] = [
        ["anzi", "no"], ["no", "aspetta"], ["volevo", "dire"], ["no", "scusa"], ["anzi"],
    ]

    private static func haCifre(_ w: String) -> Bool { w.contains(where: \.isNumber) }

    /// **Gli attacchi a vuoto, e si tolgono INTERI o non si toccano.**
    ///
    /// È la lezione del 2026-08-18, pagata su tre dettature vere di fila. La
    /// lista dei filler cancellava «diciamo» da sola, e da «Allora diciamo che
    /// il 15» usciva **«Allora che il 15»**, che non è italiano. Un'uscita
    /// sgrammaticata è peggio del non fare niente: il testo non ripulito lui lo
    /// legge, quello rotto lo deve riscrivere.
    ///
    /// Sono unità, non parole. Si riconoscono come sequenza contigua e se ne va
    /// tutta la sequenza, quindi non può nascere un frammento. Ed è anche ciò
    /// che salva il terzo caso di campo, dove «diciamo» era **l'oggetto del
    /// verbo** («è giusto che abbia tolto diciamo, però…»): lì dopo «diciamo»
    /// c'è «però» e non «che», nessuna locuzione combacia, e la frase resta
    /// intera. Una lista di parole non poteva distinguere i due casi; una lista
    /// di locuzioni lo fa per costruzione.
    ///
    /// Dal più lungo al più corto, per la solita ragione.
    private static let attacchi: [[String]] = [
        ["allora", "diciamo", "che"],
        ["voglio", "dire", "che"],
        ["diciamo", "che"],
        ["niente", "allora"],
        ["allora", "niente"],
    ]

    /// Via gli attacchi a vuoto, come unità intere.
    private static func togliAttacchi(_ parole: [String]) -> [String] {
        var parole = parole
        var mosso = true
        while mosso {
            mosso = false
            let c = parole.map(nocciolo)
            for a in attacchi {
                guard c.count > a.count else { continue }   // mai lasciare il vuoto
                for i in 0...(c.count - a.count) {
                    guard zip(a, c[i..<(i + a.count)]).allSatisfy({ $0 == $1 }) else { continue }
                    parole.removeSubrange(i..<(i + a.count))
                    mosso = true
                    break
                }
                if mosso { break }
            }
        }
        return parole
    }

    /// Il nocciolo di una parola: minuscolo, via la punteggiatura ai bordi.
    /// (Porto di `Regole.nocciolo`; i bordi sono quelli del banco.)
    static func nocciolo(_ w: String) -> String {
        let bordi = Set("\u{0020}\"«»“”„'(){}[]…-–—.,;:!?¿¡")
        var chars = Array(w.lowercased().map { ch -> Character in
            "’‘".contains(ch) ? "'" : ch
        })
        while let f = chars.first, bordi.contains(f) { chars.removeFirst() }
        while let l = chars.last, bordi.contains(l) { chars.removeLast() }
        return String(chars)
    }

    private static func pulisci(_ parole: [String]) -> String {
        parole.filter { !$0.isEmpty }.joined(separator: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    /// Solo i filler puri.
    static func rMin(_ testo: String) -> String {
        let parole = testo.split(whereSeparator: \.isWhitespace).map(String.init)
        return pulisci(parole.map { fillerPuri.contains(nocciolo($0)) ? "" : $0 })
    }

    /// Filler puri + autocorrezioni ancorate alla ripetizione dell'attacco.
    static func rAgg(_ testo: String) -> String {
        var parole = rMin(testo).split(whereSeparator: \.isWhitespace).map(String.init)

        /// Due noccioli «pari»: uguali, o stesso prefisso di 4 quando entrambi
        /// arrivano a 4. (È il confronto del banco, `pari`.)
        func pari(_ a: String, _ b: String) -> Bool {
            guard !a.isEmpty, !b.isEmpty else { return false }
            if a == b { return true }
            return a.count >= 4 && b.count >= 4 && a.prefix(4) == b.prefix(4)
        }

        var mosso = true
        while mosso {
            mosso = false
            let c = parole.map(nocciolo)
            esterno: for i in 0..<c.count {
                for m in marcatori {
                    guard i + m.count <= c.count else { continue }
                    guard zip(m, c[i..<(i + m.count)]).allSatisfy({ $0 == $1 }) else { continue }
                    let dopo = i + m.count
                    guard dopo < c.count else { continue }
                    let B = Array(c[dopo..<min(dopo + 4, c.count)])
                    var da = -1
                    var j = i - 1
                    while j >= max(0, i - 8) {
                        let ancora = c[j] == B[0] || pari(c[j], B[0])
                        if ancora {
                            let span = Array(c[j..<i])
                            if !span.isEmpty, span.count <= 4 {
                                let combacia = span.enumerated().filter { k, w in
                                    k < B.count && pari(w, B[k])
                                }.count
                                /// Il tratto ritrattato deve portare **contenuto**,
                                /// altrimenti la regola mangia le funzioni: è la
                                /// guardia che salva «non è male, anzi è ottimo»,
                                /// dove «male» si ferma a quattro lettere.
                                ///
                                /// Accanto, e non al posto suo, il **paio di
                                /// numeri allineati**: «il 15» → «il 17» non ha
                                /// una parola lunga e resta la correzione che lui
                                /// fa davvero (date, ore, quantità). Due cifre
                                /// nella stessa posizione e diverse fra loro sono
                                /// un segnale stretto, e non tocca nessun polo
                                /// negativo perché quelli non hanno cifre.
                                let contenuto = span.contains { $0.count >= 5 }
                                let numeri = span.indices.contains { k in
                                    k < B.count && haCifre(span[k]) && haCifre(B[k]) && span[k] != B[k]
                                }
                                if combacia >= Int((Double(span.count) / 2).rounded(.up)),
                                   contenuto || numeri {
                                    da = j
                                    break
                                }
                            }
                        }
                        j -= 1
                    }
                    /// **La ritrattazione nuda di un numero**, senza ripetizione
                    /// dell'attacco: «ne servono 12 anzi 20». Qui non c'è niente
                    /// da ripetere, e il segnale è tutto nella coppia di cifre a
                    /// cavallo del marcatore. Stretto per costruzione: basta che
                    /// una delle due parti non porti cifre e non scatta, che è
                    /// ciò che salva «erano in 3, anzi era pieno di gente».
                    if da < 0, i > 0, haCifre(c[i - 1]), haCifre(B[0]), c[i - 1] != B[0] {
                        da = i - 1
                    }
                    guard da >= 0 else { continue }   // niente ripetizione → non toccare
                    parole = Array(parole[0..<da]) + Array(parole[(i + m.count)...])
                    mosso = true
                    break esterno
                }
            }
        }
        return pulisci(togliAttacchi(parole))
    }
}
