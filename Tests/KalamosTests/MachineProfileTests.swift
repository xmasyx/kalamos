import Testing
@testable import Kalamos

/// The machine decides, so every threshold is tested from BOTH sides with an
/// invented machine. The real `ProcessInfo` would only ever exercise the side
/// this particular Mac happens to be on — which is the whole reason
/// `MachineProfile` is a plain struct rather than a bag of computed properties.
@Suite struct RecommendationTests {
    private static let gb: UInt64 = 1024 * 1024 * 1024

    /// A machine with room for anything, so a test about memory is not quietly a
    /// test about the disk.
    private static func mac(ram: UInt64, disk: UInt64 = 500 * gb,
                            chip: String = "Apple M4 Max") -> MachineProfile {
        MachineProfile(chipName: chip, memoryBytes: ram, freeDiskBytes: disk,
                       performanceCores: 10, efficiencyCores: 4)
    }

    // MARK: Memory

    @Test func eightGigabytesGetsTheSmallEngineAndNoModel() {
        let r = Recommendation.recommended(for: Self.mac(ram: 8 * Self.gb))
        #expect(r.engine == .parakeet)
        #expect(r.formatterMode == .ruleBased)
        #expect(r.constraint == .verySmallMemory)
        #expect(r.idleUnloadSeconds == 300)
    }

    /// The boundary is where an off-by-one lives: one byte over 8 GB is already a
    /// machine that can run the cleanup model.
    @Test func justOverEightIsAlreadyEnoughForTheModel() {
        let r = Recommendation.recommended(for: Self.mac(ram: 8 * Self.gb + 1))
        #expect(r.engine == .whisper)
        #expect(r.formatterMode == .localLLM)
        #expect(r.cleanupModelID == ModelCatalog.smallCleanupID)
        #expect(r.constraint == .tightMemory)
    }

    @Test func sixteenGetsTheBigModelAndTheLongerTimeout() {
        let r = Recommendation.recommended(for: Self.mac(ram: 16 * Self.gb))
        #expect(r.cleanupModelID == ModelCatalog.previousDefaultCleanupID)
        #expect(r.idleUnloadSeconds == 900)
        #expect(r.constraint == .none)
    }

    @Test func justUnderSixteenIsStillTheSmallModel() {
        let r = Recommendation.recommended(for: Self.mac(ram: 16 * Self.gb - 1))
        #expect(r.cleanupModelID == ModelCatalog.smallCleanupID)
        #expect(r.idleUnloadSeconds == 300)
    }

    /// The page setup used to print — "32 GB and up: always ready" — is now the
    /// rule the app applies itself.
    @Test func thirtyTwoKeepsTheModelsInMemory() {
        #expect(Recommendation.recommended(for: Self.mac(ram: 32 * Self.gb)).idleUnloadSeconds == 0)
        #expect(Recommendation.recommended(for: Self.mac(ram: 32 * Self.gb - 1)).idleUnloadSeconds == 900)
    }

    /// His own machine, which is the one configuration anybody has actually used.
    @Test func hisMacGetsWhatHeIsRunning() {
        let r = Recommendation.recommended(for: Self.mac(ram: 36 * Self.gb))
        #expect(r.engine == .whisper)
        #expect(r.cleanupModelID == ModelCatalog.previousDefaultCleanupID)
        #expect(r.formatterMode == .localLLM)
        #expect(r.idleUnloadSeconds == 0)
    }

    // MARK: Disk

    /// Plenty of memory is not permission to download onto a full disk.
    @Test func aFullDiskDropsTheCleanupModel() {
        let r = Recommendation.recommended(for: Self.mac(ram: 64 * Self.gb, disk: 4 * Self.gb))
        #expect(r.formatterMode == .ruleBased)
        #expect(r.constraint == .tightDisk)
        #expect(r.engine == .whisper)   // 1,62 GB + 2 GB di margine stanno ancora in 4 GB
    }

    @Test func aVeryFullDiskAlsoDropsTheEngine() {
        let r = Recommendation.recommended(for: Self.mac(ram: 64 * Self.gb, disk: 2 * Self.gb))
        #expect(r.engine == .parakeet)
        #expect(r.formatterMode == .ruleBased)
        #expect(r.constraint == .tightDisk)
    }

