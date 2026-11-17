//// Alignment algorithm — map transcript turn boundaries to audio timestamps.
////
//// Strategy: whisper.cpp word timestamps give absolute time for every word
//// in the audio. The transcript parser gives words per turn. We distribute
//// expected turn boundaries proportionally across the audio timeline, then
//// snap each boundary to the LARGEST silence gap within a ±3s window.
////
//// This is robust to whisper hallucinations (ggml-tiny/base mishears words)
//// because we DON'T try to match transcript text to whisper text — we only
//// use the TIMESTAMPS from whisper's AUDIO analysis, and the word-COUNT
//// distribution from the transcript.

import gleam/float
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import alignment/dialogue_types.{type Turn, type Role}
import alignment/whisper_driver.{type Word, type Segment}

/// A single gap between consecutive whisper words where silence > threshold.
pub type SilenceGap {
  SilenceGap(start: Float, end: Float, duration: Float)
}

/// An aligned turn with absolute audio start/end times (seconds).
pub type AlignedTurn {
  AlignedTurn(
    index: Int,
    role: Role,
    text: String,
    word_count: Int,
    audio_start_s: Float,
    audio_end_s: Float,
  )
}

pub type AlignError {
  NoWordTimestamps
  EmptyTranscript
  ComputationFailed(String)
}

/// Align transcript turns to whisper word timestamps.
pub fn align_turns(
  turns: List(Turn),
  words: List(Word),
  audio_duration_s: Float,
) -> Result(List(AlignedTurn), AlignError) {
  let no_turns = turns == []
  let no_words = words == []
  case no_turns, no_words {
    True, _ -> Error(EmptyTranscript)
    _, True -> Error(NoWordTimestamps)
    False, False -> {
      let silence_gaps = find_silence_gaps(words, 0.3)
      let turn_word_counts = list.map(turns, fn(t) { count_words(t.text) })
      let total_transcript_words = list.fold(turn_word_counts, 0, fn(a, b) { a + b })
      let total_whisper_words = list.length(words)
      let first_word_start = case list.first(words) {
        Ok(w) -> w.start
        Error(_) -> 0.0
      }
      let last_word_end = case list.last(words) {
        Ok(w) -> w.end
        Error(_) -> audio_duration_s
      }
      let effective_duration = last_word_end -. first_word_start

      let expected_boundaries = build_expected_boundaries(
        turn_word_counts,
        total_transcript_words,
        total_whisper_words,
        first_word_start,
        effective_duration,
      )

      let snapped = list.map(expected_boundaries, fn(exp) {
        snap_to_silence(exp, silence_gaps, 3.0)
      })

      let final_boundaries = finalize_boundaries(snapped, audio_duration_s)

      build_aligned_turns(turns, final_boundaries)
    }
  }
}

// ── Step 1: Find silence gaps ────────────────────────────────────────────────

pub fn find_silence_gaps(words: List(Word), threshold_s: Float) -> List(SilenceGap) {
  case words {
    [] -> []
    [_] -> []
    _ -> {
      let pairs = pair_consecutive(words, [])
      let filtered = list.filter(pairs, fn(pair) {
        let #(w1, w2) = pair
        let gap = w2.start -. w1.end
        gap >. threshold_s
      })
      list.map(filtered, fn(pair) {
        let #(w1, w2) = pair
        let gap_start = w1.end
        let gap_end = w2.start
        SilenceGap(
          start: gap_start,
          end: gap_end,
          duration: gap_end -. gap_start,
        )
      })
    }
  }
}

