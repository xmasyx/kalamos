import Testing
@testable import Kalamos

/// ISC-109 — the microphone that never re-attaches.
///
/// On 2026-08-01 a phone call took the input device and Kalamos stayed in
/// hands-free mode recording forty minutes of zeros, then recorded three more
/// silent clips after it. Only turning the permission off and on brought it
/// back — that is, only a NEW audio graph did. The app knew: it wrote "recording
/// was silent" in the log every time, and did nothing with what it knew.
///
/// Two rules, both tested here because neither can be tested through
/// `AVAudioEngine` (an input device cannot be made to vanish on demand).
struct MicWatchdogTests {

    // MARK: dead is zero, not quiet

    /// The distinction the whole fix rests on. A quiet room is not a dead mic:
    /// mistaking one for the other would rebuild the graph all day.
    @Test func aQuietRoomIsNotDead() {
        let roomTone = (0..<16_000).map { _ in Float.random(in: -0.0008...0.0008) }
        #expect(!AudioRecorder.isDead(roomTone))
    }

    @Test func digitalZeroIsDead() {
        #expect(AudioRecorder.isDead([Float](repeating: 0, count: 16_000)))
    }

    /// One audible sample anywhere is enough to say the device was alive.
    @Test func oneRealSampleIsEnough() {
        var s = [Float](repeating: 0, count: 16_000)
        s[9_000] = 0.4
        #expect(!AudioRecorder.isDead(s))
    }

    /// A gesture that recorded nothing at all is a fumbled gesture, not a dead
    /// device — counting it would rebuild the graph after two stray taps.
    @Test func nothingRecordedIsNotDead() {
        #expect(!AudioRecorder.isDead([]))
    }

    // MARK: two in a row, then rebuild

    @Test func oneDeadRecordingIsNotEnough() {
        var w = MicWatchdog()
        w.record(dead: true)
        #expect(!w.needsRebuild)
    }

    @Test func twoInARowAsksForARebuild() {
        var w = MicWatchdog()
        w.record(dead: true)
        w.record(dead: true)
        #expect(w.needsRebuild)
    }

    /// "In a row" means in a row: a good recording clears the count.
    @Test func aGoodRecordingResetsTheCount() {
        var w = MicWatchdog()
        w.record(dead: true)
        w.record(dead: false)
        w.record(dead: true)
        #expect(!w.needsRebuild)
    }

    /// And it must not ask twice for the same rebuild, or every later start
    /// would throw away a working graph.
    @Test func rebuildingClearsTheDemand() {
        var w = MicWatchdog()
        w.record(dead: true); w.record(dead: true)
        #expect(w.needsRebuild)
        w.rebuilt()
        #expect(!w.needsRebuild)
    }

    /// The forty-minute case: it stays asking until somebody rebuilds.
    @Test func itKeepsAskingUntilTheGraphIsReplaced() {
        var w = MicWatchdog()
        for _ in 0..<5 { w.record(dead: true) }
        #expect(w.needsRebuild)
    }
}

/// ISC-109b — the microphone is asked half a second after the key, not at the end.
///
/// The user's own design, and the better one: `engine.start()` succeeding does not
/// mean the input device is ours. The first fix noticed a dead microphone when
/// the recording ENDED, which still meant listening to nothing for as long as the
/// gesture lasted — forty minutes, the day it happened.
///
/// The window is 0.6 s, and that number is why one of these cases matters more
/// than it looks: somebody who presses the key and starts speaking a second later
/// must NOT be cut off. What is in the buffer at that moment is room tone, and
/// room tone is not zero.
struct MicStartupProbeTests {

    @Test func roomToneMeansTheMicrophoneCameUp() {
        let tone = (0..<9_600).map { _ in Float.random(in: -0.0009...0.0009) }
        #expect(AudioRecorder.health(of: tone) == .alive)
    }

    /// The case the probe exists for: buffers arriving, every sample zero.
    @Test func zeroSamplesMeanTheTapIsAttachedToNothing() {
        #expect(AudioRecorder.health(of: [Float](repeating: 0, count: 9_600)) == .silentTap)
    }

    /// A working graph delivers a buffer every ~64 ms, so nothing at all after
    /// 600 ms means the tap never started.
    @Test func noBuffersAtAllIsItsOwnDiagnosis() {
        #expect(AudioRecorder.health(of: []) == .noBuffers)
    }

    /// Someone who has not started speaking yet is still alive: a single audible
    /// sample anywhere in the window is enough.
    @Test func aSilentSpeakerIsNotADeadMicrophone() {
        var s = [Float](repeating: 0, count: 9_600)
        s[42] = 0.002
        #expect(AudioRecorder.health(of: s) == .alive)
    }

    /// And one dead start asks for a new graph outright, without waiting for a
    /// second one — we have already watched the tap deliver zeros.
    @Test func oneDeadStartIsEnoughToDemandARebuild() {
        var w = MicWatchdog()
        w.demandRebuild()
        #expect(w.needsRebuild)
    }
}

/// ISC-107 — the guard that keeps a closed claim closed.
///
/// The footprint watch writes nothing while things are well, which is the point
/// and also the danger: a branch that never runs looks exactly like a branch
/// that cannot run. A full day of real use ran at 4 GB with the memory set to
/// never free, and that is what closed the claim; this is what would notice if
/// the buffer-cache ceiling ever vanished in a refactor.
struct FootprintWatchTests {

    /// The ordinary day. Four gigabytes is what he measured, and it must be
    /// silent.
    @Test func aNormalFootprintSaysNothing() {
        #expect(!Footprint.shouldReport(mb: 4_236, lastReported: 0))
        #expect(!Footprint.shouldReport(mb: 6_000, lastReported: 0))
    }

    /// And the regression the ceiling exists to prevent — 13 GB was the number
    /// before it — must not be silent.
    @Test func crossingTheCeilingIsReported() {
        #expect(Footprint.shouldReport(mb: 7_200, lastReported: 0))
        #expect(Footprint.shouldReport(mb: 13_000, lastReported: 0))
    }

    /// Exactly at the ceiling counts as over it.
    @Test func theCeilingItselfIsOverTheCeiling() {
        #expect(Footprint.shouldReport(mb: Footprint.ceilingMB, lastReported: 0))
    }

    /// **Il massimo di vita si legge davvero, ed è per definizione almeno quanto l'istantaneo.**
    ///
    /// La lettura passa da `proc_pid_rusage` con un rebind di memoria: sbagliarlo non produce un
    /// errore di compilazione, produce un `nil` oppure un numero senza senso. Questo test è ciò che
    /// distingue le due cose. E l'invariante *picco ≥ adesso* è la ragione per cui la guardia è
    /// stata spostata sul picco: il 2026-08-07 l'istantaneo diceva 6521 MB e il picco 7315, cioè
    /// sopra il tetto, e il valore del momento non poteva accorgersene.
    @Test func thePeakIsReadAndIsNeverBelowTheCurrentReading() throws {
        let peak = try #require(Footprint.peakMegabytes)
        let now = try #require(Footprint.megabytes)
        #expect(peak > 0)
        #expect(peak >= now)
    }

    /// Once said, it stays quiet until another gigabyte — a bad day writes a
    /// short series, not a thousand identical lines.
    @Test func itDoesNotRepeatItself() {
        #expect(!Footprint.shouldReport(mb: 7_300, lastReported: 7_200))
        #expect(Footprint.shouldReport(mb: 8_300, lastReported: 7_200))
    }
}
