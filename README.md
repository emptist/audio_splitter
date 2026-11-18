# audio_splitter

Offline Gleam tool that takes a long dialogue mp3 + its transcript, and splits
it into per-turn mp3 clips with a JSON manifest. Uses whisper_cpp word
timestamps + **trigram anchor alignment** — accurate even when whisper
hallucinates text (timestamps come from audio, not text quality).

Generic: works with any `D:`/`P:` speaker-prefix dialogue transcript format.
No dependency on speak_engl or any other domain.

## Requirements

- **ffmpeg** on `PATH` (`brew install ffmpeg`)
- **whisper model** at `~/.cache/whisper/ggml-tiny.bin` (or set `SPEAK_ENGL_WHISPER_MODEL`)
- **Gleam 1.18+** and **Erlang/OTP 28/29**

```sh
mkdir -p ~/.cache/whisper
curl -L -o ~/.cache/whisper/ggml-tiny.bin \
  https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny.bin
```

## Usage

```sh
# Single dialogue
gleam run -m alignment /path/to/dialogue.mp3 /path/to/transcript.txt /path/to/output_dir

# Example
gleam run -m alignment data/GAS0001.mp3 data/GAS0001.txt out/GAS0001
```

### Batch all dialogues (single VM)

```sh
# whisper model loads ONCE and stays cached for ALL dialogues (~5.5h for 272 on CPU)
gleam run -m batch /path/to/assets_dir

# Expected directory layout:
#   assets_dir/audio/*.mp3          — input mp3s
#   assets_dir/transcripts/*.txt    — D:/P: transcripts (UTF-8, UTF-16 LE/BE all supported)
#   assets_dir/split/<dialogue_id>/ — output (one manifest + per-turn mp3 per dialogue)
```

The batch runner skips any dialogue that already has a `manifest.json` in its split
output directory, so it's safe to re-run — it picks up where it left off.

#### Shell loop (fallback — slower, whisper reloads per dialogue)

```sh
for mp3 in data/audio/*.mp3; do
  id=$(basename "$mp3" .mp3)
  txt="data/transcripts/${id}.txt"
  if [ -f "$txt" ]; then
    echo "=== $id ==="
    gleam run -m alignment "$mp3" "$txt" "out/$id"
  fi
done
```

## Output

```
out/GAS0001/
├── turn_0000.mp3      # ffmpeg -c copy lossless extraction
├── turn_0001.mp3
├── ...
└── manifest.json
```

manifest.json:
```json
{
  "dialogue_id": "GAS0001",
  "audio_file": "GAS0001.mp3",
  "duration_s": 570.8,
  "turn_count": 75,
  "turns": [
    {
      "index": 0,
      "role": "D",
      "text": "What brings you in today?",
      "word_count": 5,
      "audio_start_s": 0.0,
      "audio_end_s": 4.8,
      "duration_s": 4.8,
      "audio_path": "turn_0000.mp3"
    }
  ]
}
```

## How alignment works (trigram anchor matching)

Each boundary between transcript turns is a 3-word anchor from the tail of
the previous turn and a 3-word anchor from the head of the next turn. We
combine them into a 6-word search target and slide it through whisper's
timestamped word stream, scoring each position with exact/prefix/fuzzy
matching. This gives a precise boundary timestamp even when whisper
mishears words — timestamps come from audio analysis, not text quality.

See [docs/ALIGNMENT_ALGORITHM.md](docs/ALIGNMENT_ALGORITHM.md) for details.

## Algorithm pipeline

1. **ffmpeg decode** — mp3 → f32le PCM (16kHz mono)
2. **whisper_cpp transcribe** — with `word_timestamps: true`
3. **transcript_parser** — parse `D:`/`P:` format, merge continuation lines
4. **anchor_extractor** — extract 3-word boundary anchors from each turn pair
5. **trigram_alignment** — slide combined 6-word anchors through whisper's
   word stream in a ±5% window, score each position (exact / prefix / fuzzy
   match), return timestamp + Confidence
6. **enforce_monotonic** — append 0.0 and audio_duration edges, enforce
   non-decreasing order with 0.01s minimum gap (handles whisper coarse
   time resolution for rapid-fire exchanges)
7. **clamp_aligned_to_duration** — ensure no turn extends past audio end;
   **guarantees transcript turn count == split count** (never drops turns)
8. **ffmpeg split** — `-ss start -t duration` per turn (lossless, instant)
9. **manifest.json** — written alongside the clips

## Confidence levels

| Level | Meaning | Reliability |
|-------|---------|-------------|
| Exact | Turn[0] only (start=0.0 is always known) | 100% |
| Fuzzy | Trigram match scored ≥1.5 with exact/prefix/fuzzy word matching | ~95% |
| Fallback | Trigram failed — proportional interpolation via whisper_index ratio | ~80% |

