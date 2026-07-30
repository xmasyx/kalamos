import Foundation

/// One-time migration from the app's former identity, Parla.
///
/// Renaming the bundle identifier hands macOS a brand-new app. Two things break
/// silently as a result, and both are only recoverable here, before anything else
/// reads either location:
///
///   1. **Settings.** Preferences are stored per bundle id, so every setting —
///      trigger key, vocabulary, correction rules, chosen models — reverts to its
///      default without a word.
///   2. **Models.** Application Support is keyed by app name, so roughly 6 GB of
///      already-downloaded weights would be downloaded a second time.
///
/// What this CANNOT carry over is Microphone and Accessibility. Those grants are
/// bound to the code identity by macOS itself, deliberately, so they have to be
/// given again by hand. There is no API for it and there should not be one.
///
/// Runs once, guarded by a marker key, and is safe to call on every launch.
enum Migration {
    private static let legacyBundleID = "com.parla.app"
    private static let legacyFolder = "Parla"
    private static let currentFolder = "Kalamos"
    private static let markerKey = "migratedFromParla"

    /// Every key the app persists, listed explicitly.
    ///
    /// Deliberately not `dictionaryRepresentation()`: that also returns values
    /// inherited from NSGlobalDomain, and copying those into our own domain would
    /// pin a snapshot of system-wide settings inside the app forever.
    private static let keys = [
        "hotKeyCode", "formatterMode", "enabledLanguages", "autoDetectLanguage",
        "defaultLanguage", "translationEnabled", "translationTarget",
        "whisperModel", "cleanupModelID", "cleanupPromptOverride",
        "pushToTalkEnabled", "editModeEnabled", "editModeKeyCode",
        "idleUnloadSeconds", "debugLogging", "vocabulary", "corrections",
    ]

    static func runIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: markerKey) else { return }

        // Models FIRST. `ModelStorage.base` creates its directory the moment it is
        // read, and anything that logs goes through it — a single log line before
        // this point would create the destination and turn the move below into a
        // no-op, re-downloading 6 GB for no reason.
        migrateModels()
        migrateSettings(into: defaults)

        defaults.set(true, forKey: markerKey)
    }

    private static func migrateSettings(into defaults: UserDefaults) {
        guard let legacy = UserDefaults(suiteName: legacyBundleID) else { return }
        for key in keys {
            guard let value = legacy.object(forKey: key) else { continue }
            // Never clobber a value the user has already set under the new
            // identity — a re-run must not undo their more recent choice.
            guard defaults.object(forKey: key) == nil else { continue }
            defaults.set(value, forKey: key)
        }
    }

    private static func migrateModels() {
        let fm = FileManager.default
        guard let appSupport = try? fm.url(for: .applicationSupportDirectory,
                                           in: .userDomainMask,
                                           appropriateFor: nil,
                                           create: false) else { return }
        let old = appSupport.appendingPathComponent(legacyFolder, isDirectory: true)
        let new = appSupport.appendingPathComponent(currentFolder, isDirectory: true)

        guard fm.fileExists(atPath: old.path) else { return }

        if fm.fileExists(atPath: new.path) {
            // An empty destination is the normal case: something read
            // ModelStorage.base and created it. Anything else means real data is
            // already there, and moving on top of it would be destructive.
            let contents = (try? fm.contentsOfDirectory(atPath: new.path)) ?? ["nonempty"]
            guard contents.isEmpty else { return }
            try? fm.removeItem(at: new)
        }

        // A move within one volume is instant and, crucially, atomic: it either
        // happened or it did not. A copy could half-finish and leave two partial
        // model trees. If it fails the models simply download again — slow, but
        // never wrong.
        try? fm.moveItem(at: old, to: new)
    }
}
