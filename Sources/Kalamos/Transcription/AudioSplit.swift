import Foundation

/// Cutting a long recording into pieces that each fit inside one encoder window.
///
/// Whisper's encoder takes exactly 30 seconds — the weights are that shape. Above
/// that, both Whisper engines walk the recording with a seek loop, and the seam
/// between two windows is where this project has watched sentences disappear with
/// no error and no log line: the same 82-second file decoded eight times gave
/// between 142 and 170 words on 2026-08-04, and a bilingual recording loses the
/// English sentence and the Italian that follows it.
///
/// The recipe is Meetily's (`frontend/src-tauri/src/audio/common.rs`,
/// `split_segment_at_silence`), read in its sources on 2026-08-16 and kept close
/// on purpose: pieces never longer than 25 s so five seconds of margin stay under
/// the window, the cut placed at the quietest 100 ms found within ±3 s of the
/// target, and — when nothing quiet is there to cut on — a cut with one second of
/// overlap, so a word straddling the edge is transcribed whole on both sides
/// rather than halved on each.
///
/// **Two deliberate departures from their code, both written down rather than
/// silent.**
///
/// The first is the overlap itself. Meetily's doc comment promises "a 1-second
/// overlap split"; their loop then does `pos = chunk_end`, which advances past
/// the extra second and makes it a cut one second later, not an overlap. We
/// implement the comment, because the overlap is only useful if the word really
/// does appear on both sides, and because we have somewhere to put the cost:
/// `TextSeam.join` removes the duplicate at the seam and has been doing it for
/// the coverage repair since 2026-08-12.
///
/// The second is `shortestTail`. Meetily feeds this function VAD speech segments,
/// already bounded by where somebody stopped talking; we feed it whole raw
/// recordings, so a 29-second dictation would come out as 25 s plus a 4-second
/// crumb and a 26-second one as a 1-second crumb. A piece that short is a piece
/// Whisper invents an ending for, so a short tail is folded back into the piece
/// before it whenever the two still fit under the ceiling.
///
/// Nothing here decides WHETHER to cut — `Tuning.segmentLongAudio` does, and it
/// is off by default. This type only answers where.
enum AudioSplit {
    static let sampleRate: Float = 16_000

    /// Recordings at or under this are handed over whole, and that is the point
    /// of the number: about nine dictations in ten are shorter than this, and
    /// they must take the path they took yesterday, byte for byte.
    static let thresholdSeconds: Float = 28
    /// Meetily's 25 s — five seconds of margin under the encoder window.
    static let maximumSeconds: Float = 25
    /// How far either side of the target we look for somewhere quiet to cut.
    static let searchRadiusSeconds: Float = 3
    /// RMS is measured over 100 ms, stepped by 10 ms.
    static let energyWindowSeconds: Float = 0.1
    static let hopSeconds: Float = 0.01
    /// Below this RMS a window counts as somewhere we can cut cleanly.
    static let silenceRMS: Float = 0.02
    /// Carried into the next piece when there was no quiet place to cut.
    static let overlapSeconds: Float = 1
    /// No piece may exceed this. 25 + 3 of search + 1 of overlap is 29, which is
    /// under the window with half a second to spare; the clamp exists so that
    /// arithmetic stays true if somebody moves one of the numbers above.
    static let hardCeilingSeconds: Float = 29
    /// A final piece shorter than this is folded back into its predecessor.
    static let shortestTailSeconds: Float = 3

