//// Alignment CLI — thin entry point. Just argv parsing + pipeline dispatch.
////
//// Pipeline logic lives in this file but uses `use` + `result.try` so the
//// whole thing is flat, not 6 levels of nested callbacks.
////
//// Usage:
////   gleam run -m alignment <audio.mp3> <transcript.txt> <output_dir>

import gleam/erlang/charlist
import gleam/float
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{None}
import gleam/result
import gleam/string
import alignment/dialogue_types as dialogue_types
import alignment/transcript_parser
import alignment/whisper_driver as whisper
import alignment/aligner
import alignment/splitter
import alignment/manifest
import alignment/shell.{os_cmd, shell_quote}
import alignment/file_io

pub fn main() -> Nil {
  let args = cli_argv()
  case args {
    [audio, transcript, output] -> run_pipeline(audio, transcript, output)
    _ -> print_usage()
  }
}

fn print_usage() -> Nil {
  io.println("Usage: gleam run -m alignment <audio.mp3> <transcript.txt> <output_dir>")
  io.println("  e.g. gleam run -m alignment assets/audio/GAS0001.mp3 \\")
  io.println("                             assets/transcripts/GAS0001.txt \\")
  io.println("                             assets/split/GAS0001")
}

// ── Pipeline (flat, via `use` + result.try) ────────────────────────────────

fn run_pipeline(audio_path: String, transcript_path: String, output_dir: String) -> Nil {
  io.println("╔══ Alignment Pipeline ══")
  io.println("║  Audio:      " <> audio_path)
  io.println("║  Transcript: " <> transcript_path)
  io.println("║  Output:     " <> output_dir)
  io.println("╚════════════════════════╝")

  case run(audio_path, transcript_path, output_dir) {
    Ok(_) -> Nil
    Error(msg) -> io.println("❌ " <> msg)
  }
}

fn run(audio_path: String, transcript_path: String, output_dir: String) -> Result(Nil, String) {
  let dialogue_id = extract_id(transcript_path)

  // 1. Read transcript
  io.println("[1/6] Reading transcript...")
  use raw <- result.try(file_io.read_text(transcript_path)
    |> result.map_error(fn(e) { "transcript read: " <> describe_file_error(e) }))
  let turns = transcript_parser.parse_transcript(raw)
  io.println("  " <> int.to_string(list.length(turns)) <> " turns parsed")

  // 2. Decode mp3 → PCM via ffmpeg
  io.println("[2/6] Decoding mp3 → PCM...")
  let pcm_path = audio_path <> ".pcm"
  use _ <- result.try(decode_mp3_to_pcm(audio_path, pcm_path))
  io.println("  PCM ready")

  // 3. Transcribe with whisper
  io.println("[3/6] Whisper transcription...")
  use pcm <- result.try(file_io.read_binary(pcm_path)
    |> result.map_error(fn(e) { "pcm read: " <> describe_file_error(e) }))
  let opts = whisper.WhisperOpts(
    language: "en",
    word_timestamps: True,
    beam_size: 2,
    n_threads: 4,
    initial_prompt: None,
  )
  use transcription <- result.try(whisper.transcribe_pcm(pcm, opts)
    |> result.map_error(fn(e) { "whisper: " <> describe_whisper_error(e) }))
  let all_words = aligner.transcription_words(transcription)
  io.println("  " <> int.to_string(list.length(all_words)) <> " word timestamps")

  // 4. Align turns to timestamps
  io.println("[4/6] Aligning...")
  use aligned <- result.try(aligner.align_turns(turns, all_words, transcription.duration_s)
    |> result.map_error(fn(e) { "aligner: " <> describe_align_error(e) }))
  io.println("  " <> int.to_string(list.length(aligned)) <> " turns aligned")
  list.each(aligned, print_aligned_turn)

  // 5. Split mp3 per turn
  io.println("[5/6] Splitting mp3...")
  use _ <- result.try(file_io.make_dir(output_dir)
    |> result.map_error(fn(e) { "mkdir: " <> describe_file_error(e) }))
  let split_tasks = list.map(aligned, fn(t) {
    #(t.audio_start_s, t.audio_end_s, output_dir <> "/" <> turn_filename(t.index))
  })
  use _ <- result.try(splitter.batch_split(audio_path, split_tasks)
    |> result.map_error(fn(e) { describe_splitter_error(e) }))

  // 6. Write manifest
  io.println("[6/6] Writing manifest.json...")
  use manifest_path <- result.try(manifest.write_manifest(
    dialogue_id,
    filename_from_path(audio_path),
    filename_from_path(transcript_path),
    transcription.duration_s,
    aligned,
    output_dir,
  ) |> result.map_error(fn(e) { "manifest write: " <> describe_file_error(e) }))
  io.println("  → " <> manifest_path)

  // Clean up PCM temp file
  let _ = file_io.delete_path(pcm_path)

  io.println("✓ Done → " <> output_dir)
  Ok(Nil)
}

