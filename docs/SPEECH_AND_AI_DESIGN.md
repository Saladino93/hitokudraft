# Speech and AI Design

Design decisions for how Hitoku Draft turns voice into text and routes it to the
AI model. This is the reference for the dictation, voice command, gating, and
file transcription behavior. Keep it updated when these flows change.

Style note: no em dashes in user-facing copy or in this doc.

## Core actions

| Action | Default shortcut | What it does |
|--------|------------------|--------------|
| Dictate | Ctrl+S | Speech to text, typed at the cursor. Press to start, press again or just stop talking to finish. |
| Edit or ask with voice | Ctrl+Z | Voice command. With text selected, edit it. With nothing selected, ask a question. Press again to stop. |
| Tool use | Ctrl+A | Voice command that triggers a tool (calendar, web search, and similar). |

Shortcuts are user customizable. The Help tab reads them live so its text always
matches the current bindings.

## Capability rule (single source of truth)

Speech input needs a transcriber: either a dedicated STT model, or an
audio-capable LLM (Gemma 4 family). If neither is available for the requested
action, the action is unavailable and says so plainly. No silent failure.

## Dictation (Ctrl+S)

Dictation always produces verbatim text through a dedicated STT.

- It never routes through the LLM for transcription. Verbatim accuracy, low
  latency, and live preview are what matter for dictation, and a purpose built
  ASR (Parakeet, WhisperKit, MLX) is the right tool.
- If Active STT is set to None, dictation loads a default speech model on demand.
  So "None" never blocks dictation.

## Voice command (Ctrl+Z and Ctrl+A)

A voice command always becomes an instruction the model can act on. There are two
cases, decided by whether a dedicated STT is loaded.

### Case A: STT loaded

The STT transcribes the spoken command to text. That text, plus any screen
context, is fed to Gemma as a normal text request.

- Gate (code side): if the transcript is empty or too short to be a real command
  (silence, a cough, background noise), the model is not called and nothing is
  pasted. This is deterministic and reliable.
- This means Ctrl+Z/Ctrl+A use the STT transcript as text, not Gemma audio-direct,
  whenever an STT is loaded. We trade a little audio nuance for reliability and a
  free, trustworthy gate.

### Case B: No STT loaded (audio-capable LLM only)

A single call sends the audio (plus any screen context) straight to Gemma, with
an extra system prompt that tells the model what to do, including how to handle an
empty command. One round trip. No separate transcription pass, no feeding results
back in.

- The extra system prompt instructs Gemma to perform the task only if the audio
  contains a clear instruction, and otherwise to output a sentinel such as
  `NOOP` and nothing else.
- Gate (model side): the code treats `NOOP` (or empty output) as "nothing to act
  on" and does nothing, so the model can never echo the screen and paste it.
- Tradeoff: the model side gate depends on the model following the instruction, so
  it is less strict than the code side gate in Case A. That is acceptable for the
  No STT fallback, and it keeps the flow to one call.

### The gate principle

Every Ctrl+Z / Ctrl+A invocation must confirm there is a real instruction before
acting. Case A confirms it from the transcript (code side). Case B confirms it
from the model via the system prompt (model side).

## Screen context

Off, Standard (reads some on-screen text), or Advanced (adds OCR). Beta. Works
best for translating or summarizing visible text. Results can vary, so it is
labeled accordingly and is not the headline feature.

## File transcription

The Transcribe window decodes a file to 16 kHz mono, splits it into chunks, and
transcribes each chunk.

- Default transcriber: the loaded dedicated STT. Fast and verbatim.
- Option: use the AI model (Gemma) as the transcriber. Gemma is strong on mixed
  and many languages, so this is the better choice for multilingual material. It
  is slower than a dedicated ASR.
- Selectable per job in the Transcribe window.
- Implementation: per chunk, send the chunk audio to Gemma with a verbatim
  transcription system prompt ("Transcribe verbatim, output only the
  transcription"), then join the chunks. Backed by an STTService-conforming
  wrapper around the LLM so the rest of the transcription flow is unchanged.

## Instrumentation (falsifiability)

Each Voice Edit interaction log records what the model was given and how long each
phase took, so a bad result is diagnosable rather than spooky:

- Context: the exact screen-context text block, its source, the mode, and whether a
  screenshot was sent.
- Model: the model name and backend (mlx or litert).
- Latency split (ms): context capture, final speech transcription, time to first
  token, full model generation, insertion, and total (hotkey to result).

Logs live in `~/Library/Application Support/HitokuDraft/transcriptions/`, one JSON
per interaction. A future step is to surface this on screen for demos.

## Rationale summary

- Dictation is verbatim and latency sensitive, so it uses dedicated ASR.
- Voice commands are short instructions, so the text path (STT transcript to
  Gemma) is reliable and gives a free gate. Audio-direct is kept only as the No
  STT fallback, guarded by a model side gate in a single call.
- File transcription gains a Gemma option for multilingual quality, while keeping
  the fast dedicated STT as the default.

## Status

- [x] Case A: STT-loaded voice commands use the text path (STT transcript to
      Gemma), gated by the transcript word-count check. Audio-direct is no longer
      used when an STT is available.
- [x] Case B: No STT plus audio-capable model uses one audio-direct call with a
      NOOP system-prompt gate; NOOP or empty output does nothing.
- [x] File transcription: optional Gemma transcriber (`LLMTranscriptionSTT`),
      selectable in the Transcribe window when the selected LLM has audio.
