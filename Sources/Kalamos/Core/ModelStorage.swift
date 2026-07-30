import Foundation

/// Where Kalamos stores downloaded models. Uses Application Support — it persists
/// across launches and, unlike ~/Documents, is NOT TCC-protected, so there's no
/// permission prompt and no risk of the cache being unreadable/unwritable (which
/// caused the speech model to re-download every launch).
enum ModelStorage {
    /// Base passed to HubApi as `downloadBase`. Models land under
    /// `<base>/models/<repo-id>/<variant>/`.
    static var base: URL {
        let appSupport = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true))
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("Kalamos", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
