# VoiceEditor — Claude Code Instructions

Read `SWIFT_REWRITE_BRIEF.md` as the primary build specification.
It contains the product goal, architecture, module map, protocol signatures, UX requirements, model strategy, MVP checklist, and starter code stubs.

Read `NOTES.md` for Python prototype context when a design question arises (e.g., silence detection parameters, prompt templates, output cleaning logic).

## Build target

Native macOS menu bar app (SwiftUI + mlx-swift + FluidAudio).
Distribute outside the App Store — no sandbox.
Apple Silicon only. Everything runs locally, no cloud calls.

## Conventions

- Use Swift concurrency (async/await, actors) throughout.
- Follow the module boundaries defined in the brief's Section 3 (Architecture).
- `ConversationCoordinator` is the single orchestration center — do not scatter pipeline logic across views.
- `AppState` enum is the single source of truth for UI state.
- Clipboard operations must save and restore original contents.
- Never paste LLM output without running it through output cleaning first.

### FOR REFERENCE

Some Common Codes and Examples in this local directory from relevant input.

