//// word_matcher — normalize + fuzzy-match words between transcript and whisper.
////
//// Why fuzzy match?
////   Whisper ggml-tiny hallucinates ~5% of words:
////     "definitely" ↔ "definitly"   (missing letter)
////     "radiating"  ↔ "radiate"     (truncated)
////     "OK,"        ↔ "ok"          (punctuation difference)
////   We DON'T care about whisper's text accuracy — we only care about
////   its TIMESTAMPS. But to find which whisper word corresponds to a
////   transcript anchor word, we need tolerant matching.
////
//// Strategy (best-first):
////   1. Normalize both sides: lowercase + keep only letters/digits
////      — implemented via `gleam_regexp.replace("[^\p{L}\p{N}]", "")`
////   2. Tokenize sentence via `gleam_regexp.split("[^\p{L}\p{N}]+")`
////   3. Match levels: Exact → Prefix → Fuzzy(jaro ≥ 0.85 | levenshtein ≤ 2) → NoMatch
////
//// Dependencies (all available on BEAM target):
////   - gleam_regexp (hex.pm, lpil official) — regex split + replace
////   - edit_distance (hex.pm) — pure Gleam levenshtein
////   - Elixir String.jaro_distance — @external BEAM built-in C-speed
////   - Elixir String.to_charlist — @external, gives codepoint Int list
////
//// This module has NO knowledge of audio, whisper, or transcript format.
//// It is a pure text matching utility.

import edit_distance.{levenshtein}
import gleam/list
import gleam/string
import gleam/regexp.{from_string, replace, split}

// ── BEAM @externals — Elixir String functions (BEAM stdlib, no deps) ─────

/// Elixir String.jaro_distance/2 — float 0.0–1.0.
/// 1.0 = identical, 0.0 = nothing in common.
/// Jaro is tuned for short strings and weighted toward transpositions —
/// exactly whisper's most common mistake type. BEAM C-speed NIF.
@external(erlang, "Elixir.String", "jaro_distance")
fn jaro(a: String, b: String) -> Float

// ── Types ──────────────────────────────────────────────────────────────────

/// A normalized word ready for matching.
pub type Token {
  Token(raw: String, norm: String)
}

/// Outcome of matching one Token against a whisper word.
pub type MatchResult {
  ExactMatch
  PrefixMatch(prefix_len: Int)
  FuzzyMatch(score: Float, edit_distance: Int)
  NoMatch
}

// ── Constants ──────────────────────────────────────────────────────────────

/// Unicode-aware: split on any non-letter/digit run.
///   "Yes, definitely." → ["yes", "definitely"]
///   Uses \p{L} and \p{N} Unicode categories so accented chars work too.
const non_word_pattern: String = "[^\\p{L}\\p{N}]+"

/// Unicode-aware: keep only letters/digits, strip everything else.
///   "Definitely." → "definitely"
const strip_pattern: String = "[^\\p{L}\\p{N}]"

const fuzzy_threshold: Float = 0.85    // jaro >= 0.85 → close enough
const max_edit_distance: Int = 2       // levenshtein ≤ 2 → close enough

// ── Public API ──────────────────────────────────────────────────────────────

/// Split a sentence into normalized Tokens.
/// "Yes, definitely." → [Token("yes", "yes"), Token("definitely", "definitely")]
pub fn tokenize(text: String) -> List(Token) {
  case from_string(non_word_pattern) {
    Ok(re) -> {
      let lowered = string.lowercase(text)
      let parts = split(with: re, content: lowered)
      parts
      |> list.filter(fn(s) { s != "" })
      |> list.map(fn(norm) { Token(raw: norm, norm:) })
    }
    Error(_) -> panic as "word_matcher: non_word_pattern regex failed"
  }
}

/// Create a Token from a single raw word (normalizes it).
pub fn make_token(raw: String) -> Token {
  Token(raw, normalize(raw))
}

/// Compare transcript token against a whisper word text.
pub fn match_token(token: Token, whisper_text: String) -> MatchResult {
  let wnorm = normalize(whisper_text)
  case token.norm, wnorm {
    "", _ -> NoMatch
    _, "" -> NoMatch
    a, b if a == b -> ExactMatch
    a, b -> match_fuzzy(a, b)
  }
}

/// Find best match for one transcript token within a window of whisper words.
/// Each whisper word is (original_index, text).
pub fn find_best_in_window(
  token: Token,
  whisper_words: List(#(Int, String)),
) -> Result(#(Int, MatchResult), Nil) {
  list.fold(whisper_words, Error(Nil), fn(best, pair) {
    let idx = pair.0
    let res = match_token(token, pair.1)
    case best {
      Error(_) -> Ok(#(idx, res))
      Ok(#(_, existing)) ->
        case better_match(res, existing) {
          True -> Ok(#(idx, res))
          False -> best
        }
    }
  })
}

/// Normalize one word: lowercase + keep only letters/digits.
/// "Definitely." → "definitely",  "OK," → "ok"
pub fn normalize(s: String) -> String {
  case from_string(strip_pattern) {
    Ok(re) -> replace(each: re, in: string.lowercase(s), with: "")
    Error(_) -> panic as "word_matcher: strip_pattern regex failed"
  }
}

// ── Internal: matching logic ──────────────────────────────────────────────

fn match_fuzzy(a: String, b: String) -> MatchResult {
  // Prefix/suffix containment: "def" matches "definitely" OR vice versa
  case string.starts_with(a, b), string.starts_with(b, a) {
    True, _ -> PrefixMatch(list.length(string.to_graphemes(b)))
    _, True -> PrefixMatch(list.length(string.to_graphemes(a)))
    False, False -> match_distance(a, b)
  }
}

/// Fuzzy match: first try jaro ≥ threshold, then try levenshtein ≤ limit.
fn match_distance(a: String, b: String) -> MatchResult {
  let j = jaro(a, b)
  let ed = levenshtein(a, b)
  case j >=. fuzzy_threshold || ed <= max_edit_distance {
    True -> FuzzyMatch(score: j, edit_distance: ed)
    False -> NoMatch
  }
}

fn better_match(candidate: MatchResult, current: MatchResult) -> Bool {
  case candidate, current {
    ExactMatch, _ -> True
    _, ExactMatch -> False
    PrefixMatch(prefix_len: la), PrefixMatch(prefix_len: lb) -> la > lb
    PrefixMatch(_), FuzzyMatch(_, _) -> True        // exact prefix > fuzzy non-prefix
    FuzzyMatch(_, _), PrefixMatch(_) -> False
    FuzzyMatch(score: sa, edit_distance: ea), FuzzyMatch(score: sb, edit_distance: eb) -> {
      case sa >=. sb {
        True -> ea <= eb
        False -> False
      }
    }
    NoMatch, _ -> False
    _, NoMatch -> True
  }
}
