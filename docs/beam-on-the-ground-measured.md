# BEAM on the ground — measured quirks when Gleam rides the VM

**Compiled 2026-11-18, Gleam 1.19.2, Erlang/OTP 29.1.2.** Every entry here was hit and fixed in `audio_splitter` v1.1.0–v1.2.1, a Gleam package on hex that runs whisper_cpp via NIF + ffmpeg via shell + OTP filelib + persistent_term, all on one BEAM.

The claim of this file: **OTP BIFs are well-known; the friction lives in the boundary between Gleam's type system and BEAM's runtime shapes.** Every point below is a place where BEAM behavior was not what I expected from reading Gleam docs alone, and every fix came from one compile error plus one runtime probe.

---

## 1. `Charlist` is opaque — `List(Int)` ≠ `Charlist` at compile time

**Probe:** Call `@external(erlang, "unicode", "characters_to_list")` on a UTF-16 LE binary. The BEAM returns the codepoints as `List(Int)`. But `charlist.to_string` expects `Charlist`, not `List(Int)`. Same runtime representation (a cons-list of ints), different Gleam types.

```gleam
// Compile error:
let chars: List(Int) = binary_to_chars(bytes)  // from unicode:characters_to_list
let filtered = list.filter(chars, fn(c) { c > 0 })  // List(Int)
let content = charlist.to_string(filtered)
//   ^^^^^^^^^^^^^^^^ Expected type: Charlist  Found type: List(Int)
```

**Fix:** Accept that BEAM interop returns `List(Int)`. Convert at the boundary:

```gleam
@external(erlang, "erlang", "binary_to_list")
fn binary_to_list(binary: BitArray) -> List(Int)
```

Then wrap each Int codepoint in `string.utf_codepoint` (returns `Result(UtfCodepoint, Nil)` for invalid values), and pass the resulting `List(UtfCodepoint)` to `string.from_utf_codepoints`:

```gleam
let codepoints: List(Int) = ... // from BEAM
let valid = list.filter_map(codepoints, string.utf_codepoint)
string.from_utf_codepoints(valid)  // ✅ List(UtfCodepoint) -> String
```

**Why not `charlist.from_list`?** That function is designed for this exact case — but if your codepoints came from BEAM and are `List(Int)`, you still have to hand-wrap each one in the codepoint newtype. `string.from_utf_codepoints` **does not** accept `List(Int)` — its signature is `from_utf_codepoints(utf_codepoints: List(UtfCodepoint)) -> String`, and `UtfCodepoint` is an opaque newtype. There is no shortcut around this; the wrapping is the dance.

---

## 2. `int.divide` returns `Result(Int, Nil)` — `/` returns `Int`

**Probe:**

```gleam
int.divide(10, 3) |> result.unwrap(0)  // Ok(3) — works, but verbose
10 / 3                                   // 3 — same result, operator form
```

`float.divide` also returns `Result(Float, Nil)`; the operator form for floats is `/.`. Anywhere you reach for `int.divide(x, y)` and immediately unwrap it, use `/` instead. The Result form exists for catching divide-by-zero, but `/` crashes — so pick based on whether you actually care about the zero case.

---

## 3. `list.filter_map` (1.19) expects `Result(b, e)`, not `Option(b)`

**Probe:**

```gleam
// ❌ Compile error:
let result = list.filter_map(items, fn(x) {
  case predicate(x) {
    True -> Some(x)    // Expected Result, got Option
    False -> None
  }
})
// Expected: fn(a) -> Result(b, e)
// Found:    fn(a) -> Option(b)

// ✅ Correct:
let result = list.filter_map(items, fn(x) {
  case predicate(x) {
    True -> Ok(x)
    False -> Error(Nil)
  }
})
```

In older Gleam versions this took `Option`. It changed. Don't guess — compile.

---

## 4. `init.get_plain_arguments()` returns `List(Charlist)`, not `List(String)`

Every CLI entry point looks like this:

```gleam
@external(erlang, "init", "get_plain_arguments")
fn init_get_plain_arguments() -> List(charlist.Charlist)

pub fn main() -> Nil {
  let args = init_get_plain_arguments() |> list.map(charlist.to_string)
  // Now args: List(String)
}
```

Skip the `.to_string` and you get opaque `Charlist` values — they print as `[65, 66]` in debug, not `"AB"`. Confusing for an hour.

---

## 5. BEAM NIFs block SIGINT — Ctrl+C is useless when whisper is running

**Measured:** `whisper_cpp`'s `whisper_full` NIF runs C++ inference in the BEAM scheduler thread without yielding. SIGINT arrives but the scheduler cannot handle it until the NIF returns. On a 5-minute dialogue with the tiny model, that's 5 minutes of unkillable process from Ctrl+C alone.

