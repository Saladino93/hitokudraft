// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "VoiceEditor",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio", revision: "843250b"),
        .package(path: "HitokuInference"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", revision: "6bb84aa"),
        .package(url: "https://github.com/ml-explore/mlx-swift", .upToNextMinor(from: "0.30.6")),
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", from: "2.0.0"),
        .package(url: "https://github.com/Blaizzy/mlx-audio-swift", from: "0.1.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.0.0"),
        .package(url: "https://github.com/huggingface/swift-huggingface", from: "0.8.1"),
    ],
    targets: [
        .executableTarget(
            name: "VoiceEditor",
            dependencies: [
                "FluidAudio",
                .product(name: "HitokuInference", package: "HitokuInference"),
                .product(name: "MLXBackend", package: "HitokuInference"),
                .product(name: "LiteRTBackend", package: "HitokuInference"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLX", package: "mlx-swift"),
                "KeyboardShortcuts",
                "Sparkle",
                .product(name: "MLXAudio", package: "mlx-audio-swift"),
                .product(name: "HuggingFace", package: "swift-huggingface"),
            ],
            path: "VoiceEditor",
            exclude: ["Info.plist", "VoiceEditor.entitlements"],
            resources: [.process("Assets.xcassets"), .process("Resources")]
        ),
    ]
)
