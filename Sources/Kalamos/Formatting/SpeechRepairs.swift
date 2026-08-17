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

    private static let fillerPuri: Set<String> = [
        "ehm", "ehmm", "uhm", "uhmm", "mmm", "mmh", "ehh", "uhh",
    ]
    private static let marcatori: [[String]] = [
        ["anzi"], ["no", "aspetta"], ["volevo", "dire"], ["no", "scusa"],
    ]

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
                                let contenuto = span.contains { $0.count >= 5 }
                                if combacia >= Int((Double(span.count) / 2).rounded(.up)), contenuto {
                                    da = j
                                    break
                                }
                            }
                        }
                        j -= 1
                    }
                    guard da >= 0 else { continue }   // niente ripetizione → non toccare
                    parole = Array(parole[0..<da]) + Array(parole[(i + m.count)...])
                    mosso = true
                    break esterno
                }
            }
        }
        return pulisci(parole)
    }
}
