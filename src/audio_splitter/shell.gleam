//// Shell command helpers — single source of truth for `os:cmd` externals.
////
//// One `os_cmd`, one `shell_quote`. Every module that needs to run shell
//// commands imports this one. No duplicate @external definitions.

import gleam/erlang/charlist
import gleam/string

/// Run a shell command via Erlang `os:cmd`.
/// Returns stdout/stderr as a String. Empty string means success
/// (ffmpeg writes errors to stderr which we redirect to stdout with 2>&1).
@external(erlang, "os", "cmd")
pub fn os_cmd(command: charlist.Charlist) -> charlist.Charlist

/// Wrap a path or argument in single quotes, escaping embedded single
/// quotes. Standard shell quoting for `os:cmd`.
pub fn shell_quote(text: String) -> String {
  "'" <> string.replace(text, "'", "'\\''") <> "'"
}
