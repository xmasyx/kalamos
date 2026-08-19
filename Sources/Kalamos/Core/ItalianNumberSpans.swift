import Foundation

/// Scrive in cifre i numeri che Parakeet consegna a lettere.
///
/// **Perché esiste.** Parakeet TDT non ha normalizzazione inversa per
/// l'italiano: scrive «trenta per cento» dove Whisper scrive «30%», e
/// «uno.cinque barra uno.sette» dove lui, nella verità che riscrive a mano,
/// scrive «1.5/1.7». Non è un ascolto peggiore, è una scelta di formato — ma
/// nel testo consegnato è un errore lo stesso, e nel banco delle 158 dettature
/// la classe «numeri» vale mezzo punto di WER.
///
/// Misurato sulle sue 158 verità (metà di taratura, 19/08): scrive i numeri
/// **in cifre 32 volte e a lettere 3**. La direzione della conversione non è
/// una preferenza mia.
///
/// **Il guasto contro cui è costruito** è il gemello di quello di
/// `VocabularyRepair`: non «manca un numero», ma «ha trasformato in numero una
/// parola che numero non era». In italiano le collisioni non sono ipotetiche,
/// sono le parole più frequenti che esistano:
///
///   - **«un», «uno», «una»** sono l'articolo indeterminativo. Nel corpus di
///     taratura compaiono 70 volte e quasi nessuna è il numero.
///   - **«sei»** è la seconda persona di *essere*. Nel corpus c'è la frase
///     «**Sei** sicuro che siano 1,73 ore», che una conversione ingenua
///     manderebbe in «**6** sicuro che siano».
///   - **«per»** è una preposizione e **«punto»** un sostantivo («il punto 7»):
///     è la stessa ragione per cui il banco `Confronto.ts` li tiene fuori dalla
///     lista NUMERI.
///
/// Quindi quelle parole non si convertono **mai da sole**. Rientrano in gioco
/// solo dentro una costruzione che non ha altra lettura possibile: attaccate a
/// un punto o a una virgola con un altro numero dall'altra parte
/// («uno.cinque»), che in italiano scritto non è una frase, è un decimale.
///
/// **La regola che il corpus ha imposto, e che non era quella di partenza.**
/// La prima versione convertiva ogni parola-numero non ambigua. Il cancello sui
/// 79 testi di taratura ha prodotto nove cambi, e leggerli — che è tutto il
/// punto del cancello — ne ha bocciati cinque: «costruirlo a **zero**» → «a 0»,
/// «**zero** registrazioni» dove la verità scritta da lui dice *zero* a lettere,
/// «spezzetta l'occupazione in **due**», «tutte e **tre**», «meglio **due**
/// cosa». Sono modi di dire, non quantità, e hanno la stessa forma delle
/// conversioni giuste («**otto** ore»): numero più sostantivo. La forma non
/// separa i due casi, quindi nessuna regola sulla forma può farlo.
///
/// Da lì la regola definitiva: **una parola-numero diventa cifra solo se il
/// testo intorno prova che è un numero** — un decimale attaccato, un separatore
/// fra due numeri, un «per cento» che segue. Una parola-numero isolata resta
/// una parola. Si perdono «otto ore» e «il punto sette»; si evita di riscrivere
/// la sua lingua, che è il danno che non si vede.
///
/// **Cosa NON fa, per scelta.** Non compone numeri scritti su più parole
/// («due mila venticinque»): la composizione italiana è ricca di casi e ogni
/// regola in più è una superficie in più su cui sbagliare, mentre nel corpus
/// vero le sequenze multi-parola non compaiono affatto. Una parola per volta,
/// e se il numero è composto resta com'è.
enum ItalianNumberSpans {

