import Foundation

/// La politica I5W, misurata sul banco di punteggiatura e portata qui parola
/// per parola: i segni TERMINALI e la virgola li decide Whisper dove li ha
/// messi, il resto lo decide il modello L1; le maiuscole DI PAROLA (i nomi
/// propri) si ereditano da Whisper; dove l'allineamento non appaia una parola,
/// vale L1 e basta. Sopra tutto, la regola d'inizio frase.
///
/// I numeri che questa politica deve riprodurre (metro d'autore, 40 frasi):
/// punto 85,9 · virgola 78,4 · domanda 91,2 di F1, maiuscole 91,5%, maiuscole
/// interne 76,9. Il gate è `--bench-i5w` contro gli script del banco.
enum PunctuationHybrid {

    /// I terminali della politica (qui niente «…»: è il novero di Ibrido.ts).
    private static let term: Set<String> = [".", "!", "?"]

    /// Connettivi che a inizio frase NON vogliono la virgola d'inciso nel
    /// dettato (metro d'autore + Prontuario di punteggiatura, posizione
    /// parentetica: marcatura legittima ma facoltativa, e nel parlato la forma
    /// non marcata è quella del metro). Novero chiuso, misurato: virgola
    /// 72,7 → 73,6 sul metro, punto e domanda invariati.
    private static let connettivi: Set<String> = [
        "inoltre", "però", "quindi", "comunque", "poi", "allora", "infatti",
        "dunque", "insomma", "cioè", "intanto", "tuttavia", "ecco", "anzi",
    ]

    /// Un pezzo della frase in lavorazione: la parola e il segno che la segue.
    struct Pezzo {
        var parola: String
        var mark: String
    }

    /// Smorza la virgola facile dopo un connettivo in apertura di frase.
    /// Mai a metà frase (l'inciso «, infatti,» resta). Porto della regola del
    /// banco (`RegolaConnettivi.applica`), a livello di pezzi: una frase
    /// comincia al primo pezzo o dopo un terminale.
    static func smorzaConnettivi(_ pezzi: [Pezzo]) -> [Pezzo] {
        var out = pezzi
        var apreFrase = true
        for i in out.indices {
            if apreFrase, out[i].mark == ",", connettivi.contains(out[i].parola.lowercased()) {
                out[i].mark = ""
            }
            apreFrase = term.contains(out[i].mark)
        }
        return out
    }

    /// La scelta di segno di I5: il terminale di Whisper vince; la sua virgola
    /// vale solo dove L1 non chiude la frase; tutto il resto è di L1.
    static func scegliSegno(whisper w: String, l1 l: String) -> String {
        if term.contains(w) { return w }
        if w == ",", !term.contains(l) { return "," }
        return l
    }

    /// La regola di maiuscolizzazione del banco — prima lettera della frase su,
    /// frase nuova dopo `.` `!` `?` — PIÙ la guardia fra-due-cifre che il banco
    /// non aveva: un punto dentro «1.250,40» non apre nessuna frase. È l'unico
    /// scostamento voluto dalla versione misurata, e ripara il difetto che il
    /// metro d'autore puniva (la frase dei decimali: «1.5 Tipo… Per 1»).
    static func maiuscoleDiFrase(_ testo: String) -> String {
        let chars = Array(testo)
        var out = ""
        var apri = true
        for i in chars.indices {
            let ch = chars[i]
            if apri, ch.isLetter {
                out += String(ch).uppercased()
                apri = false
            } else {
                out.append(ch)
            }
            if ".!?".contains(ch) {
                let traDueCifre = ch == "." && i > 0 && i + 1 < chars.count
                    && chars[i - 1].isNumber && chars[i + 1].isNumber
                if !traDueCifre { apri = true }
            }
        }
        return out
    }

    private static func alza(_ w: String) -> String {
        guard let primo = w.first else { return w }
        return String(primo).uppercased() + w.dropFirst()
    }

    /// L'intera politica: dalle parole spogliate + etichette L1 + testo grezzo
    /// di Whisper al testo finale. `parole` e `etichette` hanno pari lunghezza;
    /// `grezzo` è il testo di Whisper da cui ereditare segni e maiuscole.
    static func i5w(parole: [String], etichette: [String], grezzo: String) -> String {
        precondition(parole.count == etichette.count, "parole ed etichette devono appaiarsi")

        // 1. I pezzi di L1, con lo smorzamento dei connettivi.
        var pezzi = zip(parole, etichette).map { p, l in
            Pezzo(parola: p, mark: l == "0" ? "" : l)
        }
        pezzi = smorzaConnettivi(pezzi)

        // 2. I segni e le maiuscole di Whisper, via l'allineamento del banco.
        let tokS = PunctuationAlign.tokenizza(parole.joined(separator: " "))
        let tokW = PunctuationAlign.tokenizza(grezzo)
        var markWhisper = [String](repeating: "", count: parole.count)
        var capWhisper = [Bool](repeating: false, count: parole.count)
        // Nel percorso reale `parole` viene dallo spoglio, quindi tokS ha una
        // voce per parola. Se i conti non tornano (un ingresso non spogliato),
        // nessuna eredità: resta L1 e basta, che è la politica del buco.
        if tokS.count == parole.count {
            for coppia in PunctuationAlign.allinea(tokS, tokW) {
                markWhisper[coppia.r] = tokW[coppia.h].mark
                capWhisper[coppia.r] = tokW[coppia.h].cap && !tokW[coppia.h].inizioFrase
            }
        }

        // 3. La fusione, parola per parola.
        let testo = pezzi.enumerated().map { k, pezzo -> String in
            let mark = scegliSegno(whisper: markWhisper[k], l1: pezzo.mark)
            let parola = capWhisper[k] ? alza(pezzo.parola) : pezzo.parola.lowercased()
            return parola + mark
        }.joined(separator: " ")

        // 4. La regola d'inizio frase, per ultima.
        return maiuscoleDiFrase(testo)
    }
}
