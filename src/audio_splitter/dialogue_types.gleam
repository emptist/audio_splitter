//// Generic dialogue types — reused across any dialogue/audio pipeline.
////
//// Speaker positions are proper standalone custom types (not enum variants).
//// Domain apps add aliases — e.g. medical English says Doctor = SpeakerA.
////
//// `SpeakerLabel` wraps SpeakerA/SpeakerB so Turn.speaker_label can hold
//// either in a single list (Gleam has no `A | B` union alias).
//// The label name matches what appears in transcript prefixes
//// ("D:", "P:", "Q:", "A:", etc). Conversion to/from the single-letter
//// mark happens at I/O boundaries via `label_letter` / `label_from_letter`.

import gleam/int
import gleam/option.{type Option, None, Some}
import gleam/string

/// Generic speaker position A — the first speaker in a two-way dialogue.
pub type SpeakerA { SpeakerA }

/// Generic speaker position B — the second speaker in a two-way dialogue.
pub type SpeakerB { SpeakerB }

/// Domain alias — medical English calls SpeakerA "Doctor".
pub type Doctor = SpeakerA

/// Domain alias — medical English calls SpeakerB "Patient".
pub type Patient = SpeakerB

/// The speaker label that appeared at the start of a transcript line.
/// Wraps SpeakerA or SpeakerB so Turn.speaker_label can hold either in a list.
pub type SpeakerLabel {
  LabelDoctor(Doctor)
  LabelPatient(Patient)
}

/// One spoken line — turn index, which label marked the speaker, the text.
pub type Turn {
  Turn(index: Int, speaker_label: SpeakerLabel, text: String)
}

/// Single-letter mark for a label — "D", "P", "A", "B", "Q", etc.
pub fn label_letter(label: SpeakerLabel) -> String {
  case label {
    LabelDoctor(_) -> "D"
    LabelPatient(_) -> "P"
  }
}

/// Parse a single-letter prefix ("D"/"P"/"A"/"B"/"Q"/etc, case-insensitive)
/// to a SpeakerLabel.
pub fn label_from_letter(letter: String) -> Option(SpeakerLabel) {
  case letter {
    "D" | "d" | "A" | "a" -> Some(LabelDoctor(SpeakerA))
    "P" | "p" | "B" | "b" -> Some(LabelPatient(SpeakerB))
    _ -> None
  }
}

/// Zero-padded mp3 filename for a turn — e.g. "turn_0042.mp3".
pub fn turn_filename(index: Int) -> String {
  "turn_" <> zero_pad(index, 4) <> ".mp3"
}

fn zero_pad(n: Int, width: Int) -> String {
  let s = int.to_string(n)
  case width <= string.length(s) {
    True -> s
    False -> {
      let needed = width - string.length(s)
      string.repeat("0", needed) <> s
    }
  }
}