    // MARK: - Manopole di sonda (misura, non comportamento)
    //
    // Tre numeri di questa geometria si possono muovere da riga di comando, e
    // servono a una domanda sola: **è il posto del taglio a danneggiare una
    // frase, o è il contesto che manca al pezzo?** Le due ipotesi si separano
    // spostando il taglio senza cambiare nient'altro — se una frase rovinata
    // guarisce quando il confine si muove, il colpevole è il confine.
    //
    // Nessuna di queste chiavi è impostata nell'app, e con tutte e tre assenti
    // questo tipo si comporta byte per byte come prima (il polo negativo è in
    // `AudioSplitTests`). Sulla riga di comando finiscono in `NSArgumentDomain`
    // e muoiono col processo:
    //   -forbiciPezzoSecondi 20 -forbiciSovrapposizioneSecondi 3 -forbiciTettoSecondi 29
    //
    // Il valore arriva come **String** da riga di comando e come numero dai
    // defaults: leggerlo con un solo `as?` è la trappola che `Tuning` documenta
    // dal 2026-08-01, e una sonda che legge il default mentre crede di leggere
    // il valore iniettato misura la cosa sbagliata e lo dice con sicurezza.
    private static func probe(_ key: String) -> Float? {
        let value = UserDefaults.standard.object(forKey: key)
        if let n = value as? Double { return Float(n) }
        if let n = value as? Int { return Float(n) }
        if let s = value as? String, let n = Float(s) { return n }
        return nil
    }

    static var probeMaximumSeconds: Float? { probe("forbiciPezzoSecondi") }
    static var probeOverlapSeconds: Float? { probe("forbiciSovrapposizioneSecondi") }
    /// Il tetto si muove insieme alla lunghezza, altrimenti pezzi più lunghi
    /// vengono tagliati dal `min` invece che dalla geometria, e l'esperimento
    /// misurerebbe la clamp.
    static var probeCeilingSeconds: Float? { probe("forbiciTettoSecondi") }

    /// One piece of a recording, in samples.
    struct Piece: Equatable {
        var range: Range<Int>
        /// True when the cut that ends this piece had no silence to land on, so
        /// the piece carries a second of what the next one also carries.
        var overlapsNext: Bool

        var count: Int { range.count }
    }

    /// Where to cut, or a single piece when there is nothing to gain.
    ///
    /// Returns exactly one piece spanning the whole buffer whenever the recording
    /// is at or under `thresholdSeconds`, which is what lets the caller treat
    /// "one piece" and "do not touch this" as the same case.
    static func pieces(of count: Int,
                       rms: (Int, Int) -> Float,
                       maximumSeconds: Float = maximumSeconds,
                       thresholdSeconds: Float = thresholdSeconds,
                       overlapSeconds: Float = overlapSeconds,
                       ceilingSeconds: Float = hardCeilingSeconds) -> [Piece] {
        let whole = [Piece(range: 0 ..< max(0, count), overlapsNext: false)]
        guard count > 0 else { return [] }
        guard Float(count) / sampleRate > thresholdSeconds else { return whole }

        let maximum = Int(maximumSeconds * sampleRate)
        let radius = Int(searchRadiusSeconds * sampleRate)
        let window = Int(energyWindowSeconds * sampleRate)
        let hop = max(1, Int(hopSeconds * sampleRate))
        let overlap = Int(overlapSeconds * sampleRate)
        let ceiling = Int(ceilingSeconds * sampleRate)
        guard maximum > 0, window > 0 else { return whole }

        var pieces: [Piece] = []
        var position = 0

        while position < count {
            if count - position <= maximum {
                pieces.append(Piece(range: position ..< count, overlapsNext: false))
                break
            }

            let target = position + maximum
            // Never look for a cut inside the first second of a piece: a piece
            // that short is worse than a cut in the wrong place.
            let searchStart = max(target - radius, position + Int(sampleRate))
            let searchEnd = min(target + radius, count - window)

            var bestCut = min(target, count)
            var bestRMS = Float.greatestFiniteMagnitude
            if searchStart + window <= searchEnd {
                var index = searchStart
                while index + window <= searchEnd {
                    let energy = rms(index, window)
                    if energy < bestRMS {
                        bestRMS = energy
                        bestCut = index + window / 2   // cut through the middle of the quiet
                    }
                    index += hop
                }
            }

            let quiet = bestRMS <= silenceRMS
            let end = quiet ? bestCut : min(bestCut + overlap, count)
            // The clamp is belt and braces: with the constants above it never
            // binds, and if somebody widens the search it stops a piece from
            // quietly growing past the encoder window.
            let clamped = min(end, position + ceiling)
            // Progress is guaranteed by `searchStart`, but a caller passing odd
            // constants should get a wrong answer, not a hang.
            guard clamped > position else {
                pieces.append(Piece(range: position ..< count, overlapsNext: false))
                break
            }
            pieces.append(Piece(range: position ..< clamped, overlapsNext: !quiet))
            position = quiet ? clamped : min(bestCut, clamped)
        }

        return foldingShortTail(pieces, ceiling: ceiling)
    }

