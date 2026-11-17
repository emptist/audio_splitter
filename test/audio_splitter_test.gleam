import gleam/float
import gleam/list
import gleam/option.{None, Some}
import gleeunit
import gleeunit/should
import alignment/aligner
import alignment/dialogue_types.{Doctor, Patient, Turn}
import alignment/transcript_parser as parser
import alignment/whisper_driver.{Segment, Word}

pub fn main() { gleeunit.main() }

// ── count_words ───────────────────────────────────────────────────────────

pub fn count_words_test() {
  should.equal(aligner.count_words(""), 0)
  should.equal(aligner.count_words("hello"), 1)
  should.equal(aligner.count_words("one two three"), 3)
  should.equal(aligner.count_words("  leading  and  trailing  "), 3)
  should.equal(aligner.count_words("  multiple   spaces   here  "), 3)
}

// ── find_silence_gaps ──────────────────────────────────────────────────────

pub fn find_silence_gaps_no_words_test() {
  should.equal(aligner.find_silence_gaps([], 0.3), [])
}

pub fn find_silence_gaps_single_word_test() {
  should.equal(
    aligner.find_silence_gaps(
      [Word(text: "hi", start: 0.0, end: 0.1, probability: 1.0)],
      0.3,
    ),
    [],
  )
}

pub fn find_silence_gaps_below_threshold_test() {
  // Gap of 0.2s → below 0.3s threshold → no gaps
  let words = [
    Word(text: "a", start: 0.0, end: 0.1, probability: 1.0),
    Word(text: "b", start: 0.3, end: 0.4, probability: 1.0),
  ]
  should.equal(aligner.find_silence_gaps(words, 0.3), [])
}

pub fn find_silence_gaps_above_threshold_test() {
  let words = [
    Word(text: "a", start: 0.0, end: 0.1, probability: 1.0),
    Word(text: "b", start: 0.6, end: 0.7, probability: 1.0),
  ]
  let gaps: List(aligner.SilenceGap) = aligner.find_silence_gaps(words, 0.3)
  should.equal(list.length(gaps), 1)
  case list.first(gaps) {
    Ok(gap) -> {
      should.equal(gap.start, 0.1)
      should.equal(gap.end, 0.6)
      should.equal(gap.duration, 0.5)
    }
    Error(_) -> panic
  }
}

pub fn find_silence_gaps_multiple_test() {
  let words = [
    Word(text: "a", start: 0.0, end: 0.1, probability: 1.0),
    Word(text: "b", start: 0.6, end: 0.7, probability: 1.0),
    Word(text: "c", start: 0.75, end: 0.85, probability: 1.0),
    Word(text: "d", start: 1.5, end: 1.6, probability: 1.0),
  ]
  let gaps = aligner.find_silence_gaps(words, 0.3)
  should.equal(list.length(gaps), 2)
}

// ── align_turns: edge cases ───────────────────────────────────────────────

pub fn align_no_turns_test() {
  let words = [Word(text: "hi", start: 0.0, end: 0.1, probability: 1.0)]
  case aligner.align_turns([], words, 5.0) {
    Error(aligner.EmptyTranscript) -> Nil
    _ -> panic
  }
}

pub fn align_no_words_test() {
  let turns = [Turn(index: 0, role: Doctor, text: "hello")]
  case aligner.align_turns(turns, [], 5.0) {
    Error(aligner.NoWordTimestamps) -> Nil
    _ -> panic
  }
}

