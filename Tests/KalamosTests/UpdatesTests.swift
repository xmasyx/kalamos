import Foundation
import Testing
@testable import Kalamos

// Il contratto del modulo aggiornamenti: ogni regola ha anche il suo polo negativo.

@Suite("Updates: versione")
struct UpdatesVersionTests {
    @Test func tagConPrefissoPiuNuovo() {
        #expect(Updates.newerVersion(current: "1.2.0", latestTag: "v1.3.0") == "1.3.0")
    }

    @Test func tagSenzaPrefisso() {
        #expect(Updates.newerVersion(current: "1.2.0", latestTag: "1.2.1") == "1.2.1")
    }

    @Test func ugualeNonEPiuNuova() {
        #expect(Updates.newerVersion(current: "1.2.0", latestTag: "v1.2.0") == nil)
    }

    @Test func piuVecchiaNonEPiuNuova() {
        #expect(Updates.newerVersion(current: "1.3.0", latestTag: "v1.2.9") == nil)
    }

    @Test func confrontoNumericoNonLessicale() {
        #expect(Updates.newerVersion(current: "1.9.0", latestTag: "v1.10.0") == "1.10.0")
        #expect(Updates.newerVersion(current: "1.10.0", latestTag: "v1.9.0") == nil)
    }

    @Test func componentiMancantiValgonoZero() {
        #expect(Updates.newerVersion(current: "1.2", latestTag: "v1.2.1") == "1.2.1")
        #expect(Updates.newerVersion(current: "1.2.0", latestTag: "v1.2") == nil)
    }

    @Test func spazzaturaNonEUnaVersione() {
        #expect(Updates.newerVersion(current: "1.2.0", latestTag: "garbage") == nil)
        #expect(Updates.newerVersion(current: "dev", latestTag: "v1.3.0") == nil)
        #expect(Updates.newerVersion(current: "1.2.0", latestTag: "") == nil)
    }
}

@Suite("Updates: cadenza")
struct UpdatesCadenceTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func maiControllatoEDovuto() {
        #expect(Updates.isDue(lastCheck: nil, now: now) == true)
    }

    @Test func ventitreOreNonBastano() {
        #expect(Updates.isDue(lastCheck: now.addingTimeInterval(-23 * 3600), now: now) == false)
    }

    @Test func venticinqueOreBastano() {
        #expect(Updates.isDue(lastCheck: now.addingTimeInterval(-25 * 3600), now: now) == true)
    }

    @Test func esattamenteUnGiornoEDovuto() {
        #expect(Updates.isDue(lastCheck: now.addingTimeInterval(-86_400), now: now) == true)
    }

    @Test func unOrologioTornatoIndietroNonBlocca() {
        #expect(Updates.isDue(lastCheck: now.addingTimeInterval(+3 * 86_400), now: now) == true)
    }
}

@Suite("Updates: provenienza")
struct UpdatesSourceTests {
    let roots = ["/opt/homebrew/Caskroom", "/usr/local/Caskroom"]
    let home = "/Users/prova"

    private func exists(_ present: Set<String>) -> (String) -> Bool {
        { present.contains($0) }
    }

    @Test func caskroomEBundleInApplications() {
        let source = Updates.source(bundlePath: "/Applications/Kalamos.app",
                                    caskroomRoots: roots, homeDirectory: home,
                                    fileExists: exists(["/opt/homebrew/Caskroom/kalamos"]))
        #expect(source == .homebrew)
    }

    @Test func secondaRadiceIntel() {
        let source = Updates.source(bundlePath: "/Applications/Kalamos.app",
                                    caskroomRoots: roots, homeDirectory: home,
                                    fileExists: exists(["/usr/local/Caskroom/kalamos"]))
        #expect(source == .homebrew)
    }

    @Test func applicationsDiCasa() {
        let source = Updates.source(bundlePath: "/Users/prova/Applications/Kalamos.app",
                                    caskroomRoots: roots, homeDirectory: home,
                                    fileExists: exists(["/opt/homebrew/Caskroom/kalamos"]))
        #expect(source == .homebrew)
    }

    @Test func senzaCaskroomEManuale() {
        let source = Updates.source(bundlePath: "/Applications/Kalamos.app",
                                    caskroomRoots: roots, homeDirectory: home,
                                    fileExists: exists([]))
        #expect(source == .manual)
    }

    @Test func caskroomDiUnAltraAppNonConta() {
        let source = Updates.source(bundlePath: "/Applications/Kalamos.app",
                                    caskroomRoots: roots, homeDirectory: home,
                                    fileExists: exists(["/opt/homebrew/Caskroom/nosleep"]))
        #expect(source == .manual)
    }

    @Test func bundleFuoriDaApplicationsEManuale() {
        let source = Updates.source(bundlePath: "/Users/prova/Desktop/Kalamos.app",
                                    caskroomRoots: roots, homeDirectory: home,
                                    fileExists: exists(["/opt/homebrew/Caskroom/kalamos"]))
        #expect(source == .manual)
    }
}

@Suite("Updates: azione")
struct UpdatesActionTests {
    @Test func argomentiEsattiPerBrew() {
        #expect(Updates.upgradeArguments()
                == ["upgrade", "--cask", "xmasyx/tap/kalamos"])
    }

    @Test func daBrewSiAggiornaERiavvia() {
        #expect(Updates.action(for: .homebrew, version: "1.3.0")
                == .upgradeAndRelaunch(arguments: ["upgrade", "--cask",
                                                    "xmasyx/tap/kalamos"]))
    }

    @Test func aManoSiApreLaPaginaDellaRelease() {
        let url = URL(string: "https://github.com/xmasyx/kalamos/releases/tag/v1.3.0")!
        #expect(Updates.action(for: .manual, version: "1.3.0") == .openReleasePage(url))
    }
}

@Suite("Updates: JSON di GitHub")
struct UpdatesJSONTests {
    @Test func leggeIlTag() {
        let data = Data(#"{"tag_name":"v1.3.0","name":"1.3.0","draft":false}"#.utf8)
        #expect(Updates.latestTag(fromReleaseJSON: data) == "v1.3.0")
    }

    @Test func senzaTagNil() {
        #expect(Updates.latestTag(fromReleaseJSON: Data("{}".utf8)) == nil)
    }

    @Test func nonJSONNil() {
        #expect(Updates.latestTag(fromReleaseJSON: Data("<html>".utf8)) == nil)
    }
}
