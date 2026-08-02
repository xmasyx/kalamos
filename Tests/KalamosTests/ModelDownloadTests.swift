import Foundation
import Testing
@testable import Kalamos

#if canImport(WhisperKit)
/// A download that says "fine" and leaves nothing behind (2026-08-02).
///
/// Two of the four speech models in Preferences could not be selected. The cause
/// was upstream and silent: `HubApi.snapshot` asks a network monitor whether the
/// machine is offline, that monitor is born believing it is, and is corrected
/// only by an asynchronous callback — so the first download of a process always
/// takes the offline branch. That branch does not fail. It checks the models
/// folder exists, sees the models you already had, and returns having downloaded
/// nothing. The failure then surfaced somewhere else entirely, as a missing file
/// at load time.
///
/// The race itself cannot be unit tested; it lives in a dependency and depends
/// on a callback. What CAN be locked down is the lesson: a download is finished
/// when the files are there, not when the function returns.
@Suite struct ModelDownloadTests {
    private func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kalamos-model-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func anEmptyFolderIsNotADownloadedModel() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        #expect(throws: ModelDownloadError.self) {
            try WhisperKitTranscriber.assertModelArrived(in: folder, model: "openai_whisper-small")
        }
    }

    /// The other pole, and the one that matters: the guard has to say YES to a
    /// folder that really does hold a model. A check that only ever refuses is
    /// indistinguishable from a check that is broken.
    @Test func afolderWithTheEncoderPasses() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(
            at: folder.appendingPathComponent("AudioEncoder.mlmodelc"),
            withIntermediateDirectories: true)

        try WhisperKitTranscriber.assertModelArrived(in: folder, model: "openai_whisper-small")
    }

    /// Half a model is not a model. The folder that broke this had other things
    /// in it — the config, the tokenizer — just never the encoder.
    @Test func otherFilesDoNotCountAsTheModel() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try "{}".write(to: folder.appendingPathComponent("config.json"),
                       atomically: true, encoding: .utf8)

        #expect(throws: ModelDownloadError.self) {
            try WhisperKitTranscriber.assertModelArrived(in: folder, model: "openai_whisper-large-v3")
        }
    }

    /// The message is part of the fix. The old failure named a file the reader
    /// had never heard of; this one names the model and says what to do.
    @Test func theMessageNamesTheModel() {
        let error = ModelDownloadError.nothingArrived(model: "openai_whisper-small", folder: "/tmp/x")
        #expect(error.errorDescription?.contains("openai_whisper-small") == true)
    }
}
#endif
