//// Generic dialogue types — reused across any dialogue/audio pipeline.
////
//// This module is the ONLY place the alignment tool defines Turn/Role.
//// It replaces the previous dependency on speak_engl/content.
//// These are generic dialogue concepts, not speak_engl domain types.

import gleam/int
import gleam/string

/// Who spoke a line in a doctor-patient (or any two-role) dialogue.
pub type Role {
  Doctor
  Patient
}

/// One spoken line — turn index, who spoke, the text.
pub type Turn {
  Turn(index: Int, role: Role, text: String)
}

/// Single-letter code for a role — "D" or "P".
pub fn role_letter(role: Role) -> String {
  case role {
    Doctor -> "D"
    Patient -> "P"
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
