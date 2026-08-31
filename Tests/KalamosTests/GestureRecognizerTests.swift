import Testing
@testable import Kalamos

/// Tests for the hold vs. double-tap-toggle gesture state machine (ISC-17).
@Suite struct GestureRecognizerTests {

    private func makeRecorder() -> (GestureRecognizer, @Sendable () -> [DictationAction]) {
        final class Box: @unchecked Sendable { var actions: [DictationAction] = [] }
        let box = Box()
        let g = GestureRecognizer(holdThreshold: 0.25, doubleTapWindow: 0.30)
        g.onAction = { box.actions.append($0) }
        return (g, { box.actions })
    }

    /// HOLD: press and keep down past the threshold, then release → process.
    @Test func holdRecordsAndProcesses() {
        let (g, actions) = makeRecorder()
        g.keyDown(at: 0.0)
        g.keyUp(at: 0.50)   // held 500ms ≥ 250ms
        #expect(actions() == [.beginRecording, .endRecordingAndProcess])
        #expect(g.state == .idle)
    }

    /// DOUBLE-TAP: two quick taps start hands-free; a later tap stops + processes.
    @Test func doubleTapTogglesThenSingleTapStops() {
        let (g, actions) = makeRecorder()
        g.keyDown(at: 0.00)         // begin (tap 1)
        g.keyUp(at: 0.08)           // short → cancel, await 2nd
        g.keyDown(at: 0.18)         // within window → toggle on, begin fresh
        #expect(g.state == .toggleListening)

        g.keyDown(at: 3.00)         // single tap while hands-free → stop
        #expect(actions() ==
            [.beginRecording, .cancelRecording, .beginRecording, .endRecordingAndProcess])
        #expect(g.state == .idle)
    }

    /// A lone short tap (no 2nd tap) must NOT leave a dangling recording.
    @Test func loneShortTapSettlesToIdle() {
        let (g, actions) = makeRecorder()
        g.keyDown(at: 0.00)
        g.keyUp(at: 0.08)           // short tap → cancel + await
        g.tick(at: 0.50)            // window lapsed, no 2nd tap
        #expect(actions() == [.beginRecording, .cancelRecording])
        #expect(g.state == .idle)
    }

    // MARK: Escape cancels a dictation in flight (any mode).

    /// Hands-free is the state that needed this: without it, the only way out of
    /// a dictation you changed your mind about was to let it transcribe.
    @Test func escapeCancelsHandsFree() {
        let (g, actions) = makeRecorder()
        g.keyDown(at: 0.00); g.keyUp(at: 0.08); g.keyDown(at: 0.18)   // → hands-free
        #expect(g.state == .toggleListening)

        #expect(g.cancel() == true)
        #expect(actions().last == .cancelRecording)
        #expect(g.state == .idle)
    }

    /// While holding: cancel, and the eventual key-up must NOT then process the
    /// recording we just threw away.
    @Test func escapeCancelsHoldAndKeyUpDoesNotProcess() {
        let (g, actions) = makeRecorder()
        g.keyDown(at: 0.00)
        #expect(g.cancel() == true)
        g.keyUp(at: 0.90)   // released long after — must stay silent
        #expect(actions() == [.beginRecording, .cancelRecording])
        #expect(g.state == .idle)
    }

    /// Nothing recording → Escape is not ours, and must reach the app underneath.
    @Test func escapeWhenIdleIsNotConsumed() {
        let (g, actions) = makeRecorder()
        #expect(g.cancel() == false)
        #expect(actions().isEmpty)
        #expect(g.state == .idle)
    }

    /// Cancelling twice must not emit a second discard.
    @Test func escapeIsIdempotent() {
        let (g, actions) = makeRecorder()
        g.keyDown(at: 0.00); g.keyUp(at: 0.08); g.keyDown(at: 0.18)   // → hands-free
        #expect(g.cancel() == true)
        #expect(g.cancel() == false)
        #expect(actions().filter { $0 == .cancelRecording }.count == 2)  // 1 from the tap, 1 from cancel
    }

    // MARK: Push-to-talk OFF — only double-tap arms hands-free; a lone press or
    // hold does NOTHING (so the trigger key stays usable for its OS role).

    private func makeRecorderPTTOff() -> (GestureRecognizer, @Sendable () -> [DictationAction]) {
        final class Box: @unchecked Sendable { var actions: [DictationAction] = [] }
        let box = Box()
        let g = GestureRecognizer(holdThreshold: 0.25, doubleTapWindow: 0.30, mode: .doubleTap)
        g.onAction = { box.actions.append($0) }
        return (g, { box.actions })
    }

    /// PTT off: a full hold emits NOTHING — no flicker, no recording.
    @Test func pttOff_holdDoesNothing() {
        let (g, actions) = makeRecorderPTTOff()
        g.keyDown(at: 0.00)
        g.keyUp(at: 0.50)           // held past threshold
        #expect(actions() == [])
        #expect(g.state == .idle)
    }

    /// PTT off: a lone short tap emits NOTHING and settles to idle.
    @Test func pttOff_loneTapDoesNothing() {
        let (g, actions) = makeRecorderPTTOff()
        g.keyDown(at: 0.00)
        g.keyUp(at: 0.08)           // short tap → await, but nothing recorded
        g.tick(at: 0.50)
        #expect(actions() == [])
        #expect(g.state == .idle)
    }

    /// PTT off: a double-tap DOES arm hands-free; a later tap stops + processes.
    @Test func pttOff_doubleTapTogglesThenStops() {
        let (g, actions) = makeRecorderPTTOff()
        g.keyDown(at: 0.00)         // tap 1 — no recording
        g.keyUp(at: 0.08)
        g.keyDown(at: 0.18)         // tap 2 within window → toggle on, begin
        #expect(g.state == .toggleListening)
        g.keyDown(at: 3.00)         // tap → stop + process
        #expect(actions() == [.beginRecording, .endRecordingAndProcess])
        #expect(g.state == .idle)
    }

    /// PTT off: abort() during a hold never emits cancel (nothing was recording).
    @Test func pttOff_abortDuringHoldIsSilent() {
        let (g, actions) = makeRecorderPTTOff()
        g.keyDown(at: 0.00)
        g.abort()                   // another key pressed while trigger held
        #expect(actions() == [])
        #expect(g.state == .holdingAborted)
        g.keyUp(at: 0.10)
        #expect(g.state == .idle)
    }

    /// Flipping push-to-talk off mid-hold discards the in-flight recording and
    /// settles to idle.
    @Test func setMode_resetsInFlightGesture() {
        let (g, actions) = makeRecorder()   // starts ON
        g.keyDown(at: 0.00)                 // begins recording (PTT on)
        #expect(actions() == [.beginRecording])
        g.setMode(.doubleTap)               // flip mode → discard
        #expect(actions() == [.beginRecording, .cancelRecording])
        #expect(g.state == .idle)
        #expect(g.mode == .doubleTap)
    }
}

