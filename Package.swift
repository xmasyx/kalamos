// swift-tools-version: 6.0
import PackageDescription

// Kalamos — local-only dictation for macOS (Apple Silicon).
//
// v0.1 builds with Command Line Tools (WhisperKit only).
// Phase 2 (formatting + translation LLM) needs FULL XCODE for the Metal
// shader compiler that MLX requires. Once Xcode is installed, uncomment the
// MLX dependency + products below and rebuild.
let package = Package(
    name: "Kalamos",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Kalamos", targets: ["Kalamos"])
    ],
    dependencies: [
        // WhisperKit and mlx-swift-examples share a transitive dependency on
        // huggingface/swift-transformers. Their version ranges only overlap on
        // the 0.1.x line: WhisperKit ≤0.14.x and mlx-swift-examples 2.25.4 both
        // accept swift-transformers 0.1.21..<0.2.0. Newer mlx (2.25.9+, main)
        // moved to 1.x with no WhisperKit overlap. To keep newest of BOTH, split
        // MLX into a separate sidecar process (see ISA "dependency isolation").
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", "0.14.0" ..< "0.15.0"),
        // ── Phase 2: on-device LLM (needs full Xcode for Metal) ───────────────
        .package(url: "https://github.com/ml-explore/mlx-swift-examples.git", exact: "2.25.4"),
        // Parakeet TDT 0.6B v3 — the second speech engine (2026-08-01). Safe to
        // add next to the pair above precisely because FluidAudio declares
        // `dependencies: []`: it cannot pull swift-transformers into the
        // resolution and cannot disturb the 0.1.x line WhisperKit and MLX share.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.15.5"),
    ],
    targets: [
        // whisper.cpp — il terzo motore (2026-08-05), come XCFramework già
        // compilato preso dalla loro release. Non è una dipendenza sorgente
        // perché whisper.cpp non pubblica un `Package.swift`, e NON è il binario
        // `whisper-cli`: un'app che lancia un eseguibile esterno deve spedirlo,
        // firmarlo e tenerlo su un percorso, mentre l'API C sta qui dentro.
        //
        // Il checksum è ciò che trasforma una URL in una dipendenza invece che in
        // uno scaricamento. Si ricalcola con `swift package compute-checksum`
        // quando il tag si muove.
        //
        // Licenza MIT, letta dal loro repo il 2026-08-05, quindi può stare dentro
        // un'app a sua volta pubblica.
        .binaryTarget(
            name: "whisper",
            url: "https://github.com/ggml-org/whisper.cpp/releases/download/v1.9.2/whisper-v1.9.2-xcframework.zip",
            checksum: "af74fed13ea7f2d5ca2a39d9f58ec177713fafd7cab63aef4e27b79f3ceca80b"
        ),
        .executableTarget(
            name: "Kalamos",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit"),
                "whisper",
                // ── Phase 2 ──
                .product(name: "MLXLLM", package: "mlx-swift-examples"),
                .product(name: "MLXLMCommon", package: "mlx-swift-examples"),
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            path: "Sources/Kalamos",
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "KalamosTests",
            dependencies: ["Kalamos"],
            path: "Tests/KalamosTests"
        ),
    ]
)
