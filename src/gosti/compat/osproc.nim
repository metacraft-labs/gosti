# SPDX-FileCopyrightText: 2026 Metacraft Labs / Schelling Point Labs
# SPDX-License-Identifier: Apache-2.0
## Linux compatibility repair for concurrent Nim 2.2.4 process launches.
## config.nims redirects std/osproc here, preserving its API and Process type
## across all callers. Load the selected compiler's implementation instead of
## maintaining a second copy. Its unqualified pipe calls use this constructor;
## pipe2 makes close-on-exec atomic before any other thread can fork.
## Keep this file's basename osproc.nim: Nim derives the module qualifier from
## the replacement filename, so another basename breaks osproc.Process callers.
##
## Both stdio and the error-reporting pipe need this: another child's inherited
## writer can delay EOF and keep startProcess blocked for that child's lifetime.
## The library's dup2 calls still supply ordinary child descriptors 0/1/2.
import std/[compilesettings, linux, macros, os, posix]

when defined(gostiProcessPipeTest):
  type ProcessPipeHook* = proc(fds: array[0..1, cint]) {.nimcall, gcsafe, raises: [].}
  var processPipeCreatedHook*: ProcessPipeHook
    ## Test builds only: coordinate real concurrent forks after pipe creation.

proc pipe(fds: array[0..1, cint]): cint =
  # Match posix.pipe's array-by-value signature. A `var` parameter would only
  # replace stdio calls, leaving StartProcessData's immutable error pipe unsafe.
  result = linux.pipe2(fds, O_CLOEXEC)
  when defined(gostiProcessPipeTest):
    if result == 0 and processPipeCreatedHook != nil:
      processPipeCreatedHook(fds)

proc dup2(source, destination: cint): cint =
  result = posix.dup2(source, destination)
  if result >= 0 and source == destination:
    # A caller can have closed standard input. A new pipe then occupies fd 0;
    # dup2(0, 0) is a no-op and does NOT clear close-on-exec. Preserve the
    # standard library's child-stdio behavior in that case too.
    let flags = fcntl(destination, F_GETFD)
    if flags < 0 or fcntl(destination, F_SETFD, flags and not FD_CLOEXEC) < 0:
      result = -1

macro loadSelectedOsproc(): untyped =
  let source = querySetting(SingleValueSetting.libPath) / "pure" / "osproc.nim"
  # readFile uses the actual toolchain path. staticRead/include also apply
  # module overrides and would load this replacement recursively.
  result = parseStmt(readFile(source), filename = source)

loadSelectedOsproc()
