# Alignment algorithm — why silence-gap + proportional

Proven on GAS0001 (9.5 min, 75 D/P turns, ggml-tiny on Metal ~17s).

## The problem

Long medical dialogue mp3s (5–10 min) need to be split into per-turn audio
clips. We have the transcript. We want real audio per phrase, not TTS.

## Why NOT text matching

Whisper ggml-tiny hallucinates text: "nagging"→"nauseated", "worship"→"worse".
You can't reliably align transcript text to whisper text with LCS, Jaccard,
or sequential word counting — they all drift when whisper mishears.

## Why silence-gap + proportional works

Whisper's **word timestamps come from audio analysis**, not text decoding.
The AUDIO knows exactly where each word is, regardless of what whisper
thinks it heard.

### Algorithm

1. **ffmpeg decode** mp3 → f32le PCM (16kHz mono)
2. **whisper_cpp transcribe** with `word_timestamps: true`
3. **transcript_parser** → `[{Turn(index, role, text), word_count}]`
4. **aligner** core math:
   a. **Find silence gaps** — for consecutive whisper words, if `gap > 300ms`
      → record a gap. 143 gaps found in GAS0001, 46 >600ms.
      D/P transitions naturally cluster here.
   b. **Proportional boundary estimation** — compute expected time for
      each turn boundary:
      ```
      boundary[i] = first_word_start
        + (cumulative_transcript_words[i] / total_transcript_words)
          × (total_whisper_words / total_transcript_words)
          × effective_duration
      ```
      The whisper_ratio corrects for whisper producing ±5% more/fewer words
      than the transcript.
   c. **Snap to silence** — for each expected boundary, pick the LARGEST
      silence gap within ±3s window.
   d. **Monotonic enforcement** — pad edges (0.0 and audio_end), enforce
      strictly increasing order, min 50ms between boundaries.
5. **ffmpeg split** — `-ss start -to end -c copy` per turn (lossless frame-accurate)
6. **manifest.json** — per-turn audio_path, timestamps, role, text, word_count

### Results on GAS0001

- 1065 transcript words → 1110 whisper words (0.98 ratio — sequential feasible)
- 75 turns aligned
- 143 silence gaps >300ms, 46 >600ms
- whisper ggml-tiny: ~17s decode on Metal
- whisper ggml-base: ~30s (144 MB, better word-timestamp accuracy)

## Whisper model gotcha

`~/.cache/whisper/ggml-base.bin` (144 MB) was corrupted in this dev env — a 9-byte
text placeholder, not the real model. whisper_cpp returns `ModelLoadFailed: bad magic`.
The fix:
```sh
curl -L -o ~/.cache/whisper/ggml-base.bin \
  https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin
```

The default fallback is `ggml-tiny.bin` (74 MB, verified working).
Set `SPEAK_ENGL_WHISPER_MODEL=/path/to/model.bin` to override.

## Known limitations

- whisper word_timestamps are experimental — "may not be perfectly accurate"
- very quiet speech → gaps detected where there aren't D/P transitions
- consecutive fast D/D or P/P turns with no silence between will be merged
  (boundary snaps to the nearest gap, which may be before or after the
  real turn boundary)
- `word_timestamps: true` doubles transcribe time