pub fn align_single_turn_single_word_test() {
  let turns = [Turn(index: 0, role: Doctor, text: "hi")]
  let words = [Word(text: "hi", start: 0.5, end: 0.7, probability: 1.0)]
  case aligner.align_turns(turns, words, 5.0) {
    Ok(aligned) -> {
      case list.first(aligned) {
        Ok(a) -> {
          should.equal(a.index, 0)
          should.equal(a.role, Doctor)
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

// ── align_turns: two turns, three words (regression sanity) ────────────────

pub fn align_two_turns_three_words_test() {
  let turns = [
    Turn(index: 0, role: Doctor, text: "hello"),
    Turn(index: 1, role: Patient, text: "hi there"),
  ]
  let words = [
    Word(text: "hello", start: 0.5, end: 0.7, probability: 1.0),
    Word(text: "hi", start: 3.0, end: 3.1, probability: 1.0),
    Word(text: "there", start: 3.2, end: 3.4, probability: 1.0),
  ]
  case aligner.align_turns(turns, words, 6.0) {
    Ok(aligned) -> {
      should.equal(list.length(aligned), 2)
      // Boundaries should be monotonic
      case aligned {
        [t0, t1] -> {
          let ordered = t0.audio_end_s <=. t1.audio_start_s
          should.be_true(ordered)
        }
        _ -> panic
      }
    }
    Error(_) -> panic
  }
}

// ── flatten_words flattens segments ───────────────────────────────────────

pub fn flatten_words_test() {
  let segments = [
    Segment(
      text: "a b",
      start: 0.0,
      end: 0.5,
      words: [
        Word(text: "a", start: 0.0, end: 0.2, probability: 1.0),
        Word(text: "b", start: 0.3, end: 0.5, probability: 1.0),
      ],
    ),
    Segment(
      text: "c",
      start: 0.5,
      end: 0.7,
      words: [Word(text: "c", start: 0.5, end: 0.7, probability: 1.0)],
    ),
  ]
  let flat = aligner.flatten_words(segments)
  should.equal(list.length(flat), 3)
  should.equal(list.map(flat, fn(w) { w.text }), ["a", "b", "c"])
}

// ── transcript_parser: parse_speaker_line ─────────────────────────────────

pub fn parse_speaker_line_doctor_test() {
  should.equal(parser.parse_speaker_line("D: hello"), Some(#(Doctor, "hello")))
}

pub fn parse_speaker_line_patient_test() {
  should.equal(parser.parse_speaker_line("P: hi there"), Some(#(Patient, "hi there")))
}

pub fn parse_speaker_line_trim_test() {
  should.equal(parser.parse_speaker_line("  D:  leading space  "), Some(#(Doctor, "leading space")))
}

pub fn parse_speaker_line_unknown_prefix_test() {
  should.equal(parser.parse_speaker_line("X: nope"), None)
}

pub fn parse_speaker_line_empty_test() {
  should.equal(parser.parse_speaker_line(""), None)
}

// ── transcript_parser: parse_transcript edge cases ────────────────────────

pub fn parse_empty_test() {
  should.equal(parser.parse_transcript(""), [])
}

pub fn parse_only_blank_lines_test() {
  should.equal(parser.parse_transcript("\n\n\n"), [])
}

pub fn parse_single_doctor_test() {
  let turns = parser.parse_transcript("D: Good morning")
  should.equal(list.length(turns), 1)
  case list.first(turns) {
    Ok(Turn(index: 0, role: Doctor, text: "Good morning")) -> Nil
    _ -> panic
  }
}

pub fn parse_single_patient_test() {
  let turns = parser.parse_transcript("P: I feel sick")
  should.equal(list.length(turns), 1)
  case list.first(turns) {
    Ok(Turn(index: 0, role: Patient, text: "I feel sick")) -> Nil
    _ -> panic
  }
}

pub fn parse_basic_dialogue_test() {
  let raw = "D: Hello\nP: Hi there\nD: How are you?"
  let turns = parser.parse_transcript(raw)
  should.equal(list.length(turns), 3)
  should.equal(list.map(turns, fn(t) { t.index }), [0, 1, 2])
  should.equal(list.map(turns, fn(t) { t.role }), [Doctor, Patient, Doctor])
}

pub fn parse_blank_line_separator_test() {
  // Turns separated by blank lines
  let raw = "D: What brings you in?\n\nP: I have a headache\n"
  let turns = parser.parse_transcript(raw)
  should.equal(list.length(turns), 2)
}

pub fn parse_continuation_line_test() {
  // Non-speaker line after a speaker line is merged
  let raw = "D: I thought it might be a\nchest infection or something\nP: Oh I see"
  let turns = parser.parse_transcript(raw)
  should.equal(list.length(turns), 2)
  case turns {
    [Turn(text: t, ..), _] -> should.equal(t, "I thought it might be a chest infection or something")
    _ -> panic
  }
}

pub fn parse_crlf_line_endings_test() {
  let raw = "D: Hello\r\nP: Hi\r\n"
  let turns = parser.parse_transcript(raw)
  should.equal(list.length(turns), 2)
}

pub fn parse_unknown_lines_ignored_test() {
  // Lines without D:/P: are ignored (unless continuation)
  let raw = "some header\nD: Real line\nfooter text"
  let turns = parser.parse_transcript(raw)
  // "some header" → no pending role, ignored
  // "D: Real line" → starts turn 0
  // "footer text" → continuation (no D:/P: prefix, pending role exists)
  should.equal(list.length(turns), 1)
  case list.first(turns) {
    Ok(Turn(text: t, ..)) -> should.equal(t, "Real line footer text")
    _ -> panic
  }
}

pub fn parse_indices_sequential_test() {
  let raw = "D: one\nP: two\nD: three\nP: four"
  let turns = parser.parse_transcript(raw)
  should.equal(list.map(turns, fn(t) { t.index }), [0, 1, 2, 3])
}
