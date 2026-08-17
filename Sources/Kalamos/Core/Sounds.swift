import AppKit

/// The app's small confirmation noises, at the volume he asked for.
///
/// `NSSound(named:)?.play()` plays at the system volume, full scale, which for a
/// tick that fires several times a minute is louder than it needs to be: these
/// sounds say "written down", not "something happened". Sua richiesta del
/// 2026-08-15, **fissa a metà**, not a preference and not a setting.
///
/// One place, because the app made this noise from ten different lines and a
/// volume set in nine of them is a volume nobody set.
enum Sounds {
    /// Fixed at 30% (sua richiesta, 2026-08-16; era 50% per due ore).
    static let level: Float = 0.3

    /// Written down, learned, saved.
    static func ok() { play("Glass") }

    /// Nothing to do, or it did not work.
    static func no() { play("Funk") }

    static func play(_ name: String) {
        guard let sound = NSSound(named: name) else { return }
        // A fresh copy each time: `NSSound(named:)` hands back a shared
        // instance, and a second play while the first is still sounding is
        // dropped rather than overlapped.
        let s = sound.copy() as? NSSound ?? sound
        s.volume = level
        s.play()
    }
}
