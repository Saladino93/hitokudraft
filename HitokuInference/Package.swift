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
    ],
    dependencies: [
        .package(url: "https://github.com/adrgrondin/mlx-swift-lm", revision: "c21a372"),
        .package(url: "https://github.com/ml-explore/mlx-swift", .upToNextMinor(from: "0.31.3")),
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
        .testTarget(
            name: "HitokuInferenceTests",
            dependencies: ["HitokuInference"],
            path: "Tests/HitokuInferenceTests"
        ),
    ]
)
