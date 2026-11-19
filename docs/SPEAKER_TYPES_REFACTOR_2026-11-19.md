# Speaker Types Refactor — 2026-11-19

## Summary

Replaced the single abuse-prone `Role { Doctor Patient }` enum with:
- Two **proper standalone custom types** (`SpeakerA`, `SpeakerB`) representing actual speaker positions
- **Domain aliases** (`Doctor = SpeakerA`, `Patient = SpeakerB`) for readability in medical English
- A **speaker label** sum type (`SpeakerLabel`) wrapping them for use in `Turn.speaker_label`

**Result**: Every type name now means what it says. No more using "Doctor" to mean a single-letter enum branch when the real Doctor speaker type was never modeled at all.

---

## Why

### The original sin

The original audio_splitter had:

```gleam
pub type Role { Doctor Patient }   // two enum variants
pub type Turn { Turn(index: Int, role: Role, text: String) }
```

This was wrong for **three independent reasons**:

**1. Name abuse — "Doctor" was an enum variant, not a character type**

The word "Doctor" means a medical professional. But in the original code, `Role.Doctor` was just a branch of a switch that mapped to the letter `"D"`. It carried no Doctor-specific data or behavior. A Doctor with actual domain semantics — allowed utterances, vocabulary rules, speaker embeddings — never existed as a type at all.

**2. Generic tool carrying domain knowledge**

audio_splitter is a dialogue/audio alignment tool. It should work for any two-way dialogue — Q&A, customer support, interview, debate. Hardcoding `Doctor`/`Patient` constructors baked medical English into a tool that should be domain-agnostic.

**3. String boundary hidden inside an enum**

Every `Role` constructor was immediately converted back to a letter string `"D"`/`"P"` at the JSON/manifest boundary. The enum was pure indirection — wrapping a letter that was always unwrapped one step later.

### The false alias detour

Multiple attempts were made to "fix" this with type aliases:

```gleam
// ❌ Same-namespace collision — Doctor used twice
pub type Doctor = SpeakerA
pub type Role { Doctor Patient }   // Doctor is now both type alias AND constructor
```

Or even worse, invented syntax that doesn't exist in Gleam:

```gleam
pub type Doctor = Role.RecordSpeakerA   // ❌ Role.RecordSpeakerA is not valid Gleam
```

The user repeatedly pointed out that `SpeakerA` and `SpeakerB` are **different types** — like Dog and Pig — and that aliases should be **type-only** (no value-constructors with the same name).

### The English word confusion

The English word "character" means both a **letter** (D, P) and a **persona** (Doctor, Patient). The original code extended this ambiguity into Gleam types by using `Role { Doctor Patient }` to mean "which letter prefix appeared at the start of the transcript line."

The correct term for what appears at the start of a dialog line is **speaker prefix** or **speaker label** — not "role," not "character."

---

## What changed

### New shape

```gleam
// Generic speaker positions — domain-agnostic, reusable
pub type SpeakerA { SpeakerA }
pub type SpeakerB { SpeakerB }

// Domain aliases — medical English interpretation
pub type Doctor = SpeakerA
pub type Patient = SpeakerB

// The label that marked the speaker in the transcript prefix ("D:", "P:", etc.)
// Wraps SpeakerA/SpeakerB so Turn.speaker_label can hold either in a list
pub type SpeakerLabel {
  LabelDoctor(Doctor)
  LabelPatient(Patient)
}

// Turns now use speaker_label, not role
pub type Turn {
  Turn(index: Int, speaker_label: SpeakerLabel, text: String)
}
```

### Functions renamed

| Before | After | Reason |
|--------|-------|--------|
| `role_letter(Role) -> String` | `label_letter(SpeakerLabel) -> String` | Operates on labels, not roles |
| `role_from_letter(String) -> Option(Role)` | `label_from_letter(String) -> Option(SpeakerLabel)` | Parses to label, not role |

### Field renamed

| Before | After | Reason |
|--------|-------|--------|
| `Turn.role: Role` | `Turn.speaker_label: SpeakerLabel` | Field name matches type name |
| `AlignedTurn.role: Role` | `AlignedTurn.speaker_label: SpeakerLabel` | Same |

### Variables renamed

All local variables holding `SpeakerLabel` are now `label`, not `role`. No more misleading variable names.

### What was NOT changed

- **JSON wire-format key** still `"role"` — changing this would break existing manifests. The string `"D"`/`"P"` values stay the same.
- **Transcript prefixes** still `"D:"`/`"P:"` — tool reads user's convention, preserves it.
- **`label_from_letter` still accepts** `"D"`/`"d"`/`"A"`/`"a"` → LabelDoctor, `"P"`/`"p"`/`"B"`/`"b"` → LabelPatient — backward-compatible with both medical and generic conventions.

