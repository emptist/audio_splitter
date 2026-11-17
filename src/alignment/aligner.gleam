//// Alignment algorithm (trigram anchor matching) — map transcript turn
//// boundaries to audio timestamps.
////
//// Pipeline:
////   Turn list + whisper Word list
////     → anchor_extractor.extract_anchors → BoundaryAnchor list
////     → trigram_alignment.align_boundaries → BoundaryResult list
////     → extract boundary_s, Fallback → proportional estimate
////     → enforce_monotonic + append [0.0, duration] edges
////     → pair consecutive boundaries → AlignedTurn list
////
//// Key design: each interior boundary timestamp comes from trigram
//// matching (or proportional Fallback). We only enforce NON-DECREASING
//// order (no crossing) — NO artificial minimum gaps. Whisper tiny model
//// has coarse time resolution so rapid-fire exchanges may land at the
//// same float timestamp. Those boundaries stay right where they are
//// — no staircase artifacts from cascaded 0.1s pushes.
////
//// See anchor_extractor.gleam and trigram_alignment.gleam for details.

import gleam/int
import gleam/list
import gleam/option.{type Option, Some, None}
import gleam/string
import alignment/dialogue_types.{type Turn, type Role}
import alignment/whisper_driver.{type Word, type Segment, Word}
import alignment/anchor_extractor.{
  type BoundaryAnchor,
  BoundaryAnchor,
  extract_anchors,
}
import alignment/trigram_alignment.{
  type Confidence,
  Fallback,
  Exact,
  align_boundaries,
}

// ── Public types (stable, used by splitter/manifest/CLI) ────────────────────

pub type AlignedTurn {
  AlignedTurn(
    index: Int,
    role: Role,
    text: String,
    word_count: Int,
    audio_start_s: Float,
    audio_end_s: Float,
    /// Boundary match confidence: Exact | Fuzzy | Fallback
    /// Low-confidence (Fallback) boundaries are rough proportional estimates.
    confidence: Confidence,
  )
}

pub type AlignError {
  NoWordTimestamps
  EmptyTranscript
  ComputationFailed(String)
}

// ── Public API ──────────────────────────────────────────────────────────────

pub fn align_turns(
  turns: List(Turn),
  words: List(Word),
  audio_duration_s: Float,
) -> Result(List(AlignedTurn), AlignError) {
  case turns == [], words == [] {
    True, _ -> Error(EmptyTranscript)
    _, True -> Error(NoWordTimestamps)
    False, False -> do_align(turns, words, audio_duration_s)
  }
}

// ── Pipeline ────────────────────────────────────────────────────────────────

fn do_align(
  turns: List(Turn),
  words: List(Word),
  audio_duration_s: Float,
) -> Result(List(AlignedTurn), AlignError) {
  let whisper_total = list.length(words)
  let words = list.filter(words, fn(w) { w.start <=. audio_duration_s })

  let anchors = extract_anchors(turns, whisper_total)
  let results = align_boundaries(anchors, words)

  // Each interior boundary: observed trigram timestamp + confidence.
  // Fallback boundaries (trigram failed) use proportional estimate.
  let boundary_data = list.index_map(results, fn(r, i) {
    let anchor = nth_anchor(anchors, i)
    let boundary = case r.confidence {
      Fallback -> estimate_from_anchor(anchor, words, audio_duration_s)
      _ -> r.boundary_s
    }
    #(boundary, r.confidence)
  })

  let boundaries = list.map(boundary_data, fn(p) { p.0 })
  let boundary_confidences = list.map(boundary_data, fn(p) { p.1 })

  // Append edges, enforce non-decreasing order
  let full = [0.0, ..list.append(boundaries, [audio_duration_s])]
  let final_boundaries = enforce_monotonic(full)

  build_aligned_turns(turns, final_boundaries, boundary_confidences)
}

// ── Fallback estimation ────────────────────────────────────────────────────

fn nth_anchor(anchors: List(BoundaryAnchor), idx: Int) -> BoundaryAnchor {
  case list.drop(anchors, idx) {
    [h, ..] -> h
    _ -> BoundaryAnchor(
      turn_before_index: 0,
      turn_after_index: 0,
      last_tokens: [],
      first_tokens: [],
      expected_whisper_index: 0.0,
    )
  }
}

/// Convert anchor.expected_whisper_index → absolute audio time by
/// interpolating between whisper word timestamps.
fn estimate_from_anchor(
  anchor: BoundaryAnchor,
  words: List(Word),
  audio_duration_s: Float,
) -> Float {
  let pos = anchor.expected_whisper_index
  let total = list.length(words)
  case total {
    0 -> 0.0
    1 -> case list.first(words) {
      Ok(w) -> w.end
      Error(_) -> 0.0
    }
    _ -> {
      let clamped = clamp_float(pos, 0.0, int.to_float(total - 1))
      let lo_idx = trunc_float(clamped)
      let frac = clamped -. int.to_float(lo_idx)
      case nth_word(words, lo_idx), nth_word(words, lo_idx + 1) {
        Some(Word(end: e_lo, ..)), Some(Word(start: s_hi, ..)) -> {
          let t = e_lo +. { s_hi -. e_lo } *. frac
          clamp_float(t, 0.0, audio_duration_s)
        }
        Some(w_word), None -> clamp_float(w_word.end, 0.0, audio_duration_s)
        None, Some(w_word) -> clamp_float(w_word.start, 0.0, audio_duration_s)
        _, _ -> 0.0
      }
    }
  }
}