fn pair_consecutive(words: List(Word), acc: List(#(Word, Word))) -> List(#(Word, Word)) {
  case words {
    [] -> list.reverse(acc)
    [_] -> list.reverse(acc)
    [a, b, ..rest] -> pair_consecutive([b, ..rest], [#(a, b), ..acc])
  }
}

// ── Step 2: Build expected boundary times ───────────────────────────────────

fn build_expected_boundaries(
  turn_word_counts: List(Int),
  total_transcript_words: Int,
  total_whisper_words: Int,
  first_word_start: Float,
  effective_duration: Float,
) -> List(Float) {
  let whisper_ratio = case total_transcript_words > 0 {
    True -> int.to_float(total_whisper_words) /. int.to_float(total_transcript_words)
    False -> 1.0
  }
  let cumulative = scan_sum(turn_word_counts, 0, [])
  // Drop the last cumulative value (that's total = audio end)
  let drop_last = case cumulative {
    [] -> []
    [_] -> []
    _ -> list.reverse(cumulative) |> list.drop(1) |> list.reverse
  }
  list.map(drop_last, fn(cum) {
    let progress = int.to_float(cum) /. int.to_float(total_transcript_words)
    first_word_start +. progress *. whisper_ratio *. effective_duration
  })
}

/// Running sum: [2, 3, 4] with start=0 → [2, 5, 9]
fn scan_sum(values: List(Int), current: Int, acc: List(Int)) -> List(Int) {
  case values {
    [] -> list.reverse(acc)
    [v, ..rest] -> {
      let next = current + v
      scan_sum(rest, next, [next, ..acc])
    }
  }
}

// ── Step 3: Snap to silence ──────────────────────────────────────────────────

fn snap_to_silence(expected: Float, gaps: List(SilenceGap), window_s: Float) -> Float {
  let candidates = list.filter(gaps, fn(g) {
    let mid = g.start +. g.end
    let center = mid /. 2.0
    float.absolute_value(center -. expected) <=. window_s
  })
  case candidates {
    [] -> expected
    _ -> {
      let init: Option(SilenceGap) = None
      let best = list.fold(candidates, init, fn(acc, g) {
        case acc {
          None -> Some(g)
          Some(current) ->
            case g.duration >. current.duration {
              True -> Some(g)
              False -> Some(current)
            }
        }
      })
      case best {
        None -> expected
        Some(g) -> {
          let mid = g.start +. g.end
          mid /. 2.0
        }
      }
    }
  }
}

// ── Step 4: Finalize boundaries ─────────────────────────────────────────────

fn finalize_boundaries(snapped: List(Float), audio_duration_s: Float) -> List(Float) {
  let with_front = [0.0, ..snapped]
  let with_edges = list.append(with_front, [audio_duration_s])
  // First element (0.0 = audio start) is fixed — don't re-enforce it
  case with_edges {
    [first, ..rest] -> list.reverse(enforce_monotonic(rest, first, [first]))
    _ -> list.reverse(enforce_monotonic(with_edges, 0.0, []))
  }
}

fn enforce_monotonic(
  values: List(Float),
  last: Float,
  acc: List(Float),
) -> List(Float) {
  case values {
    [] -> acc
    [v, ..rest] -> {
      let min_gap = 0.05
      let adjusted = case v >. last +. min_gap {
        True -> v
        False -> last +. min_gap
      }
      enforce_monotonic(rest, adjusted, [adjusted, ..acc])
    }
  }
}

// ── Step 5: Build aligned turns ──────────────────────────────────────────────

fn build_aligned_turns(
  turns: List(Turn),
  boundaries: List(Float),
) -> Result(List(AlignedTurn), AlignError) {
  let pairs = pair_consecutive_floats(boundaries, [])
  let turn_count = list.length(turns)
  let pair_count = list.length(pairs)
  case turn_count == pair_count {
    True -> {
      list.map2(turns, pairs, fn(turn, pair) {
        let #(start, end) = pair
        AlignedTurn(
          index: turn.index,
          role: turn.role,
          text: turn.text,
          word_count: count_words(turn.text),
          audio_start_s: start,
          audio_end_s: end,
        )
      })
      |> Ok
    }
    False -> Error(ComputationFailed(
      "turn count (" <> int.to_string(turn_count) <>
      ") != boundary pairs (" <> int.to_string(pair_count) <> ")",
    ))
  }
}

fn pair_consecutive_floats(values: List(Float), acc: List(#(Float, Float))) -> List(#(Float, Float)) {
  case values {
    [] -> list.reverse(acc)
    [_] -> list.reverse(acc)
    [a, b, ..rest] -> pair_consecutive_floats([b, ..rest], [#(a, b), ..acc])
  }
}

// ── Utilities ───────────────────────────────────────────────────────────────

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
