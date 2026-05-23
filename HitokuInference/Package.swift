// swift-tools-version: 5.10
//
// HitokuInference — on-device LLM/VLM inference framework.
//
// mlx-swift-lm pinning policy
// ---------------------------
// We pin `mlx-swift-lm` to an EXACT upstream commit, not a tag/version range.
// Rationale: Gemma 4 support was merged into upstream in spring 2026 (PR #180
// plus follow-ups #183/#185/#192/#211/#212). While that surface stabilizes,
// reproducible builds matter more than automatic bumps.
//
// History
// -------
// - <= 2026-04-12  adrgrondin/mlx-swift-lm@c21a372  (fork; fork-only broadcast_shapes
//                                                   crash in Gemma 4 repetition-penalty
//                                                   processor — unfixable downstream).
// - 2026-04-16 →   ml-explore/mlx-swift-lm@2dccb38  (official; PR #180 merged +
//                                                   follow-up fixes; Gemma 4 text + VLM
//                                                   working).
//
// Bumping procedure
// -----------------
// 1. Change `revision:` below and `packages.mlx-swift-lm.revision` in project.yml.
// 2. Delete HitokuDraft.xcodeproj/.../swiftpm/Package.resolved and rm -rf HitokuInference/.build.
// 3. `xcodegen generate` to pick up project.yml changes.
// 4. Run the smoke tests from docs/gemma4-migration.md.
// 5. Only bump if ALL smoke tests pass.
//
// Do NOT switch to `.upToNextMinor(from: "3.x.y")` until upstream cuts a
// stable release tag covering Gemma 4 + tool calling (#215) + audio (#192/#194).
//
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
        // Official upstream — do not revert to the adrgrondin fork.
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", revision: "2dccb380cd26822589af6ec8682132b7149a425b"),
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
