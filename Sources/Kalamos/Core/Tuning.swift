import Foundation

/// Runtime-tunable knobs (changeable without a rebuild via `defaults write`).
enum Tuning {
    /// Seconds of inactivity before a model is unloaded from memory to free RAM.
    /// `nil` = never (keep in memory). Default 300 (5 min). Settable from the menu
    /// or `defaults write com.kalamos.app idleUnloadSeconds -int <secs|0=never>`.
    static var idleUnloadSeconds: UInt64? {
        guard let n = stored else { return 300 }
        return n > 0 ? UInt64(n) : nil   // 0 (or negative) = never unload
    }

    /// Raw stored value for the menu (300 if unset; 0 = never).
    static var idleUnloadRaw: Int { stored ?? 300 }

    /// The value on disk, whichever way it got there.
    ///
    /// `as? Int` alone was silently wrong for one caller: a value passed on the
    /// command line lands in `NSArgumentDomain` as a **String**, so
    /// `-idleUnloadSeconds 1800` was read as nil and fell back to the 300
    /// default. A probe that injects a setting then measures the DEFAULT and
    /// reports it as the injected one — which is exactly what happened while
    /// checking this row's own screenshot, 2026-08-01. The app itself always
    /// writes an Int, so this only ever mattered to the thing looking at it.
    private static var stored: Int? {
        let value = UserDefaults.standard.object(forKey: "idleUnloadSeconds")
        if let n = value as? Int { return n }
        if let s = value as? String, let n = Int(s) { return n }
        return nil
    }

    /// Seconds of silence after which a HANDS-FREE dictation closes the
    /// microphone by itself. 0 disables the guard entirely — for someone who
    /// would rather hold the key open indefinitely.
    /// `defaults write com.kalamos.app handsFreeSilenceSeconds -int <secs|0=off>`
    static var handsFreeSilenceSeconds: Double {
        let v = UserDefaults.standard.object(forKey: "handsFreeSilenceSeconds")
        if let n = v as? Int { return Double(n) }
        if let s = v as? String, let n = Double(s) { return n }
        return HandsFreeSilence.defaultSeconds
    }

    /// How many recent dictations keep their audio on disk, for diagnosing one
    /// that went wrong. 0 turns the archive off entirely and deletes nothing that
    /// is already there — emptying the folder stays the user's call.
    /// `defaults write com.kalamos.app keepLastDictations -int <count|0=off>`
    static var keepLastDictations: Int {
        let v = UserDefaults.standard.object(forKey: "keepLastDictations")
        if let n = v as? Int { return n }
        if let s = v as? String, let n = Int(s) { return n }
        return 20
    }

    static func setIdleUnload(_ seconds: Int) {
        UserDefaults.standard.set(seconds, forKey: "idleUnloadSeconds")
    }
}
