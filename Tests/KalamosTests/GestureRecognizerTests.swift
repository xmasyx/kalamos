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

    // MARK: Push-to-talk OFF — only double-tap arms hands-free; a lone press or
    // hold does NOTHING (so the trigger key stays usable for its OS role).

    private func makeRecorderPTTOff() -> (GestureRecognizer, @Sendable () -> [DictationAction]) {
        final class Box: @unchecked Sendable { var actions: [DictationAction] = [] }
        let box = Box()
        let g = GestureRecognizer(holdThreshold: 0.25, doubleTapWindow: 0.30, pushToTalkEnabled: false)
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
    @Test func setPushToTalk_resetsInFlightGesture() {
        let (g, actions) = makeRecorder()   // starts ON
        g.keyDown(at: 0.00)                 // begins recording (PTT on)
        #expect(actions() == [.beginRecording])
        g.setPushToTalk(false)              // flip off → discard
        #expect(actions() == [.beginRecording, .cancelRecording])
        #expect(g.state == .idle)
        #expect(g.pushToTalkEnabled == false)
    }
}