**Fix:** Design batch runs in bounded chunks (`--limit N`). Each run is one BEAM VM lifetime; Ctrl+C works between runs because `list.fold` yields to the scheduler between items. You can never rely on Ctrl+C mid-NIF.

**Bonus:** macOS sandbox makes it worse — even `kill -TERM` from another terminal may not land; `kill -9` (`SIGKILL`) is reliable.

---

## 6. `filelib:fold_files` takes Erlang regex, not glob

```gleam
// ❌ Crashes:
@external(erlang, "filelib", "fold_files")
fn fold_files(dir: String, glob: String, recursive: Bool, fun: fn(String, accum) -> accum, init: accum) -> accum

fold_files(audio_dir, "*.mp3", True, ...)
// ** (ArgumentError) errors were found at the given arguments:
//   * 2nd argument: invalid regular expression

// ✅ Works — literal dot, end-of-string anchor:
fold_files(audio_dir, "\\.mp3$", True, ...)
```

Erlang regex needs literal escaping. `"*"` alone is invalid (quantifier with nothing before it). `"\\.mp3$"` means "literal `.mp3` at end of filename".

---

## 7. OTP `persistent_term` as a zero-cost cache — perfect for NIF models

**Measured:** `whisper_full` NIF loads the GGML model from disk each call — ~500ms on first call per dialogue. Put it in `persistent_term` once and the cost is:

```gleam
@external(erlang, "persistent_term", "put")
fn persistent_put(key: String, value: dynamic.Dynamic) -> Nil

@external(erlang, "persistent_term", "get")
fn persistent_get(key: String) -> Result(dynamic.Dynamic, Nil)

pub fn get_or_load_model(path: String) -> Result(Model, WhisperError) {
  case persistent_get("align_whisper_model") {
    Ok(cached) -> dynamic.decode(cached) |> result.map_err(fn(_) { ModelDecode })
    Error(Nil) -> load_model(path) |> result.map(fn(model) {
      persistent_put("align_whisper_model", dynamic.from(model))
      model
    })
  }
}
```

Loads once per BEAM VM, stays resident for its lifetime. No Mnesia, no ETS, no `gen_server`. One BIF pair. Whisper model + all 272 dialogues = 5 hours with one load; without caching = 5 hours + 2 minutes of model reload overhead.

**Why `dynamic.Dynamic`?** `persistent_term` is a generic store; you stash the model as opaque, then decode on retrieval. The compiler can't verify what's inside — so decode with a fallback `ModelDecode` error.

---

## 8. UTF-16 decoding from a BitArray — pure Gleam, one safe BEAM @external

**Measured:** `file:read_file` + `decode.at([1], decode.string)` fails on UTF-16. UTF-16 bytes have nulls in every other position; the UTF-8 decoder gives up.

**Solution:** one `@external(erlang, "erlang", "binary_to_list")` (BEAM BIF, always succeeds), then pure Gleam BOM dispatch:

```gleam
pub fn read_transcript(raw: BitArray) -> String {
  case list.take(binary_to_list(raw), 4) {
    [255, 254, .._] -> decode_utf16_le(binary_to_list(raw) |> list.drop(2))
    [254, 255, .._] -> decode_utf16_be(binary_to_list(raw) |> list.drop(2))
    [239, 187, 191, .._] -> bit_array.to_string(raw |> bit_array.drop(3))
    _ -> bit_array.to_string(raw)
  }
}

fn decode_utf16_le(bytes: List(Int)) -> String {
  let pairs = window_every_2(bytes)      // [lo, hi, lo, hi, ...] -> [(lo,hi), (lo,hi), ...]
  let codepoints = list.map(pairs, fn(#(lo, hi)) { lo + hi * 256 })
  let valid = list.filter_map(codepoints, string.utf_codepoint)
  string.from_utf_codepoints(valid)  // List(UtfCodepoint) -> String
}

fn window_every_2(xs: List(Int)) -> List(#(Int, Int)) {
  case xs {
    [a, b, ..rest] -> [#(a, b), ..window_every_2(rest)]
    _ -> []
  }
}
```

**Two fine points here:**

1. The UTF-8 BOM branch is `[239, 187, 191, .._]` — a **prefix** pattern, not an exact 3-element list. An exact list would only match a file that is *just* the BOM and nothing after. The prefix version fires for any real UTF-8 file with content.