/// The third mode, added because setup needed to offer three honest choices and
/// the old boolean could only express two. "Hold only" is for a trigger key that
/// has a day job: a tap must do nothing at all, and no stray double-tap may leave
/// the microphone open behind your back.
@Suite struct HoldOnlyModeTests {

    private func make() -> (GestureRecognizer, @Sendable () -> [DictationAction]) {
        final class Box: @unchecked Sendable { var actions: [DictationAction] = [] }
        let box = Box()
        let g = GestureRecognizer(holdThreshold: 0.25, doubleTapWindow: 0.30, mode: .hold)
        g.onAction = { box.actions.append($0) }
        return (g, { box.actions })
    }

    @Test func holdStillRecords() {
        let (g, actions) = make()
        g.keyDown(at: 0.0)
        g.keyUp(at: 0.50)
        #expect(actions() == [.beginRecording, .endRecordingAndProcess])
    }

    /// The point of the mode: two quick taps must NOT arm hands-free.
    @Test func doubleTapDoesNotArmHandsFree() {
        let (g, actions) = make()
        g.keyDown(at: 0.00); g.keyUp(at: 0.08)   // tap 1
        g.keyDown(at: 0.18); g.keyUp(at: 0.24)   // tap 2, well inside the window
        #expect(g.state == .idle)
        #expect(!actions().contains(.endRecordingAndProcess))
        #expect(actions().filter { $0 == .beginRecording }.count == 2)   // two aborted taps
        #expect(actions().filter { $0 == .cancelRecording }.count == 2)  // both discarded
    }

    /// A lone short tap settles immediately instead of leaving a window open for a
    /// gesture this mode does not have.
    @Test func shortTapSettlesWithoutWaiting() {
        let (g, _) = make()
        g.keyDown(at: 0.00); g.keyUp(at: 0.08)
        #expect(g.state == .idle)
    }
}

/// Typing while a hands-free dictation is running must not stop it.
///
/// Requested on 2026-07-31 after watching a competitor cut the recording the
/// moment a key was touched. Kalamos already behaved this way — `abort()` acts
/// only while the trigger is physically HELD, where another key genuinely is a
/// shortcut — but "already true" is not a guarantee until something fails when
/// it stops being true.
@Suite struct TypingDuringHandsFreeTests {

