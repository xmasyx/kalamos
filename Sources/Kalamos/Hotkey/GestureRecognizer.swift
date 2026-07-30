import Foundation

/// Actions the gesture recognizer asks the controller to perform.
enum DictationAction: Equatable {
    case beginRecording          // start capturing audio now
    case endRecordingAndProcess  // stop capturing, transcribe + inject
    case cancelRecording         // discard (gesture turned out to be a no-op)
}

/// Translates raw key down/up events on a single hot-key into Kalamos's two
/// gestures, with NO dependency on AppKit/CGEvent so it can be unit-tested:
///
///   • HOLD       — press and keep the key down; recording runs while held,
///                  and ends on release.
///   • DOUBLE-TAP — two quick taps start continuous ("toggle") listening;
///                  a later single tap stops it.
///
/// Disambiguation: a press shorter than `holdThreshold` is provisionally a
/// "tap". If a second tap arrives within `doubleTapWindow`, it's a double-tap
/// → toggle on. Otherwise the lone short tap is treated as a (tiny) hold that
/// already started + ended, and we cancel it (no empty transcription).
final class GestureRecognizer {
    enum State: Equatable {
        case idle
        case holding(downAt: TimeInterval)   // key currently down (could become hold or 1st tap)
        case holdingAborted                  // another key was pressed → not a dictation gesture
        case awaitingSecondTap(deadline: TimeInterval)
        case toggleListening                 // hands-free; next tap stops it
    }

    private(set) var state: State = .idle

    let holdThreshold: TimeInterval      // press >= this == real hold
    let doubleTapWindow: TimeInterval    // 2nd tap must land within this

    /// Push-to-talk. true = hold the trigger to record (+ double-tap toggles).
    /// false = ONLY a double-tap arms hands-free; a lone press/hold does
    /// nothing, so the trigger key stays usable for its normal OS role without
    /// flickering Kalamos. Live-settable via `setPushToTalk`.
    private(set) var pushToTalkEnabled: Bool

    /// Emits actions for the controller to execute.
    var onAction: ((DictationAction) -> Void)?

    init(holdThreshold: TimeInterval = 0.25, doubleTapWindow: TimeInterval = 0.30,
         pushToTalkEnabled: Bool = true) {
        self.holdThreshold = holdThreshold
        self.doubleTapWindow = doubleTapWindow
        self.pushToTalkEnabled = pushToTalkEnabled
    }

    /// Change push-to-talk at runtime. Discards any in-flight gesture and
    /// settles to idle so the new mode starts clean.
    func setPushToTalk(_ on: Bool) {
        switch state {
        case .holding where pushToTalkEnabled, .toggleListening:
            emit(.cancelRecording)   // discard whatever was recording
        default:
            break
        }
        pushToTalkEnabled = on
        state = .idle
    }

    /// Feed a key-DOWN event. `now` is a monotonic timestamp (seconds).
    func keyDown(at now: TimeInterval) {
        switch state {
        case .idle:
            // Provisional first-tap-or-hold. With push-to-talk ON we start
            // recording immediately so HOLD feels instant; with it OFF a lone
            // hold does nothing — only a double-tap (below) records.
            state = .holding(downAt: now)
            if pushToTalkEnabled { emit(.beginRecording) }

        case .awaitingSecondTap:
            // Second tap in time → double-tap → go hands-free. In PTT-on we
            // already cancelled the first (empty) tap's recording on its key-up;
            // in PTT-off nothing was recording. Either way, begin fresh now.
            state = .toggleListening
            emit(.beginRecording)

        case .toggleListening:
            // A tap while hands-free → stop and process.
            state = .idle
            emit(.endRecordingAndProcess)

        case .holding, .holdingAborted:
            // Key already down (e.g. auto-repeat); ignore.
            break
        }
    }

    /// Another (non-trigger) key was pressed while the trigger was held — this
    /// was a keyboard shortcut or capital letter, not a dictation gesture.
    /// Discard the in-flight recording (if any) and wait for the trigger release.
    func abort() {
        if case .holding = state {
            if pushToTalkEnabled { emit(.cancelRecording) }
            state = .holdingAborted
        }
    }

    /// The user pressed Escape mid-dictation: throw the audio away.
    ///
    /// Distinct from `abort()`, which only fires while the trigger is *held* and
    /// another key interrupts it. This one works from any recording state — and
    /// hands-free is the state that needed it, because until now the only way out
    /// of a dictation you had changed your mind about was to let it transcribe and
    /// then delete the text.
    ///
    /// Returns whether anything was actually cancelled, so the caller can swallow
    /// the Escape key press only when it meant "cancel" and let it through
    /// everywhere else.
    @discardableResult
    func cancel() -> Bool {
        switch state {
        case .holding where pushToTalkEnabled:
            // Wait for the trigger release rather than going straight to idle, so
            // the key-up does not read as a fresh gesture.
            state = .holdingAborted
            emit(.cancelRecording)
            return true

        case .toggleListening:
            state = .idle
            emit(.cancelRecording)
            return true

        case .idle, .holding, .holdingAborted, .awaitingSecondTap:
            return false   // nothing was recording — Escape is not ours
        }
    }

    /// Feed a key-UP event.
    func keyUp(at now: TimeInterval) {
        switch state {
        case .holding(let downAt):
            let heldFor = now - downAt
            if heldFor >= holdThreshold {
                // Genuine hold. PTT on → finish and process; PTT off → hold is a
                // no-op (nothing was recording).
                state = .idle
                if pushToTalkEnabled { emit(.endRecordingAndProcess) }
            } else {
                // Short tap → might be the 1st of a double-tap. PTT on: discard
                // the tiny recording first. Either way, wait for a second tap.
                if pushToTalkEnabled { emit(.cancelRecording) }
                state = .awaitingSecondTap(deadline: now + doubleTapWindow)
            }

        case .holdingAborted:
            state = .idle   // trigger released after an aborted (shortcut) hold

        case .idle, .awaitingSecondTap, .toggleListening:
            // key-up with no matching down we care about
            break
        }
    }

    /// Drive timers. Call periodically (or once `now >= deadline`).
    /// If the double-tap window lapses with no second tap, settle to idle.
    func tick(at now: TimeInterval) {
        if case .awaitingSecondTap(let deadline) = state, now >= deadline {
            state = .idle   // lone short tap → nothing to do (recording already cancelled)
        }
    }

    private func emit(_ a: DictationAction) { onAction?(a) }
}
