# VoiceEditor — Pre-Launch Audit Checklist

**Date:** 2026-03-09
**Scope:** Feature completeness vs SWIFT_REWRITE_BRIEF.md, prompt quality, code safety
**Status:** In progress (session 3)

---

## 1. Feature Completeness

| Status | Item | Notes |
|--------|------|-------|
| ✅ | `ConversationCoordinator` — single orchestration center | All pipeline logic here |
| ✅ | `AppState` enum — single source of truth for UI state | |
| ✅ | MLX LLM inference (`MLXLLMService`) | mlx-swift + ModelContainer |
| ✅ | FluidAudio STT | `FluidAudioSTT` wraps FluidAudio models |
| ✅ | Audio capture + VAD + silence detection | `AudioCaptureService` |
| ✅ | Text capture via Accessibility API | `TextCaptureService` |
| ✅ | Clipboard save/restore | Save before capture, restore after paste |
| ✅ | Voice edit (hotkey → record → transcribe → LLM → paste) | |
| ✅ | Dictation mode (press to start/stop) | |
| ✅ | Grammar fix (hotkey → capture → LLM → paste) | |
| ✅ | DraftDetector — keyword-based draft vs edit routing | Fixed in session 3 (was unwired) |
| ✅ | OutputCleaner — strips LLM artifacts before paste | |
| ✅ | LanguageDetector — NaturalLanguage-based detection | |
| ✅ | HotkeyManager — global hotkeys | |
| ✅ | ModelManager — download, switch, custom HuggingFace URLs | |
| ✅ | PermissionsCoordinator — mic + accessibility gating | |
| ✅ | SettingsView — model selection, hotkey config | |
| ✅ | MenuBarView + DictationOverlayPanel | |
| ✅ | Sparkle auto-update integration | Added session 2 |
| ✅ | Developer ID signing / no sandbox | |
| ⚠️ | Onboarding — no dedicated first-launch UI | PermissionsCoordinator gates flows; low priority |
| ❌ | `AppleSTT.swift` — SFSpeechRecognizer fallback | Brief requires it; deferred to own session |

---

## 2. Prompt / LLM Audit

### 2a. Issues fixed in session 3

| Issue | File | Fix |
|-------|------|-----|
| `DraftDetector.isDraftCommand()` never called | `ConversationCoordinator.swift:194` | Added `\|\| DraftDetector.isDraftCommand(trimmedCommand)` |
| No system prompt → small models drift | `MLXLLMService.swift` | Added `Chat.Message.system(Prompts.systemPrompt)` |
| Draft prompt too minimal (1 sentence) | `Prompts.swift` | Expanded with scaffolding for small models |
| Grammar fix: unsupported languages fell back to English | `Instructions.swift` | Universal fallback: "reply in same language as input" |

### 2b. Current prompt templates (post-session-3)

**systemPrompt** (passed as `.system` role to all LLM calls):
```
You are a precise, concise text editor and writing assistant.
Follow instructions exactly. Output ONLY the requested text —
no commentary, no explanations, no preamble.
```

**edit(text:instruction:)**
- Detects language of TEXT via `LanguageDetector`
- Emits `languageRule` for non-English text
- Structured as: role description → rules → TEXT block → INSTRUCTION block → "REWRITTEN TEXT:" sentinel

**draft(instruction:)**
- Detects language of instruction
- 5-line scaffolding: role, task, no-repeat rule, paste-ready framing, `Request:` label

**grammar fix** uses `Instructions.forLanguage()`:
- en / it / fr / de: native language instructions
- Any other language: universal English fallback with "reply in same language" instruction

### 2c. Remaining prompt gaps (low priority)

| Gap | Impact | Recommendation |
|-----|--------|----------------|
| OutputCleaner doesn't catch "I changed X to Y" narrations | Low | Add regex for "I (changed\|replaced\|rewrote)" prefix stripping |
| `edit()` prompt embeds role description even though system prompt now does so too | Cosmetic | Simplify `edit()` preamble in a future pass |

---

## 3. Code Quality Findings

These are all low severity and deferred from this session:

| Severity | Issue | File | Line | Notes |
|----------|-------|------|------|-------|
| Low | HuggingFace URL not existence-validated before download attempt | `SettingsView.swift` | 419–422 | UX: user gets a confusing error; add basic URL format check |
| Low | Forced unwrap on `AVAudioFormat` init | `AudioCaptureService.swift` | 26, 274 | Crashes if hardware doesn't support 16 kHz mono; rare on Apple Silicon |
| Low | `[weak self]` in `ModelManager` progress closure not guarded with `guard let self` | `ModelManager.swift` | 33, 58 | Not a leak, but could silently drop progress updates if coordinator deallocated |

---

## 4. Prompting Improvement Roadmap

### Completed
- [x] System prompt added (session 3)
- [x] Draft prompt scaffolding strengthened (session 3)
- [x] Universal language fallback for grammar fix (session 3)
- [x] DraftDetector wired into voice-edit flow (session 3)

### Future (post-launch)
- [ ] Fine-tuned model support: app already accepts custom HuggingFace URLs; user uploads fine-tuned models directly
- [ ] Per-language draft prompts for non-English voice commands
- [ ] OutputCleaner: strip "I changed X to Y" narration patterns
- [ ] Consider few-shot examples in edit prompt for very small models (1B)

---

## 5. Distribution Readiness

| Check | Status |
|-------|--------|
| No App Store sandbox required | ✅ Developer ID |
| CGEvent.post accessibility usage declared | ✅ |
| Sparkle SUFeedURL configured | ✅ `https://hitoku.me/appcast.xml` |
| ExportOptions.plist ready | ✅ |
| DISTRIBUTION.md written | ✅ |
| AppleSTT fallback | ❌ Deferred |
| Onboarding UI | ⚠️ Deferred |

**Launch gate:** AppleSTT deferred by design (brief permits). All core flows functional.

---

## 6. Verification Checklist (run before freeze)

- [ ] Voice-edit: text selected + "draft an email thanking John" → uses draft prompt, does NOT echo the phrase
- [ ] Voice-edit: no text selected → still enters draft mode (empty selection path preserved)
- [ ] Voice-edit: text selected + "make this more formal" → uses edit prompt (no draft trigger)
- [ ] Grammar fix: Spanish text → universal fallback fires, not English instructions
- [ ] Grammar fix: Italian text → native Italian instructions fire
- [ ] Build succeeds: `xcodegen generate && xcodebuild build -scheme HitokuDraft`
- [ ] Menu bar icon cycles correctly through all states
- [ ] Clipboard contents restored after voice edit and grammar fix
- [ ] Sparkle update check available in menu