    /// A disk we could not read comes back as zero, and zero must not be read as
    /// "full" — an unknown is not a constraint, or an unreadable volume would
    /// quietly downgrade a 64 GB Mac to the smallest of everything.
    @Test func anUnreadableDiskConstrainsNothing() {
        let r = Recommendation.recommended(for: Self.mac(ram: 64 * Self.gb, disk: 0))
        #expect(r.engine == .whisper)
        #expect(r.formatterMode == .localLLM)
        #expect(r.constraint == .none)
    }

    // MARK: What it must never propose

    /// ISC-149. The 14B and Whisper Large v3 are real choices in Preferences and
    /// have never been measured here; proposing one would be promising a quality
    /// nobody has seen. This sweeps every machine from a 4 GB Mac to a 256 GB one.
    @Test func neverProposesAModelNobodyMeasured() {
        let allowed: Set<String> = [ModelCatalog.smallCleanupID, ModelCatalog.previousDefaultCleanupID]
        for gb in stride(from: UInt64(4), through: 256, by: 4) {
            let r = Recommendation.recommended(for: Self.mac(ram: gb * Self.gb))
            #expect(allowed.contains(r.cleanupModelID), "\(gb) GB proposed \(r.cleanupModelID)")
        }
    }

    /// Whatever is proposed has to be selectable afterwards, or the app starts up
    /// pointing at a model that is not in its own menu.
    @Test func everyProposalIsInTheCatalogue() {
        let ids = Set(ModelCatalog.cleanup.map(\.id))
        for gb in stride(from: UInt64(4), through: 128, by: 4) {
            #expect(ids.contains(Recommendation.recommended(for: Self.mac(ram: gb * Self.gb)).cleanupModelID))
        }
    }

    /// ISC-148 — the chip is shown, never used to decide. Two machines that differ
    /// only in the name of their chip must get the same proposal, because the only
    /// measurements this app owns are about what fits, not about which silicon.
    @Test func theChipNameChangesNothing() {
        let m4 = Recommendation.recommended(for: Self.mac(ram: 16 * Self.gb, chip: "Apple M4 Max"))
        let m1 = Recommendation.recommended(for: Self.mac(ram: 16 * Self.gb, chip: "Apple M1"))
        let unknown = Recommendation.recommended(for: Self.mac(ram: 16 * Self.gb, chip: "Apple M9 Ultra"))
        #expect(m4 == m1)
        #expect(m4 == unknown)
    }
}

/// The reading side. It cannot assert what this Mac is — the test has to pass on
/// somebody else's too — so it asserts that every field was actually read, which
/// is the failure that matters: a `sysctl` key that silently returns nothing puts
/// a zero on the screen and nobody notices until the page says "0 GB".
@Suite struct MachineReadingTests {
    /// It asserts that a reading HAPPENED, never how big the machine is. The first
    /// version ended in `memoryGB >= 8` and went red on CI, where the runner has
    /// 7 GB — the test was smuggling in an assumption about whose Mac runs it,
    /// which is the same mistake the whole feature exists to stop making. (And a
    /// 7 GB machine is not hypothetical: it is exactly the branch that gets
    /// Parakeet and no cleanup model.)
    @Test func thisMacReadsAsARealMachine() {
        let m = MachineProfile.current
        #expect(!m.chipName.isEmpty)
        #expect(m.chipName != "Apple Silicon")        // the fallback, not a reading
        #expect(m.memoryBytes > 2 * 1024 * 1024 * 1024)
        #expect(m.performanceCores > 0)
        // Not `memoryGB == <the same formula>`: that is a tautology dressed as a
        // check. What can actually break is a field that reads as nothing, so the
        // assertion is that each one is non-degenerate.
        #expect(m.memoryGB > 0)
        #expect(!m.coreSummary.isEmpty)
        #expect(!m.coreSummary.hasSuffix("+ 0"))
    }

