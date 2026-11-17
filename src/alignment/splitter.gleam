//// MP3 splitter — per-turn extraction via ffmpeg.
////
//// Uses `-c:a libmp3lame -b:a 192k` (re-encode) instead of `-c copy`
//// (lossless copy) because MP3 frame boundaries are ~26ms apart.
//// `-c copy` fails at the edge of the file and can't produce valid
//// MP3s shorter than ~80ms (needs ≥3 consecutive frames).
//// Re-encoding guarantees frame-accurate output at any duration.

import gleam/erlang/charlist
import gleam/float
import gleam/int
import gleam/io
import gleam/list
import alignment/shell.{os_cmd, shell_quote}

pub type SplitterError {
  SplitFailed(String)
}

/// Extract a time range from source mp3 to a new mp3 file.
/// Re-encodes with libmp3lame for frame accuracy at any duration.
pub fn split_mp3(
  input_path: String,
  start_s: Float,
  end_s: Float,
  output_path: String,
) -> Result(Nil, SplitterError) {
  let cmd =
    "ffmpeg -hide_banner -loglevel error -y " <>
    "-ss " <> float.to_string(start_s) <> " " <>
    "-t " <> float.to_string(end_s -. start_s) <> " " <>
    "-i " <> shell_quote(input_path) <> " " <>
    "-c:a libmp3lame -b:a 192k " <>
    shell_quote(output_path) <> " 2>&1"
  let result = os_cmd(charlist.from_string(cmd)) |> charlist.to_string
  case result {
    "" -> {
      io.println("[splitter] OK: " <> output_path)
      Ok(Nil)
    }
    _ -> Error(SplitFailed(result))
  }
}

/// Batch split each aligned turn. Returns Error(n_failed) on any failure.
pub fn batch_split(
  input_path: String,
  turns: List(#(Float, Float, String)),
) -> Result(Nil, SplitterError) {
  let results = list.map(turns, fn(t) {
    let #(start, end, out) = t
    split_mp3(input_path, start, end, out)
  })
  let n_failed = list.index_fold(results, 0, fn(count, r, idx) {
    case r {
      Ok(_) -> count
      Error(SplitFailed(msg)) -> {
        let pair = case list.drop(turns, idx) {
          [#(s, e, path), ..] -> path <> " [" <> float.to_string(s) <> "–" <> float.to_string(e) <> "]"
          _ -> ""
        }
        io.println("[splitter] FAIL #" <> int.to_string(idx) <> " " <> pair <> ": " <> msg)
        count + 1
      }
    }
  })
  case n_failed {
    0 -> Ok(Nil)
    n -> Error(SplitFailed(int.to_string(n) <> " split(s) failed"))
  }
}
