# Alignment algorithm — trigram anchor matching

Replaced the old **proportional + silence-gap** algorithm in v1.1.0.
Proven on GAS0001 (9.5 min, 75 D/P turns) and CAR0001 (10.4 min, 121 D/P turns).

## The problem

Long medical dialogue mp3s (5–10 min) need to be split into per-turn audio
clips. We have the transcript. We want real audio per phrase, not TTS.

Old approach ("silence-gap + proportional") failed because:
- Whisper tiny model reports many rapid-fire words at **identical float
  timestamps** (no silence gap detectable between "No." → "Yes." → "No.")
- D/D or P/P consecutive turns with no silence between → boundary snaps to
  wrong gap
- Could not guarantee transcript_turn_count == split_count

## Why NOT text matching

Whisper ggml-tiny hallucinates text: "nagging"→"nauseated", "worship"→"worse".
You can't reliably align transcript text to whisper text with LCS, Jaccard,
or sequential word counting — they all drift when whisper mishears.

## Why trigram anchor matching works

Whisper's **word timestamps come from audio analysis**, not text decoding.
The AUDIO knows exactly where each word is, regardless of what whisper
thinks it heard.

A **trigram anchor** is 3 words — the tail of turn N + the head of turn N+1 —
combined into a 6-word search target that is unique enough to match
unambiguously, even when whisper mishears 1-2 words.

### Algorithm

1. **ffmpeg decode** mp3 → f32le PCM (16kHz mono)
2. **whisper_cpp transcribe** with `word_timestamps: true`
3. **transcript_parser** → `[{Turn(index, role, text), word_count}]`
4. **anchor_extractor** — for each boundary between turn[i] and turn[i+1]:
   ```
   last_tokens  = last 3 words of turn[i]   e.g. ["sick", "at", "all"]
   first_tokens = first 3 words of turn[i+1] e.g. ["ok", "have", "you"]
   expected_whisper_index = proportional position in whisper word stream
                            (turn boundary word / total transcript words
                             × total whisper words)
   ```
5. **trigram_alignment** — for each anchor:
   - Search window: `expected ± 5%` of total whisper words
   - Slide combined 6-word target through whisper's timestamped word stream
   - Score each position with word_matcher (per-word scoring):
     - **ExactMatch** (1.0): word matches exactly after normalize (lowercase, strip punctuation)
     - **PrefixMatch** (0.8): whisper word is a prefix of transcript word
       (whisper truncated "sensa" for "sensation")
     - **FuzzyMatch** (0.5): jaro-distance ≥ 0.8 between transcript and whisper
       (whisper "nagging" vs transcript "nauseated")
     - **NoMatch** (0.0): word doesn't match
   - Total score ≥ 1.5 → accept this position as boundary timestamp
   - Total score < 1.5 → mark as **Fallback** (proportional estimate via
     whisper_index interpolation)
6. **enforce_monotonic** — append 0.0 and audio_duration edges, enforce
   non-decreasing order with 0.01s minimum gap:
   ```
   adjusted[v] = max(v, last + 0.01)
   ```
   The tiny gap handles whisper's coarse time resolution — when multiple
   boundary anchors collapse to the same float timestamp, we push them 10ms
   apart instead of creating zero-duration pairs.
7. **clamp_aligned_to_duration** — clip any boundary past audio end.
   **GUARANTEES transcript turn count == split count** by design — we never
   drop a turn; if clamping would zero it we expand to `min_turn_gap` instead.
8. **ffmpeg split** — `-ss start -t duration` per turn
9. **manifest.json** — per-turn audio_path, timestamps, role, text

### Word matching details

Normalization:
```
normalize = string.lowercase
          |> regex_replace(re: /[^a-z0-9]/, with: "")  # strip punctuation
```

Fuzzy match uses **Jaro-Winkler distance** via Elixir's built-in
`String.jaro_distance` (single `@external(erlang, "Elixir.String", "jaro_distance")`).

Edit distance uses the `edit_distance` hex.pm package (v3.0.1, pure Gleam).

### Results

| Dialogue | Turns | Whisper words | Exact | Fuzzy | Fallback |
|----------|-------|---------------|-------|-------|----------|
| GAS0001 | 75 | 1083 | 1 | 70 | 4 |
| CAR0001 | 121 | 1032 | 1 | 118 | 2 |

Both guarantee: **transcript turns == MP3 splits**.

## Whisper model gotchas

- Default: `~/.cache/whisper/ggml-tiny.bin` (74 MB, verified working)
- `ggml-base.bin` (144 MB) was once corrupted in dev env — a 9-byte text
  placeholder. Fix:
  ```sh
  curl -L -o ~/.cache/whisper/ggml-base.bin \
    https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin
  ```
- Set `SPEAK_ENGL_WHISPER_MODEL=/path/to/model.bin` to override
- **Metal crashes** — force CPU backend via whisper_cpp config on Apple Silicon
- `word_timestamps: true` doubles transcribe time
- whisper tiny model has coarse time resolution for rapid-fire exchanges —
  many word timestamps come back as identical floats (handled by the 0.01s
  min_boundary_gap in enforce_monotonic)

## Known limitations

- whisper word_timestamps are experimental — "may not be perfectly accurate"
- Fallback boundaries (~2-5%) are proportional estimates, not trigram-matched
- Very low-confidence Fallback boundaries may need manual review
- Rapid-fire exchanges (7 quick questions) cascade spread by 0.01s each —
  total 70ms, realistic for spoken dialogue
- `word_timestamps: true` doubles transcribe time

## Module map

```
src/alignment/
├── word_matcher.gleam         # Tokenize + exact/prefix/fuzzy per-word matching
├── anchor_extractor.gleam     # Turn list → BoundaryAnchor list (3-word tail/head)
├── trigram_alignment.gleam    # Slide 6-word anchors through whisper stream, score
├── whisper_driver.gleam       # Word timestamps from whisper_cpp
├── aligner.gleam              # Pipeline orchestrator
├── splitter.gleam             # ffmpeg extraction
└── manifest.gleam             # JSON writer
```
