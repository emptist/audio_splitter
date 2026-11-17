//// Generic dialogue types — reused across any dialogue/audio pipeline.
////
//// This module is the ONLY place the alignment tool defines Turn/Role.
//// It replaces the previous dependency on speak_engl/content.
//// These are generic dialogue concepts, not speak_engl domain types.

/// Who spoke a line in a doctor-patient (or any two-role) dialogue.
pub type Role {
  Doctor
  Patient
}

/// One spoken line — turn index, who spoke, the text.
pub type Turn {
  Turn(index: Int, role: Role, text: String)
}