**Real results**: GAS0001 (75 turns) — 1 Exact, 70 Fuzzy, 4 Fallback.
CAR0001 (121 turns) — 1 Exact, 118 Fuzzy, 2 Fallback.

## Architecture

```
src/
├── alignment.gleam              # Single-dialogue CLI entry + flat pipeline
├── batch.gleam                  # Batch CLI — single VM, whisper cached, UTF-16 aware
└── alignment/
    ├── dialogue_types.gleam     # Generic Turn/Role
    ├── transcript_parser.gleam  # D:/P: format parser
    ├── shell.gleam              # @external erlang:os:cmd (single source of truth)
    ├── file_io.gleam            # @external erlang:file:* (single source of truth)
    ├── whisper_driver.gleam     # Opaque WhisperModel, word-timestamp decode
    ├── word_matcher.gleam       # Tokenize + exact/prefix/fuzzy per-word matching
    ├── anchor_extractor.gleam   # Extract 3-word boundary anchors + proportional expected whisper_index
    ├── trigram_alignment.gleam  # Slide 6-word anchor through whisper stream, score positions
    ├── aligner.gleam            # Pipeline orchestrator — extract → match → enforce monotonic
    ├── splitter.gleam           # ffmpeg extraction
    └── manifest.gleam           # JSON manifest writer
```

## Transcript encoding support

Transcripts are read as raw bytes and decoded via a pure-Gleam BOM-aware decoder in
`batch.gleam` (one safe BEAM @external: `erlang:binary_to_list`). All common encodings
work without any hand-written Erlang:

| BOM bytes | Encoding | Decoder action |
|-----------|----------|----------------|
| `255, 254` | UTF-16 LE | Pair bytes as `lo + hi * 256` → codepoints |
| `254, 255` | UTF-16 BE | Pair bytes as `hi * 256 + lo` → codepoints |
| `239, 187, 191` | UTF-8 BOM | Strip BOM, use `bit_array.to_string` |
| None | Plain UTF-8 | Use `bit_array.to_string`, fall back to Latin-1 |

The single-dialogue CLI (`alignment.gleam`) uses `file_io.read_text` which assumes
UTF-8. For UTF-16 transcripts, either pre-convert with `iconv` or use `gleam run -m batch`.

## Gleam patterns enforced

- **Opaque types** hide FFI handles (`pub opaque type WhisperModel`)
- **Single @external boundary** — `shell.gleam` has `os_cmd`, `file_io.gleam` has file externals
- **`use x <- result.try(...)`** flattens Result chains — no nested callbacks
- **Typed error propagation** — every fallible function returns `Result(value, error)`
- **Zero compiler warnings** on build
- **Qualified imports everywhere** — no wildcard imports

## Build commands

```sh
gleam build                                # compile (zero warnings expected)
gleam run -m alignment <mp3> <txt> <out>   # single dialogue CLI
gleam run -m batch <assets_dir>            # batch CLI (single VM, whisper cached)
gleam test                                 # run tests
gleam build --warnings-as-errors           # CI gate
gleam export hex-tarball                   # prepare hex package
gleam publish                              # publish to hex.pm
```

## Dependencies

| Package | Purpose |
|---------|---------|
| `gleam_stdlib` | Standard library |
| `gleam_erlang` | Erlang interop (atom, charlist, lists:seq) |
| `gleam_json` | JSON encoding |
| `gleam_regexp` | regex-based tokenization + normalization (by lpil) |
| `edit_distance` | Pure-Gleam levenshtein for fuzzy matching (v3.0.1) |
| `whisper_cpp` | whisper.cpp speech-to-text NIF (>= 0.5.0) |
| `gleeunit` | Test framework (dev only) |

## Version history

- **v1.1.0** — Major upgrade (trigram + batch + UTF-16):
  - Replaced old proportional + silence-gap algorithm with trigram anchor matching.
    Each boundary verified by sliding 3-word tail + 3-word head anchor through
    whisper's word stream. Guaranteed transcript turn count == split count.
    Added `word_matcher`, `anchor_extractor`, `trigram_alignment` modules.
  - New `batch.gleam` CLI — processes all dialogues in one BEAM VM. Whisper
    model loads once and stays cached for the entire batch (~5.5h for 272
    dialogues on CPU). Skips dialogues that already have `manifest.json`.
  - Pure-Gleam UTF-16 BOM-aware transcript decoder (UTF-16 LE/BE, UTF-8 BOM,
    plain UTF-8 all supported). Single safe BEAM @external (`erlang:binary_to_list`).
    No hand-written Erlang code.
  - Fixed `file_exists` helper (was always returning `True`).
  - Added `edit_distance` + `gleam_regexp` deps.
- **v1.0.1** — Initial release: ffmpeg decode, whisper transcribe,
  proportional + silence-gap alignment, per-turn mp3 split, JSON manifest.
