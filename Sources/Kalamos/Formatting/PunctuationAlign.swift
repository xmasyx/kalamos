import Foundation

/// Porto fedele delle quattro funzioni di misura del banco di punteggiatura
/// (`03-Plans/Kalamos/kalamos-punteggiatura/Banco.ts`): spogliare un testo,
/// tokenizzarlo in parole etichettate, allineare due sequenze di parole.
///
/// La fedeltà non è un dettaglio: la politica I5W è stata MISURATA con queste
/// esatte definizioni (metro d'autore, 40 frasi — 85,9 / 78,4 / 91,2 di F1),
/// e un porto "quasi uguale" farebbe in campo una cosa diversa da quella
/// misurata. Il gate è `--bench-i5w`, che deve riprodurre i numeri del banco.
enum PunctuationAlign {

    /// I segni che il banco riconosce come marchio di una parola.
    static let segni: [Character] = [".", ",", "?", "!", ";", ":"]
    /// I segni che chiudono una frase: la parola dopo va maiuscola.
    static let terminali: Set<Character> = [".", "!", "?", "…"]

    /// Una parola tokenizzata: nocciolo normalizzato, segno che la segue,
    /// maiuscola iniziale, posizione di apertura frase.
    struct Tok {
        let core: String
        let mark: String
        let cap: Bool
        let inizioFrase: Bool
    }

    /// Normalizza per il confronto: minuscolo, apostrofi uniformi, via il resto.
    /// (Banco.ts `norm`.)
    static func norm(_ s: String) -> String {
        var out = ""
        for ch in s.lowercased() {
            if "’‘`´".contains(ch) { out.append("'") }
            else if ch.isLetter || ch.isNumber || ch == "'" { out.append(ch) }
        }
        return out
    }

    /// Segnaposto per i separatori decimali: dentro un numero non sono
    /// punteggiatura. (Banco.ts `proteggiDecimali`, DEC = U+0000.)
    private static let dec = Character("\u{0000}")
    private static func proteggiDecimali(_ t: String) -> String {
        var out = [Character]()
        let chars = Array(t)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if (c == "." || c == ","), i > 0, i + 1 < chars.count,
               chars[i - 1].isNumber, chars[i + 1].isNumber {
                out.append(dec)
            } else {
                out.append(c)
            }
            i += 1
        }
        return String(out)
    }

    private static let bordo = Set("\u{0020}\"«»“”„‘’'(){}[]…-–—.,;:!?¿¡")

    /// Spoglia un testo: via punteggiatura e maiuscole, restano le parole.
    /// Il separatore dentro un numero sopravvive nella forma che aveva
    /// («1,73» resta una parola sola). (Banco.ts `spoglia`.)
    static func spoglia(_ testo: String) -> String {
        var separatori: [Character] = []
        var t = ""
        let compresso = testo.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        let chars = Array(compresso)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if (c == "." || c == ","), i > 0, i + 1 < chars.count,
               chars[i - 1].isNumber, chars[i + 1].isNumber {
                separatori.append(c)
                t.append(dec)
            } else {
                t.append(c)
            }
            i += 1
        }
        t = t.replacingOccurrences(of: "…", with: " ")
        t = String(t.map { ch in "\u{0022}«»“”„.,;:!?¿¡()[]{}–—".contains(ch) ? " " : ch })
        // trattino: resta dentro una parola, sparisce quando è isolato
        t = t.replacingOccurrences(of: "(^|\\s)-+(\\s|$)", with: " ", options: .regularExpression)
        var restaurato = ""
        var k = 0
        for ch in t {
            if ch == dec {
                restaurato.append(k < separatori.count ? separatori[k] : ",")
                k += 1
            } else {
                restaurato.append(ch)
            }
        }
        return restaurato
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
    }

    /// Da testo a sequenza di parole etichettate. (Banco.ts `tokenizza`.)
    static func tokenizza(_ testo: String) -> [Tok] {
        let conACapo = testo.replacingOccurrences(of: "\\n+", with: " \n ", options: .regularExpression)
        let grezzi = conACapo.split(omittingEmptySubsequences: true, whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        var out: [Tok] = []
        var apriFrase = true
        for g in grezzi {
            if g == "\n" { apriFrase = true; continue }
            let protetto = proteggiDecimali(g)
            var chars = Array(protetto)
            while let f = chars.first, bordo.contains(f) { chars.removeFirst() }
            let senzaTesta = chars
            var nocciolo = senzaTesta
            while let l = nocciolo.last, bordo.contains(l) { nocciolo.removeLast() }
            let coda = senzaTesta.suffix(senzaTesta.count - nocciolo.count)
            guard !nocciolo.isEmpty else { continue }
            var mark = ""
            for ch in coda {
                if segni.contains(ch) { mark = String(ch) }
                else if ch == "…", mark.isEmpty { mark = "…" }
            }
            let core = norm(String(nocciolo))
            guard !core.isEmpty else { continue }
            let primaLettera = nocciolo.first(where: { $0.isLetter })
            let cap = primaLettera.map { String($0) != String($0).lowercased() } ?? false
            out.append(Tok(core: core, mark: mark, cap: cap, inizioFrase: apriFrase))
            apriFrase = mark.count == 1 && terminali.contains(Character(mark))
        }
        return out
    }

    /// Allineamento di Levenshtein sui noccioli: solo le coppie in cui la
    /// parola è LA STESSA. (Banco.ts `allinea`.)
    static func allinea(_ ref: [Tok], _ hyp: [Tok]) -> [(r: Int, h: Int)] {
        let n = ref.count, m = hyp.count
        var d = [Int](repeating: 0, count: (n + 1) * (m + 1))
        @inline(__always) func at(_ i: Int, _ j: Int) -> Int { i * (m + 1) + j }
        for i in 0...n { d[at(i, 0)] = i }
        for j in 0...m { d[at(0, j)] = j }
        if n > 0 && m > 0 {
            for i in 1...n {
                for j in 1...m {
                    let c = ref[i - 1].core == hyp[j - 1].core ? 0 : 1
                    d[at(i, j)] = min(d[at(i - 1, j)] + 1, d[at(i, j - 1)] + 1, d[at(i - 1, j - 1)] + c)
                }
            }
        }
        var coppie: [(r: Int, h: Int)] = []
        var i = n, j = m
        while i > 0 && j > 0 {
            let c = ref[i - 1].core == hyp[j - 1].core ? 0 : 1
            if d[at(i, j)] == d[at(i - 1, j - 1)] + c {
                if c == 0 { coppie.append((r: i - 1, h: j - 1)) }
                i -= 1; j -= 1
            } else if d[at(i, j)] == d[at(i - 1, j)] + 1 {
                i -= 1
            } else {
                j -= 1
            }
        }
        return coppie.reversed()
    }
}
