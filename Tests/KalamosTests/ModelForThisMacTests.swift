import Testing
@testable import Kalamos

/// The cleanup model is chosen by the machine, not asked of the user (ISC-99).
///
/// The threshold is the whole claim, so it is tested from both sides. The real
/// `ProcessInfo` would only ever test the one side this Mac happens to be on.
@Suite struct ModelForThisMacTests {
    private static let gb: UInt64 = 1024 * 1024 * 1024

    @Test func smallMacGetsTheSmallModel() {
        #expect(ModelCatalog.recommendedCleanupID(physicalMemory: 8 * Self.gb)
                == ModelCatalog.smallCleanupID)
    }

    /// Exactly 16 GB is the first machine that gets the big one — the boundary is
    /// where an off-by-one lives.
    @Test func sixteenIsAlreadyBigEnough() {
        #expect(ModelCatalog.recommendedCleanupID(physicalMemory: 16 * Self.gb)
                == ModelCatalog.previousDefaultCleanupID)
    }

    @Test func justUnderSixteenIsNot() {
        #expect(ModelCatalog.recommendedCleanupID(physicalMemory: 16 * Self.gb - 1)
                == ModelCatalog.smallCleanupID)
    }

    @Test func bigMacGetsTheBigModel() {
        #expect(ModelCatalog.recommendedCleanupID(physicalMemory: 64 * Self.gb)
                == ModelCatalog.previousDefaultCleanupID)
    }

    /// Both ends of the choice have to exist in the catalogue, or the app starts
    /// pointing at a model nobody can select.
    @Test func bothChoicesAreInTheCatalogue() {
        let ids = Set(ModelCatalog.cleanup.map(\.id))
        #expect(ids.contains(ModelCatalog.smallCleanupID))
        #expect(ids.contains(ModelCatalog.previousDefaultCleanupID))
    }
}

/// The status says which model it is about, so two models loading at once cannot
/// clear each other (Gemini audit, 2026-07-31).
@Suite struct StatusOwnershipTests {
    @Test func aStatusKnowsWhichModelItIsAbout() {
        #expect(DictationStatus.downloading(.cleanup, fraction: 0.4).modelKind == .cleanup)
        #expect(DictationStatus.loading(.speech).modelKind == .speech)
    }

    /// The states that belong to nobody must not be clearable by a model task —
    /// this is what made `isModelBusy` the wrong test to clear on.
    @Test func workAndIdleBelongToNoModel() {
        #expect(DictationStatus.idle.modelKind == nil)
        #expect(DictationStatus.working(.summarizing).modelKind == nil)
        #expect(DictationStatus.transcribing.modelKind == nil)
        #expect(DictationStatus.error("x").modelKind == nil)
    }

    /// The concrete case the audit described: the speech model finishes first
    /// while the cleanup model is still downloading.
    @Test func aFinishedSpeechLoadDoesNotClearACleanupDownload() {
        let live = DictationStatus.downloading(.cleanup, fraction: 0.12)
        #expect(live.modelKind != .speech)      // → the speech task leaves it alone
        #expect(live.isModelBusy)               // → the old test would have cleared it
    }
}