    /// Le parole che valgono un numero, una per una. Le decine composte in
    /// italiano si scrivono attaccate («ventitré», «trentacinque»), quindi
    /// stanno qui come parole singole e non serve comporle.
    static let value: [String: Int] = {
        var t: [String: Int] = [
            "zero": 0, "uno": 1, "un": 1, "una": 1, "due": 2, "tre": 3,
            "quattro": 4, "cinque": 5, "sei": 6, "sette": 7, "otto": 8,
            "nove": 9, "dieci": 10, "undici": 11, "dodici": 12, "tredici": 13,
            "quattordici": 14, "quindici": 15, "sedici": 16, "diciassette": 17,
            "diciotto": 18, "diciannove": 19, "venti": 20, "trenta": 30,
            "quaranta": 40, "cinquanta": 50, "sessanta": 60, "settanta": 70,
            "ottanta": 80, "novanta": 90, "cento": 100, "mille": 1000,
        ]
        // Le composte 21–99, generate invece che elencate: la troncatura della
        // decina davanti a «uno» e «otto» («ventuno», «ventotto») è una regola,
        // e scritta a mano sarebbe un elenco di 80 righe da sbagliare.
        let decine = [(2, "venti"), (3, "trenta"), (4, "quaranta"), (5, "cinquanta"),
                      (6, "sessanta"), (7, "settanta"), (8, "ottanta"), (9, "novanta")]
        let unita = ["", "uno", "due", "tre", "quattro", "cinque", "sei", "sette", "otto", "nove"]
        for (d, nome) in decine {
            for u in 1...9 {
                let tronca = (u == 1 || u == 8)
                let radice = tronca ? String(nome.dropLast()) : nome
                t[radice + unita[u]] = d * 10 + u
                if u == 3 { t[radice + "tré"] = d * 10 + 3 }   // ventitré, trentatré
            }
        }
        return t
    }()

    /// Mai convertite da sole: articolo, pronome, verbo. Vedi il commento sopra.
    static let ambigue: Set<String> = ["un", "uno", "una", "sei"]

    /// Marcatore interno per «per cento» riconosciuto: non compare mai in uscita.
    private static let percentoMark = "\u{0}percento\u{0}"

    /// `paroleIsolate` è il polo bocciato, tenuto vivo perché il banco possa
    /// rimisurarlo: con `true` converte anche una parola-numero che nessuna
    /// costruzione licenzia. Misurato il 19/08 sulla metà di taratura, peggiora.
    /// In produzione non si accende: lo accende solo `--selftest-numeri`.
    static func apply(to text: String, paroleIsolate: Bool = false) -> String {
        guard !text.isEmpty else { return text }
        var tokens = VocabularyRepair.tokenize(text)
        unisciPerCento(&tokens)
        cifra(&tokens, paroleIsolate: paroleIsolate)
        separatori(&tokens)
        return tokens.map(\.text).joined()
    }

    // MARK: - Attrezzi sui token

    private static func indiciParola(_ tokens: [VocabularyRepair.Token]) -> [Int] {
        tokens.indices.filter { tokens[$0].isWord }
    }

    /// Il testo che sta FRA due parole consecutive. Il tokenizer alterna parola
    /// e non-parola, quindi è sempre un token solo — ma leggerlo per posizione
    /// invece che assumerlo è ciò che tiene la funzione vera anche se il
    /// tokenizer cambia.
    private static func giunzione(_ tokens: [VocabularyRepair.Token], _ a: Int, _ b: Int) -> String {
        guard b > a + 1 else { return "" }
        return tokens[(a + 1)..<b].map(\.text).joined()
    }

    private static func èCifre(_ s: String) -> Bool {
        !s.isEmpty && s.allSatisfy(\.isNumber)
    }

    private static func èNumero(_ s: String) -> Bool {
        value[s.lowercased()] != nil || èCifre(s)
    }

    // MARK: - Passata 0: «per cento» → un token solo

    /// «trenta per cento» diventa «trenta ␀percento␀», ma solo se davanti c'è un
    /// numero: senza quella guardia «per cento chilometri» — dove «per» è la
    /// preposizione — entrerebbe nella stessa strada.
    private static func unisciPerCento(_ tokens: inout [VocabularyRepair.Token]) {
        var k = 1
        while true {
            let w = indiciParola(tokens)
            guard k + 1 < w.count else { break }
            let per = tokens[w[k]].text.lowercased()
            let cento = tokens[w[k + 1]].text.lowercased()
            let prima = tokens[w[k - 1]].text
            if per == "per", cento == "cento", èNumero(prima),
               giunzione(tokens, w[k], w[k + 1]) == " ",
               giunzione(tokens, w[k - 1], w[k]) == " " {
                tokens.replaceSubrange(w[k]...w[k + 1], with: [.word(percentoMark)])
                continue   // gli indici sono cambiati: si ricalcolano
            }
            k += 1
        }
        // «percento» già attaccato dal motore: stesso marcatore, stessa guardia.
        let w = indiciParola(tokens)
        for k in 1..<max(1, w.count) where tokens[w[k]].text.lowercased() == "percento" {
            if èNumero(tokens[w[k - 1]].text), giunzione(tokens, w[k - 1], w[k]) == " " {
                tokens[w[k]] = .word(percentoMark)
            }
        }
    }