fn nth_word(words: List(Word), idx: Int) -> Option(Word) {
  case list.drop(words, idx) {
    [] -> None
    [h, ..] -> Some(h)
  }
}

fn clamp_float(v: Float, lo: Float, hi: Float) -> Float {
  case v <. lo {
    True -> lo
    False -> case v >. hi {
      True -> hi
      False -> v
    }
  }
}

/// BEAM erlang:trunc — float → Int truncation (Gleam 1.19 int.floor missing).
@external(erlang, "erlang", "trunc")
fn trunc_float(f: Float) -> Int

// ── Monotonic enforcement ──────────────────────────────────────────────────

/// Ensure boundaries are non-decreasing (no crossing).
/// This is a safety net — trigram_alignment should already return
/// monotonically increasing boundaries in transcript order.
///
/// IMPORTANT: We use NO minimum gap. Multiple boundaries may legitimately
/// land at the same whisper timestamp (whisper tiny model has coarse
/// time resolution for rapid-fire exchanges). Those boundaries stay
/// exactly where they are — no cascaded staircase artifacts.
fn enforce_monotonic(values: List(Float)) -> List(Float) {
  case values {
    [] -> []
    [only] -> [only]
    [first, ..rest] -> list.reverse(enforce_tail(rest, first, [first]))
  }
}

/// Minimum gap between consecutive boundaries.
/// 
/// Why non-zero: whisper tiny model has coarse time resolution —
/// consecutive trigram anchors can land on IDENTICAL float timestamps
/// (whisper reports all words in a rapid-fire exchange at the same time).
/// Without a gap, pair_consecutive_floats produces zero-duration pairs
/// (e.g., start=end=79.25s for turns that should be distinct).
///
/// Why 0.01s: ffmpeg handles ≥5ms reliably. 10ms is tiny enough that
/// cascaded spread for 7 rapid questions = 70ms (realistic for spoken
/// dialogue) but large enough to eliminate floating-point duplicates.
///
/// Why not 0.1s: that creates a visible staircase artifact — 7 quick
/// exchanges spread over 0.7s of artificial audio.
const min_boundary_gap: Float = 0.01

fn enforce_tail(values: List(Float), last: Float, acc: List(Float)) -> List(Float) {
  case values {
    [] -> acc
    [v, ..rest] -> {
      let adjusted = case v >. last +. min_boundary_gap {
        True -> v
        False -> last +. min_boundary_gap
      }
      enforce_tail(rest, adjusted, [adjusted, ..acc])
    }
  }
}

// ── Build AlignedTurns ──────────────────────────────────────────────────────

fn build_aligned_turns(
  turns: List(Turn),
  boundaries: List(Float),
  boundary_confs: List(Confidence),
) -> Result(List(AlignedTurn), AlignError) {
  let pairs = pair_consecutive_floats(boundaries, [])
  case list.length(turns) == list.length(pairs) {
    True -> {
      // Turn[i] confidence = boundary[i-1] confidence (start boundary)
      // Turn[0] always starts at 0.0 → Exact
      let confs = turn_confidences(boundary_confs, list.length(turns))
      // Gleam 1.19 stdlib has no list.map3 — use indexed map on turns,
      // then look up pairs[i] and confs[i] by index.
      Ok(list.index_map(turns, fn(turn, i) {
        let pair = case list.drop(pairs, i) {
          [p, ..] -> p
          _ -> #(0.0, 0.0)
        }
        let conf = case list.drop(confs, i) {
          [c, ..] -> c
          _ -> Fallback
        }
        let #(start, end) = pair
        AlignedTurn(
          index: turn.index,
          role: turn.role,
          text: turn.text,
          word_count: count_words(turn.text),
          audio_start_s: start,
          audio_end_s: end,
          confidence: conf,
        )
      }))
    }
    False -> Error(ComputationFailed(
      "turn count (" <> int.to_string(list.length(turns)) <>
      ") != boundary pairs (" <> int.to_string(list.length(pairs)) <> ")",
    ))
  }
}

/// boundary_confs has N-1 entries for N turns (interior boundaries only).
/// Turn[0] confidence = Exact (start=0.0 is always right).
/// Turn[i] confidence = boundary_confs[i-1] (the boundary between turn[i-1] and turn[i]).
fn turn_confidences(boundary_confs: List(Confidence), turn_count: Int) -> List(Confidence) {
  case turn_count {
    0 -> []
    1 -> [Exact]
    _ -> {
      // Prepend Exact for turn[0]
      [Exact, ..boundary_confs]
    }
  }
}

fn pair_consecutive_floats(values: List(Float), acc: List(#(Float, Float))) -> List(#(Float, Float)) {
  case values {
    [] -> list.reverse(acc)
    [_] -> list.reverse(acc)
    [a, b, ..rest] -> pair_consecutive_floats([b, ..rest], [#(a, b), ..acc])
  }
}

// ── Public utilities ────────────────────────────────────────────────────────

pub fn count_words(text: String) -> Int {
  text
  |> string.trim
  |> string.split(" ")
  |> list.filter(fn(w) { w != "" })
  |> list.length
}

pub fn flatten_words(segments: List(Segment)) -> List(Word) {
  list.fold(segments, [], fn(acc, seg) { list.append(acc, seg.words) })
}

pub fn transcription_words(t: whisper_driver.Transcription) -> List(Word) {
  flatten_words(t.segments)
}
