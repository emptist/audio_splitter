//// trigram_alignment — find exact speaker-change timestamps using anchor trigrams.
////
//// HEART of the new alignment design. Replaces proportional-silence-gap.
////
//// Flow (per anchor):
////   1. Narrow window: search only ±5% of whisper words around expected position
////   2. Build trigram: anchor.last_tokens(1) + anchor.first_tokens(2) = 3 tokens
////   3. Slide through window, score each position
////      score = Σ weight(token_match)  where weight: exact=1.0, prefix=0.8, fuzzy=0.5
////   4. Pick position with highest score >= threshold
////   5. Extract boundary timestamps from matched whisper words
////   6. Fallback to proportional estimate if no good match
////
//// Why this beats proportional:
////   - Whisper hallucinates WORDS but rarely drops a speaker-change trigram.
////     Even if whisper heard "defo" for "definitely", fuzzy match catches it.
////   - Proportional only knows "~X words here". Trigram knows "these specific
////     words should be together".
////
//// Confidence tells you how much to trust each boundary.
//// Fallback means the trigram didn't match — caller should flag for review.

import gleam/int
import gleam/list
import gleam/option.{type Option, Some, None}
import audio_splitter/word_matcher.{
  type Token,
  match_token,
  ExactMatch,
  PrefixMatch,
  FuzzyMatch,
  NoMatch,
}
import audio_splitter/anchor_extractor.{
  type BoundaryAnchor,
  search_window,
}
import audio_splitter/whisper_driver.{type Word}

// ── Types ──────────────────────────────────────────────────────────────────

pub type Confidence {
  Exact     // every trigram token matched exactly
  Fuzzy     // at least one token matched via jaro/edit distance
  Fallback  // no trigram matched — we interpolated
}

pub type BoundaryResult {
  BoundaryResult(
    turn_before_index: Int,
    turn_after_index: Int,
    /// Audio time (seconds) where boundary falls.
    /// This is the midpoint between matched whisper words.
    boundary_s: Float,
    confidence: Confidence,
    /// Which whisper word indices we matched (for debugging/manual review)
    matched_whisper_indices: List(Int),
  )
}

// ── Constants ──────────────────────────────────────────────────────────────

const exact_weight: Float = 1.0
const prefix_weight: Float = 0.8
const fuzzy_weight: Float = 0.5

// ── Public API ──────────────────────────────────────────────────────────────

/// Run trigram alignment over all anchors.
/// Returns results in transcript order (same as anchors input order).
pub fn align_boundaries(
  anchors: List(BoundaryAnchor),
  whisper_words: List(Word),
) -> List(BoundaryResult) {
  let word_count = list.length(whisper_words)
  // Pre-extract whisper text list + timestamp info for fast lookup
  let whisper_texts = list.map(whisper_words, fn(w) { w.text })
  let whisper_starts = list.map(whisper_words, fn(w) { w.start })
  let whisper_ends = list.map(whisper_words, fn(w) { w.end })
  list.map(anchors, fn(anchor) {
    find_one_boundary(anchor, whisper_texts, whisper_starts, whisper_ends, word_count)
  })
}

// ── Internal: per-anchor boundary finding ──────────────────────────────────

fn find_one_boundary(
  anchor: BoundaryAnchor,
  whisper_texts: List(String),
  whisper_starts: List(Float),
  whisper_ends: List(Float),
  whisper_count: Int,
) -> BoundaryResult {
  case search_trigram(anchor, whisper_texts, whisper_starts, whisper_ends, whisper_count) {
    Some(result) -> result
    None -> fallback_boundary(anchor)
  }
}

