//// JSON manifest writer — one manifest per dialogue directory.
////
//// Output format (per dialogue):
////   {
////     "dialogue_id": "GAS0001",
////     "audio_file": "GAS0001.mp3",
////     "transcript_file": "GAS0001.txt",
////     "duration_s": 565.2,
////     "turn_count": 75,
////     "turns": [{ "index", "role", "text", "audio_path", "audio_start_s", "audio_end_s", ... }]
////   }
////
//// Returns Result — file write failure is not silently ignored.

import gleam/json
import gleam/list
import audio_splitter/dialogue_types as dialogue_types
import audio_splitter/aligner.{type AlignedTurn}
import audio_splitter/file_io

/// Write manifest.json to output_dir. Returns the path on success.
pub fn write_manifest(
  dialogue_id: String,
  audio_file: String,
  transcript_file: String,
  duration_s: Float,
  turns: List(AlignedTurn),
  output_dir: String,
) -> Result(String, file_io.FileError) {
  let manifest = build_manifest_json(
    dialogue_id,
    audio_file,
    transcript_file,
    duration_s,
    turns,
  )
  let path = output_dir <> "/manifest.json"
  case file_io.write_text(path, manifest) {
    Ok(_) -> Ok(path)
    Error(e) -> Error(e)
  }
}

fn build_manifest_json(
  dialogue_id: String,
  audio_file: String,
  transcript_file: String,
  duration_s: Float,
  turns: List(AlignedTurn),
) -> String {
  let turn_objects = list.map(turns, fn(t) {
    json.object([
      #("index", json.int(t.index)),
      #("role", json.string(dialogue_types.role_letter(t.role))),
      #("text", json.string(t.text)),
      #("word_count", json.int(t.word_count)),
      #("audio_start_s", json.float(t.audio_start_s)),
      #("audio_end_s", json.float(t.audio_end_s)),
      #("duration_s", json.float(t.audio_end_s -. t.audio_start_s)),
      #("audio_path", json.string(dialogue_types.turn_filename(t.index))),
    ])
  })

  json.to_string(json.object([
    #("dialogue_id", json.string(dialogue_id)),
    #("audio_file", json.string(audio_file)),
    #("transcript_file", json.string(transcript_file)),
    #("duration_s", json.float(duration_s)),
    #("turn_count", json.int(list.length(turns))),
    #("turns", json.array(turn_objects, of: fn(x) { x })),
  ]))
}
