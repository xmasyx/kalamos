import Foundation

/// Actions the gesture recognizer asks the controller to perform.
enum DictationAction: Equatable {
    case beginRecording          // start capturing audio now
    case endRecordingAndProcess  // stop capturing, transcribe + inject
    case cancelRecording         // discard (gesture turned out to be a no-op)
}

/// How the trigger key is meant to be used.
///
/// `hold` exists because the trigger is often a key with a day job: someone who
/// uses Right Option to type accents wants the key to do nothing on a tap, and
/// someone who never dictates hands-free does not want a stray double-tap to leave
/// the microphone open behind their back.
enum TriggerMode: String, CaseIterable, Codable, Sendable {
    case hold        // hold to record; a tap does nothing
    /// One tap starts hands-free, the next stops it.
    ///
    /// Asked for on 2026-07-31, and the reasoning is sound: pressing Option on
    /// its own does nothing in macOS, so the gesture is free. It costs the
    /// disambiguation the other modes rely on — every short tap fires — which is
    /// why holding does nothing here and why a mouse click while the key is down
    /// cancels: ⌥-click is a real shortcut and must not become a dictation.
    case singleTap
    case doubleTap   // double-tap to go hands-free; holding does nothing
    case both        // hold to record, double-tap for hands-free
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
        /// Un tocco singolo è stato visto e il microfono NON è ancora aperto: si
        /// aspetta `singleTapGrace` per vedere se era l'inizio di una scorciatoia.
        case pendingSingleTap(deadline: TimeInterval)
        case toggleListening                 // hands-free; next tap stops it

