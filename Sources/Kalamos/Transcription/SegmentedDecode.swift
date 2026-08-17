import Foundation

/// Decoding a long recording piece by piece, and putting the text back together.
///
/// The cut itself is `AudioSplit`; this is the half that both Whisper engines
/// share, and it is shared for the same reason `trimSilence` and `isSilent` are:
/// these are the places this project has already been wrong twice, and two copies
/// drift apart without a test noticing.
///
/// Four properties, in the order they matter:
///
/// **Off by default, and off means untouched.** With `Tuning.segmentLongAudio`
/// unset — which is how it ships — this function is one `guard` and a call, so a
/// dictation takes exactly the path it took yesterday. The same is true with the
/// switch ON for anything at or under `AudioSplit.thresholdSeconds`: the buffer
/// handed to the engine is the same array object, not a copy of a slice.
///
/// **Each piece takes the whole ordinary path.** A piece is not a raw decode: it
/// goes through the engine's own `transcribeOne`, which means the silence gate,
/// the trailing-hallucination strip, the empty-decode reload (ISC-108), the
/// coverage repair (ISC-174) and the vocabulary's second pass all still run —
/// per piece.
///
/// That last one is a decision worth stating, because the alternative looks
/// tidier and is wrong. The targeted vocabulary prompt is built from what a
/// decode got wrong (`VocabularyPrompt`), so it needs a text to look at; running
/// it once at the end would mean re-decoding the WHOLE recording with a prompt,
/// which is the seek loop the cut exists to avoid, and it would throw the pieces
/// away to do it. Per piece, the mechanism is intact and the cut survives.
///
/// **One recording comes back in one language.** The first piece that decodes to
/// something settles it and the rest are decoded in it. This is the rule
/// `decodeCovering` already follows for its repairs, and the reason is the same:
/// the result carries a single `detectedLanguage`, so two pieces disagreeing
/// would put two decisions about the same recording into one field.
///
/// **The seam does not say anything twice.** Where there was no silence to cut
/// on, `AudioSplit` deliberately makes the pieces overlap by a second so a word
/// on the edge is transcribed whole on both sides; `TextSeam.join` then removes
/// the repetition once, and only once, using the same rule that already protects
/// his genuine repetitions ("tutto tutto tutto" is his, not the decoder's).
/// Vero soltanto DENTRO la decodifica di un pezzo delle forbici.
///
/// Esiste per una regola sola: **il taglio del silenzio in coda non si applica a
/// un pezzo.** Quel taglio è una regola per la fine di una dettatura, dove toglie
/// il rumore di stanza su cui Whisper allucina; un pezzo invece finisce dentro
/// una pausa fra due frasi, e quella pausa è ciò che serve al decodificatore per
/// chiudere l'ultima frase. Applicare lì la regola della coda significa pagarne
/// il rischio una volta per pezzo invece di una per dettatura — misurato il
/// 2026-08-17 su `lungo-reale`: «close the window» 0/8 col taglio per pezzo,
/// 8/8 senza (referto forbici §⑪). È anche il modo di Acta, letta lo stesso
/// giorno: i suoi chunk non vengono mai rifilati in coda, e infatti quel difetto
/// non ce l'ha.
///
/// Un `@TaskLocal` e non un parametro, perché la firma della decodifica è
/// condivisa dai due motori e il punto da informare è uno solo, dentro
/// `trimSilence`. Il valore fluisce lungo l'albero dei task: la rifilatura
/// dell'intera registrazione, che avviene FUORI da questo contesto, resta viva.
enum PieceDecode {
    @TaskLocal static var inPiece = false
}

enum SegmentedDecode {
    /// Manopola di sonda: ogni pezzo decide la propria lingua, invece di
    /// ereditare quella del primo.
    ///
    /// Esiste per falsificare l'ipotesi scritta nel referto del 2026-08-17 —
    /// «le forbici cancellano la frase inglese perché il primo pezzo fissa
    /// l'italiano». L'ipotesi è sospetta prima ancora di misurarla: il banco
    /// girava con `--lang it`, quindi `settled` valeva già `forced` **prima**
    /// del primo pezzo e questa regola non ha mai deciso nulla. Con la manopola
    /// accesa la corsa a lingua forzata deve tornare **identica**, che è la
    /// forma sperimentale di quella lettura del codice.
    ///
    /// Spenta nell'app e non impostata da nessuna parte:
    /// `-forbiciLinguaPerPezzo YES` sulla riga di comando, per quel processo.
    static var probePerPieceLanguage: Bool {
        let v = UserDefaults.standard.object(forKey: "forbiciLinguaPerPezzo")
        if let b = v as? Bool { return b }
        if let n = v as? Int { return n != 0 }
        if let s = v as? String { return ["1", "true", "yes", "YES"].contains(s) }
        return false
    }