    private func handsFreeRecorder() -> (GestureRecognizer, @Sendable () -> [DictationAction]) {
        final class Box: @unchecked Sendable { var actions: [DictationAction] = [] }
        let box = Box()
        let g = GestureRecognizer(holdThreshold: 0.25, doubleTapWindow: 0.30)
        g.onAction = { box.actions.append($0) }
        return (g, { box.actions })
    }

    @Test func typingDoesNotCancelAHandsFreeDictation() {
        let (g, actions) = handsFreeRecorder()
        // Double-tap → hands-free listening. The first short tap is itself a
        // tiny hold that gets cancelled when the second tap arrives, so the
        // history ALREADY contains a cancel by now: counting cancels over the
        // whole run would fail on the gesture rather than on the typing. Only
        // what happens AFTER listening starts is the question.
        g.keyDown(at: 0.0); g.keyUp(at: 0.05)
        g.keyDown(at: 0.20); g.keyUp(at: 0.25)
        #expect(actions().last == .beginRecording)
        let beforeTyping = actions().count

        // Now type a whole sentence while it listens.
        for _ in 0 ..< 40 { g.abort() }

        #expect(actions().count == beforeTyping, "typing stopped a hands-free dictation")

        // And it still ends the way it should: one tap, one transcription.
        g.keyDown(at: 5.0); g.keyUp(at: 5.05)
        #expect(actions().last == .endRecordingAndProcess)
    }

    /// The opposite case, and it must stay: while the key is HELD, another key
    /// is ⌘S or a capital letter — not speech.
    @Test func typingDuringAHoldStillAborts() {
        let (g, actions) = handsFreeRecorder()
        g.keyDown(at: 0.0)
        g.abort()                      // ⌘-something
        g.keyUp(at: 0.60)
        #expect(actions().contains(.cancelRecording))
        #expect(!actions().contains(.endRecordingAndProcess))
    }
}

/// One tap starts, one tap finishes (asked 2026-07-31).
@Suite struct SingleTapModeTests {

    private func recorder() -> (GestureRecognizer, @Sendable () -> [DictationAction]) {
        final class Box: @unchecked Sendable { var actions: [DictationAction] = [] }
        let box = Box()
        let g = GestureRecognizer(holdThreshold: 0.25, doubleTapWindow: 0.30, mode: .singleTap)
        g.onAction = { box.actions.append($0) }
        return (g, { box.actions })
    }

    /// Dal 31/08 il microfono non si apre più sulla risalita, ma alla scadenza della
    /// finestra di grazia: al momento del rilascio «⌥ da solo» e «⌥ò scritto un attimo
    /// storto» sono lo stesso evento, e decidere lì dentro era il difetto. I due poli
    /// stanno in `OptionPiuLetteraNonDetta`.
    @Test func oneTapStartsAndTheNextOneFinishes() {
        let (g, actions) = recorder()
        g.keyDown(at: 0.0); g.keyUp(at: 0.05)
        #expect(actions().isEmpty, "il microfono non si apre prima della grazia")
        g.tick(at: 0.05 + g.singleTapGrace + 0.01)
        #expect(actions() == [.beginRecording])
        g.keyDown(at: 3.0); g.keyUp(at: 3.05)
        #expect(actions() == [.beginRecording, .endRecordingAndProcess])
    }

    /// Holding the key is how you use Option as a modifier. It must do nothing.
    @Test func holdingDoesNothing() {
        let (g, actions) = recorder()
        g.keyDown(at: 0.0); g.keyUp(at: 1.20)
        #expect(actions().isEmpty)
    }

    /// ⌥-click: the click arrives while the key is down, and it cancels the
    /// gesture — otherwise releasing the key would start dictating.
    @Test func aClickWhileHeldCancelsTheGesture() {
        let (g, actions) = recorder()
        g.keyDown(at: 0.0)
        g.abort()                       // the mouse press
        g.keyUp(at: 0.10)               // released quickly, as in a real ⌥-click
        #expect(actions().isEmpty, "⌥-click started a dictation")
    }

    /// A shortcut typed with the modifier held, same reasoning.
    @Test func anotherKeyWhileHeldCancelsTheGesture() {
        let (g, actions) = recorder()
        g.keyDown(at: 0.0)
        g.abort()
        g.keyUp(at: 0.08)
        #expect(actions().isEmpty)
    }
}
