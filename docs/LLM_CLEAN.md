MEMORY FOOTPRINT UTLITY -> WHEN CHOOSING A MODEL, IT TELLS YOU...
MODEL AGNOSTIC, SOME GENERAL WRAPPER
REMEMBER TO CLEAN UP TEXT AND OUTPUT OF MODELS

 You are working on a Swift MLX app that runs on-device LLM
  inference and
  post-processes the generated text before displaying or using it.

  Implement a single Swift function called `cleanModelOutput` that
   robustly
  strips known generation artifacts from raw LLM text output. The
  function must
  handle all of the following cases, applied in this exact order:

  1. THINKING BLOCKS — complete or empty
     Remove any content enclosed between a think-open and
  think-close tag,
     including the tags themselves and any surrounding whitespace.
     Tag variants to handle (case-insensitive):
       <think>, <thinking>, <|think|>, <|thinking|>
     Corresponding close variants: </think>, </thinking>,
  <|/think|>, <|/thinking|>
     Example input:  "<think>\nsome reasoning\n</think>\nActual
  answer."
     Expected output: "Actual answer."

  2. UNCLOSED THINKING BLOCKS — generation was cut off mid-thought
     If a think-open tag exists with no matching close tag, remove
   everything
     from the open tag to the end of the string (the answer never
  arrived).
     Example input:  "Some prefix\n<think>\nreasoning that never
  ends..."
     Expected output: "Some prefix" (or empty string if the open
  tag is at start)

  3. END-OF-TURN / SPECIAL TOKENS
     Remove all occurrences of model-specific delimiter tokens
  that leaked into
     the output. Strip these tokens and any content that follows
  the first
     occurrence (since models typically hallucinate garbage after
  their EOS token).
     Tokens to handle:
       <end_of_turn>, <|end_of_turn|>, <|im_end|>, <|eot_id|>,
  [INST], [/INST],
       </s>, <|endoftext|>
     Example input:  "Good
  answer.<end_of_turn>\n<end_of_turn>\ngarbage text"
     Expected output: "Good answer."

  4. FINAL CLEANUP
     After all removals: strip leading/trailing whitespace, then
  collapse any
     run of 3 or more consecutive newlines to exactly two
  newlines.

  Function signature:
      func cleanModelOutput(_ text: String) -> String

  Requirements:
  - Use Swift's built-in `NSRegularExpression` or `Regex`
  (whichever is
    appropriate for the minimum deployment target you choose —
  state your choice).
  - All patterns must be compiled once (e.g., as static/lazy
  constants),
    not constructed inside the function body.
  - The function must be pure: given the same input it always
  returns the
    same output, with no side effects.
  - A perfectly clean input (no artifacts present) must pass
  through unchanged
    except for outer whitespace trimming.
  - Include a brief comment above each step explaining what it
  handles.
  - Do NOT write unit tests — only the function and its supporting
   constants.

