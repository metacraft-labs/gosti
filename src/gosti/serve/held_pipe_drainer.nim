# SPDX-FileCopyrightText: 2026 Metacraft Labs / Schelling Point Labs
# SPDX-License-Identifier: Apache-2.0
## Drains, and finally closes, worker output pipes that outlive their worker.
##
## ``handleExec`` reads a worker's merged stdout/stderr until EOF. EOF comes
## only when EVERY writer has closed the pipe, and a worker's background
## descendants inherit its writer: a ``tart run`` left behind by
## ``run --ephemeral --keep`` held it for the guest's whole life. Once the worker
## itself has exited and a short grace has passed, the handler reports
## ``exit`` without waiting for that EOF. It cannot simply close its read end:
## the descendant's next write would then fail. With SIGPIPE at its default
## disposition that write kills the writer; the daemon itself ignores SIGPIPE
## (Nim's default) and an ignored disposition survives ``exec``, so a
## descendant that keeps it instead gets EPIPE on every later write. Either is
## a fault injected into a process that is still doing its job, ``tart run``
## among them. Nor can the handler leave the read end open and unread: the
## pipe buffer fills and the descendant blocks on its next write instead.
##
## So the handler hands the read end to this module. ONE drainer thread, started
## on first use, polls every handed-over pipe, reads and discards whatever the
## descendants write, and closes each pipe once it reaches EOF (every writer
## gone) or fails. The pipe is therefore closed exactly once, by its sole
## remaining owner, and only when no process can still write to it. The cost
## while a descendant lives is one descriptor and nothing else.
##
## Ownership crosses threads as a plain descriptor number written to a
## control pipe, never as a GC-managed object, the rule the rest of the
## daemon follows. A 4-byte ``write`` to a pipe is atomic (POSIX: writes of at
## most ``PIPE_BUF`` bytes are not interleaved), so concurrent handlers need no
## lock to submit.
##   https://pubs.opengroup.org/onlinepubs/9799919799/functions/write.html
##
## POSIX only: the Windows daemon keeps reading to EOF.

when not defined(posix):
  {.error: "held_pipe_drainer is POSIX-only".}

import std/[atomics, locks, posix]
when defined(linux):
  import std/linux

var
  drainerLock: Lock
  drainerStarted: bool      ## guarded by ``drainerLock``
  drainerControl: array[2, cint] = [-1.cint, -1.cint]
    ## [read, write] ends of the submission pipe; written once under the lock
  drainerThread: Thread[void]
  heldPipes: Atomic[int]
    ## pipes handed over and not yet closed; observable for tests and logs

initLock(drainerLock)

proc heldPipeCount*(): int =
  ## How many handed-over pipes the drainer still holds open.
  heldPipes.load()

proc setCloseOnExec(fd: cint): bool =
  let flags = fcntl(fd, F_GETFD)
  flags >= 0 and fcntl(fd, F_SETFD, flags or FD_CLOEXEC) >= 0

proc openControlPipe(fds: var array[2, cint]): bool =
  ## Both ends close-on-exec, so no worker spawned later inherits them. Linux
  ## sets the flag atomically (as ``compat/osproc`` does for worker pipes);
  ## elsewhere a fork between ``pipe`` and ``fcntl`` could leak the pair into
  ## one child, which is harmless here: no reader waits for EOF on it.
  when defined(linux):
    if pipe2(fds, O_CLOEXEC) != 0:
      return false
  else:
    if pipe(fds) != 0:
      return false
    if not setCloseOnExec(fds[0]) or not setCloseOnExec(fds[1]):
      discard close(fds[0])
      discard close(fds[1])
      return false
  true

proc drainerLoop() {.thread.} =
  ## Runs for the life of the process. ``fds`` is this thread's own list: the
  ## only state shared with the handlers is the control pipe.
  var fds: seq[cint]
  var pending: seq[byte]           # a partial descriptor number, if any
  var scratch: array[4096, byte]
  while true:
    var pfds = newSeq[TPollfd](fds.len + 1)
    pfds[0] = TPollfd(fd: drainerControl[0], events: POLLIN)
    for i, fd in fds:
      pfds[i + 1] = TPollfd(fd: fd, events: POLLIN)
    let ready = poll(addr pfds[0], Tnfds(pfds.len), -1)
    if ready < 0:
      if errno == EINTR: continue
      # Nothing sensible to do but wait and retry; never spin hot.
      discard usleep(100_000)
      continue
    # Retire finished pipes first, walking backwards so indices stay valid.
    for i in countdown(fds.len - 1, 0):
      let ev = pfds[i + 1].revents
      if ev == 0:
        continue
      var retire = (ev and POLLNVAL) != 0
      if not retire:
        let n = read(fds[i], addr scratch[0], scratch.len)
        # n == 0: EOF, every writer is gone. n < 0 other than EINTR/EAGAIN:
        # the pipe is unusable. Both end our ownership.
        retire = n == 0 or (n < 0 and errno notin [EINTR, EAGAIN])
      if retire:
        if (ev and POLLNVAL) == 0:
          discard close(fds[i])
        fds.delete(i)
        heldPipes.atomicDec()
    if pfds[0].revents != 0:
      let n = read(drainerControl[0], addr scratch[0], scratch.len)
      if n > 0:
        for k in 0 ..< n:
          pending.add(scratch[k])
        while pending.len >= sizeof(cint):
          var fd: cint
          copyMem(addr fd, addr pending[0], sizeof(cint))
          pending = pending[sizeof(cint) .. ^1]
          fds.add(fd)

proc ensureDrainer(): bool =
  withLock drainerLock:
    if drainerStarted:
      return true
    var fds: array[2, cint]
    if not openControlPipe(fds):
      return false
    drainerControl = fds
    try:
      createThread(drainerThread, drainerLoop)
    except ResourceExhaustedError:
      discard close(fds[0])
      discard close(fds[1])
      drainerControl = [-1.cint, -1.cint]
      return false
    drainerStarted = true
    return true

proc handOffHeldPipe*(fd: cint): bool =
  ## Transfer ownership of the read end ``fd`` to the drainer. On ``true`` the
  ## caller must never read, close or otherwise touch ``fd`` again. On
  ## ``false`` (the drainer could not be started or reached) ownership stays
  ## with the caller.
  if fd < 0 or not ensureDrainer():
    return false
  heldPipes.atomicInc()
  var value = fd
  while true:
    let n = write(drainerControl[1], addr value, sizeof(value))
    if n == sizeof(value):
      return true
    if n < 0 and errno == EINTR:
      continue
    heldPipes.atomicDec()
    return false
