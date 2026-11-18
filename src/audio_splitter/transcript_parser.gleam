//// Parse raw transcript text into structured Turns.
////
//// Transcript format (generic D:/P: speaker prefix):
////
////     D: What brings you in today?
////
////     P: I've been feeling nauseated for about nine days.
////
////     D: When did this start?
////
//// Lines begin with "D: " (doctor) or "P: " (patient). Turns are separated
//// by blank lines. Files may use \r\n line endings.
////
//// Continuation lines: a non-blank line without a D:/P: prefix that
//// immediately follows a speaker line is merged into the current turn's
//// text. This handles transcripts where long utterances wrap onto the
//// next line (e.g. "I thought it might be a\nchest infection...").
////
//// Pure module — no I/O. Caller reads the file and hands the string over.

import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import audio_splitter/dialogue_types.{type Turn, type Role, Turn, Doctor, Patient}

/// Accumulator state for the fold.
type ParseState {
  ParseState(
    index: Int,
    turns: List(Turn),
    pending_role: Option(Role),
    pending_text: String,
  )
}

/// Parse a raw transcript string into a list of Turns in order.
/// Returns an empty list if no recognized speaker lines are found.
pub fn parse_transcript(raw: String) -> List(Turn) {
  raw
  |> normalize_line_endings
  |> string.split("\n")
  |> list.fold(
    ParseState(index: 0, turns: [], pending_role: None, pending_text: ""),
    fn(acc, line) {
      let trimmed = string.trim(line)
      case parse_speaker_line(trimmed) {
        Some(#(role, text)) -> {
          let acc = finalize_pending(acc)
          ParseState(
            index: acc.index,
            turns: acc.turns,
            pending_role: Some(role),
            pending_text: text,
          )
        }
        None -> {
          case acc.pending_role, trimmed {
            Some(_), "" -> finalize_pending(acc)
            Some(_), cont ->
              ParseState(
                index: acc.index,
                turns: acc.turns,
                pending_role: acc.pending_role,
                pending_text: acc.pending_text <> " " <> cont,
              )
            None, _ -> acc
          }
        }
      }
    },
  )
  |> finalize_pending
  |> fn(state) { list.reverse(state.turns) }
}

/// If a turn is being built, finalize it and bump index.
fn finalize_pending(state: ParseState) -> ParseState {
  case state.pending_role {
    None -> state
    Some(role) -> {
      let turn = Turn(index: state.index, role:, text: string.trim(state.pending_text))
      ParseState(
        index: state.index + 1,
        turns: [turn, ..state.turns],
        pending_role: None,
        pending_text: "",
      )
    }
  }
}

/// Detect and extract the speaker role and text from one line.
/// Returns `None` if the line doesn't match "D: ..." or "P: ...".
pub fn parse_speaker_line(line: String) -> Option(#(Role, String)) {
  let trimmed = string.trim(line)
  case string.starts_with(trimmed, "D:") {
    True -> Some(#(Doctor, string.trim(string.drop_start(trimmed, 2))))
    False ->
      case string.starts_with(trimmed, "P:") {
        True -> Some(#(Patient, string.trim(string.drop_start(trimmed, 2))))
        False -> None
      }
  }
}

fn normalize_line_endings(raw: String) -> String {
  raw
  |> string.replace("\r\n", "\n")
  |> string.replace("\r", "\n")
}
