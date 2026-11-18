//// BEAM file I/O — typed wrappers around `erlang:file` externals.
////
//// Every @external lives here. Other modules call typed functions like
//// `read_text`, `read_binary`, `write_text`, `mkdir`, `delete_path`.
//// No @external leaks into CLI or pipeline modules.

import gleam/dynamic
import gleam/dynamic/decode
import gleam/erlang/atom

pub type FileError {
  NotFound
  PermissionDenied
  DecodeFailed
  Unknown(String)
}

// ── Erlang externals (private to this module) ──────────────────────────────

@external(erlang, "file", "read_file")
fn raw_read_file(path: String) -> dynamic.Dynamic

@external(erlang, "file", "write_file")
fn raw_write_file(path: String, content: String) -> dynamic.Dynamic

@external(erlang, "file", "make_dir")
fn raw_make_dir(path: String) -> dynamic.Dynamic

@external(erlang, "file", "delete")
fn raw_delete(path: String) -> dynamic.Dynamic

// ── Public typed API ─────────────────────────────────────────────────────

/// Read a text file as String.
pub fn read_text(path: String) -> Result(String, FileError) {
  case raw_read_file(path) {
    raw -> case decode.run(raw, decode.at([0], atom.decoder())) {
      Ok(tag) -> {
        case atom.to_string(tag) {
          "ok" -> case decode.run(raw, decode.at([1], decode.string)) {
            Ok(s) -> Ok(s)
            Error(_) -> Error(DecodeFailed)
          }
          "enoent" -> Error(NotFound)
          "eacces" -> Error(PermissionDenied)
          other -> Error(Unknown(other))
        }
      }
      Error(_) -> Error(DecodeFailed)
    }
  }
}

/// Read a binary file as BitArray.
pub fn read_binary(path: String) -> Result(BitArray, FileError) {
  case raw_read_file(path) {
    raw -> case decode.run(raw, decode.at([0], atom.decoder())) {
      Ok(tag) -> {
        case atom.to_string(tag) {
          "ok" -> case decode.run(raw, decode.at([1], decode.bit_array)) {
            Ok(b) -> Ok(b)
            Error(_) -> Error(DecodeFailed)
          }
          "enoent" -> Error(NotFound)
          "eacces" -> Error(PermissionDenied)
          other -> Error(Unknown(other))
        }
      }
      Error(_) -> Error(DecodeFailed)
    }
  }
}

/// Write a String to a file.
pub fn write_text(path: String, content: String) -> Result(Nil, FileError) {
  case raw_write_file(path, content) {
    raw -> case decode.run(raw, atom.decoder()) {
      Ok(tag) -> {
        case atom.to_string(tag) {
          "ok" -> Ok(Nil)
          "enotdir" -> Error(NotFound)
          other -> Error(Unknown(other))
        }
      }
      Error(_) -> Error(DecodeFailed)
    }
  }
}

/// Create a directory. Safe to call if it already exists.
pub fn make_dir(path: String) -> Result(Nil, FileError) {
  case raw_make_dir(path) {
    raw -> case decode.run(raw, atom.decoder()) {
      Ok(tag) -> {
        case atom.to_string(tag) {
          "ok" -> Ok(Nil)
          "eexist" -> Ok(Nil) // already exists — not an error
          "enoent" -> Error(NotFound)
          other -> Error(Unknown(other))
        }
      }
      Error(_) -> Error(DecodeFailed)
    }
  }
}

/// Delete a file. Returns Ok even if file doesn't exist (safe cleanup).
pub fn delete_path(path: String) -> Result(Nil, FileError) {
  case raw_delete(path) {
    raw -> case decode.run(raw, atom.decoder()) {
      Ok(tag) -> {
        case atom.to_string(tag) {
          "ok" -> Ok(Nil)
          "enoent" -> Ok(Nil) // already gone — fine for cleanup
          other -> Error(Unknown(other))
        }
      }
      Error(_) -> Error(DecodeFailed)
    }
  }
}
