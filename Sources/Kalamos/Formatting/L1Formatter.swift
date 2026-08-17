import Foundation

/// Il formatter del livello L1: punteggiatura dal modello dedicato, fusa con
/// ciò che Whisper ha già sentito (politica I5W), più le regole di riparazione
/// del parlato. Costa ~20 ms dove l'LLM ne costa ~3.300, e non può cambiare le
/// parole: sceglie solo segni e maiuscole.
///
/// L'ordine della pipeline è un vincolo misurato, non una preferenza:
/// grezzo → comandi parlati → L1/I5W → rifiniture. Il modello lavora sul testo
/// spogliato PRIMA di ogni regola di spaziatura: passargli l'uscita delle
/// regole significherebbe ereditare i loro difetti (era la strada in cui
/// `tidySpacing` spaccava i decimali).
struct L1Formatter: TextFormatter {

    func format(_ raw: String, context: FormattingContext) async -> String {
        // Dentro un editor di codice la dettatura resta verbatim: stessa scelta
        // del formatter a regole, che qui si riusa per intero.
        if context.isCodeEditor {
            return await RuleBasedFormatter().format(raw, context: context)
        }

        let rb = RuleBasedFormatter()
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "" }

        // I comandi parlati sono istruzioni, non parole: si eseguono prima,
        // così «punto interrogativo» diventa un segno che la politica ibrida
        // tratta come qualunque segno già presente nel grezzo.
        text = rb.applyCommands(to: text, lang: context.language)
        text = rb.applyPunctuationWord(to: text, lang: context.language)

        // Un blocco per riga: gli a-capo (dai comandi «a capo» / «nuovo
        // paragrafo») sono confini che il modello non deve attraversare.
        let blocchi = text.components(separatedBy: "\n")
        var fuori: [String] = []
        for blocco in blocchi {
            let pulito = blocco.trimmingCharacters(in: .whitespaces)
            guard !pulito.isEmpty else { fuori.append(""); continue }
            fuori.append(await punteggia(blocco: pulito))
        }
        text = fuori.joined(separator: "\n")

        text = rb.ensureTerminalPunctuation(text)
        return rb.tidySpacing(text)
    }

    /// Un blocco di testo attraverso L1 + I5W. Se il modello inciampa, il
    /// blocco passa dalle regole classiche: mai un blocco perso.
    private func punteggia(blocco: String) async -> String {
        let spoglio = PunctuationAlign.spoglia(blocco)
        guard !spoglio.isEmpty else { return blocco }

        // Riparazioni del parlato sul testo spogliato: le parole tolte non
        // arrivano mai al modello.
        let riparato = SpeechRepairs.rAgg(spoglio)
        let parole = riparato.split(separator: " ").map(String.init)
        guard !parole.isEmpty else { return blocco }

        do {
            try await PunctuationModel.shared.prepare()
            let etichette = try await PunctuationModel.shared.etichette(perParole: parole)
            return PunctuationHybrid.i5w(parole: parole, etichette: etichette, grezzo: blocco)
        } catch {
            Log.write("punteggiatura L1 fallita (\(error.localizedDescription)) — blocco alle regole")
            return blocco
        }
    }
}
