# SPDX-FileCopyrightText: 2026 Metacraft Labs / Schelling Point Labs
# SPDX-License-Identifier: Apache-2.0
## t_pool_class_queue — a pool's jobs wait for a slot, and with a RunQuota
## class configured the pool reports each wait as a ``class-queue`` wait
## through one long-lived reporting session (``runquota pressure report``).
##
## What is pinned: the pool starts no reporter without a class; with one it
## starts exactly one, at construction, with the class (and session group)
## it was given; ``acquireFor`` and ``withdraw`` end a job's wait and send
## one line per wait of at least a second, starting at the job's queued
## time; a wait under a second is not sent; a reporter that cannot start or
## goes away never fails the pool; teardown ends the session.
##
## A RECORDING ``runquota`` (a shell script) stands in for the client here,
## because what is under test is gosti's side of the line protocol -- which
## lines, when, with which arguments -- and the stand-in records exactly
## that. The real client and a real daemon publishing the waits are
## ``tests/e2e/t_pool_class_queue_wait.nim``.
##
## Each case names the change that makes it fail.

import std/[os, strutils, tempfiles, unittest]
import gosti

when not defined(posix):
  echo "[skip] t_pool_class_queue: POSIX host required (shell stand-in)"
  quit(0)

proc recordingRunquota(dir: string; ready = true): string =
  ## A `runquota` that records its argv and environment, answers `ready`,
  ## then answers each line as the real one does (`reported <length>`).
  result = dir / "runquota"
  writeFile(result, "#!/bin/sh\n" &
    "echo \"argv $*\" >> " & quoteShell(dir / "log") & "\n" &
    "echo \"session ${RUNQUOTA_SESSION:-}\" >> " & quoteShell(dir / "log") & "\n" &
    "echo \"class ${RUNQUOTA_CLASS:-}\" >> " & quoteShell(dir / "log") & "\n" &
    (if ready: "echo ready 7\n" else: "echo 'no daemon' >&2; exit 1\n") &
    "while read kind started length; do\n" &
    "  echo \"line $kind $started $length\" >> " & quoteShell(dir / "log") & "\n" &
    "  echo \"reported $length\"\n" &
    "done\n" &
    "echo closed >> " & quoteShell(dir / "log") & "\n")
  setFilePermissions(result, {fpUserRead, fpUserWrite, fpUserExec})

proc mkPool(cmd: string; class: string; session = ""): Pool =
  let b = newNoopBackend()
  b.provisionBaseline(BaselineSpec(name: "golden", guestOs: goLinux,
    guestArch: gaX86_64))
  var cfg = PoolConfig(backend: b, baseline: "golden",
    algorithm: paRecycleFromPool, size: 1, readyTimeoutSec: 5,
    runquotaClass: class, runquotaSession: session, runquotaCmd: @[cmd])
  cfg.createMember = proc(idx: int): VmHandle =
    VmHandle(backend: b, name: "pool-member-" & $idx, baseline: "golden")
  newPool(cfg)

proc logLines(dir: string): seq[string] =
  if fileExists(dir / "log"): readFile(dir / "log").strip().splitLines()
  else: @[]

suite "pool class-queue waits":
  test "no class: no reporter, nothing reported":
    # Mutation: starting a reporter regardless of the class makes every pool
    # depend on a RunQuota client.
    let dir = createTempDir("gosti-cq-", "")
    defer: removeDir(dir)
    var p = mkPool(recordingRunquota(dir), "")
    p.construct()
    let job = p.submit("j", queuedAtUnixMillis = unixMillisNow() - 5000)
    let lease = p.acquireFor(job)
    check not lease.isNil
    check job.waitedMillis >= 5000
    check not job.reported
    p.teardown()
    check logLines(dir).len == 0

  test "one reporter per pool, with its class and group; one line per wait":
    # Mutations: measuring from `acquireFor` instead of the job's queued
    # time reports ~0 and nothing is sent; sending sub-second waits sends a
    # second line; leaving an inherited RUNQUOTA_CLASS in the reporter's
    # environment makes it disagree with `--class` about the class's socket.
    let dir = createTempDir("gosti-cq-", "")
    defer: removeDir(dir)
    putEnv("RUNQUOTA_CLASS", "inherited")
    defer: delEnv("RUNQUOTA_CLASS")
    var p = mkPool(recordingRunquota(dir), "ci", session = "pool-7")
    p.construct()
    check not p.reporter.isNil
    check p.reporter.sessionId == 7'u64
    let busy = p.acquire()
    let queuedAt = unixMillisNow() - 3000
    let job = p.submit("j1", queuedAtUnixMillis = queuedAt)
    check p.waiting.len == 1
    check p.oldestWaitMillis() >= 3000
    expect PoolError:
      discard p.acquireFor(job)       # the only member is busy: still waiting
    check p.waiting.len == 1
    p.release(busy)
    let lease = p.acquireFor(job)
    check job.reported
    check job.waitedMillis >= 3000
    p.release(lease)
    # A wait under a second is not reported.
    let quick = p.submit("j2")
    p.release(p.acquireFor(quick))
    check not quick.reported
    # A withdrawn job's wait is reported too.
    let gone = p.submit("j3", queuedAtUnixMillis = unixMillisNow() - 2000)
    p.withdraw(gone)
    check gone.reported
    check p.waiting.len == 0
    p.teardown()
    let lines = logLines(dir)
    check lines[0] == "argv pressure report --class ci"
    check lines[1] == "session pool-7"
    check lines[2] == "class ci"
    var reported: seq[string]
    for line in lines:
      if line.startsWith("line "): reported.add(line)
    check reported.len == 2
    check reported[0].startsWith("line class-queue " & $queuedAt & " ")
    check parseInt(reported[0].split(' ')[3]) >= 3000
    check lines[^1] == "closed"

  test "a reporter that cannot start never fails the pool":
    # Mutation: letting the reporter's error propagate from `construct`
    # stops the pool from serving jobs when RunQuota is unavailable.
    let dir = createTempDir("gosti-cq-", "")
    defer: removeDir(dir)
    var p = mkPool(recordingRunquota(dir, ready = false), "ci")
    p.construct()
    check p.constructed
    check p.reporter.isNil
    let job = p.submit("j", queuedAtUnixMillis = unixMillisNow() - 2000)
    check not p.acquireFor(job).isNil
    check not job.reported
    check "class_queue=unreported" in p.describe()
    p.teardown()

  test "the line protocol":
    check classQueueArgs("ci") == @["pressure", "report", "--class", "ci"]
    check classQueueLine(1700000000000, 90000) ==
      "class-queue 1700000000000 90000"
    check classQueueLine(-1, -5) == "class-queue 0 0"
