import Foundation
import Testing
@testable import Kalamos

/// Where a long recording gets cut.
///
/// Every property here has two poles, because this project has paid for the
/// lesson twice: a probe that only shows the good case cannot tell "it works"
/// apart from "it never ran". So each test that asserts the cut lands somewhere
/// also asserts that it does NOT land there when the audio says otherwise.
@Suite struct AudioSplitTests {
    private static let rate = Int(AudioSplit.sampleRate)

    /// Loud audio with quiet gaps at the given seconds (each `hole` long).
    private func speech(seconds: Float,
                               pausesAt: [Float] = [],
                               pause: Float = 0.6,
                               level: Float = 0.2) -> [Float] {
        var s = [Float](repeating: 0, count: Int(seconds * AudioSplit.sampleRate))
        // A square-ish wave rather than a constant: RMS of a constant is the
        // constant, which would make the energy measurement look right for the
        // wrong reason.
        for i in s.indices { s[i] = (i % 2 == 0) ? level : -level }
        for start in pausesAt {
            let from = Int(start * AudioSplit.sampleRate)
            let to = min(s.count, from + Int(pause * AudioSplit.sampleRate))
            guard from < to else { continue }
            for i in from ..< to { s[i] = 0 }
        }
        return s
    }

    private func seconds(_ piece: AudioSplit.Piece) -> (Float, Float) {
        (Float(piece.range.lowerBound) / AudioSplit.sampleRate,
         Float(piece.range.upperBound) / AudioSplit.sampleRate)
    }

    // MARK: - The short path is not a path

    @Test func aShortRecordingIsOnePieceCoveringEverything() {
        let s = speech(seconds: 12)
        let pieces = AudioSplit.pieces(of: s)
        #expect(pieces.count == 1)
        #expect(pieces[0].range == 0 ..< s.count)
    }

    /// The negative pole of the line above: the threshold is a threshold, not a
    /// decoration. 27.9 s stays whole, 40 s does not.
    @Test func theThresholdIsWhereItSaysItIs() {
        #expect(AudioSplit.pieces(of: speech(seconds: 27.9)).count == 1)
        #expect(AudioSplit.pieces(of: speech(seconds: 40)).count > 1)
    }

    // MARK: - The quietest place wins

    @Test func theCutLandsInTheSilence() {
        // A pause at 23.5 s, inside the ±3 s search around the 25 s target.
        let pieces = AudioSplit.pieces(of: speech(seconds: 45, pausesAt: [23.5]))
        #expect(pieces.count == 2)
        let (_, end) = seconds(pieces[0])
        // Cut through the middle of the quiet 600 ms, so ~23.5–24.1.
        #expect(end > 23.4 && end < 24.2)
        #expect(pieces[0].overlapsNext == false)
        // And the second piece starts exactly where the first ended: a silent
        // cut is a cut, not an overlap.
        #expect(pieces[1].range.lowerBound == pieces[0].range.upperBound)
    }

    /// The negative pole: a pause OUTSIDE the ±3 s window is not chosen, however
    /// quiet it is. Without this, "the cut landed at a pause" could just mean
    /// "the cut landed where it always lands and there happened to be a pause".
    @Test func aPauseOutOfReachIsNotChosen() {
        // Quiet at 10 s only — nowhere near the 22–28 s search band.
        let pieces = AudioSplit.pieces(of: speech(seconds: 45, pausesAt: [10]))
        let (_, end) = seconds(pieces[0])
        #expect(end > 20)
        #expect(pieces[0].overlapsNext == true)   // nothing quiet was found
    }

    @Test func theQUIETESTOfSeveralWins() {
        // Two candidates in the band; the one at 26 s is a real hole, the one at
        // 23 s is only half as quiet.
        var s = speech(seconds: 45)
        for i in Int(23 * Float(Self.rate)) ..< Int(23.4 * Float(Self.rate)) {
            s[i] = (i % 2 == 0) ? 0.05 : -0.05
        }
        for i in Int(26 * Float(Self.rate)) ..< Int(26.4 * Float(Self.rate)) { s[i] = 0 }
        let pieces = AudioSplit.pieces(of: s)
        let (_, end) = seconds(pieces[0])
        #expect(end > 25.9 && end < 26.5)
    }

    // MARK: - The overlap, and only when it is needed

    @Test func theOverlapAppearsOnlyWithoutSilence() {
        // No pause anywhere: every cut has to carry its second.
        let loud = AudioSplit.pieces(of: speech(seconds: 60))
        #expect(loud.dropLast().allSatisfy { $0.overlapsNext })
        for (a, b) in zip(loud, loud.dropFirst()) {
            let shared = Float(a.range.upperBound - b.range.lowerBound) / AudioSplit.sampleRate
            #expect(shared > 0.9 && shared < 1.1)
        }

        // The negative pole, same length, with pauses where the cuts want to be.
        let paused = AudioSplit.pieces(of: speech(seconds: 60, pausesAt: [24, 48]))
        #expect(paused.allSatisfy { !$0.overlapsNext })
        for (a, b) in zip(paused, paused.dropFirst()) {
            #expect(a.range.upperBound == b.range.lowerBound)
        }
    }