        /// Nome corto per il registro degli eventi (`HotkeyTrace`). Senza i valori
        /// associati: al registro serve la transizione, e i tempi ce li ha già.
        var label: String {
            switch self {
            case .idle: return "idle"
            case .holding: return "holding"
            case .holdingAborted: return "aborted"
            case .awaitingSecondTap: return "awaiting2"
            case .pendingSingleTap: return "pending1"
            case .toggleListening: return "listening"
            }
        }
    }

    private(set) var state: State = .idle

    let holdThreshold: TimeInterval      // press >= this == real hold
    let doubleTapWindow: TimeInterval    // 2nd tap must land within this

    /// Quanto si aspetta, in modalità «un tocco», prima di aprire davvero il microfono.
    /// Non è latenza percepita: nessuno parla nei due decimi dopo aver toccato il tasto.
    /// È il tempo che serve alla lettera di ⌥ò per arrivare e annullare il gesto.
    let singleTapGrace: TimeInterval = 0.20

    /// Which gestures the trigger key answers to.
    ///
    /// This used to be a single boolean, which could express "both" and "hands-free
    /// only" but not "hold only" — so the setup screen would have had to offer three
    /// choices, one of which was a lie. Three real modes instead.
    private(set) var mode: TriggerMode

    private var allowsHold: Bool { mode == .hold || mode == .both }
    private var allowsDoubleTap: Bool { mode == .doubleTap || mode == .both }

    /// Emits actions for the controller to execute.
    var onAction: ((DictationAction) -> Void)?

    init(holdThreshold: TimeInterval = 0.25, doubleTapWindow: TimeInterval = 0.30,
         mode: TriggerMode = .both) {
        self.holdThreshold = holdThreshold
        self.doubleTapWindow = doubleTapWindow
        self.mode = mode
    }

    /// Change the mode at runtime. Discards any in-flight gesture and settles to
    /// idle, so the new mode starts from a clean state rather than inheriting a
    /// half-finished one it may not even have a rule for.
    func setMode(_ newMode: TriggerMode) {
        switch state {
        case .holding where allowsHold, .toggleListening:
            emit(.cancelRecording)   // discard whatever was recording
        default:
            break
        }
        mode = newMode
        state = .idle
    }

    /// True while listening with no finger on the key.
    var isHandsFree: Bool {
        if case .toggleListening = state { return true }
        return false
    }

    /// Settle to idle without emitting anything.
    ///
    /// For the one case where the recording ended somewhere other than here: the
    /// hands-free silence guard closed the microphone. Without this the machine
    /// still believes it is listening, and the user's next tap is spent stopping
    /// a recording that stopped by itself a minute ago.
    func settleToIdle() { state = .idle }

    /// Feed a key-DOWN event. `now` is a monotonic timestamp (seconds).
    func keyDown(at now: TimeInterval) {
        switch state {
        case .idle:
            // Provisional first-tap-or-hold. When holding is allowed we start
            // recording at once so HOLD feels instant; when it is not, a lone hold
            // does nothing and only a double-tap (below) records.
            state = .holding(downAt: now)
            if allowsHold { emit(.beginRecording) }

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

        case .pendingSingleTap:
            // Un altro tocco mentre la grazia scorre: il gesto ricomincia da capo,
            // e quello di prima non ha mai aperto niente da chiudere.
            state = .holding(downAt: now)
            if allowsHold { emit(.beginRecording) }

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
            if allowsHold { emit(.cancelRecording) }
            state = .holdingAborted
        }
        // La finestra di grazia del tocco singolo esiste proprio per questo: la
        // lettera di ⌥ò arriva un attimo dopo la risalita, non mentre il tasto è giù.
        if case .pendingSingleTap = state { state = .idle }
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
        case .holding where allowsHold:
            // Wait for the trigger release rather than going straight to idle, so
            // the key-up does not read as a fresh gesture.
            state = .holdingAborted
            emit(.cancelRecording)
            return true

        case .toggleListening:
            state = .idle
            emit(.cancelRecording)
            return true

        case .pendingSingleTap:
            // Niente sta registrando, quindi Esc non è nostro e passa oltre. La
            // grazia però si chiude: Esc non è mai l'inizio di una dettatura.
            state = .idle
            return false

        case .idle, .holding, .holdingAborted, .awaitingSecondTap:
            return false   // nothing was recording — Escape is not ours
        }
    }

    /// Feed a key-UP event.
    ///
    /// `otherKeyDuringPress` è la seconda guardia del tocco singolo, e non passa dal
    /// nostro tap: è il sistema a dire quando è stato premuto l'ultimo tasto. Serve
    /// perché `abort()` copre solo il caso in cui il tap ha VISTO la lettera, e un tap
    /// disabilitato per lentezza o un campo a input sicuro la fanno sparire senza che
    /// nessuno se ne accorga. Misurato il 31/08: dei quattro ordini in cui ⌥ e una
    /// lettera possono arrivare, solo quello ideale non faceva partire una dettatura.
    func keyUp(at now: TimeInterval, otherKeyDuringPress: Bool = false) {
        switch state {
        case .holding(let downAt):
            let heldFor = now - downAt
            if heldFor >= holdThreshold {
                // Genuine hold: finish and process where holding is allowed, and
                // otherwise a no-op, because nothing was ever recording.
                state = .idle
                if allowsHold { emit(.endRecordingAndProcess) }
            } else {
                // Short tap. Discard the tiny recording it may have started, then
                // either wait for a second tap or — in hold-only mode, where a
                // double-tap means nothing — settle straight back to idle rather
                // than leaving a window open for a gesture that cannot happen.
                if allowsHold { emit(.cancelRecording) }
                if mode == .singleTap {
                    // Un tocco è tutto il gesto, ma il microfono NON si apre qui.
                    // Aprirlo sulla risalita significa decidere prima di sapere: al
                    // momento del rilascio «⌥ da solo» e «⌥ò scritto un attimo storto»
                    // sono lo stesso evento. Si aspetta `singleTapGrace`, e un tasto o
                    // un clic dentro quella finestra annulla.
                    if otherKeyDuringPress {
                        state = .idle          // il sistema dice che una lettera c'era
                    } else {
                        state = .pendingSingleTap(deadline: now + singleTapGrace)
                    }
                } else {
                    state = allowsDoubleTap
                        ? .awaitingSecondTap(deadline: now + doubleTapWindow)
                        : .idle
                }
            }

        case .holdingAborted:
            state = .idle   // trigger released after an aborted (shortcut) hold

        case .idle, .awaitingSecondTap, .pendingSingleTap, .toggleListening:
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
        // La grazia del tocco singolo è scaduta senza che arrivasse niente: era un
        // tocco vero, e solo adesso si apre il microfono.
        if case .pendingSingleTap(let deadline) = state, now >= deadline {
            state = .toggleListening
            emit(.beginRecording)
        }
    }

    private func emit(_ a: DictationAction) { onAction?(a) }
}
