# SPDX-FileCopyrightText: 2026 Metacraft Labs / Schelling Point Labs
# SPDX-License-Identifier: Apache-2.0
## Reporting how long a pool's jobs wait for a slot to the host's RunQuota
## daemon, as `class-queue` waits of the pool's class.
##
## A host may reserve capacity for a class of work (a CI runner pool, a VM
## pool), and whether the reservation is large enough is judged by how long
## the class's jobs wait. RunQuota publishes that per class beside its
## build-wait pressure, from what the pools report. A pool reports through
## ONE long-lived reporting session -- ``runquota pressure report --class C``
## -- started with the pool and kept for its life: the daemon trusts no
## client-sent wait longer than the reporting session has existed, so a
## session opened per job could report about a second and no more.
##
## The protocol with the reporter is lines: it prints ``ready <session>``
## once registered; for each finished wait gosti writes
## ``class-queue <started-unix-millis> <length-millis>`` and reads one
## answer (``reported ...``, ``skipped ...`` for a wait under a second,
## ``refused ...``). Closing its stdin ends the session.
##
## Reporting is the pool's configuration: a pool with no class starts no
## reporter and reports nothing. A reporter that cannot be started, or that
## goes away, is a lost measurement, never a failed job: the pool keeps
## serving and says so on stderr once.

import std/[os, osproc, streams, strtabs, strutils, times]
import ./runquota_vm

type
  ClassQueueReporter* = ref object
    process*: Process
    className*: string
    sessionId*: uint64
    lost*: bool
      ## The reporter could not be started or went away: nothing more is
      ## reported.
    reported*: int
      ## Waits the reporter accepted.

  ClassQueueError* = object of CatchableError

const
  ClassQueueMinWaitMillis* = 1000'i64
    ## The shortest wait reported, as for every RunQuota wait.
  ClassQueueReadySec = 30
  ClassQueueAnswerSec = 10

proc classQueueArgs*(className: string): seq[string] =
  ## ``runquota``'s arguments for a pool's reporting session.
  @["pressure", "report", "--class", className]

proc classQueueLine*(startedAtUnixMillis, lengthMillis: int64): string =
  ## The line that reports one finished wait.
  "class-queue " & $max(0'i64, startedAtUnixMillis) & " " &
    $max(0'i64, lengthMillis)

proc unixMillisNow*(): int64 = int64(epochTime() * 1000.0)

proc startClassQueueReporter*(command: seq[string]; className: string;
                              session = ""): ClassQueueReporter =
  ## Start the reporting session for ``className`` and wait for it to be
  ## registered. ``session`` names the RunQuota session group (else the
  ## daemon puts it in the group named after the class). Raises
  ## ``ClassQueueError`` when the client cannot be run or refuses (an
  ## unknown class name, a daemon that predates classes, none reachable).
  if command.len == 0:
    raise newException(ClassQueueError, "no runquota command")
  if className.len == 0:
    raise newException(ClassQueueError, "no class to report waits in")
  var env = newStringTable(modeCaseSensitive)
  for k, v in envPairs():
    env[k] = v
  if session.len > 0:
    env["RUNQUOTA_SESSION"] = session
  let p =
    try:
      startProcess(command[0], args = command[1 .. ^1] &
        classQueueArgs(className), env = env, options = {poUsePath})
    except OSError as e:
      raise newException(ClassQueueError,
        "cannot run " & command[0] & " (the RunQuota client): " & e.msg)
  var line = ""
  if not p.readLineWithin(ClassQueueReadySec, line) or
      not line.startsWith("ready "):
    var detail = ""
    if p.exitedWithin(1000):
      try:
        detail = p.errorStream.readAll().strip()
      except CatchableError:
        discard
    else:
      p.inputStream.close()
      if not p.exitedWithin(5000):
        p.terminate()
        discard p.exitedWithin(5000)
    p.close()
    raise newException(ClassQueueError,
      "the RunQuota reporting session for class " & className &
      " did not start" & (if detail.len > 0: ": " & detail else: ""))
  ClassQueueReporter(process: p, className: className,
    sessionId: uint64(parseBiggestUInt(line[6 .. ^1].strip())))

proc reportWait*(reporter: ClassQueueReporter; startedAtUnixMillis,
                 lengthMillis: int64): bool =
  ## Report one job's finished wait for a slot. True when the reporter
  ## accepted it; a wait under a second is not sent (false), and a lost
  ## reporter reports nothing (false).
  if reporter.isNil or reporter.lost:
    return false
  if lengthMillis < ClassQueueMinWaitMillis:
    return false
  let p = reporter.process
  try:
    p.inputStream.write(classQueueLine(startedAtUnixMillis, lengthMillis) &
      "\n")
    p.inputStream.flush()
  except CatchableError as e:
    reporter.lost = true
    stderr.writeLine("gosti: the RunQuota reporting session for class " &
      reporter.className & " went away; class-queue waits are no longer " &
      "reported (" & e.msg & ")")
    return false
  var answer = ""
  if not p.readLineWithin(ClassQueueAnswerSec, answer):
    reporter.lost = true
    stderr.writeLine("gosti: the RunQuota reporting session for class " &
      reporter.className & " stopped answering; class-queue waits are no " &
      "longer reported")
    return false
  if answer.startsWith("reported "):
    inc reporter.reported
    return true
  false

proc close*(reporter: ClassQueueReporter) =
  ## End the reporting session: its stdin closes, it closes the session and
  ## exits. A reporter that does not exit is stopped (it is this process's
  ## own child).
  if reporter.isNil or reporter.process.isNil:
    return
  let p = reporter.process
  try:
    p.inputStream.close()
  except CatchableError:
    discard
  if not p.exitedWithin(10_000):
    p.terminate()
    discard p.exitedWithin(5000)
  p.close()
  reporter.process = nil
  reporter.lost = true