    // MARK: - Invariants that hold whatever the audio is

    @Test func noPieceEverExceedsTheEncoderWindow() {
        for length in [Float(29), 31, 45, 60, 77, 82, 112, 300] {
            for pauses in [[], [24], [10, 26, 50], [23.5, 47.5, 71.5]] as [[Float]] {
                let pieces = AudioSplit.pieces(of: speech(seconds: length, pausesAt: pauses))
                for piece in pieces {
                    let secs = Float(piece.count) / AudioSplit.sampleRate
                    #expect(secs <= AudioSplit.hardCeilingSeconds,
                            "\(secs)s piece from a \(length)s recording")
                }
            }
        }
    }

    @Test func everySampleIsInSomePiece() {
        for length in [Float(31), 45, 60, 77, 112] {
            let s = speech(seconds: length, pausesAt: [23.5, 47.5, 71.5])
            let pieces = AudioSplit.pieces(of: s)
            #expect(pieces.first?.range.lowerBound == 0)
            #expect(pieces.last?.range.upperBound == s.count)
            // Contiguous or overlapping, never a hole.
            for (a, b) in zip(pieces, pieces.dropFirst()) {
                #expect(b.range.lowerBound <= a.range.upperBound)
            }
        }
    }

    @Test func aCrumbAtTheEndIsFoldedBack() {
        // 28.5 s with a pause at 26: the cut lands there and leaves 2.45 s
        // alone, and a piece that short is where Whisper invents an ending.
        // Folded back, the whole thing is 28.5 s — still under the ceiling, so
        // one piece and no cut at all.
        let pieces = AudioSplit.pieces(of: speech(seconds: 28.5, pausesAt: [26]))
        #expect(pieces.count == 1)
        #expect(pieces[0].range == 0 ..< Int(28.5 * AudioSplit.sampleRate))

        // The negative pole: a tail long enough to stand on its own keeps its
        // own piece, so the fold is a guard and not a general "join the last
        // two".
        let longer = AudioSplit.pieces(of: speech(seconds: 45, pausesAt: [23.5]))
        #expect(longer.count == 2)
        #expect(Float(longer[1].count) / AudioSplit.sampleRate > AudioSplit.shortestTailSeconds)
    }

    @Test func anEmptyBufferHasNoPieces() {
        #expect(AudioSplit.pieces(of: []).isEmpty)
    }

    // MARK: - Le manopole di sonda

    /// I due poli della geometria mobile (2026-08-17).
    ///
    /// Il polo che conta è il PRIMO: con nessuna manopola impostata — che è come
    /// gira l'app, sempre — il percorso vero deve dare esattamente i pezzi della
    /// funzione pura coi suoi valori di serie. Una manopola che cambia qualcosa
    /// quando nessuno l'ha girata sarebbe un cambiamento di comportamento
    /// travestito da strumento di misura.
    ///
    /// Il secondo polo dice che i parametri fanno quello che promettono, e serve
    /// perché fino a oggi `overlapSeconds` e il tetto erano costanti: un banco
    /// che li muove misura una geometria che nessun test aveva mai esercitato.
    ///
    /// Il cablaggio `UserDefaults` → percorso vero **non** si prova qui, e la
    /// ragione è che questi test girano in parallelo dentro un processo solo:
    /// scrivere nei defaults globali per una prova rende rumorose le altre. Lo
    /// prova il banco, che è il posto giusto — con `-forbiciPezzoSecondi 20` il
    /// registro stampa confini diversi da quelli di serie, sulla stessa clip.
    @Test func theProbeKnobsChangeNothingUntilSomebodyTurnsThem() {
        let audio = speech(seconds: 90, pausesAt: [23.5, 47.5, 71.5])
        let live = AudioSplit.pieces(of: audio)
        let plain = AudioSplit.pieces(of: audio.count, rms: { start, window in
            var energy: Float = 0
            for i in start ..< (start + window) { energy += audio[i] * audio[i] }
            return (energy / Float(window)).squareRoot()
        })
        #expect(live == plain)
        #expect(AudioSplit.probeMaximumSeconds == nil)
        #expect(AudioSplit.probeOverlapSeconds == nil)
        #expect(AudioSplit.probeCeilingSeconds == nil)
    }

    @Test func theGeometryFollowsItsParameters() {
        let audio = speech(seconds: 90)   // niente pause: ogni taglio si sovrappone
        func cut(maximum: Float, overlap: Float, ceiling: Float) -> [AudioSplit.Piece] {
            AudioSplit.pieces(of: audio.count, rms: { start, window in
                var energy: Float = 0
                for i in start ..< (start + window) { energy += audio[i] * audio[i] }
                return (energy / Float(window)).squareRoot()
            }, maximumSeconds: maximum, thresholdSeconds: AudioSplit.thresholdSeconds,
               overlapSeconds: overlap, ceilingSeconds: ceiling)
        }

        // Pezzi più corti: più pezzi, e i confini si spostano.
        let corti = cut(maximum: 20, overlap: 1, ceiling: 29)
        let serie = cut(maximum: 25, overlap: 1, ceiling: 29)
        #expect(corti.count > serie.count)
        #expect(corti.first?.range.upperBound != serie.first?.range.upperBound)

        // Più sovrapposizione: le sponde condividono più audio, e il conto è
        // esatto, non «di più».
        let largo = cut(maximum: 25, overlap: 3, ceiling: 31)
        for (a, b) in zip(largo, largo.dropFirst()) {
            let shared = Float(a.range.upperBound - b.range.lowerBound) / AudioSplit.sampleRate
            #expect(shared > 2.9 && shared < 3.1)
        }
        // ...e il polo negativo dello stesso numero: di serie è un secondo.
        for (a, b) in zip(serie, serie.dropFirst()) {
            let shared = Float(a.range.upperBound - b.range.lowerBound) / AudioSplit.sampleRate
            #expect(shared > 0.9 && shared < 1.1)
        }
    }

    // MARK: - Il punto quieto (per il riascolto di ISC-174)

    /// Due poli: la pausa piantata viene trovata al centro; senza pausa la
    /// risposta resta DENTRO l'intervallo chiesto; un intervallo troppo corto
    /// per una finestra intera risponde nil, mai un numero inventato.
    @Test func theQuietestPointLandsInThePlantedPause() {
        let s = speech(seconds: 30, pausesAt: [24.0])
        let found = AudioSplit.quietestPoint(in: s, betweenSeconds: 22, and: 26)
        #expect(found != nil)
        // La pausa è 24,0-24,6: il centro della finestra più quieta cade lì.
        #expect(found! > 24.0 && found! < 24.7, "\(found!)")

        // Polo negativo: nessuna pausa nell'intervallo — si risponde comunque
        // un punto di QUELL'intervallo, non uno fuori.
        let senza = AudioSplit.quietestPoint(in: s, betweenSeconds: 5, and: 9)
        #expect(senza != nil && senza! >= 5 && senza! <= 9)

        // E l'intervallo degenere risponde nil.
        #expect(AudioSplit.quietestPoint(in: s, betweenSeconds: 29.99, and: 30.5) == nil)
        #expect(AudioSplit.quietestPoint(in: s, betweenSeconds: -3, and: 0.05) == nil)
    }

    // MARK: - Un pezzo delle forbici non si rifila in coda

    /// I due poli del `@TaskLocal` (2026-08-17, referto forbici §⑪): dentro il
    /// contesto-pezzo `trimSilence` restituisce il buffer INTATTO — la pausa in
    /// cui il taglio è caduto serve al decodificatore per chiudere la frase —
    /// e fuori dal contesto taglia esattamente come prima. Se il polo negativo
    /// smettesse di tagliare, non starebbe più misurando niente.
    @Test func aPieceIsNeverTailTrimmed() {
        // Parlato forte con una coda di quiete lunga: fuori dal pezzo SI taglia.
        var s = speech(seconds: 10)
        let coda = Int(4 * AudioSplit.sampleRate)
        for i in (s.count - coda) ..< s.count { s[i] = 0 }

        let fuori = WhisperKitTranscriber.trimSilence(s)
        #expect(fuori.count < s.count, "fuori dal pezzo il taglio deve tagliare")

        let dentro = PieceDecode.$inPiece.withValue(true) {
            WhisperKitTranscriber.trimSilence(s)
        }
        #expect(dentro.count == s.count, "dentro un pezzo il buffer resta intatto")
    }

    // MARK: - The seam, on the text side

    /// The overlap is only affordable because the join removes it. This is the
    /// same guarantee `TextSeamTests` covers, restated here against the exact
    /// shape this feature produces: a piece ending mid-sentence and the next one
    /// starting a second earlier, so the last words are said twice.
    @Test func theOverlappedWordsAreNotSaidTwice() {
        let first = "e quindi il preventivo che abbiamo mandato ieri sera"
        let second = "mandato ieri sera è di trentacinquemila euro"
        #expect(TextSeam.join([first, second])
                == "e quindi il preventivo che abbiamo mandato ieri sera è di trentacinquemila euro")
    }
}
