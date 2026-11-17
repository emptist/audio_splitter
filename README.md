# audio_splitter

Offline Gleam tool that takes a long dialogue mp3 + its transcript, and splits
it into per-turn mp3 clips with a JSON manifest. Uses whisper_cpp word
timestamps + silence-gap alignment — accurate even when whisper hallucinates
text (timestamps come from audio, not text quality).

Generic: works with any D:/P: speaker-prefix dialogue transcript format.
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

### Batch all dialogues

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
  "duration_s": 565.2,
  "turn_count": 75,
  "turns": [
    {
      "index": 0,
      "role": "D",
      "text": "What brings you in today?",
      "word_count": 7,
      "audio_start_s": 0.42,
      "audio_end_s": 3.15,
      "duration_s": 2.73,
      "audio_path": "turn_0000.mp3"
    }
  ]
}
```

## How alignment works

1. **ffmpeg decode** — mp3 → f32le PCM (16kHz mono)
2. **whisper_cpp transcribe** — with `word_timestamps: true`
3. **transcript_parser** — parse D:/P: format, merge continuation lines
4. **aligner** — find silence gaps >300ms; distribute expected boundaries
   proportionally to cumulative word position; snap each boundary to the
   largest silence gap within ±3s window; enforce monotonic order
5. **ffmpeg split** — `-ss start -to end -c copy` per turn (lossless, instant)
6. **manifest.json** — written alongside the clips

Why silence-gap matching works when whisper hallucinates text: whisper's
word timestamps come from audio analysis, not text decoding quality. If
whisper says "nagging" but the transcript says "nauseated", the timestamps
for that position are still correct.

## Architecture

```
src/
├── alignment.gleam              # CLI entry + flat pipeline via `use`
└── alignment/
    ├── dialogue_types.gleam     # Generic Turn/Role
    ├── transcript_parser.gleam # D:/P: format parser
    ├── shell.gleam              # @external erlang:os:cmd (single source of truth)
    ├── file_io.gleam            # @external erlang:file:* (single source of truth)
    ├── whisper_driver.gleam     # Opaque WhisperModel, word-timestamp decode
    ├── aligner.gleam            # Pure math — silence-gap + proportional match
    ├── splitter.gleam           # ffmpeg -c copy lossless extraction
    └── manifest.gleam           # JSON manifest writer
```

## Gleam patterns enforced

- **Opaque types** hide FFI handles (`pub opaque type WhisperModel`)
- **Single @external boundary** — `shell.gleam` has `os_cmd`, `file_io.gleam` has file externals
- **`use x <- result.try(...)`** flattens Result chains — no nested callbacks
- **Typed error propagation** — every fallible function returns `Result(value, error)`
- **Zero compiler warnings** on build
- **Qualified imports everywhere** — no wildcard imports

## Build commands

```sh
gleam build                          # compile (zero warnings expected)
gleam run -m alignment <mp3> <txt> <out>   # run the tool
gleam test                           # run tests
gleam build --warnings-as-errors     # CI gate
```

## Dependencies

| Package | Purpose |
|---------|---------|
| `gleam_stdlib` | Standard library |
| `gleam_erlang` | Erlang interop (atom, charlist) |
| `gleam_json` | JSON encoding |
| `whisper_cpp` | whisper.cpp speech-to-text NIF (>= 0.5.0) |
| `gleeunit` | Test framework (dev only) |
