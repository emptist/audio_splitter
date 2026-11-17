//// anchor_extractor — extract boundary anchor word groups from transcript turns.
////
//// What problem it solves:
////   Given transcript Turn list, we know speaker boundaries but have NO audio
////   timestamps. Whisper transcribe gives us word timestamps but NO speaker
////   labels. We need to "glue" them together.
////
//// Strategy:
////   For every pair of adjacent turns (prev → curr), extract:
////     - LAST N normalized token(s) from prev turn text (tail)
////     - FIRST M normalized token(s) from curr turn text (head)
////   These form a **boundary anchor** — a small set of words that should
////   appear consecutively in the whisper word stream near the speaker
////   change. We then search whisper's word list for this anchor.
////
////   Example (CAR0001.txt lines 35-43):
////     Turn P: "Yes, definitely."
////     Turn D: "OK, do you find that the pain is radiating anywhere?"
////     → tail=["definitely"], head=["ok", "do"]
////     → whisper should have [..., "definitely", "ok", "do", ...]
////     → boundary = end_of_"definitely" / start_of_"ok"
////
////   To FIND this whisper position efficiently:
////     We compute expected_whisper_index via proportional math:
////       ratio = whisper_total_words / transcript_total_words
////       expected = cumulative_transcript_words_at_boundary * ratio
////       search_window = [expected - 5%, expected + 5%]
////     Only search that window — not the full whisper word list.
////
//// Output type: BoundaryAnchor — carries everything trigram_alignment needs.

import gleam/list
import gleam/int
import gleam/string
import alignment/dialogue_types.{type Turn}
import alignment/word_matcher.{type Token, tokenize}

// ── Types ──────────────────────────────────────────────────────────────────

/// One boundary anchor between two adjacent transcript turns.
pub type BoundaryAnchor {
  BoundaryAnchor(
    /// Transcript index of the turn BEFORE the boundary
    turn_before_index: Int,
    /// Transcript index of the turn AFTER the boundary
    turn_after_index: Int,
    /// Normalized tokens from the END of the previous turn (1 word)
    last_tokens: List(Token),
    /// Normalized tokens from the START of the next turn (2 words)
    first_tokens: List(Token),
    /// Estimated whisper word index where this boundary falls.
    /// float because it's fractional: e.g. 847.3
    expected_whisper_index: Float,
  )
}

// ── Constants ──────────────────────────────────────────────────────────────

const tail_words: Int = 1
const head_words: Int = 2
const window_pct: Float = 0.05     // ±5% search window around expected index

// ── Public API ──────────────────────────────────────────────────────────────

/// Extract boundary anchors from a full transcript Turn list.
///
/// Algorithm:
///   1. Compute transcript_total_words (counts whitespace splits)
///   2. ratio = whisper_total_words / transcript_total_words
///   3. Walk adjacent turn pairs, accumulating word count so far
///   4. For each pair: extract tail/head tokens, expected whisper index
pub fn extract_anchors(turns: List(Turn), whisper_total_words: Int) -> List(BoundaryAnchor) {
  let transcript_total = list.fold(turns, 0, fn(acc, t) {
    acc + count_words_in_turn(t)
  })
  case transcript_total, whisper_total_words {
    0, _ -> []
    _, 0 -> []
    _, _ -> {
      let ratio = int.to_float(whisper_total_words) /. int.to_float(transcript_total)
      let anchors = build_anchors(turns, ratio, 0, [])
      list.reverse(anchors)
    }
  }
}

/// Whitespace-word count for one Turn — used for proportional estimation.
/// We DON'T use word_matcher.tokenize here because we just need a rough
/// count; accuracy comes from the fuzzy matching later.
pub fn count_words_in_turn(t: Turn) -> Int {
  t.text
  |> string.split(" ")
  |> list.filter(fn(s) { s != "" })
  |> list.length
}

/// Given a BoundaryAnchor and the full whisper word count, return the
/// (start, end) whisper index search window.
/// We search only this window — not all whisper words.
pub fn search_window(anchor: BoundaryAnchor, whisper_total: Int) -> #(Int, Int) {
  let center = anchor.expected_whisper_index
  let half_window = int.to_float(whisper_total) *. window_pct
  let lower = floor(center -. half_window)
  let upper = ceil(center +. half_window)
  let lo = max3(lower, 0, whisper_total)
  let hi = min3(upper, whisper_total - 1, whisper_total)
  #(lo, hi)
}

// ── Internal ──────────────────────────────────────────────────────────────

fn build_anchors(
  turns: List(Turn),
  ratio: Float,
  cumulative_words: Int,
  acc: List(BoundaryAnchor),
) -> List(BoundaryAnchor) {
  case turns {
    [] -> acc
    [_] -> acc
    [prev, next, ..rest] -> {
      let prev_word_count = count_words_in_turn(prev)

      // Extract tokens
      let tail = take_last_n(tokenize(prev.text), tail_words)
      let head = take_first_n(tokenize(next.text), head_words)

      // Expected whisper index for the boundary:
      //   We've accumulated `cumulative_words + prev_word_count` transcript
      //   words up to (and including) the prev turn. The boundary between
      //   prev and next sits right after prev's last word.
      let boundary_transcript_pos = cumulative_words + prev_word_count
      let expected = int.to_float(boundary_transcript_pos) *. ratio

      let anchor = BoundaryAnchor(
        turn_before_index: prev.index,
        turn_after_index: next.index,
        last_tokens: tail,
        first_tokens: head,
        expected_whisper_index: expected,
      )

      let new_cumulative = cumulative_words + prev_word_count
      build_anchors([next, ..rest], ratio, new_cumulative, [anchor, ..acc])
    }
  }
}

fn take_last_n(items: List(a), n: Int) -> List(a) {
  list.reverse(items) |> list.take(n) |> list.reverse
}

fn take_first_n(items: List(a), n: Int) -> List(a) {
  list.take(items, n)
}

fn floor(f: Float) -> Int {
  trunc(f)
}

fn ceil(f: Float) -> Int {
  let t = trunc(f)
  case int.to_float(t) <. f {
    True -> t + 1
    False -> t
  }
}

/// BEAM erlang:trunc — truncate a float to its integer part.
/// Equivalent to int.from_float but BEAM-native for any float.
@external(erlang, "erlang", "trunc")
fn trunc(f: Float) -> Int

fn min3(a: Int, b: Int, cap: Int) -> Int {
  let m = case a < b {
    True -> a
    False -> b
  }
  case m < cap {
    True -> m
    False -> cap
  }
}

fn max3(a: Int, lo: Int, _cap: Int) -> Int {
  case a > lo {
    True -> a
    False -> lo
  }
}
