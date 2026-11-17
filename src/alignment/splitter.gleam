//// MP3 splitter — lossless per-turn extraction via ffmpeg `-c copy`.
////
//// One `os_cmd` from shell.gleam — no duplicated @externals.
//// ffmpeg frame-accurate, lossless (just copies MP3 frames, no re-encode).

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
pub fn split_mp3(
  input_path: String,
  start_s: Float,
  end_s: Float,
  output_path: String,
) -> Result(Nil, SplitterError) {
  let cmd =
    "ffmpeg -hide_banner -loglevel error -y " <>
    "-ss " <> float.to_string(start_s) <> " " <>
    "-to " <> float.to_string(end_s) <> " " <>
    "-i " <> shell_quote(input_path) <> " " <>
    "-c copy " <> shell_quote(output_path) <> " 2>&1"
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
  let errors = list.filter(results, fn(r) {
    case r {
      Error(_) -> True
      Ok(_) -> False
    }
  })
  case list.length(errors) {
    0 -> Ok(Nil)
    n -> Error(SplitFailed(int.to_string(n) <> " split(s) failed"))
  }
}
