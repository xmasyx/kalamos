import Foundation

/// Runtime-tunable knobs (changeable without a rebuild via `defaults write`).
enum Tuning {
    /// Seconds of inactivity before a model is unloaded from memory to free RAM.
    /// `nil` = never (keep in memory). Default 300 (5 min). Settable from the menu
    /// or `defaults write com.kalamos.app idleUnloadSeconds -int <secs|0=never>`.
    static var idleUnloadSeconds: UInt64? {
        guard let n = UserDefaults.standard.object(forKey: "idleUnloadSeconds") as? Int else { return 300 }
        return n > 0 ? UInt64(n) : nil   // 0 (or negative) = never unload
    }

    /// Raw stored value for the menu (300 if unset; 0 = never).
    static var idleUnloadRaw: Int {
        (UserDefaults.standard.object(forKey: "idleUnloadSeconds") as? Int) ?? 300
    }

    static func setIdleUnload(_ seconds: Int) {
        UserDefaults.standard.set(seconds, forKey: "idleUnloadSeconds")
    }
}
