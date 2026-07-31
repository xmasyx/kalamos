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
    ],
    targets: [
        .executableTarget(
            name: "Kalamos",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit"),
                // ── Phase 2 ──
                .product(name: "MLXLLM", package: "mlx-swift-examples"),
                .product(name: "MLXLMCommon", package: "mlx-swift-examples"),
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