// ── Helpers ───────────────────────────────────────────────────────────────

@external(erlang, "init", "get_plain_arguments")
fn init_get_plain_arguments() -> List(charlist.Charlist)

fn cli_argv() -> List(String) {
  init_get_plain_arguments() |> list.map(charlist.to_string)
}

fn decode_mp3_to_pcm(input: String, output: String) -> Result(Nil, String) {
  let cmd =
    "ffmpeg -hide_banner -loglevel error -y -i " <> shell_quote(input) <>
    " -f f32le -ac 1 -ar 16000 " <> shell_quote(output) <> " 2>&1"
  let result = os_cmd(charlist.from_string(cmd)) |> charlist.to_string
  case result {
    "" -> Ok(Nil)
    _ -> Error(result)
  }
}

fn extract_id(path: String) -> String {
  let base = filename_from_path(path)
  case string.split(base, ".") {
    [id, _] -> id
    _ -> base
  }
}

fn filename_from_path(path: String) -> String {
  let parts = string.split(path, "/")
  case list.last(parts) {
    Ok(name) -> name
    Error(_) -> path
  }
}

fn role_letter(role: dialogue_types.Role) -> String {
  case role {
    dialogue_types.Doctor -> "D"
    dialogue_types.Patient -> "P"
  }
}

fn turn_filename(index: Int) -> String {
  let s = int.to_string(index)
  case string.length(s) {
    4 -> "turn_" <> s <> ".mp3"
    n if n < 4 -> "turn_" <> string.repeat("0", 4 - n) <> s <> ".mp3"
    _ -> "turn_" <> s <> ".mp3"
  }
}

fn print_aligned_turn(t: aligner.AlignedTurn) -> Nil {
  let dur = t.audio_end_s -. t.audio_start_s
  let preview = string.slice(t.text, 0, 40)
  io.println(
    "    [" <> int.to_string(t.index) <> "] " <> role_letter(t.role) <> " " <>
    float.to_string(t.audio_start_s) <> "s–" <>
    float.to_string(t.audio_end_s) <> "s (" <>
    float.to_string(dur) <> "s)  " <> preview,
  )
}

// ── Error describers ───────────────────────────────────────────────────────

fn describe_whisper_error(e: whisper.WhisperError) -> String {
  case e {
    whisper.ModelLoadFailed(m) -> "ModelLoadFailed: " <> m
    whisper.TranscribeFailed(m) -> "TranscribeFailed: " <> m
    whisper.DecodeFailed(m) -> "DecodeFailed: " <> m
  }
}

fn describe_align_error(e: aligner.AlignError) -> String {
  case e {
    aligner.NoWordTimestamps -> "whisper returned no word timestamps"
    aligner.EmptyTranscript -> "transcript is empty"
    aligner.ComputationFailed(m) -> "ComputationFailed: " <> m
  }
}

fn describe_splitter_error(e: splitter.SplitterError) -> String {
  case e { splitter.SplitFailed(m) -> m }
}

fn describe_file_error(e: file_io.FileError) -> String {
  case e {
    file_io.NotFound -> "not found"
    file_io.PermissionDenied -> "permission denied"
    file_io.DecodeFailed -> "decode failed"
    file_io.Unknown(m) -> m
  }
}
