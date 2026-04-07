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
        // LiteRT-LM backend — wraps C API for native multimodal inference
        .library(name: "LiteRTBackend", targets: ["LiteRTBackend"]),
    ],
    dependencies: [
        .package(path: "../mlx-swift-lm"),
        .package(url: "https://github.com/ml-explore/mlx-swift", .upToNextMinor(from: "0.30.6")),
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
        // C module wrapping the LiteRT-LM engine.h header
        .systemLibrary(
            name: "CLiteRTEngine",
            path: "Sources/CLiteRTEngine",
            pkgConfig: nil,
            providers: nil
        ),
        .target(
            name: "LiteRTBackend",
            dependencies: [
                "HitokuInference",
                "CLiteRTEngine",
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