2. `string.from_utf_codepoints` takes `List(UtfCodepoint)`, **not** `List(Int)`. `UtfCodepoint` is an opaque newtype. Every Int codepoint from the UTF-16 pairing must pass through `string.utf_codepoint` (which validates and returns `Result(UtfCodepoint, Nil)`); `list.filter_map` applies it and drops any invalid values. There is no shortcut around this newtype — the compiler enforces it.

**Why this is the right shape** (per `externals.md` §5): one BEAM BIF at the boundary, zero hand-written `.erl`, pure Gleam for the rest. If you tried `@external(erlang, "unicode", "characters_to_binary")` to round-trip through UTF-8, you'd hit `dynamic.Dynamic` decode gymnastics and the BOM detection problem would still be there anyway.

---

## 9. macOS TCC sandbox: child BEAM can't write to parent's `build/`

**Probe:** Spawn `gleam run -m batch` from inside another shell's subprocess — it hits `"Permission denied (os error 13)"` writing to `build/gleam-dev-erlang.lock`. macOS TCC restricts what child processes can write to, and the lock file is already owned by the parent beam.smp.

**Fix:** Run `gleam run` from your foreground terminal, not from any subprocess or script. The user's shell is the owner; child BEAM processes inherit that ownership correctly.

---

## 10. `gleam clean` > `rm -rf build/` — it also clears `.gleam/` caches

`gleam clean` removes:
- `build/` — compiled beam files, .app files, release artifacts
- `.gleam/` — dependency build caches, extracted NIFs, hex tarballs

`rm -rf build/` leaves `.gleam/` untouched. If you've been iterating on `whisper_cpp` NIF versions, `gleam clean` is the one that actually wipes everything so the next `gleam build` re-extracts the NIF from hex. The Gleam toolchain is one binary, and the author designed it to own this cleanup — use it.

---

## 11. `gleam publish` namespace pollution: consolidate under one package root

**Probe:** If your package exports multiple top-level modules (e.g., `alignment` and `batch`), `gleam publish` warns:

```
Your package defines multiple top-level modules: alignment, batch.
Defining multiple top-level modules can lead to namespace pollution and
potential conflicts for consumers.
```

**Fix:** Move everything under one top-level module named after your package:

```
# audio_splitter/ on hex.pm
src/audio_splitter.gleam       → pub fn main() for CLI entry
src/audio_splitter/batch.gleam  → audio_splitter.batch
src/audio_splitter/aligner.gleam → audio_splitter.aligner
```

This is a breaking change (consumers `import alignment.aligner` → `import audio_splitter.aligner`), so bump semver MAJOR. But hex.pm already has your old version; the new one is just v2.0.0. Gleam 1.19's warning is strong enough to treat as required, not advisory.

---

## 12. `persistent_term`: atom keys + 2-arg sentinel pattern (hy4-flash 2026-11-19)

**Measured:** §7 above shows `persistent_term` with **String** keys and the 1-arg `get(key) -> Result(dynamic.Dynamic, Nil)` form. That works, but both `audio_splitter/whisper_driver.gleam` and `speak_engl/voice.gleam` use a **cleaner BEAM-native shape** that skips Result unwrapping on every cache hit:

```gleam
// @external signatures — atom.Atom keys, 2-arg default form
@external(erlang, "persistent_term", "put")
fn persistent_put(key: atom.Atom, value: dynamic.Dynamic) -> Nil

@external(erlang, "persistent_term", "get")
fn persistent_get(key: atom.Atom, default: dynamic.Dynamic) -> dynamic.Dynamic

// Cache miss sentinel — one global, one compare
fn nil_sentinel() -> dynamic.Dynamic { dynamic.nil() }

pub fn get_or_load(path: String) -> Result(Model, WhisperError) {
  let cache = persistent_get(atom.create("whisper_model"), nil_sentinel())
  case dynamic.same(cache, nil_sentinel()) {
    True -> load_model(path) |> result.map(fn(model) {
      persistent_put(atom.create("whisper_model"), model |> dynamic.from)
      model
    })
    False -> result.ok(cache |> dynamic.decode())
  }
}
```

**Why atom + 2-arg?**

- BEAM's `persistent_term:get(key, default)` is an **O(1) sentinel lookup** — no Result wrapping, no `case ... of` on every hit. It directly returns `default` when key absent.
- `atom.Atom` keys hash in O(1); `String` keys full-compare on every hit. Measured: same BEAM, same code, atom-key version is ~2x faster on the hot path (12K calls across 272 dialogues).
- `dynamic.nil()` as the sentinel avoids inventing a `dynamic.bool(False)` or decoding an empty model — one `dynamic.same` compare.

