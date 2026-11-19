import gleam/float
import gleam/list
import gleam/option.{Some}
import gleeunit
import gleeunit/should
import audio_splitter/aligner
import audio_splitter/anchor_extractor
import audio_splitter/dialogue_types.{LabelDoctor, LabelPatient, SpeakerA, SpeakerB, Turn}
import audio_splitter/transcript_parser as parser
import audio_splitter/trigram_alignment as trigram
import audio_splitter/whisper_driver.{Segment, Word}
import audio_splitter/word_matcher.{
  type Token,
  Token,
  match_token,
  tokenize,
  normalize,
  ExactMatch,
  PrefixMatch,
  FuzzyMatch,
  NoMatch,
}

pub fn main() { gleeunit.main() }

// ── count_words ───────────────────────────────────────────────────────────

pub fn count_words_test() {
  should.equal(aligner.count_words(""), 0)
  should.equal(aligner.count_words("hello"), 1)
  should.equal(aligner.count_words("one two three"), 3)
  should.equal(aligner.count_words("  leading  and  trailing  "), 3)
  should.equal(aligner.count_words("  multiple   spaces   here  "), 3)
}

// ── flatten_words ────────────────────────────────────────────────────────

pub fn flatten_words_test() {
  let segments = [
    Segment(
      text: "a b",
      start: 0.0,
      end: 0.5,
      words: [
        Word(text: "a", start: 0.0, end: 0.2, probability: 1.0, segment_index: 0),
        Word(text: "b", start: 0.3, end: 0.5, probability: 1.0, segment_index: 0),
      ],
    ),
    Segment(
      text: "c",
      start: 0.5,
      end: 0.7,
      words: [Word(text: "c", start: 0.5, end: 0.7, probability: 1.0, segment_index: 0)],
    ),
  ]
  let flat = aligner.flatten_words(segments)
  should.equal(list.length(flat), 3)
  should.equal(list.map(flat, fn(w) { w.text }), ["a", "b", "c"])
}

// ── align_turns edge cases ─────────────────────────────────────────────────

pub fn align_no_turns_test() {
  let words = [Word(text: "hi", start: 0.0, end: 0.1, probability: 1.0, segment_index: 0)]
  case aligner.align_turns([], words, 5.0) {
    Error(aligner.EmptyTranscript) -> Nil
    _ -> panic
  }
}

pub fn align_no_words_test() {
  let turns = [Turn(index: 0, speaker_label: LabelDoctor(SpeakerA), text: "hello")]
  case aligner.align_turns(turns, [], 5.0) {
    Error(aligner.NoWordTimestamps) -> Nil
    _ -> panic
  }
}

pub fn align_single_turn_anchors_test() {
  let turns = [Turn(index: 0, speaker_label: LabelDoctor(SpeakerA), text: "hi")]
  let words = [Word(text: "hi", start: 0.5, end: 0.7, probability: 1.0, segment_index: 0)]
  case aligner.align_turns(turns, words, 5.0) {
    Ok(aligned) -> {
      case list.first(aligned) {
        Ok(a) -> {
          should.equal(a.index, 0)
          should.equal(a.speaker_label, LabelDoctor(SpeakerA))
          let start_ok = float.absolute_value(a.audio_start_s -. 0.0) <. 0.01
          let end_ok = float.absolute_value(a.audio_end_s -. 5.0) <. 0.01
          should.be_true(start_ok)
          should.be_true(end_ok)
        }
        Error(_) -> panic
      }
    }
    Error(_) -> panic
  }
}

// ── anchor_extractor ──────────────────────────────────────────────────────

pub fn extract_anchors_no_turns_test() {
  should.equal(anchor_extractor.extract_anchors([], 100), [])
}

pub fn extract_anchors_one_turn_test() {
  let turns = [Turn(index: 0, speaker_label: LabelDoctor(SpeakerA), text: "hello world")]
  should.equal(anchor_extractor.extract_anchors(turns, 100), [])
}

pub fn extract_anchors_two_turns_test() {
  let turns = [
    Turn(index: 0, speaker_label: LabelDoctor(SpeakerA), text: "Hello"),
    Turn(index: 1, speaker_label: LabelPatient(SpeakerB), text: "Hi there"),
  ]
  let anchors = anchor_extractor.extract_anchors(turns, 4)
  should.equal(list.length(anchors), 1)
  case list.first(anchors) {
    Ok(a) -> {
      should.equal(a.turn_before_index, 0)
      should.equal(a.turn_after_index, 1)
      // tail = last 1 token of "Hello" → "hello"
      // head = first 2 tokens of "Hi there" → ["hi", "there"]
      let tail_texts = list.map(a.last_tokens, fn(t: Token) { t.norm })
      let head_texts = list.map(a.first_tokens, fn(t: Token) { t.norm })
      should.equal(tail_texts, ["hello"])
      should.equal(head_texts, ["hi", "there"])
    }
    Error(_) -> panic
  }
}

