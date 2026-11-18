//// Batch runner — processes MP3s in one BEAM VM with bounded batches.
////
//// whisper_driver caches the model in persistent_term, so it loads ONCE
//// and stays resident for the whole batch — ~10s saved per dialogue vs
//// spawning `gleam run` N times.
////
//// Usage:
////   gleam run -m audio_splitter/batch <assets_dir> [--limit N]
////   gleam run -m audio_splitter/batch --limit 10 <assets_dir>
////   gleam run -m audio_splitter/batch <assets_dir> --limit 10
////
////   --limit N  Process at most N NEW (not yet done) dialogues, then exit.
////              Already-done dialogues are skipped and do NOT count.
////              Omitting --limit processes all remaining (unbounded).
////
////   dir layout:
////     assets_dir/audio/*.mp3
////     assets_dir/transcripts/*.txt
////     assets_dir/split/<dialogue_id>/turn_NNNN.mp3  ← output

import gleam/bit_array
import gleam/erlang/charlist
import gleam/float
import gleam/int
import gleam/io
import gleam/list
import gleam/result
import gleam/string
import audio_splitter/dialogue_types as dialogue_types
import audio_splitter/transcript_parser
import audio_splitter/whisper_driver as whisper
import audio_splitter/aligner
import audio_splitter/trigram_alignment as trigram
import audio_splitter/splitter
import audio_splitter/manifest
import audio_splitter/shell.{os_cmd, shell_quote}
import audio_splitter/file_io

// ── BEAM externals ──────────────────────────────────────────────────────

@external(erlang, "filelib", "fold_files")
fn fold_files(
  dir: String,
  pattern: String,
  recursive: Bool,
  func: fn(String, List(String)) -> List(String),
  acc: List(String),
) -> List(String)

@external(erlang, "lists", "seq")
fn lists_seq(from: Int, to: Int) -> List(Int)

/// erlang:binary_to_list — zero-risk identity mapping.
/// Converts a binary (BitArray) to a list of raw bytes (0-255).
/// Never fails — returns List(Int) for any binary input.
@external(erlang, "erlang", "binary_to_list")
fn binary_to_list(binary: BitArray) -> List(Int)

@external(erlang, "erlang", "monotonic_time")
fn monotonic_time() -> Int

// ── Types ───────────────────────────────────────────────────────────────

type DialogueStats {
  DialogueStats(mp3_count: Int, exact: Int, fuzzy: Int, fallback: Int)
}