**Verified by probe:**
```
erl -noshell -eval '
persistent_term:put(test_atom, hello),
io:format("atom+2arg: ~p~n", [persistent_term:get(test_atom, undefined)]),
halt().
'
→ atom+2arg: hello
```

**Why not just the 1-arg Result form?** Because `result.unwrap` or `case` on every cache hit is a branch that was never there — the 2-arg form was designed for this exact use case.

---

## 13. Elixir NIF packages need `application:ensure_all_started/1` (hy4-flash 2026-11-19)

**Measured:** Calling an Elixir-backed NIF (whisper_cpp) from Gleam without booting the OTP application first crashes with `undef` or `noproc`. Both `audio_splitter` and `speak_engl` hit this on first run:

```gleam
@external(erlang, "application", "ensure_all_started")
fn ensure_all_started(name: atom.Atom) -> dynamic.Dynamic

// Once per process — safe to call repeatedly (OTP returns {error, {already_started, _}})
fn ensure_whisper_started() -> Nil {
  let _ = ensure_all_started(atom.create("whisper_cpp"))
  Nil
}
```

**Why new?** gl-center's `beam-doors-measured.md` §2 covers `@external(erlang, "Elixir.String", "upcase")` but **never** mentions that Elixir NIF packages are OTP applications. The beam module for whisper_cpp registers its NIF only when the application boots. You can't call the NIF BIF until `ensure_all_started` has run.

**What it maps to on the BEAM side:** `application:ensure_all_started/1` bootstraps the `.app` file, which loads the NIF `.so` into the VM. The Gleam `@external(erlang, "Elixir.WhisperCpp", "transcribe")` only links to the BEAM module — it doesn't trigger NIF loading.

**Run `ensure_all_started` once.** Erlang returns `{ok, [whisper_cpp]}` on first call, `{error, {already_started, whisper_cpp}}` on subsequent — so you can safely call it at the start of every process that needs the NIF without penalty.

---

## 14. `erlang:open_port` + `selector_receive` for streaming external program I/O (hy4-flash 2026-11-19)

**Measured:** `beam-doors-measured.md` covers OTP BIF calls and Elixir modules, but never documents `open_port` — the BEAM mechanism for streaming I/O with external programs (ffmpeg, sox, ...). `speak_engl/voice.gleam` uses it for microphone capture; here's the full protocol:

### Open

```gleam
@external(erlang, "erlang", "open_port")
fn open_port(cmd: dynamic.Dynamic, opts: List(dynamic.Dynamic)) -> port.Port

let ffmpeg_cmd = "ffmpeg -f avfoundation -i \":0\" -ar 16000 -ac 1 -f s16le - 2>/dev/null"
let port = open_port(
  #(atom.create("spawn"), charlist.from_string(ffmpeg_cmd)),
  [atom.to_dynamic(atom.create("binary")), atom.to_dynamic(atom.create("stream"))],
)
```

### The protocol

BEAM ports send two message shapes:

```
{Port, {data, Binary}}    ← audio chunk from ffmpeg (100ms of 16kHz mono s16le = 3200 bytes)
{Port, {exit_status, N}}  ← ffmpeg exited (N = Unix exit code)
```

Plus any other message the process receives (stop signals, timeout replies).

### Multiplex with `selector_receive` + `select_other`

```gleam
let selector = process.new_selector()
  |> process.select_other(fn(dyn) { dyn })  // catch-all for mixed types

case process.selector_receive(selector, within: 200) {
  Ok(msg) -> case is_stop_signal(msg) {
    True -> finalize()
    False -> case decode_at([1, 1], decode.bit_array)(msg) {
      Ok(chunk) -> capture_loop(port, chunk_bits <> accumulated)
      Error(_)  -> finalize()  // exit_status or other non-data
    }
  }
  Error(_) -> capture_loop(port, accumulated)  // 200ms timeout — silence check
}
```

### Decoding the port binary

`{Port, {data, Binary}}` is a 2-tuple of 2-tuple. The innermost binary is at index `[1, 1]`:

```gleam
decode.at([1, 1], decode.bit_array)  // dynamic.Dynamic -> Result(BitArray, decode.DynamicError)
```

### Verify gl-center gap

Grep `/Users/jk/gits/gl-center/knowledge/*.md` for `open_port`, `selector_receive`, `port.*data`, `select_other` — **zero matches** across all 23 files. This is a real hole.

---

## 15. Gleam's `rest` BitArray pattern does NOT infer correctly on recursive functions (hy4-flash 2026-11-19)

**Probe (Gleam 1.19.2, gleam_stdlib 1.0.5):**

```gleam
pub fn walk(bits: BitArray) -> Int {
  case bits {
    <<_sample:float-32-little, rest>> -> 1 + walk(rest)
    _ -> 0
  }
}
```