---

## Files modified (audio_splitter only)

| File | Change |
|------|--------|
| `src/audio_splitter/dialogue_types.gleam` | Core types — SpeakerA/B, Doctor/Patient aliases, SpeakerLabel, Turn.speaker_label |
| `src/audio_splitter/transcript_parser.gleam` | Imports, field access, variable names (`role`→`label`) |
| `src/audio_splitter/aligner.gleam` | `AlignedTurn.speaker_label`, import type name |
| `src/audio_splitter/manifest.gleam` | `label_letter(t.speaker_label)` |
| `src/audio_splitter/batch.gleam` | Field construction renamed |
| `src/audio_splitter/audio_splitter.gleam` | CLI display, field construction renamed |
| `test/audio_splitter_test.gleam` | All imports, constructors, field access, variable names |

**No new files.** No files deleted.

---

## Who is affected

### Direct consumers

| Consumer | What they need to change |
|----------|-------------------------|
| **speak_engl** (hex.pm dependency) | Imports `Role` → imports `SpeakerLabel`. Field `.role` → `.speaker_label`. Constructors `Doctor`/`Patient` → `LabelDoctor(SpeakerA)` / `LabelPatient(SpeakerB)`. Delete duplicate local `Role` type — import audio_splitter's. |

### Not affected

- **Existing manifest JSON files** — `"role": "D"` key and values unchanged
- **Transcript text files** — `"D:"`/`"P:"` prefixes unchanged
- **External audio_splitter CLI users** — output still shows `"D "`/`"P "` prefix

---

## What we learned about Gleam

1. **Type aliases are type-only.** `type Doctor = SpeakerA` does NOT create a `Doctor` value constructor. It means: wherever a type is expected, `Doctor` means exactly `SpeakerA`. This prevents same-name collision: you can have `type Doctor = SpeakerA` (alias) and `type SpeakerLabel { LabelDoctor(Doctor) }` (constructor using alias as argument type) with zero conflict, because aliases live in the type namespace and constructors live in the value namespace.

2. **Constructors are module-level, not type-scoped.** `Role.RecordSpeakerA` is NOT valid Gleam. Constructors sit at the same namespace level as functions and constants. This means two custom types CANNOT share a constructor name — it's a module collision.

3. **No `type X = A | B` union alias.** Gleam has no syntax to say "X is either A or B" as a type alias. The only way to put two different types in the same list field is a custom type that wraps them — i.e. the `SpeakerLabel` sum type.

4. **Type aliases should be rare (gleam.run guidance).** They're for documenting complex types or giving short names to long signatures. Aliasing trivial single-variant custom types to other trivial single-variant types — like `Doctor = SpeakerA` — buys zero simplification and creates naming confusion. The only defense is that it documents domain intent for the human reader.

---

## Verification

```
audio_splitter: gleam build --warnings-as-errors → clean
audio_splitter: gleam test → 23 passed, no failures
```

speak_engl has NOT been updated to consume the new API yet — that's the next step, documented above.

---

## What to avoid next time

1. **Your label is not you.** The letter `"D"` at the start of a transcript line is NOT the Doctor. The Doctor is a person — with domain knowledge, vocabulary constraints, speaker embeddings, behavioral rules. The label is a single-letter mark. Never name a type or constructor after a thing it doesn't represent. **This is also namespace theft:** by naming an enum constructor `Doctor`, you steal the word. The real Doctor (a medical professional with actual capabilities) now has nowhere clean to live — the name is already taken by a switch branch. Even if you somehow manage to have both in different namespaces (Gleam's value vs type namespaces), every reader must scan surrounding context to know which one they're looking at. Chaos is guaranteed. This is the most basic naming discipline — confusing an identifier with the thing it identifies is a low-level mistake, easy to make when rushed, and the source of every other bad design decision that followed in this session.
2. **Don't encode domain knowledge in a generic tool's type constructors.** Speaker positions are generic; who they are (Doctor/Patient, Q/A, Host/Guest) is domain interpretation.
3. **Don't invent syntax.** `Role.RecordSpeakerA`, `type X = A | B` — if you're not 100% sure Gleam has this, compile a 3-line probe first.
4. **Don't use `role` as a variable name for a label.** A role is what someone does (treating, instructing, questioning). A label is a single-letter mark at the start of a line. They're different concepts.
5. **Don't commit half-finished refactors.** Every step in this file was tested before moving to the next. No commits until everything compiled green.
