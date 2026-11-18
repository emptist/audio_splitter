//// whisper_cpp driver — BEAM interop for speech-to-text with word timestamps.
////
//// Wraps the Elixir WhisperCpp NIFs. Model handle is hidden behind an
//// **opaque** WhisperModel type (wrapping dynamic.Dynamic internally).
//// External callers can never touch the raw Elixir struct — this enforces
//// the opaque-type pattern from custom-types.md.
////
//// Model caching: Erlang persistent_term, one ~500ms load per OTP session.

import gleam/dynamic
import gleam/dynamic/decode
import gleam/erlang/atom
import gleam/erlang/charlist
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import audio_splitter/shell.{os_cmd}

// ── Types ──────────────────────────────────────────────────────────────────

/// Opaque handle to a loaded whisper model.
/// Internally wraps the Elixir struct that whisper_cpp.load_model returns.
/// External modules can't construct or inspect — only pass back to us.
pub opaque type WhisperModel {
  WhisperModel(dynamic.Dynamic)
}

pub type Word {
  Word(text: String, start: Float, end: Float, probability: Float, segment_index: Int)
}

pub type Segment {
  Segment(text: String, start: Float, end: Float, words: List(Word))
}

pub type Transcription {
  Transcription(
    text: String,
    segments: List(Segment),
    language: String,
    duration_s: Float,
  )
}

pub type WhisperError {
  ModelLoadFailed(String)
  TranscribeFailed(String)
  DecodeFailed(String)
}

pub type WhisperOpts {
  WhisperOpts(
    language: String,
    word_timestamps: Bool,
    beam_size: Int,
    n_threads: Int,
    initial_prompt: Option(String),
  )
}

// ── BEAM interop (all take/return dynamic.Dynamic — unwrap below) ────────

