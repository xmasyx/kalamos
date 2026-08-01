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
