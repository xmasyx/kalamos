import Foundation

/// The settings this Mac should start with, decided by the machine.
///
/// Four of them: which engine listens, whether the cleanup model runs at all,
/// which cleanup model, and when the memory is freed. Setup used to ask for the
/// last two by printing the rule and hoping the reader knew their own RAM.
///
/// **Two things it deliberately does not decide, and the reason is the same.**
/// The Whisper variant stays Turbo everywhere, and the 14B cleanup model is never
/// proposed: we have measurements for neither Small/Base on his three languages
/// nor for the 14B on any machine here. Proposing them would be promising a
/// quality nobody has seen (ISC-149). They remain one click away in Preferences,
/// which is where a choice you make yourself belongs.
///
/// **And one thing it does not look at.** The chip. "Apple M4 Max" is shown,
/// because it is what makes someone recognise their own machine, but nothing here
/// branches on it: the only measurements we own are about how much fits in memory
/// and on disk. A rule keyed on the chip tier would be invented (ISC-148).
struct Recommendation: Equatable, Sendable {
    let engine: SpeechEngine
    let formatterMode: FormatterMode
    /// Meaningful only when `formatterMode == .localLLM`; carried anyway so the
    /// page can say which model it *would* be.
    let cleanupModelID: String
    /// Seconds of idleness before the models are unloaded. 0 = never.
    let idleUnloadSeconds: Int
    let constraint: Constraint

    /// Why the proposal is what it is. The view turns this into a sentence in the
    /// reader's language — the strings live where `L.t` lives, not here.
    enum Constraint: Equatable, Sendable {
        /// Room for everything.
        case none
        /// Under 16 GB: the small cleanup model, and the memory freed sooner.
        case tightMemory
        /// 8 GB or less: no cleanup model at all, and the small engine.
        case verySmallMemory
        /// The disk cannot hold what the memory could have run.
        case tightDisk
    }
}

extension Recommendation {
    // Download sizes. Every figure here is one the app already shows somewhere it
    // was measured or read off the transfer — the two engines from
    // `SpeechEngine.note`, the two cleanup models from `ModelCatalog.cleanup`.
    static let whisperBytes: UInt64 = 1_500_000_000
    static let parakeetBytes: UInt64 = 461_000_000
    /// I pesi GGML, presi dalla costante che il motore usa già per verificare che lo scaricamento
    /// sia arrivato intero. Riscriverla qui a mano sarebbe stato un numero che invecchia da solo il
    /// giorno che il modello cambia.
    static let whispercppBytes = UInt64(WhisperCppTranscriber.modelBytes)
    static let cleanup7BBytes: UInt64 = 4_300_000_000
    static let cleanup3BBytes: UInt64 = 1_800_000_000

    /// Never fill the disk to the brim on someone's behalf: a Mac with 200 MB left
    /// after the download is a Mac that stops working for reasons that have
    /// nothing to do with dictation.
    static let diskHeadroomBytes: UInt64 = 2 * 1024 * 1024 * 1024

    /// At or below this much memory the cleanup model is not proposed at all.
    /// Whisper's 1.5 GB plus a 1.8 GB model on an 8 GB machine leaves the desktop
    /// competing for what is left, and the swapping costs more than the tidier
    /// punctuation buys.
    static let cleanupMinimumBytes: UInt64 = 8 * 1024 * 1024 * 1024 + 1

    /// Above this, the models are worth keeping in memory permanently: the app is
    /// then ready the instant the key is pressed. This is the number setup used to
    /// print and ask the reader to apply ("32 GB and up: always ready").
    static let keepInMemoryBytes: UInt64 = 32 * 1024 * 1024 * 1024

    static func recommended(for machine: MachineProfile) -> Recommendation {
        let ram = machine.memoryBytes

        // 1. What the memory allows.
        var engine: SpeechEngine = .whispercpp
        var formatter: FormatterMode = .localLLM
        let cleanupID = ModelCatalog.recommendedCleanupID(physicalMemory: ram)
        var constraint: Recommendation.Constraint = .none

        if ram < cleanupMinimumBytes {
            // The small engine too: 461 MB against 1.5 GB is the difference that
            // matters here, and Parakeet is measured, not guessed.
            engine = .parakeet
            formatter = .ruleBased
            constraint = .verySmallMemory
        } else if ram < ModelCatalog.sevenBMinimumBytes {
            constraint = .tightMemory
        }

        let idle: Int = ram >= keepInMemoryBytes
            ? 0
            : (ram >= ModelCatalog.sevenBMinimumBytes ? 900 : 300)

        // 2. What the disk allows — which can be less. Nothing above knows how
        // much room the machine actually has, and a proposal that does not fit is
        // a first run that ends in a failed download.
        //
        // A disk we could not read is zero, and zero must not be read as "full":
        // an unknown is not a constraint, or an unreadable volume would quietly
        // downgrade a 64 GB Mac to the smallest of everything.
        let free = machine.freeDiskBytes
        if free > 0 {
            let cleanupBytes = cleanupID == ModelCatalog.smallCleanupID ? cleanup3BBytes : cleanup7BBytes
            // Un peso per ogni motore, letto dal motore proposto. Scritto come «whisper oppure
            // parakeet» dava a whisper.cpp il peso di Parakeet, cioè 461 MB per un file da 1,6 GB:
            // una proposta che non sta sul disco e un primo avvio che finisce in uno scaricamento
            // fallito.
            let engineBytes: UInt64
            switch engine {
            case .whisper:    engineBytes = whisperBytes
            case .whispercpp: engineBytes = whispercppBytes
            case .parakeet:   engineBytes = parakeetBytes
            }

            if formatter == .localLLM, free < engineBytes + cleanupBytes + diskHeadroomBytes {
                formatter = .ruleBased
                constraint = .tightDisk
            }
            // Il ripiego è sempre Parakeet, che è il più piccolo dei tre: su un disco che non tiene
            // un modello grande, l'unica proposta onesta è quella che ci sta.
            if engine != .parakeet, free < engineBytes + diskHeadroomBytes {
                engine = .parakeet
                constraint = .tightDisk
            }
        }

        return Recommendation(engine: engine,
                              formatterMode: formatter,
                              cleanupModelID: cleanupID,
                              idleUnloadSeconds: idle,
                              constraint: constraint)
    }
}