    /// Convenience over a real buffer.
    ///
    /// Questo è il solo punto in cui le manopole di sonda entrano nel percorso
    /// vero: la funzione pura sopra resta governata dai suoi parametri, così un
    /// test non deve toccare i defaults del processo per misurare una geometria.
    static func pieces(of samples: [Float]) -> [Piece] {
        pieces(of: samples.count,
               rms: { start, window in
                   var energy: Float = 0
                   for i in start ..< (start + window) { energy += samples[i] * samples[i] }
                   return (energy / Float(window)).squareRoot()
               },
               maximumSeconds: probeMaximumSeconds ?? maximumSeconds,
               thresholdSeconds: thresholdSeconds,
               overlapSeconds: probeOverlapSeconds ?? overlapSeconds,
               ceilingSeconds: probeCeilingSeconds ?? hardCeilingSeconds)
    }

    /// Il centro della finestra da 100 ms più quieta fra due istanti, in secondi.
    ///
    /// Serve alla riparazione ISC-174 per spostare gli estremi di un riascolto
    /// dentro una pausa. Misurato il 2026-08-17 sulla clip del crollo
    /// (`20260812-225206`): il tratto 25,7-55,7 s — estremi scelti dal ciclo di
    /// ricerca di WhisperKit, cioè in mezzo al parlato — tornava vuoto 6 volte su
    /// 8 a qualunque lunghezza; lo stesso tratto con gli estremi nel quieto
    /// (24,05 e 54,20 s, trovati esattamente con questa ricerca) ha dato zero
    /// vuoti su 8 a tre lunghezze diverse, compresa una sopra la finestra
    /// dell'encoder. Referto forbici §⑪.
    ///
    /// Ritorna `nil` quando l'intervallo non contiene una finestra intera: il
    /// chiamante tiene l'estremo che aveva, che è il comportamento di prima.
    static func quietestPoint(in samples: [Float],
                              betweenSeconds from: Float,
                              and to: Float) -> Float? {
        let window = Int(energyWindowSeconds * sampleRate)
        let hop = max(1, Int(hopSeconds * sampleRate))
        let start = max(0, Int(from * sampleRate))
        let end = min(samples.count, Int(to * sampleRate))
        guard start + window <= end else { return nil }

        var best = start
        var bestRMS = Float.greatestFiniteMagnitude
        var index = start
        while index + window <= end {
            var energy: Float = 0
            for i in index ..< (index + window) { energy += samples[i] * samples[i] }
            let rms = (energy / Float(window)).squareRoot()
            if rms < bestRMS {
                bestRMS = rms
                best = index
            }
            index += hop
        }
        return (Float(best) + Float(window) / 2) / sampleRate
    }

    /// The last piece, when it is a crumb, joined to the one before it.
    private static func foldingShortTail(_ pieces: [Piece], ceiling: Int) -> [Piece] {
        guard pieces.count > 1, let last = pieces.last else { return pieces }
        guard Float(last.count) / sampleRate < shortestTailSeconds else { return pieces }
        let previous = pieces[pieces.count - 2]
        let merged = previous.range.lowerBound ..< last.range.upperBound
        guard merged.count <= ceiling else { return pieces }
        var out = pieces.dropLast(2).map { $0 }
        out.append(Piece(range: merged, overlapsNext: false))
        return out
    }

    /// A one-line description for the log, so a dictation that went wrong can be
    /// read back afterwards instead of guessed at.
    static func describe(_ pieces: [Piece]) -> String {
        pieces.map {
            String(format: "%.1f-%.1f%@",
                   Float($0.range.lowerBound) / sampleRate,
                   Float($0.range.upperBound) / sampleRate,
                   $0.overlapsNext ? "+" : "")
        }.joined(separator: " ")
    }
}