fn search_trigram(
  anchor: BoundaryAnchor,
  whisper_texts: List(String),
  whisper_starts: List(Float),
  whisper_ends: List(Float),
  whisper_count: Int,
) -> Option(BoundaryResult) {
  // Dynamic threshold: 0.5 * n where n = actual combined anchor token count.
  // For normal 3-token anchors → 1.5 (unchanged).
  // For 2-token anchors (short "No." responses) → 1.0 (requires both match at least fuzzy).
  // For 1-token anchors → 0.5 (requires at least fuzzy match).
  let combined_tokens = list.append(anchor.last_tokens, anchor.first_tokens)
  let threshold = fuzzy_weight *. int.to_float(list.length(combined_tokens))

  let #(lo, hi) = search_window(anchor, whisper_count)

  // All positions in the window
  let positions = range_helper(lo, hi + 1)
  let scored = list.map(positions, fn(i) {
    score_position(anchor, whisper_texts, i, whisper_count)
  })

  // Pick highest-scoring Some(...)
  let best = list.fold(scored, None, fn(current, cand) {
    case cand {
      Some(#(idx, score)) ->
        case current {
          None -> Some(#(idx, score))
          Some(#(_, cur)) ->
            case score >. cur {
              True -> Some(#(idx, score))
              False -> current
            }
        }
      None -> current
    }
  })

  case best {
    None -> None
    Some(#(idx, score)) ->
      case score >=. threshold {
        True -> Some(build_boundary_result(anchor, whisper_starts, whisper_ends, idx, score))
        False -> None
      }
  }
}

// ── Internal: scoring ────────────────────────────────────────────────────

fn score_position(
  anchor: BoundaryAnchor,
  whisper_texts: List(String),
  start_idx: Int,
  whisper_count: Int,
) -> Option(#(Int, Float)) {
  let combined_tokens = list.append(anchor.last_tokens, anchor.first_tokens)
  let n = list.length(combined_tokens)
  case start_idx + n <= whisper_count {
    False -> None
    True -> {
      // Use stdlib list.index_fold — acc, item, index order
      let score = list.index_fold(combined_tokens, 0.0, fn(total, token, j) {
        let wtext = nth(whisper_texts, start_idx + j)
        case wtext {
          Some(t) -> total +. score_token(token, t)
          None -> total
        }
      })
      Some(#(start_idx, score))
    }
  }
}

fn score_token(token: Token, whisper_text: String) -> Float {
  case match_token(token, whisper_text) {
    ExactMatch -> exact_weight
    PrefixMatch(_) -> prefix_weight
    FuzzyMatch(_, _) -> fuzzy_weight
    NoMatch -> 0.0
  }
}

// ── Internal: build result from best match ─────────────────────────────────

fn build_boundary_result(
  anchor: BoundaryAnchor,
  whisper_starts: List(Float),
  whisper_ends: List(Float),
  best_idx: Int,
  _score: Float,
) -> BoundaryResult {
  let total_token_count = list.length(anchor.last_tokens) + list.length(anchor.first_tokens)
  let matched_indices = range_helper(best_idx, best_idx + total_token_count)

  // Boundary: midpoint between last whisper word of prev turn and first
  // whisper word of next turn.
  //   matched_indices[0..last_n-1] = last_tokens matched at whisper[best_idx..best_idx+last_n-1]
  //   matched_indices[last_n..]   = first_tokens matched at whisper[best_idx+last_n..]
  let last_n = list.length(anchor.last_tokens)
  case nth(whisper_ends, best_idx + last_n - 1), nth(whisper_starts, best_idx + last_n) {
    Some(prev_end), Some(next_start) -> {
      let boundary_s = { prev_end +. next_start } /. 2.0
      BoundaryResult(
        turn_before_index: anchor.turn_before_index,
        turn_after_index: anchor.turn_after_index,
        boundary_s:,
        confidence: Fuzzy,
        matched_whisper_indices: matched_indices,
      )
    }
    _, _ -> BoundaryResult(
      turn_before_index: anchor.turn_before_index,
      turn_after_index: anchor.turn_after_index,
      boundary_s: nth_or_default(whisper_starts, best_idx, 0.0),
      confidence: Fuzzy,
      matched_whisper_indices: matched_indices,
    )
  }
}

// ── Internal: fallback ────────────────────────────────────────────────────

fn fallback_boundary(anchor: BoundaryAnchor) -> BoundaryResult {
  BoundaryResult(
    turn_before_index: anchor.turn_before_index,
    turn_after_index: anchor.turn_after_index,
    boundary_s: 0.0,  // caller must fill via interpolation
    confidence: Fallback,
    matched_whisper_indices: [],
  )
}

// ── Helpers ────────────────────────────────────────────────────────────────

/// BEAM :lists.seq → [from, from+1, ..., to]
@external(erlang, "lists", "seq")
fn lists_seq(from: Int, to: Int) -> List(Int)

/// [from, from+1, ..., to-1]  (Python range semantics)
fn range_helper(from: Int, to: Int) -> List(Int) {
  case from >= to {
    True -> []
    False -> lists_seq(from, to - 1)
  }
}

/// Safe nth: return element at index, or None.
fn nth(xs: List(a), idx: Int) -> Option(a) {
  case list.drop(xs, idx) {
    [] -> None
    [h, ..] -> Some(h)
  }
}

fn nth_or_default(xs: List(a), idx: Int, default: a) -> a {
  case nth(xs, idx) {
    Some(v) -> v
    None -> default
  }
}