type BatchState {
  BatchState(
    total: Int,
    ok_count: Int,
    fail_count: Int,
    skip_count: Int,
    exact_total: Int,
    fuzzy_total: Int,
    fallback_total: Int,
    fallback_dialogues: List(#(String, Int)),
    fail_details: List(String),
  )
}

// ── Entry point ─────────────────────────────────────────────────────────

pub fn main() -> Nil {
  let args = init_get_plain_arguments() |> list.map(charlist.to_string)
  case parse_args(args) {
    Ok(#(dir, limit)) -> run_batch(dir, limit)
    Error(msg) -> io.println(msg)
  }
}

@external(erlang, "init", "get_plain_arguments")
fn init_get_plain_arguments() -> List(charlist.Charlist)

/// Parse CLI args: accepts assets_dir anywhere, and --limit N in any order.
/// Valid forms:
///   <dir>                           → limit = 0 (unbounded)
///   <dir> --limit 10                → limit = 10
///   --limit 10 <dir>                → limit = 10
///   <dir> --limit=10                → limit = 10
fn parse_args(args: List(String)) -> Result(#(String, Int), String) {
  parse_args_loop(args, "", 0)
}

fn parse_args_loop(args: List(String), dir: String, limit: Int) -> Result(#(String, Int), String) {
  case args {
    [] -> case dir {
      "" -> Error("Usage: gleam run -m audio_splitter/batch <assets_dir> [--limit N]")
      _ -> Ok(#(dir, limit))
    }
    [head, ..tail] -> case head {
      "--limit" -> case tail {
        [n_str, ..rest] -> case int.parse(n_str) {
          Ok(n) -> parse_args_loop(rest, dir, n)
          Error(_) -> Error("--limit requires an integer, got: " <> n_str)
        }
        _ -> Error("--limit requires an argument")
      }
      other -> case string.starts_with(other, "--limit=") {
        True -> case int.parse(string.drop_start(other, 8)) {
          Ok(n) -> parse_args_loop(tail, dir, n)
          Error(_) -> Error("--limit= requires an integer")
        }
        False -> case string.starts_with(other, "-") {
          True -> Error("Unknown flag: " <> other)
          False -> case dir {
            "" -> parse_args_loop(tail, other, limit)
            _ -> Error("Unexpected argument: " <> other <> " (assets_dir already given)")
          }
        }
      }
    }
  }
}

// ── Batch runner ─────────────────────────────────────────────────────────

fn run_batch(assets_dir: String, limit: Int) -> Nil {
  let audio_dir = assets_dir <> "/audio"
  let txt_dir = assets_dir <> "/transcripts"
  let split_dir = assets_dir <> "/split"

  let all_mp3s = collect_files(audio_dir, "mp3")
  let all_mp3s = list.sort(all_mp3s, string.compare)
  let total = list.length(all_mp3s)

  // Pre-scan: find pending (not yet done, has transcript)
  let pending_ids = list.filter_map(all_mp3s, fn(mp3) {
    let id = extract_id(mp3)
    let out_path = split_dir <> "/" <> id
    let txt_path = txt_dir <> "/" <> id <> ".txt"
    case !is_already_done(out_path) && file_exists(txt_path) {
      True -> Ok(id)
      False -> Error(Nil)
    }
  })
  let pending = list.map(pending_ids, fn(id) {
    let mp3 = audio_dir <> "/" <> id <> ".mp3"
    #(mp3, id)
  })

  let already_done = total - list.length(pending)
  let remaining = list.length(pending)
  let to_process = case limit <= 0 {
    True -> remaining
    False -> int.min(limit, remaining)
  }
  let will_process = list.take(pending, to_process)

  let limit_label = case limit <= 0 {
    True -> "unbounded"
    False -> int.to_string(limit)
  }

  io.println("╔══════════════════════════════════════════════════════╗")
  io.println("║  BATCH audio_splitter                                 ║")
  io.println("║  Audio:      " <> audio_dir)
  io.println("║  Transcripts: " <> txt_dir)
  io.println("║  Output:     " <> split_dir)
  io.println("║  Limit:      " <> limit_label)
  io.println("╚══════════════════════════════════════════════════════╝")
  io.println("Found  " <> int.to_string(total) <> " MP3s total")
  io.println("  ✅ already done:  " <> int.to_string(already_done))
  io.println("  🆕 remaining:     " <> int.to_string(remaining))
  case limit <= 0 {
    True -> io.println("  → will process ALL " <> int.to_string(remaining) <> " (unbounded, use --limit N to bound)")
    False -> case to_process == remaining {
      True -> io.println("  → will process all " <> int.to_string(to_process) <> " (limit covers everything)")
      False -> io.println("  → will process " <> int.to_string(to_process) <> " of " <> int.to_string(remaining) <> " (limit=" <> int.to_string(limit) <> ")")
    }
  }
  io.println("")

  let _ = file_io.make_dir(split_dir)

  let indices = lists_seq(1, to_process)
  let with_index = list.zip(will_process, indices)

  let initial = BatchState(
    total: total,
    ok_count: 0,
    fail_count: 0,
    skip_count: 0,
    exact_total: 0,
    fuzzy_total: 0,
    fallback_total: 0,
    fallback_dialogues: [],
    fail_details: [],
  )

  let final_state = list.fold(with_index, initial, fn(state, pair) {
    let #(#(mp3_path, dialogue_id), idx) = pair
    let txt_path = txt_dir <> "/" <> dialogue_id <> ".txt"
    let out_path = split_dir <> "/" <> dialogue_id
    let tag = "[" <> int.to_string(idx) <> "/" <> int.to_string(to_process) <> "] " <> dialogue_id

    run_pipeline(state, mp3_path, txt_path, out_path, dialogue_id, tag)
  })

  print_summary(final_state, to_process, remaining, already_done)
}

fn run_pipeline(
  state: BatchState,
  audio_path: String,
  transcript_path: String,
  output_dir: String,
  dialogue_id: String,
  tag: String,
) -> BatchState {
  let t0 = monotonic_time()

  let result = process_one(audio_path, transcript_path, output_dir)

  let elapsed_ms = int.divide(monotonic_time() - t0, 1_000_000) |> result.unwrap(0)
  // Convert ms seconds. float.from_int doesn't exist in Gleam 1.19,
  // so we compute with integer division for seconds display.
  let elapsed_s = int.divide(elapsed_ms, 1000) |> result.unwrap(0)

  case result {
    Ok(stats) -> {
      let transcript_count = count_transcript_turns(transcript_path)
      case stats.mp3_count == transcript_count {
        False -> {
          io.println(
            tag <> " → FAIL: turn_count=" <> int.to_string(transcript_count) <>
            " but mp3_count=" <> int.to_string(stats.mp3_count),
          )
          BatchState(
            ..state,
            fail_count: state.fail_count + 1,
            fail_details: [dialogue_id <> ": count mismatch", ..state.fail_details],
          )
        }
        True -> {
          let state = BatchState(
            ..state,
            ok_count: state.ok_count + 1,
            exact_total: state.exact_total + stats.exact,
            fuzzy_total: state.fuzzy_total + stats.fuzzy,
            fallback_total: state.fallback_total + stats.fallback,
          )

          let state = case stats.fallback > 0 {
            True -> BatchState(
              ..state,
              fallback_dialogues: [#(dialogue_id, stats.fallback), ..state.fallback_dialogues],
            )
            False -> state
          }

          case stats.fallback > 0 {
            True -> io.println(
              tag <> " → OK (" <> format_s(elapsed_s) <> "s) ⚠️ " <>
              int.to_string(stats.fallback) <> " fb — " <>
              int.to_string(stats.mp3_count) <> " mp3s",
            )
            False -> io.println(
              tag <> " → OK (" <> format_s(elapsed_s) <> "s) — " <>
              int.to_string(stats.mp3_count) <> " mp3s",
            )
          }

          state
        }
      }
    }
    Error(msg) -> {
      io.println(tag <> " → FAIL: " <> msg)
      BatchState(
        ..state,
        fail_count: state.fail_count + 1,
        fail_details: [dialogue_id <> ": " <> msg, ..state.fail_details],
      )
    }
  }
}

fn format_s(s: Int) -> String {
  int.to_string(s)
}

// ── Single dialogue pipeline ─────────────────────────────────────────────

fn process_one(
  audio_path: String,
  transcript_path: String,
  output_dir: String,
) -> Result(DialogueStats, String) {
  let dialogue_id = extract_id(audio_path)

  use raw_transcript <- result.try(read_transcript(transcript_path))
  let turns = transcript_parser.parse_transcript(raw_transcript)
  case list.length(turns) < 2 {
    True -> Error("only " <> int.to_string(list.length(turns)) <> " turns")
    False -> {
      use actual_duration <- result.try(probe_duration(audio_path))
      let pcm_path = audio_path <> ".pcm"
      use _ <- result.try(decode_mp3_to_pcm(audio_path, pcm_path))

      use pcm <- result.try(file_io.read_binary(pcm_path)
        |> result.map_error(fn(e) { describe_file_error(e) }))
      use transcription <- result.try(
        whisper.transcribe_pcm(pcm, whisper.default_opts())
        |> result.map_error(fn(e) { describe_whisper_error(e) })
      )
      let all_words = aligner.transcription_words(transcription)

      use aligned <- result.try(
        aligner.align_turns(turns, all_words, actual_duration)
        |> result.map_error(fn(e) { describe_align_error(e) })
      )
      let aligned = clamp_aligned_to_duration(aligned, actual_duration)

      use _ <- result.try(file_io.make_dir(output_dir)
        |> result.map_error(fn(e) { describe_file_error(e) }))
      let split_tasks = list.map(aligned, fn(t) {
        #(t.audio_start_s, t.audio_end_s, output_dir <> "/" <> dialogue_types.turn_filename(t.index))
      })
      use _ <- result.try(splitter.batch_split(audio_path, split_tasks)
        |> result.map_error(fn(e) { describe_splitter_error(e) }))

      use _ <- result.try(manifest.write_manifest(
        dialogue_id,
        filename_from_path(audio_path),
        filename_from_path(transcript_path),
        transcription.duration_s,
        aligned,
        output_dir,
      ) |> result.map_error(fn(e) { describe_file_error(e) }))

      let _ = file_io.delete_path(pcm_path)

      let #(exact, fuzzy, fallback) = count_confidence(aligned)
      Ok(DialogueStats(
        mp3_count: count_mp3_files(output_dir),
        exact: exact,
        fuzzy: fuzzy,
        fallback: fallback,
      ))
    }
  }
}

const min_turn_gap: Float = 0.1

fn clamp_aligned_to_duration(
  turns: List(aligner.AlignedTurn),
  duration: Float,
) -> List(aligner.AlignedTurn) {
  list.fold(turns, [], fn(acc, t) {
    let clamped_start = case t.audio_start_s >. duration {
      True -> duration
      False -> t.audio_start_s
    }
    let clamped_end = case t.audio_end_s >. duration {
      True -> duration
      False -> t.audio_end_s
    }
    let clamped_end = case clamped_end <=. clamped_start +. 0.001 {
      True -> float.min(clamped_start +. min_turn_gap, duration)
      False -> clamped_end
    }
    [
      aligner.AlignedTurn(
        index: t.index, role: t.role, text: t.text, word_count: t.word_count,
        audio_start_s: clamped_start, audio_end_s: clamped_end, confidence: t.confidence,
      ),
      ..acc
    ]
  })
  |> list.reverse
}

fn count_confidence(aligned: List(aligner.AlignedTurn)) -> #(Int, Int, Int) {
  list.fold(aligned, #(0, 0, 0), fn(acc, t) {
    let #(e, f, fb) = acc
    case t.confidence {
      trigram.Exact -> #(e + 1, f, fb)
      trigram.Fuzzy -> #(e, f + 1, fb)
      trigram.Fallback -> #(e, f, fb + 1)
    }
  })
}

fn count_mp3_files(dir: String) -> Int {
  collect_files(dir, "mp3") |> list.length
}

fn count_transcript_turns(path: String) -> Int {
  case read_transcript(path) {
    Ok(raw) -> transcript_parser.parse_transcript(raw) |> list.length
    Error(_) -> 0
  }
}

fn is_already_done(out_dir: String) -> Bool {
  case file_io.read_text(out_dir <> "/manifest.json") {
    Ok(_) -> True
    Error(_) -> False
  }
}

fn collect_files(dir: String, ext: String) -> List(String) {
  // filelib:fold_files uses Erlang regex, not glob. "\.mp3$" = ends with literal .mp3
  let pattern = "\\." <> ext <> "$"
  fold_files(dir, pattern, False, fn(path, acc) { [path, ..acc] }, [])
}

fn file_exists(path: String) -> Bool {
  case file_io.read_text(path) {
    Ok(_) -> True
    Error(_) -> False
  }
}

fn read_transcript(path: String) -> Result(String, String) {
  case file_io.read_binary(path) {
    Ok(bytes) -> decode_text(bytes)
    Error(e) -> Error(describe_file_error(e))
  }
}

/// Pure Gleam BOM-aware text decoder.
/// Uses ONE safe BEAM @external (`erlang:binary_to_list`) for raw bytes,
/// then handles all encoding logic in Gleam. Supports:
///   - UTF-16 LE (BOM 255,254)
///   - UTF-16 BE (BOM 254,255)
///   - UTF-8 with BOM (239,187,191)
///   - Plain UTF-8 (no BOM)
///   - Latin-1 fallback for invalid UTF-8
fn decode_text(bytes: BitArray) -> Result(String, String) {
  let raw = binary_to_list(bytes)
  case raw {
    // UTF-16 LE BOM
    [255, 254, ..rest] -> decode_utf16_le(rest)
    // UTF-16 BE BOM
    [254, 255, ..rest] -> decode_utf16_be(rest)
    // UTF-8 BOM
    [239, 187, 191, ..rest] -> decode_utf8_bytes(rest)
    // No BOM — try UTF-8, fall back to Latin-1
    _ -> decode_utf8_bytes(raw)
  }
}

/// UTF-16 LE: pair bytes as (low, high) → codepoint = lo + hi * 256
fn decode_utf16_le(bytes: List(Int)) -> Result(String, String) {
  let codepoints = pair_bytes_le(bytes, [])
  cps_to_string(codepoints)
}

/// UTF-16 BE: pair bytes as (high, low) → codepoint = hi * 256 + lo
fn decode_utf16_be(bytes: List(Int)) -> Result(String, String) {
  let codepoints = pair_bytes_be(bytes, [])
  cps_to_string(codepoints)
}

fn pair_bytes_le(bytes: List(Int), acc: List(Int)) -> List(Int) {
  case bytes {
    [lo, hi, ..rest] -> pair_bytes_le(rest, [lo + hi * 256, ..acc])
    _ -> list.reverse(acc)
  }
}

fn pair_bytes_be(bytes: List(Int), acc: List(Int)) -> List(Int) {
  case bytes {
    [hi, lo, ..rest] -> pair_bytes_be(rest, [hi * 256 + lo, ..acc])
    _ -> list.reverse(acc)
  }
}

/// Convert raw UTF-8 byte list to Gleam String.
/// Falls back to Latin-1 (each byte = codepoint) if UTF-8 is invalid.
fn decode_utf8_bytes(bytes: List(Int)) -> Result(String, String) {
  // Reconstruct BitArray from byte list using binary append
  let bitarray = list.fold(bytes, <<>>, fn(acc, b) {
    let byte_bits: BitArray = <<b:8>>
    bit_array.append(acc, byte_bits)
  })
  case bit_array.to_string(bitarray) {
    Ok(s) -> Ok(s)
    Error(_) -> {
      // Latin-1 fallback: each byte 0-255 is its own codepoint
      let codepoints = list.map(bytes, fn(b) { b })
      cps_to_string(codepoints)
    }
  }
}

/// Convert raw codepoint ints to Gleam String, skipping invalid ones.
fn cps_to_string(cps: List(Int)) -> Result(String, String) {
  let valid = list.filter_map(cps, string.utf_codepoint)
  Ok(string.from_utf_codepoints(valid))
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

fn probe_duration(path: String) -> Result(Float, String) {
  let cmd =
    "ffprobe -v error -show_entries format=duration -of csv=p=0 " <>
    shell_quote(path) <> " 2>&1"
  let out = os_cmd(charlist.from_string(cmd)) |> charlist.to_string |> string.trim
  case float.parse(out) {
    Ok(d) -> Ok(d)
    Error(_) -> Error("ffprobe: " <> out)
  }
}

fn extract_id(path: String) -> String {
  case string.split(filename_from_path(path), ".") {
    [id, _] -> id
    _ -> filename_from_path(path)
  }
}

fn filename_from_path(path: String) -> String {
  case list.last(string.split(path, "/")) {
    Ok(name) -> name
    Error(_) -> path
  }
}

// ── Summary ───────────────────────────────────────────────────────────────

fn print_summary(
  state: BatchState,
  to_process: Int,
  remaining: Int,
  _already_done: Int,
) -> Nil {
  let total_confs = state.exact_total + state.fuzzy_total + state.fallback_total
  io.println("")
  io.println("═══════════════════════════════════════════════════════")
  io.println("FINAL SUMMARY")
  io.println("═══════════════════════════════════════════════════════")
  io.println("Processed:  " <> int.to_string(to_process) <> " (of " <> int.to_string(remaining) <> " remaining)")
  io.println("OK:         " <> int.to_string(state.ok_count))
  io.println("FAIL:       " <> int.to_string(state.fail_count))
  io.println("")
  case state.ok_count + state.fail_count == 0 {
    True -> Nil
    False -> case remaining > to_process {
      True -> io.println("  🔜 left for next run: " <> int.to_string(remaining - to_process))
      False -> io.println("  🎉 all done!")
    }
  }
  io.println("")
  io.println("Confidence:")
  io.println("  Exact:    " <> int.to_string(state.exact_total))
  io.println("  Fuzzy:    " <> int.to_string(state.fuzzy_total))
  io.println("  Fallback: " <> int.to_string(state.fallback_total))
  case total_confs > 0 {
    True -> {
      let good = state.exact_total + state.fuzzy_total
      let good_pct = int.divide(good * 100, total_confs) |> result.unwrap(0)
      let fb_pct = int.divide(state.fallback_total * 100, total_confs) |> result.unwrap(0)
      io.println(
        "  Good:     " <> int.to_string(good) <> "/" <> int.to_string(total_confs) <>
        " (" <> int.to_string(good_pct) <> "%)",
      )
      io.println(
        "  Fallback: " <> int.to_string(fb_pct) <> "%",
      )
    }
    False -> Nil
  }
  case state.fallback_dialogues {
    [] -> Nil
    _ -> {
      io.println("")
      io.println("Dialogues with Fallback boundaries:")
      list.each(list.reverse(state.fallback_dialogues), fn(pair) {
        io.println("  " <> pair.0 <> ": " <> int.to_string(pair.1))
      })
    }
  }
  case state.fail_count {
    0 -> Nil
    _ -> {
      io.println("")
      io.println("Failures:")
      list.each(list.take(state.fail_details, 20), fn(d) {
        io.println("  " <> d)
      })
    }
  }
  Nil
}

// ── Error describers ─────────────────────────────────────────────────────

fn describe_whisper_error(e: whisper.WhisperError) -> String {
  case e {
    whisper.ModelLoadFailed(m) -> m
    whisper.TranscribeFailed(m) -> m
    whisper.DecodeFailed(m) -> m
  }
}

fn describe_align_error(e: aligner.AlignError) -> String {
  case e {
    aligner.NoWordTimestamps -> "no word timestamps"
    aligner.EmptyTranscript -> "empty transcript"
    aligner.ComputationFailed(m) -> m
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
