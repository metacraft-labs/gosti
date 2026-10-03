# SPDX-FileCopyrightText: 2026 Metacraft Labs / Schelling Point Labs
# SPDX-License-Identifier: Apache-2.0
## t_serve_worker_fd_hygiene — the serve daemon closes each of a worker's
## stdio file descriptors EXACTLY ONCE (gosti#69).
##
## The bug. ``handleExec`` spawns every worker with ``poStdErrToStdOut``, so
## osproc's ``errorStream`` and ``outputStream`` are the SAME pipe fd. The old
## cleanup closed ``outputStream`` and then touched ``errorStream``, which
## lazily ``fdopen``s that fd NUMBER again and closes it a second time (and,
## when that ``fdopen`` failed, ``osproc.close`` fell back to a raw
## ``close(2)`` of the same number). In a multi-threaded daemon the number is
## free in between, so another handler thread's freshly opened pipe or socket
## can sit on it, and the stale close shuts THAT descriptor: the other
## request then fails with "worker stream error: Bad file descriptor".
##
## Deterministic, no timing: the cleanup exposes a stage hook right after the
## stdout pipe is closed. The test uses it to do what the racing thread did —
## open ``/dev/null`` until the kernel hands back every just-freed descriptor
## number (POSIX allocates the LOWEST free number, and this test is
## single-threaded, so the planted fds land exactly on the freed numbers) —
## and then asserts that every planted descriptor is still open, and still
## ``/dev/null``, after the cleanup finishes. Against the old cleanup the
## planted fd on the stdout number is closed out from under the test (the
## first check fails); against the fixed cleanup all of them survive.
##
## Mock policy: there are NO mocks. The worker is this same binary re-execed
## in a trivial ``__work`` role (real process, real pipes, real fds); the hook
## is a test seam in the production cleanup path that is nil outside tests.
## POSIX only: on Windows osproc owns the handle closes and the seam's
## stdout stage is never reached.

import std/[os, osproc, streams, unittest]
import vm_harness

when isMainModule:
  let params = commandLineParams()
  if params.len >= 1 and params[0] == "__work":
    stdout.writeLine("to-stdout")
    stderr.writeLine("to-stderr")
    quit(0)

when not defined(windows):
  import std/posix

  var planted: seq[cint]
  var plantCeiling: cint

  proc plantFreedNumbers() =
    ## Occupy every free descriptor number up to ``plantCeiling`` with an
    ## fd of our own, the way a concurrent request's new pipe would.
    while true:
      let fd = posix.open("/dev/null", O_RDONLY)
      doAssert fd >= 0, "open(/dev/null) failed"
      if fd > plantCeiling:
        discard posix.close(fd)
        break
      planted.add(fd)

  proc hook(stage: WorkerCleanupStage) {.nimcall, gcsafe.} =
    {.cast(gcsafe).}:
      if stage == wcsStdoutClosed:
        plantFreedNumbers()

  proc isDevNull(fd: cint): bool =
    var st, ref0: Stat
    if fstat(fd, st) != 0: return false
    if stat("/dev/null", ref0) != 0: return false
    st.st_rdev == ref0.st_rdev and st.st_ino == ref0.st_ino

  proc spawnAndDrain(): Process =
    ## Spawn + drain exactly as ``handleExec`` does: same options, stdin
    ## closed before the read loop, worker reaped before cleanup.
    let p = startProcess(getAppFilename(), args = @["__work"],
                         options = WorkerSpawnOptions)
    p.inputStream.close()
    var lines: seq[string]
    var line = ""
    while p.outputStream.readLine(line):
      lines.add(line)
    check "to-stdout" in lines
    check "to-stderr" in lines       # stderr really is merged into stdout
    discard p.waitForExit()
    p

  suite "t_serve_worker_fd_hygiene":
    teardown:
      workerCleanupHook = nil
      for fd in planted:
        discard posix.close(fd)
      planted.setLen(0)

    test "the merged stdout/stderr fd is closed once: a reused number survives":
      let p = spawnAndDrain()
      let outFd = cint(p.outputHandle)
      plantCeiling = outFd
      workerCleanupHook = hook
      releaseWorkerStdio(p)
      workerCleanupHook = nil
      # The racing open landed exactly on the stdout number ...
      check outFd in planted
      # ... and every planted descriptor is still ours after the cleanup.
      var killed: seq[cint]
      for fd in planted:
        if fcntl(fd, F_GETFD) == -1 or not isDevNull(fd):
          killed.add(fd)
      checkpoint("stdout fd " & $outFd & "; planted " & $planted &
                 "; closed by the cleanup " & $killed)
      check killed.len == 0

    test "after cleanup every worker fd number is free (nothing leaked)":
      let p = spawnAndDrain()
      let outFd = cint(p.outputHandle)
      let inFd = cint(p.inputHandle)
      releaseWorkerStdio(p)
      check fcntl(outFd, F_GETFD) == -1
      check fcntl(inFd, F_GETFD) == -1

    test "repeated cleanup cycles leave no stray closes":
      # Many spawn/cleanup cycles, each planting into the freed numbers; a
      # single stray close in any cycle surfaces as a dead planted fd.
      var killed: seq[string]
      for i in 0 ..< 50:
        let p = spawnAndDrain()
        plantCeiling = max(cint(p.outputHandle), cint(p.inputHandle))
        workerCleanupHook = hook
        releaseWorkerStdio(p)
        workerCleanupHook = nil
        for fd in planted:
          if fcntl(fd, F_GETFD) == -1 or not isDevNull(fd):
            killed.add("cycle " & $i & ": fd " & $fd)
          discard posix.close(fd)
        planted.setLen(0)
      checkpoint("planted fds closed by the cleanup: " & $killed)
      check killed.len == 0