@external(erlang, "Elixir.WhisperCpp", "load_model")
fn whisper_load_model(
  path: String,
  opts: List(#(atom.Atom, dynamic.Dynamic)),
) -> dynamic.Dynamic

@external(erlang, "Elixir.WhisperCpp", "transcribe")
fn whisper_transcribe_nif(
  model_raw: dynamic.Dynamic,
  pcm: #(atom.Atom, BitArray),
  opts: List(#(atom.Atom, dynamic.Dynamic)),
) -> dynamic.Dynamic

@external(erlang, "persistent_term", "put")
fn pt_put(key: atom.Atom, value: dynamic.Dynamic) -> Nil

@external(erlang, "persistent_term", "get")
fn pt_get_with_default(
  key: atom.Atom,
  default: dynamic.Dynamic,
) -> dynamic.Dynamic

@external(erlang, "application", "ensure_all_started")
fn application_ensure_all_started(name: atom.Atom) -> dynamic.Dynamic

@external(erlang, "maps", "get")
fn maps_get(
  key: atom.Atom,
  map: dynamic.Dynamic,
  default: dynamic.Dynamic,
) -> dynamic.Dynamic

const model_cache_key = "align_whisper_model"

// ── Public API ──────────────────────────────────────────────────────────────

pub fn default_opts() -> WhisperOpts {
  WhisperOpts(
    language: "en",
    word_timestamps: True,
    beam_size: 2,
    n_threads: 4,
    initial_prompt: None,
  )
}

/// Transcribe PCM audio and return structured result with word timestamps.
pub fn transcribe_pcm(
  pcm: BitArray,
  opts: WhisperOpts,
) -> Result(Transcription, WhisperError) {
  use WhisperModel(model_raw) <- result.try(get_cached_model())
  let nif_opts = build_nif_opts(opts)
  let nif_result = whisper_transcribe_nif(
    model_raw,
    #(atom.create("pcm_f32"), pcm),
    nif_opts,
  )
  decode_transcription(nif_result)
}

fn build_nif_opts(opts: WhisperOpts) -> List(#(atom.Atom, dynamic.Dynamic)) {
  let base = [
    #(atom.create("language"), dynamic.string(opts.language)),
    #(atom.create("beam_size"), dynamic.int(opts.beam_size)),
    #(atom.create("n_threads"), dynamic.int(opts.n_threads)),
  ]
  let with_ts = case opts.word_timestamps {
    True -> [#(atom.create("word_timestamps"), dynamic.bool(True)), ..base]
    False -> base
  }
  case opts.initial_prompt {
    Some(prompt) -> [#(atom.create("initial_prompt"), dynamic.string(prompt)), ..with_ts]
    None -> with_ts
  }
}

// ── Model caching ──────────────────────────────────────────────────────────

fn get_cached_model() -> Result(WhisperModel, WhisperError) {
  let key = atom.create(model_cache_key)
  let sentinel = dynamic.nil()
  let cached = pt_get_with_default(key, sentinel)
  case cached == sentinel {
    True -> load_and_cache_model()
    False -> Ok(WhisperModel(cached))
  }
}

fn load_and_cache_model() -> Result(WhisperModel, WhisperError) {
  ensure_whisper_started()
  // Force CPU backend — Metal crashes in this environment.
  let load_opts = [#(atom.create("use_gpu"), dynamic.bool(False))]
  let raw = whisper_load_model(default_model_path(), load_opts)
  case decode.run(raw, decode.at([0], atom.decoder())) {
    Ok(tag) -> {
      case atom.to_string(tag) {
        "ok" -> {
          case decode.run(raw, decode.at([1], decode.dynamic)) {
            Ok(model_handle) -> {
              pt_put(atom.create(model_cache_key), model_handle)
              io.println("[whisper_driver] model loaded and cached")
              Ok(WhisperModel(model_handle))
            }
            Error(_) -> Error(ModelLoadFailed("failed to extract model handle"))
          }
        }
        other -> Error(ModelLoadFailed("unexpected load_model tag: " <> other))
      }
    }
    Error(_) -> Error(ModelLoadFailed("could not decode load_model result"))
  }
}

fn ensure_whisper_started() -> Nil {
  let _ = application_ensure_all_started(atom.create("whisper_cpp"))
  Nil
}

// ── Transcription decoding ─────────────────────────────────────────────────

fn decode_transcription(raw: dynamic.Dynamic) -> Result(Transcription, WhisperError) {
  case decode.run(raw, decode.at([0], atom.decoder())) {
    Ok(tag) -> {
      case atom.to_string(tag) {
        "ok" -> {
          case decode.run(raw, decode.at([1], decode.dynamic)) {
            Ok(trans_map) -> decode_transcription_map(trans_map)
            Error(_) -> Error(DecodeFailed("could not extract transcribe map"))
          }
        }
        _ -> Error(DecodeFailed("unexpected transcribe tag"))
      }
    }
    Error(_) -> Error(DecodeFailed("could not decode transcribe result"))
  }
}

fn decode_transcription_map(map: dynamic.Dynamic) -> Result(Transcription, WhisperError) {
  let text_s = decode.run(maps_get(atom.create("text"), map, dynamic.nil()), decode.string)
  let lang_s = decode.run(maps_get(atom.create("language"), map, dynamic.nil()), decode.string)
  let dur_f = decode.run(maps_get(atom.create("duration_s"), map, dynamic.nil()), decode.float)
  let segments = decode_segments(maps_get(atom.create("segments"), map, dynamic.nil()))

  case text_s, lang_s, dur_f, segments {
    Ok(text), Ok(lang), Ok(dur), Ok(segs) ->
      Ok(Transcription(text:, segments: segs, language: lang, duration_s: dur))
    _, _, _, _ -> Error(DecodeFailed("missing fields in transcription map"))
  }
}

fn decode_segments(raw: dynamic.Dynamic) -> Result(List(Segment), WhisperError) {
  case decode.run(raw, decode.list(decode.dynamic)) {
    Ok(seg_list) -> {
      let indices = build_index_list(list.length(seg_list))
      let indexed = list.zip(seg_list, indices)
      list.try_map(indexed, fn(pair) { decode_segment(pair.0, pair.1) })
    }
    Error(_) -> Error(DecodeFailed("could not decode segments list"))
  }
}

/// Build [0, 1, 2, ..., n-1] using BEAM lists:seq (no stdlib list.range).
fn build_index_list(n: Int) -> List(Int) {
  case n <= 0 {
    True -> []
    False -> lists_seq(0, n - 1)
  }
}

@external(erlang, "lists", "seq")
fn lists_seq(from: Int, to: Int) -> List(Int)

fn decode_segment(raw: dynamic.Dynamic, seg_idx: Int) -> Result(Segment, WhisperError) {
  let text_s = decode.run(maps_get(atom.create("text"), raw, dynamic.nil()), decode.string)
  let start_f = decode.run(maps_get(atom.create("start"), raw, dynamic.nil()), decode.float)
  let end_f = decode.run(maps_get(atom.create("end"), raw, dynamic.nil()), decode.float)
  let words = decode_words(maps_get(atom.create("words"), raw, dynamic.nil()), seg_idx)

  case text_s, start_f, end_f, words {
    Ok(t), Ok(s), Ok(e), Ok(w) -> Ok(Segment(text: t, start: s, end: e, words: w))
    _, _, _, _ -> Error(DecodeFailed("could not decode segment"))
  }
}

fn decode_words(raw: dynamic.Dynamic, seg_idx: Int) -> Result(List(Word), WhisperError) {
  case raw == dynamic.nil() {
    True -> Ok([])
    False -> case decode.run(raw, decode.list(decode.dynamic)) {
      Ok(wlist) -> list.try_map(wlist, fn(r) { decode_word(r, seg_idx) })
      Error(_) -> Error(DecodeFailed("could not decode words list"))
    }
  }
}

fn decode_word(raw: dynamic.Dynamic, seg_idx: Int) -> Result(Word, WhisperError) {
  let text_r = decode.run(maps_get(atom.create("text"), raw, dynamic.nil()), decode.string)
  let start_r = decode.run(maps_get(atom.create("start"), raw, dynamic.nil()), decode.float)
  let end_r = decode.run(maps_get(atom.create("end"), raw, dynamic.nil()), decode.float)
  let prob_r = decode.run(maps_get(atom.create("probability"), raw, dynamic.nil()), decode.float)

  case text_r, start_r, end_r, prob_r {
    Ok(t), Ok(s), Ok(e), Ok(p) -> Ok(Word(text: t, start: s, end: e, probability: p, segment_index: seg_idx))
    _, _, _, _ -> Error(DecodeFailed("could not decode word"))
  }
}

// ── Model location helpers ────────────────────────────────────────────────

pub fn default_model_path() -> String {
  case env("SPEAK_ENGL_WHISPER_MODEL") {
    Ok(path) -> path
    Error(_) -> home() <> "/.cache/whisper/ggml-tiny.bin"
  }
}

fn home() -> String {
  case env("HOME") {
    Ok(path) -> path
    Error(_) -> "."
  }
}

fn env(name: String) -> Result(String, Nil) {
  let value =
    os_cmd(charlist.from_string("printenv " <> name))
    |> charlist.to_string
    |> string.trim
  case value {
    "" -> Error(Nil)
    v -> Ok(v)
  }
}
