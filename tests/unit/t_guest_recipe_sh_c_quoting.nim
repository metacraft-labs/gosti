# SPDX-FileCopyrightText: 2026 Metacraft Labs / Schelling Point Labs
# SPDX-License-Identifier: Apache-2.0
## The guest recipes send in-guest scripts as `incus exec … -- sh -c "<script>"`.
## That script is a DOUBLE-quoted string, so the HOST shell expands it first. A
## backtick inside it, even in a `#` comment, is command substitution that runs
## on the BUILD HOST, before the text reaches the guest.
##
## Measured 2026-11-03 on every golden-building host. The dbus comments in
## linux-x64-runner's baseline install quoted `dbus-daemon --session`,
## `dbus-uuidgen` and `garm-*` in backticks, and each build printed
## "line 487: dbus-daemon: command not found". It was harmless there only
## because the unit's PATH had no dbus. On a host with dbus on PATH it would
## start a session bus on the host.
##
## A double quote written inside such a string closes it early. The same block
## quoted ".../session.conf" in a comment, which is why `garm-*` further down
## was expanded too.
##
## This gate scans every `sh -c "` string in guest-recipes/**/*.sh and fails on
## any unescaped backtick, and on any unescaped double quote that is not the
## string's closing quote. A `$(…)` meant for the guest must already be written
## `\$(…)`, so a host-side expansion inside these strings is always a bug.

import std/[os, strutils, unittest]

proc lineOf(text: string, at: int): int = text[0 ..< at].count('\n') + 1

proc hostExpansions(text: string): seq[string] =
  ## Each problem inside a `sh -c "…"` string, as "<line>: <what>".
  ##
  ## A multi-line script must close on a `"` that is the first non-blank
  ## character of its line, the shape every recipe uses. Any other unescaped
  ## `"` closes the host string early (a quoted word in a comment does this),
  ## and whatever follows it is parsed by the HOST.
  var i = 0
  while true:
    let start = text.find("sh -c \"", i)
    if start < 0: break
    var j = start + len("sh -c \"")
    let multiLine = j < text.len and text[j] == '\n'
    while j < text.len:
      let c = text[j]
      if c == '\\':
        j += 2
        continue
      if c == '`':
        let msg = $lineOf(text, j) & ": unescaped backtick (host-side command substitution)"
        if msg notin result: result.add msg
      elif c == '"':
        if not multiLine: break
        let bol = text.rfind('\n', last = j) + 1
        if text[bol ..< j].strip().len == 0: break
        result.add $lineOf(text, j) & ": unescaped double quote closes the host string early"
      inc j
    i = j + 1

suite "guest recipe sh -c quoting":
  test "the scanner sees a backtick in a comment and ignores an escaped one":
    let bad = "incus exec b -- sh -c \"\n  # runs `dbus-daemon` twice `x`\n  true\n\"\n"
    check hostExpansions(bad).len == 1
    check hostExpansions(bad)[0].startsWith("2: unescaped backtick")
    let early = "incus exec b -- sh -c \"\n  # open \"session.conf\"\n  true\n\"\n"
    check hostExpansions(early).len == 2
    check hostExpansions(early)[0].startsWith("2: unescaped double quote")
    let ok = "incus exec b -- sh -c \"\n  echo \\`x\\` \\\"q\\\"\n\" || fail\nlater `fine`\n" &
      "incus exec b -- sh -c \"echo one-line\"\n"
    check hostExpansions(ok).len == 0

  test "no recipe expands anything on the build host":
    var scanned = 0
    for path in walkDirRec("guest-recipes"):
      if not path.endsWith(".sh"): continue
      inc scanned
      let hits = hostExpansions(readFile(path))
      for hit in hits:
        checkpoint path & ":" & hit & " inside a sh -c \"…\" string"
      check hits.len == 0
    check scanned > 0