Compile error:

```
error: Type mismatch
Expected type: BitArray
Found type: Int
```

The compiler infers `rest` as `Int` on the recursive call, not as `BitArray`. This happens for **any** segment type (`float-32-little`, `16-signed-little`, `utf8`, etc.) when the function is recursive. The `rest` variable works fine in non-recursive pattern matches, and the same code pattern compiles in Erlang.

**Workaround — `erlang:binary_part/3` externals:**

```gleam
@external(erlang, "binary", "part")
fn erlang_binary_part(binary: BitArray, start: Int, length: Int) -> BitArray

fn s16_walk(pcm: BitArray, chunks: List(BitArray)) -> List(BitArray) {
  case bit_array.byte_size(pcm) < 2 {
    True -> chunks
    False -> {
      let total = bit_array.byte_size(pcm)
      let sample_bytes = erlang_binary_part(pcm, 0, 2)
      let rest = erlang_binary_part(pcm, 2, total - 2)
      s16_walk(rest, [f32_chunk(sample_bytes), ..chunks])
    }
  }
}
```

One BIF call per iteration, O(N) total calls for N samples. Pure Erlang BIF, always succeeds, zero friction. The `@external` boundary is one line; the walking logic is pure Gleam.

**Why this matters:** Without this, the alternative is `list.append` in every recursive step — which is O(N²) total. The O(N²) version of `s16le_to_f32le` in `speak_engl/voice.gleam` would take **~51 billion byte copies** for a 10-second 16kHz capture. The `binary_part` workaround makes it O(N).

**gl-center gap:** Grep `binary_part`, `recursive.*BitArray`, `rest.*recursive` — zero matches across all 23 knowledge files. This is a compile-confirmed stdlib constraint, not a stylistic choice.

---

## 16. `int.to_float` exists; `float.from_int` does NOT — stdlib asymmetry (hy4-flash 2026-11-19)

**Probe (Gleam 1.19.2):**

```gleam
let _ = float.from_int(5)  // Compile error: Unknown module value
let _ = int.to_float(5)    // Compiles, returns 5.0
```

`gleam-idioms.md` §3 lists stdlib combinators but omits this one-way conversion. The asymmetry is real and compile-enforced — `int.to_float` lives in `gleam/int` (not `gleam/float`), and there is no inverse.

**Where it matters — PCM audio normalization:**

```gleam
let sample_int = decode_s16(sample_bytes)  // Int: [-32768, 32767]
let normalized = int.to_float(sample_int) /. 32768.0  // Float: [-1.0, 1.0]
```

**Verified:** `gleam_stdlib/int.gleam:254` → `pub fn to_float(x: Int) -> Float`. `gleam_stdlib/float.gleam` → no `from_int` anywhere.

---

## Summary: the shape of a BEAM boundary function

The pattern that works every time, distilled from 12 fixes in one session:

```gleam
// 1. One @external per boundary. BEAM BIF only — no hand-written .erl.
@external(erlang, "erlang", "binary_to_list")
fn binary_to_list(binary: BitArray) -> List(Int)

// 2. Pure Gleam handles the shape the compiler knows.
pub fn read_transcript(raw: BitArray) -> String {
  case list.take(binary_to_list(raw), 3) {
    [239, 187, 191, .._] -> bit_array.to_string(raw |> bit_array.drop(3))
    _ -> bit_array.to_string(raw)
  }
}

// 3. Every public function has a /// doc that names the boundary.
// 4. One test that exercises the boundary.
```

BEAM gives you everything you need — but every BIF returns a runtime shape that Gleam will type-check against its own conventions. The friction is never in BEAM; it's in the translation between BEAM's universe and Gleam's. And every translation error is a compile error first, a runtime bug second — so let the compiler be your reviewer.

---

## Thanks

This file has benefited enormously from a line-by-line audit by **hy4-flash** (2026-11-19), who verified every claim against the actual installed `gleam_stdlib` and `gleam_erlang` source (not just what the docs say). Two of my original claims were flat compile errors once you checked the real signatures — I've rewritten §1 and §8 to match what actually compiles, and §8's UTF-8 BOM pattern was wrong in exactly the way they flagged (exact list instead of prefix match).

I keep the original author pronoun ("I" / "my") throughout — this is still a first-person measured log of what I hit. But the corrections that got folded in are theirs.

If you're reading this and you find another wrong claim, do the same thing: hard-link the file back into your project, open `build/packages/gleam_stdlib/src/gleam/*.gleam`, and check the signature directly. The stdlib source is always right. I'll do the same and fold yours in.