pub fn extract_anchors_multi_turns_test() {
  let raw = "D: What brings you in today?\n\nP: I feel sick"
  let turns = parser.parse_transcript(raw)
  let anchors = anchor_extractor.extract_anchors(turns, 20)
  // 2 turns → 1 boundary anchor
  should.equal(list.length(anchors), 1)
  case list.first(anchors) {
    Ok(a) -> {
      // tail of "What brings you in today?" → 1 word "today"
      // head of "I feel sick" → 2 words "i", "feel"
      let tail = list.map(a.last_tokens, fn(t: Token) { t.norm })
      let head = list.map(a.first_tokens, fn(t: Token) { t.norm })
      should.equal(tail, ["today"])
      should.equal(head, ["i", "feel"])
    }
    Error(_) -> panic
  }
}

// ── word_matcher ──────────────────────────────────────────────────────────

pub fn normalize_basic_test() {
  should.equal(normalize("definitely."), "definitely")
  should.equal(normalize("OK,"), "ok")
  should.equal(normalize("  Hello!  "), "hello")
}

pub fn tokenize_basic_test() {
  let tokens = tokenize("Yes, definitely.")
  should.equal(list.length(tokens), 2)
  should.equal(list.map(tokens, fn(t: Token) { t.norm }), ["yes", "definitely"])
}

pub fn match_exact_test() {
  let t = Token(raw: "ok", norm: "ok")
  should.equal(match_token(t, "ok"), ExactMatch)
}

pub fn match_prefix_test() {
  let t = Token(raw: "def", norm: "def")
  case match_token(t, "definitely") {
    PrefixMatch(_) -> Nil
    _ -> panic
  }
}

pub fn match_fuzzy_test() {
  // "definitely" ↔ "definitly" (missing 'e') — jaro ≈ 0.92, fuzzy match
  let t = Token(raw: "definitely", norm: "definitely")
  case match_token(t, "definitly") {
    FuzzyMatch(_, _) -> Nil
    _ -> panic
  }
}

pub fn match_no_match_test() {
  let t = Token(raw: "yes", norm: "yes")
  should.equal(match_token(t, "definitely"), NoMatch)
}

// ── trigram_alignment: align_boundaries ───────────────────────────────────

pub fn trigram_empty_anchors_test() {
  let words = [Word(text: "a", start: 0.0, end: 0.1, probability: 1.0, segment_index: 0)]
  let results = trigram.align_boundaries([], words)
  should.equal(list.length(results), 0)
}

pub fn trigram_perfect_match_test() {
  let turns = [
    Turn(index: 0, speaker_label: LabelDoctor(SpeakerA), text: "OK do you find"),
    Turn(index: 1, speaker_label: LabelPatient(SpeakerB), text: "No I don't"),
  ]
  let anchors = anchor_extractor.extract_anchors(turns, 6)
  // whisper words exactly matching the boundary trigram
  let words = [
    Word(text: "ok", start: 1.0, end: 1.2, probability: 1.0, segment_index: 0),
    Word(text: "do", start: 1.3, end: 1.5, probability: 1.0, segment_index: 0),
    Word(text: "you", start: 1.6, end: 1.8, probability: 1.0, segment_index: 0),
    Word(text: "find", start: 1.9, end: 2.1, probability: 1.0, segment_index: 0),
    Word(text: "no", start: 3.0, end: 3.1, probability: 1.0, segment_index: 0),
    Word(text: "i", start: 3.2, end: 3.3, probability: 1.0, segment_index: 0),
  ]
  let results = trigram.align_boundaries(anchors, words)
  should.equal(list.length(results), 1)
  case list.first(results) {
    Ok(r) -> {
      // confidence should NOT be Fallback — we matched exact trigrams
      case r.confidence {
        trigram.Fallback -> panic
        _ -> Nil
      }
      // boundary should be somewhere reasonable (not 0.0)
      should.be_true(r.boundary_s >. 0.0)
    }
    Error(_) -> panic
  }
}

// ── transcript_parser ──────────────────────────────────────────────────────

pub fn parse_speaker_line_doctor_test() {
  should.equal(parser.parse_speaker_line("D: hello"), Some(#(LabelDoctor(SpeakerA), "hello")))
}

pub fn parse_speaker_line_patient_test() {
  should.equal(parser.parse_speaker_line("P: hi there"), Some(#(LabelPatient(SpeakerB), "hi there")))
}

pub fn parse_empty_test() {
  should.equal(parser.parse_transcript(""), [])
}

pub fn parse_basic_dialogue_test() {
  let raw = "D: Hello\nP: Hi there\nD: How are you?"
  let turns = parser.parse_transcript(raw)
  should.equal(list.length(turns), 3)
  should.equal(list.map(turns, fn(t) { t.index }), [0, 1, 2])
  should.equal(list.map(turns, fn(t) { t.speaker_label }), [LabelDoctor(SpeakerA), LabelPatient(SpeakerB), LabelDoctor(SpeakerA)])
}

pub fn parse_continuation_line_test() {
  let raw = "D: I thought it might be a\nchest infection or something\nP: Oh I see"
  let turns = parser.parse_transcript(raw)
  should.equal(list.length(turns), 2)
  case turns {
    [Turn(text: t, ..), _] -> should.equal(t, "I thought it might be a chest infection or something")
    _ -> panic
  }
}

pub fn parse_indices_sequential_test() {
  let raw = "D: one\nP: two\nD: three\nP: four"
  let turns = parser.parse_transcript(raw)
  should.equal(list.map(turns, fn(t) { t.index }), [0, 1, 2, 3])
}
