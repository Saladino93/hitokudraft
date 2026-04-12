// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "VoiceEditor",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio", revision: "843250b"),
        .package(path: "HitokuInference"),
        .package(url: "https://github.com/adrgrondin/mlx-swift-lm", revision: "c21a372"),
        .package(url: "https://github.com/ml-explore/mlx-swift", .upToNextMinor(from: "0.31.3")),
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", from: "2.0.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.0.0"),
        .package(url: "https://github.com/huggingface/swift-huggingface", from: "0.8.1"),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.1.6"),
    ],
    targets: [
        .executableTarget(
            name: "VoiceEditor",
            dependencies: [
                "FluidAudio",
                .product(name: "HitokuInference", package: "HitokuInference"),
                .product(name: "MLXBackend", package: "HitokuInference"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXVLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLX", package: "mlx-swift"),
                "KeyboardShortcuts",
                "Sparkle",
                .product(name: "HuggingFace", package: "swift-huggingface"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ],
            path: "VoiceEditor",
            exclude: ["Info.plist", "VoiceEditor.entitlements"],
            resources: [.process("Assets.xcassets"), .process("Resources")]
        ),
    ]
)
