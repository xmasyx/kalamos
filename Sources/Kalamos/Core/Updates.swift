import Foundation

/// Le decisioni pure dell'aggiornamento: niente rete, processi o interfaccia.
enum Updates {
    /// Il repo GitHub da cui si legge l'ultima release.
    static let repo = "xmasyx/kalamos"
    /// Il token del cask nel tap.
    static let caskToken = "kalamos"
    /// Il tap Homebrew della famiglia (`brew tap xmasyx/tap` → repo `xmasyx/homebrew-tap`).
    static let tap = "xmasyx/tap"

    /// Come l'app è arrivata sul Mac: dal cask, o a mano (zip, DMG, `install.sh`).
    enum Source: Equatable {
        case homebrew
        case manual
    }

    /// Cosa fa il bottone quando c'è una versione nuova.
    enum Action: Equatable {
        /// Lancia `brew` con questi argomenti (senza il binario), poi riavvia l'app.
        case upgradeAndRelaunch(arguments: [String])
        /// Apre la pagina della release nel browser.
        case openReleasePage(URL)
    }

    /// La versione nuova ("1.3.0") se `latestTag` (`v1.3.0` o `1.3.0`) è più recente di `current`;
    /// `nil` se è uguale, più vecchia, o non si legge. Il confronto è numerico per componente:
    /// 1.10.0 batte 1.9.0.
    static func newerVersion(current: String, latestTag: String) -> String? {
        func components(_ raw: String, acceptsPrefix: Bool) -> [Int]? {
            let version: Substring
            if acceptsPrefix, raw.first == "v" {
                version = raw.dropFirst()
            } else {
                version = raw[...]
            }
            guard !version.isEmpty else { return nil }
            let pieces = version.split(separator: ".", omittingEmptySubsequences: false)
            guard !pieces.isEmpty else { return nil }
            let numbers = pieces.compactMap { piece -> Int? in
                guard !piece.isEmpty, piece.allSatisfy(\.isNumber) else { return nil }
                return Int(piece)
            }
            return numbers.count == pieces.count ? numbers : nil
        }

        guard let installed = components(current, acceptsPrefix: false),
              let released = components(latestTag, acceptsPrefix: true) else { return nil }
        let count = max(installed.count, released.count)
        for index in 0..<count {
            let old = index < installed.count ? installed[index] : 0
            let new = index < released.count ? released[index] : 0
            if new != old {
                return new > old ? released.map(String.init).joined(separator: ".") : nil
            }
        }
        return nil
    }

    /// `true` se non c'è mai stato un controllo, o se sono passati almeno `interval` secondi.
    static func isDue(lastCheck: Date?, now: Date, interval: TimeInterval = 86_400) -> Bool {
        guard let lastCheck else { return true }
        let elapsed = now.timeIntervalSince(lastCheck)
        return elapsed < 0 || elapsed >= interval
    }

    /// `.homebrew` quando esiste `<root>/<token>/` in una delle radici del Caskroom E il bundle
    /// sta in `/Applications/<Nome>.app` o `~/Applications/<Nome>.app`; altrimenti `.manual`.
    /// `fileExists` è iniettato così il test non tocca il disco.
    static func source(bundlePath: String,
                       caskroomRoots: [String],
                       homeDirectory: String,
                       token: String = caskToken,
                       fileExists: (String) -> Bool) -> Source {
        let bundle = URL(fileURLWithPath: bundlePath).standardized.path
        let appName = URL(fileURLWithPath: bundle).lastPathComponent
        let systemApp = URL(fileURLWithPath: "/Applications")
            .appendingPathComponent(appName).standardized.path
        let userApp = URL(fileURLWithPath: homeDirectory)
            .appendingPathComponent("Applications")
            .appendingPathComponent(appName).standardized.path
        guard bundle == systemApp || bundle == userApp else { return .manual }

        let installed = caskroomRoots.contains { root in
            fileExists(URL(fileURLWithPath: root).appendingPathComponent(token).standardized.path)
        }
        return installed ? .homebrew : .manual
    }

    /// Gli argomenti per `brew`, senza il binario.
    static func upgradeArguments(token: String = caskToken, tap: String = tap) -> [String] {
        // Homebrew 6 non ha più `--no-quarantine`; l'Updater toglie il contrassegno dal proprio
        // bundle soltanto dopo un upgrade riuscito.
        ["upgrade", "--cask", "\(tap)/\(token)"]
    }

    /// L'azione per una versione nuova, data la provenienza.
    static func action(for source: Source, version: String, repo: String = repo) -> Action {
        switch source {
        case .homebrew:
            return .upgradeAndRelaunch(arguments: upgradeArguments())
        case .manual:
            return .openReleasePage(
                URL(string: "https://github.com/\(repo)/releases/tag/v\(version)")!
            )
        }
    }

    /// Il `tag_name` dal JSON di `GET /repos/<repo>/releases/latest`; `nil` se manca o non è JSON.
    static func latestTag(fromReleaseJSON data: Data) -> String? {
        struct Release: Decodable { let tagName: String }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try? decoder.decode(Release.self, from: data).tagName
    }
}
