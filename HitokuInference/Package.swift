// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "HitokuInference",
    platforms: [.macOS(.v14)],
    products: [
        // Core protocol + types — zero heavy dependencies
        .library(name: "HitokuInference", targets: ["HitokuInference"]),
        // MLX backend — wraps MLXLLM / MLXVLM via ModelContainer
        .library(name: "MLXBackend", targets: ["MLXBackend"]),
        // LiteRT-LM backend — wraps the official LiteRT-LM Swift SDK
        .library(name: "LiteRTBackend", targets: ["LiteRTBackend"]),
    ],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", revision: "6bb84aa"),
        .package(url: "https://github.com/ml-explore/mlx-swift", .upToNextMinor(from: "0.30.6")),
        // Official LiteRT-LM Swift SDK — vendors a prebuilt, code-signed
        // CLiteRTLM_mac.xcframework via a checksummed SwiftPM binary target.
        // Pinned by revision (v0.13.1 tag): the LiteRTLM target uses
        // .unsafeFlags(["-Xlinker", "-all_load"]), and SwiftPM forbids
        // depending on a package with unsafe flags by version range.
        .package(url: "https://github.com/google-ai-edge/LiteRT-LM",
                 revision: "a0afb5a56acd106b23a2b2385b8469834dc268c0"),
    ],
    targets: [
        .target(
            name: "HitokuInference",
            dependencies: [],
            path: "Sources/HitokuInference"
        ),
        .target(
            name: "MLXBackend",
            dependencies: [
                "HitokuInference",
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXVLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLX", package: "mlx-swift"),
            ],
            path: "Sources/MLXBackend"
        ),
        .target(
            name: "LiteRTBackend",
            dependencies: [
                "HitokuInference",
                .product(name: "LiteRTLM", package: "LiteRT-LM"),
            ],
            path: "Sources/LiteRTBackend"
        ),
        .testTarget(
            name: "HitokuInferenceTests",
            dependencies: ["HitokuInference"],
            path: "Tests/HitokuInferenceTests"
        ),
    ]
)
