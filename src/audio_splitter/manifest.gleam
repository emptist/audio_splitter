//// ETF manifest writer — one manifest per dialogue directory.
////
//// Output: `manifest.etf` (OTP External Term Format) — the whole manifest
//// container type serialised in one `term_to_binary` call. No JSON codec,
//// no string downgrades — AlignedTurn.SpeakerLabel variant tags preserved
//// intact. Compare glibe §6.6: "Let types speak for themselves, don't add
//// a codec layer."
////
//// Reader calls `etf_codec.decode(bits)` on the same container type —
//// infallible within the same VM (all binaries produced here, never
//// hand-written).

import gleam/list
import audio_splitter/dialogue_types as dialogue_types
import audio_splitter/aligner.{type AlignedTurn}
import audio_splitter/file_io

/// Container type — one per dialogue directory.
/// Every SpeakerLabel variant, every Float precision, every confidence tag
/// preserved intact by term_to_binary. No string codec anywhere.
pub type ManifestSum {
  Manifest(
    dialogue_id: String,
    audio_file: String,
    transcript_file: String,
    duration_s: Float,
    turns: List(ManifestTurn),
  )
}

pub type ManifestTurn {
  ManifestTurn(
    index: Int,
    speaker_label: dialogue_types.SpeakerLabel,
    text: String,
    word_count: Int,
    audio_start_s: Float,
    audio_end_s: Float,
    duration_s: Float,
    audio_path: String,
  )
}

@external(erlang, "erlang", "term_to_binary")
fn to_etf(term: a) -> BitArray

/// Write manifest.etf to output_dir. Returns the path on success.
pub fn write_manifest(
  dialogue_id: String,
  audio_file: String,
  transcript_file: String,
  duration_s: Float,
  turns: List(AlignedTurn),
  output_dir: String,
) -> Result(String, file_io.FileError) {
  let manifest = Manifest(
    dialogue_id:,
    audio_file:,
    transcript_file:,
    duration_s:,
    turns: list.map(turns, build_manifest_turn),
  )
  let path = output_dir <> "/manifest.etf"
  case file_io.write_binary(path, to_etf(manifest)) {
    Ok(_) -> Ok(path)
    Error(e) -> Error(e)
  }
}

fn build_manifest_turn(t: AlignedTurn) -> ManifestTurn {
  let duration = t.audio_end_s -. t.audio_start_s
  ManifestTurn(
    index: t.index,
    speaker_label: t.speaker_label,
    text: t.text,
    word_count: t.word_count,
    audio_start_s: t.audio_start_s,
    audio_end_s: t.audio_end_s,
    duration_s: duration,
    audio_path: dialogue_types.turn_filename(t.index),
  )
}