    /// - Parameter decode: the engine's ordinary single-buffer path.
    static func run(
        _ samples: [Float],
        allowedLanguages: Set<Language>,
        forced: Language?,
        engine: String,
        decode: ([Float], Set<Language>, Language?) async throws -> TranscriptionResult
    ) async throws -> TranscriptionResult {
        guard Tuning.segmentLongAudio else {
            return try await decode(samples, allowedLanguages, forced)
        }
        // The trailing silence goes BEFORE the cut, not after it, and this is
        // the difference between a repair and a new bug.
        //
        // Measured 2026-08-16 on `d-reale-77s`: cut on the raw buffer, the last
        // piece was the room tone he left after the final word, and whisper.cpp
        // — handed that on its own, with no sentence around it to anchor on —
        // invented something on every single pass («Wow, chickpea!», «Un bel
        // occhi.», «Ehi, l'hoggio.») and on one pass looped «No, no, no…» a
        // hundred and ten times. Whisper hallucinating on silence is the oldest
        // known failure in this app; what the cut did was hand it silence with
        // nothing else in the frame, which is the worst case for it.
        //
        // Trimming here costs nothing on the ordinary path — `transcribeOne`
        // trims each piece anyway and the function is idempotent — and it means
        // the last piece ends on speech.
        //
        // The trimmed buffer is used ONLY when there is really something to cut.
        // A recording that comes back as one piece is handed on exactly as it
        // arrived, because "under the threshold pays nothing" has to mean the
        // same array, not an array that happens to decode the same.
        let cut = WhisperKitTranscriber.trimSilence(samples)
        let pieces = AudioSplit.pieces(of: cut)
        guard pieces.count > 1 else {
            return try await decode(samples, allowedLanguages, forced)
        }

        Log.write("\(engine): forbici — \(pieces.count) pezzi su "
                  + String(format: "%.1fs", Float(cut.count) / AudioSplit.sampleRate)
                  + " · " + AudioSplit.describe(pieces))

        var texts: [String] = []
        var settled = forced
        let perPiece = probePerPieceLanguage
        for (index, piece) in pieces.enumerated() {
            let out = try await PieceDecode.$inPiece.withValue(true) {
                try await decode(Array(cut[piece.range]), allowedLanguages,
                                 perPiece ? forced : settled)
            }
            if settled == nil { settled = out.detectedLanguage }
            // A piece that came back in a loop is dropped, not joined.
            //
            // This is the same rule the vocabulary's second round already
            // follows, moved to where a piece can now hit it: a decode fed one
            // short stretch and nothing else has no context to fall back on, and
            // when it degenerates it does so LOUDLY — «No, no, no…» a hundred
            // and ten times on one pass of `d-reale-77s`. Keeping the rest of
            // the recording and losing that piece is strictly better than
            // pasting a loop into the middle of his text.
            let loop = RepetitionGuard.degenerated(out.text)
            // Il TESTO del pezzo, non solo la sua lunghezza (2026-08-17).
            //
            // Con i soli caratteri, la domanda «quella frase l'ha scritta il
            // pezzo, o l'ha persa la ricucitura?» non si può rispondere dopo:
            // le due cose danno lo stesso conteggio, e il referto del 17/08 ha
            // dovuto tirare a indovinare proprio lì. Costa una riga per pezzo,
            // e solo con `debugLogging` acceso.
            Log.write(String(format: "\(engine): pezzo %d/%d %.1f-%.1fs%@ → %d caratteri%@ «%@»",
                             index + 1, pieces.count,
                             Float(piece.range.lowerBound) / AudioSplit.sampleRate,
                             Float(piece.range.upperBound) / AudioSplit.sampleRate,
                             piece.overlapsNext ? " +sovrapposto" : "",
                             out.text.count,
                             out.text.isEmpty ? " *** VUOTO ***"
                                              : (loop ? " *** IN LOOP, SCARTATO ***" : ""),
                             out.text))
            if !out.text.isEmpty, !loop { texts.append(out.text) }
        }

        // La ricucitura è l'altro posto dove una parola può sparire, e finora
        // era muta: `TextSeam.join` toglie fino a cinque parole dal pezzo di
        // sinistra quando le due sponde dicono la stessa cosa. Se la somma dei
        // pezzi e il testo finale non hanno lo stesso numero di parole, la
        // differenza l'ha tolta la giunzione, e questa riga lo dice invece di
        // lasciarlo dedurre.
        let joined = TextSeam.join(texts)
        let prima = texts.reduce(0) { $0 + $1.split(whereSeparator: \.isWhitespace).count }
        let dopo = joined.split(whereSeparator: \.isWhitespace).count
        if prima != dopo {
            Log.write("\(engine): ricucitura — \(prima) parole nei pezzi, \(dopo) unite"
                      + " (\(prima - dopo) tolte alle giunzioni)")
        }
        return TranscriptionResult(text: joined,
                                   detectedLanguage: settled ?? forced)
    }
}
