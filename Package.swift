// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "VoiceEditor",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "examples/FluidAudio"),
        .package(path: "examples/mlx-swift-lm"),
        .package(url: "https://github.com/ml-explore/mlx-swift", .upToNextMinor(from: "0.30.6")),
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", from: "2.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "VoiceEditor",
            dependencies: [
                "FluidAudio",
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLX", package: "mlx-swift"),
                "KeyboardShortcuts",
            ],
            path: "VoiceEditor",
            exclude: ["Info.plist", "VoiceEditor.entitlements"],
            resources: [.process("Assets.xcassets")]
        ),
    ]
)
