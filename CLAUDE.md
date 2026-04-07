# VoiceEditor — Claude Code Instructions

Read `SWIFT_REWRITE_BRIEF.md` as the primary build specification.
It contains the product goal, architecture, module map, protocol signatures, UX requirements, model strategy, MVP checklist, and starter code stubs.

Read `NOTES.md` for Python prototype context when a design question arises (e.g., silence detection parameters, prompt templates, output cleaning logic).

## Build target

Native macOS menu bar app (SwiftUI + mlx-swift + FluidAudio).
Distribute outside the App Store — no sandbox.
Apple Silicon only. Everything runs locally, no cloud calls.

## Design before implementation

For any new service, feature, or significant code change:
1. Present a plan separating: goals, system design, layer responsibilities, and ordered implementation steps.
2. Wait for explicit user approval before writing any code.
3. Plans must clearly separate: protocol/abstraction, concrete implementations, integration points, and UI changes.

## Conventions

- Use Swift concurrency (async/await, actors) throughout.
- Follow the module boundaries defined in the brief's Section 3 (Architecture).
- `ConversationCoordinator` is the single orchestration center — do not scatter pipeline logic across views.
- `AppState` enum is the single source of truth for UI state.
- Clipboard operations must save and restore original contents.
- Never paste LLM output without running it through output cleaning first.
- **New services must be backed by a protocol.** Concrete backends implement the protocol; callers depend only on the protocol. Example: `TTSProvider` protocol → `KokoroTTSProvider` / `PocketTTSProvider`. Never expose a concrete type directly to the orchestration layer.

## SettingsView conventions

- Window width is fixed at 620pt. Do not change it.
- Each tab has an explicit `currentHeight` in `SettingsView.swift`. Update it when adding content.
- When a tab's content is conditionally expanded (e.g., TTS enabled/disabled), set `currentHeight` to a tuple expression: `return condition ? expandedHeight : collapsedHeight`. Add `.animation(.spring(...), value: condition)` alongside the existing tab animation.
- Match the `Grid/GridRow` layout pattern for label-value rows (label right-aligned in first column, content left-aligned in second column).
- New settings belong in the most semantically appropriate existing tab. Avoid creating new tabs unless the feature is truly orthogonal to all existing content.

## FluidAudio reference documentation

Before exploring FluidAudio source code, check `examples/FluidAudio/Documentation/` first.
It contains up-to-date API guides for: ASR, TTS (Kokoro, PocketTTS, SSML), VAD, and Diarization.
Key TTS files: `Documentation/TTS/Kokoro.md`, `Documentation/TTS/PocketTTS.md`.

## Adding new files

**Never manually edit `project.pbxproj`.** The project is managed by xcodegen:
- `project.yml` is the source of truth (uses `sources: path: VoiceEditor` — auto-globs all Swift files)
- After creating any new `.swift` file, run: `xcodegen generate`
- Then verify: `xcodebuild -scheme HitokuDraft -configuration Debug -disablePackageRepositoryCache build`

The release script (`release.sh`) runs `xcodegen generate` automatically, so all new files in `VoiceEditor/` are included without any manual registration.

## Version bumping

Version lives in `project.yml` (`MARKETING_VERSION`, `CURRENT_PROJECT_VERSION`).
The release script bumps it — do not manually edit `project.pbxproj` build settings.
Use `./release.sh <version>` for all releases.

## Testing new permissions

When adding a new `NS*UsageDescription` key or changing a permission API (EventKit, Contacts, etc.), macOS caches prior decisions. Reset before testing:
```bash
tccutil reset Calendar com.hitokudraft.app
tccutil reset Reminders com.hitokudraft.app
# replace service name as appropriate
```

### FOR REFERENCE

Some Common Codes and Examples in this local directory from relevant input.

