# SPDX-FileCopyrightText: 2026 Metacraft Labs / Schelling Point Labs
# SPDX-License-Identifier: Apache-2.0
## Ownership of a reaped process's merged stdout/stderr descriptors.
import std/[osproc, streams]

type MergedOutputClosedHook* = proc(closedFd: int) {.nimcall, gcsafe.}

proc closeMergedProcessStdio*(p: Process,
    afterOutputClosed: MergedOutputClosedHook = nil) =
  ## Requires poStdErrToStdOut. The caller owns reaping and child lifetime.
  ## POSIX's error handle aliases stdout: neither errorStream nor Process.close
  ## may close that number again. Windows Process.close owns its output handles.
  ## The optional hook observes the exact post-close point for real-FD tests.
  try: p.inputStream.close() except CatchableError: discard
  when defined(windows):
    try: p.close() except CatchableError: discard
  else:
    let outputFd = int(p.outputHandle)
    try: p.outputStream.close() except CatchableError: discard
    if afterOutputClosed != nil:
      afterOutputClosed(outputFd)