    // MARK: - Passata A: la parola-numero diventa cifra

    private static func cifra(_ tokens: inout [VocabularyRepair.Token], paroleIsolate: Bool) {
        let w = indiciParola(tokens)
        for (k, i) in w.enumerated() {
            let parola = tokens[i].text.lowercased()
            guard let n = value[parola] else { continue }
            guard licenziata(tokens, w, k) || (paroleIsolate && !ambigue.contains(parola))
            else { continue }
            tokens[i] = .word(String(n))
        }
    }

    /// Il testo intorno prova che questa parola è un numero?
    ///
    /// Tre prove, e nessuna è un'euristica: sono costruzioni che in italiano
    /// scritto non hanno una seconda lettura.
    ///
    ///   1. **decimale attaccato** — un punto o una virgola SENZA spazi, con un
    ///      numero dall'altra parte: «uno.cinque». Una frase italiana non
    ///      attacca due parole a un punto.
    ///   2. **separatore fra due numeri** — «uno virgola cinque», «uno barra
    ///      due»: a destra e a sinistra del segno c'è un numero.
    ///   3. **«per cento» che segue** — già ridotto a un marcatore dalla
    ///      passata 0, che a sua volta pretendeva un numero davanti.
    private static func licenziata(_ tokens: [VocabularyRepair.Token],
                                   _ w: [Int], _ k: Int) -> Bool {
        let i = w[k]
        let prima = k > 0 ? giunzione(tokens, w[k - 1], i) : nil
        let dopo = k + 1 < w.count ? giunzione(tokens, i, w[k + 1]) : nil
        let numPrima = k > 0 && èNumero(tokens[w[k - 1]].text)
        let numDopo = k + 1 < w.count && èNumero(tokens[w[k + 1]].text)

        // 1. decimale attaccato
        if let g = prima, [".", ","].contains(g), numPrima { return true }
        if let g = dopo, [".", ","].contains(g), numDopo { return true }
        // 3. «per cento»
        if dopo == " ", k + 1 < w.count, tokens[w[k + 1]].text == percentoMark { return true }
        // 2. separatore con un numero dall'altra parte del segno
        let segni: Set<String> = ["virgola", "punto", "barra"]
        if dopo == " ", k + 2 < w.count, segni.contains(tokens[w[k + 1]].text.lowercased()),
           giunzione(tokens, w[k + 1], w[k + 2]) == " ", èNumero(tokens[w[k + 2]].text) {
            return true
        }
        if prima == " ", k >= 2, segni.contains(tokens[w[k - 1]].text.lowercased()),
           giunzione(tokens, w[k - 2], w[k - 1]) == " ", èNumero(tokens[w[k - 2]].text) {
            return true
        }
        return false
    }

    // MARK: - Passata B: i separatori, solo fra cifre

    /// «virgola», «punto» e «barra» valgono come segno **solo** con una cifra da
    /// entrambe le parti: è la guardia che lascia stare «il punto sette», dove
    /// «punto» è il sostantivo e davanti c'è un articolo.
    private static func separatori(_ tokens: inout [VocabularyRepair.Token]) {
        let segno = ["virgola": ",", "punto": ".", "barra": "/"]
        var k = 1
        while true {
            let w = indiciParola(tokens)
            guard k + 1 < w.count else { break }
            let parola = tokens[w[k]].text.lowercased()
            if let s = segno[parola],
               èCifre(tokens[w[k - 1]].text), èCifre(tokens[w[k + 1]].text),
               giunzione(tokens, w[k - 1], w[k]) == " ",
               giunzione(tokens, w[k], w[k + 1]) == " " {
                tokens.replaceSubrange((w[k - 1] + 1)...(w[k + 1] - 1), with: [.gap(s)])
                continue
            }
            k += 1
        }
        // Il marcatore del percento: attaccato alla cifra se la cifra c'è ancora,
        // altrimenti rimesso com'era. Un marcatore che sopravvive è un guasto
        // visibile nel testo consegnato, e non deve poter succedere.
        var j = 0
        while j < tokens.count {
            guard tokens[j].text == percentoMark else { j += 1; continue }
            let w = indiciParola(tokens)
            let k = w.firstIndex(of: j)!
            if k > 0, èCifre(tokens[w[k - 1]].text), giunzione(tokens, w[k - 1], j) == " " {
                tokens.replaceSubrange((w[k - 1] + 1)...j, with: [.gap("%")])
            } else {
                tokens[j] = .word("per cento")
                j += 1
            }
        }
    }
}