    /// The summary is what the page prints, so an efficiency-core count of zero
    /// must not come out as a stray "+ 0".
    @Test func theCoreSummaryHidesAnAbsentSecondKind() {
        let both = MachineProfile(chipName: "x", memoryBytes: 0, freeDiskBytes: 0,
                                  performanceCores: 10, efficiencyCores: 4)
        let one = MachineProfile(chipName: "x", memoryBytes: 0, freeDiskBytes: 0,
                                 performanceCores: 8, efficiencyCores: 0)
        #expect(both.coreSummary == "10 + 4")
        #expect(one.coreSummary == "8")
    }
}

/// Accepting the proposal has to make setup SHORTER, or the page that proposes
/// is just one more page. A10.
@Suite struct OnboardingFlowTests {
    /// Walk the flow the way a person does, and count the pages seen.
    private func pagesVisited(accepting: Bool) -> [Int] {
        var seen = [0]
        var step = 0
        while step < OnboardingFlow.permissions {
            step = OnboardingFlow.next(from: step, accepted: accepting)
            seen.append(step)
        }
        return seen
    }

    @Test func acceptingSkipsThePagesTheMachineDecided() {
        let accepted = pagesVisited(accepting: true)
        for page in OnboardingFlow.decided {
            #expect(!accepted.contains(page), "accepting still walked through page \(page)")
        }
    }

    @Test func choosingYourselfWalksThroughThemAll() {
        let chosen = pagesVisited(accepting: false)
        for page in OnboardingFlow.decided {
            #expect(chosen.contains(page))
        }
    }

    @Test func acceptingIsStrictlyShorter() {
        #expect(pagesVisited(accepting: true).count < pagesVisited(accepting: false).count)
    }

    /// Back out of the permissions after accepting and you land where you left,
    /// not inside the pages that were skipped — a "Back" that walks into a page
    /// you never saw is worse than no Back at all.
    @Test func backFromThePermissionsReturnsToWhereYouWere() {
        #expect(OnboardingFlow.previous(from: OnboardingFlow.permissions, accepted: true)
                == OnboardingFlow.lastAsked)
        #expect(OnboardingFlow.previous(from: OnboardingFlow.permissions, accepted: false)
                == OnboardingFlow.permissions - 1)
    }

    /// Every page between the first and the permissions is reachable when nobody
    /// accepts anything — the guard against inserting a page and forgetting to
    /// wire it into the sequence.
    @Test func noPageIsUnreachable() {
        #expect(pagesVisited(accepting: false) == Array(0...OnboardingFlow.permissions))
    }
}

/// Setup has to offer everything the app accepts, for the settings whose answers
/// are a closed set.
///
/// The bug this exists to stop: the trigger gained a fourth mode on 2026-07-31,
/// Preferences picked it up for free because it builds from `allCases`, and setup
/// kept its three hand-written ones. Someone running the fourth mode reached that
/// page and saw nothing selected — his own setting was not on it — and Continue
/// let him walk past. Found by him, in the real window, on 2026-08-02.
@Suite @MainActor struct OnboardingCoverageTests {
    @Test func everyTriggerModeIsOffered() {
        #expect(Set(OnboardingChoices.triggerModes) == Set(TriggerMode.allCases))
    }

    @Test func everyCleanupModeIsOffered() {
        #expect(Set(OnboardingChoices.formatterModes) == Set(FormatterMode.allCases))
    }

    /// Order is a choice, coverage is not — but a duplicate would draw the same
    /// tile twice and is never intended.
    @Test func nothingIsOfferedTwice() {
        #expect(OnboardingChoices.triggerModes.count == Set(OnboardingChoices.triggerModes).count)
        #expect(OnboardingChoices.formatterModes.count == Set(OnboardingChoices.formatterModes).count)
        #expect(OnboardingChoices.triggerKeys.count == Set(OnboardingChoices.triggerKeys).count)
        #expect(OnboardingChoices.idleSeconds.count == Set(OnboardingChoices.idleSeconds).count)
    }

    /// The two open sets. They CANNOT cover their setting — a key code is any key,
    /// an idle timeout any number — which is precisely why those two pages gate
    /// Continue instead of pretending an answer is always present. This test is
    /// here so that fact stays written down: if one of them ever becomes closed,
    /// it belongs in the coverage tests above.
    @Test func theOpenSetsAreTheOnesThatCanBeEmpty() {
        #expect(!OnboardingChoices.triggerKeys.isEmpty)
        #expect(!OnboardingChoices.idleSeconds.isEmpty)
        // A value outside each list is what a page with nothing lit looks like.
        #expect(!OnboardingChoices.triggerKeys.contains(0x00))
        #expect(!OnboardingChoices.idleSeconds.contains(600))
    }

    /// Every mode the app has gets its own wording on the tile. A case added
    /// without one would ship a tile with a blank second line.
    @Test func everyModeHasANote() {
        for mode in TriggerMode.allCases {
            #expect(!OnboardingView.modeNote(mode, .italian).isEmpty, "\(mode) has no note")
        }
        for mode in FormatterMode.allCases {
            #expect(!OnboardingView.formatterTitle(mode, .italian).isEmpty, "\(mode) has no title")
        }
    }
}

/// Setup and Preferences offer the SAME trigger keys.
///
/// They had a copy each until 2026-08-02, and Right Shift lived in one of them
/// only — the same drift that had just lost the fourth trigger mode, found in
/// the same hour. There is one list now; this is what keeps it one.
@Suite @MainActor struct TriggerKeyListTests {
    @Test func everyOfferedKeyHasAName() {
        for code in OnboardingChoices.triggerKeys {
            let name = HotkeyManager.displayName(for: code)
            #expect(!name.isEmpty)
            #expect(name != "\(code)", "key \(code) falls back to its raw number")
        }
    }

    /// The keys have to be ones the tap can actually watch: `HotkeyManager` maps
    /// each to a modifier mask, and one that is missing would be offered in the
    /// interface and never fire.
    @Test func everyOfferedKeyIsAKeyTheTapWatches() {
        for code in OnboardingChoices.triggerKeys {
            #expect(HotkeyManager.isSupportedTriggerKey(code), "key \(code) is not watchable")
        }
    }
}

/// A row of choices in Preferences must not truncate one of them.
///
/// "Premuto o doppio tocco" came out as "Premuto o doppio…" once the trigger had
/// four modes and the row still insisted on four columns. A choice you cannot
/// read is not a choice. Reported with a screenshot, 2026-08-02.
@Suite @MainActor struct ChipRowLayoutTests {
    private func columns(_ labels: [String], notes: Bool = false) -> Int {
        ChipRow<Int>.columnCount(labels: labels, hasNotes: notes)
    }

    @Test func fourShortWordsStayInFourColumns() {
        #expect(columns(["Right Command", "Right Option", "Right Shift", "Fn / Globe"]) == 4)
    }

    /// The row that reported the bug, in all three languages it ships in.
    @Test func aLongLabelDropsTheRowToTwoColumns() {
        #expect(columns(["Tieni premuto", "Un tocco", "Doppio tocco", "Premuto o doppio tocco"]) == 2)
        #expect(columns(["Hold to talk", "One tap", "Double-tap", "Hold or double-tap"]) == 2)
        #expect(columns(["Maintenir", "Un appui", "Double-appui", "Maintenir ou double-appui"]) == 2)
    }

    /// A row shorter than the ceiling fills the width it has rather than leaving
    /// a hole where a fourth chip would be — the behaviour before this rule, kept.
    @Test func threeShortWordsFillTheirRow() {
        #expect(columns(["Italiano", "English", "Français"]) == 3)
    }

    /// Chips with a second line have always been two-up, whatever their length.
    @Test func notesStillMeanTwoColumns() {
        #expect(columns(["Whisper", "Parakeet"], notes: true) == 2)
    }

    /// The boundary, from both sides — where a truncation would start.
    @Test func theBoundaryIsWhereAQuarterPaneRunsOut() {
        let fits = String(repeating: "a", count: ChipRow<Int>.charactersInAQuarterPane)
        let doesNot = fits + "a"
        #expect(columns([fits, fits, fits, fits]) == 4)
        #expect(columns([fits, fits, fits, doesNot]) == 2)
    }
}
