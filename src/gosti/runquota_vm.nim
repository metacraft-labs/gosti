# SPDX-FileCopyrightText: 2026 Metacraft Labs / Schelling Point Labs
# SPDX-License-Identifier: Apache-2.0
## Registering a VM gosti starts with the host's RunQuota daemon.
##
## A VM's memory is the host's from the moment the VM boots, and its vCPUs
## compete with the host's own builds. RunQuota holds both for the VM's life
## as one lease, through a HOLDER process: ``runquota vm hold``. gosti starts
## the holder BEFORE the VM, waits for its ``granted <lease>`` line (the host
## has reserved the VM's memory and counted its shape), starts the VM, then
## writes ``<pid> <vsock-cid>`` -- the VM's host process and the CID its guest
## RunQuota daemon will link from -- and waits for ``started``. From then on
## the holder waits on the VM process itself and releases the lease when it
## exits, so gosti's teardown (deleting the VM) is what ends it; gosti only
## reaps the holder afterwards.
##
## A VM RESTARTED IN PLACE (an Incus VM's guest reboot) runs on in a NEW
## process. The provider therefore also gives the holder a probe command:
## when the watched process exits, the holder asks the probe, for up to
## ``DefaultRunQuotaVmRestartGraceSec``, whether the VM runs again and as
## which process, and goes on holding with the new one; it releases once the
## probe says the VM no longer exists, or the grace runs out.
##
## If gosti dies, the holder keeps holding; if the holder dies, the daemon
## holds the reservation exactly as long as the VM process lives (the VM
## process is the lease's watched child). Nothing here or in RunQuota stops
## the VM.
##
## While the guest's daemon is linked to the host's (vsock), the host charges
## the VM what the guest's own leases hold; without the link, its full shape.
## Provider-agnostic: a provider supplies the shape before start and the pid
## and CID after.

import std/[os, osproc, streams, strtabs, strutils, tables, times]
when defined(posix):
  import std/posix

type
  RunQuotaVmHolder* = object
    process*: Process
    name*: string
    leaseId*: uint64
    started*: bool

  RunQuotaVmError* = object of CatchableError

const
  DefaultRunQuotaVmWaitSec* = 600
    ## How long a VM create waits for the host to grant the VM's shape
    ## before failing (a busy host queues it like any lease).
  DefaultRunQuotaVmRestartGraceSec* = 120
    ## How long the holder keeps the registration after the VM's process
    ## exits while it waits for the probe to report the VM's next process
    ## (a guest reboot) or its end. A VM stopped and kept is held this long.

var holders = initTable[string, RunQuotaVmHolder]()
  ## The holder of each VM this process registered, by VM name, so teardown
  ## can reap it.

proc runquotaVmCommand*(configured: seq[string]): seq[string] =
  ## The ``runquota`` client to run: the spec's, else ``GOSTI_RUNQUOTA_CMD``
  ## (split on whitespace), else ``runquota`` on ``PATH``.
  if configured.len > 0:
    return configured
  let fromEnv = getEnv("GOSTI_RUNQUOTA_CMD").strip()
  if fromEnv.len > 0:
    return fromEnv.splitWhitespace()
  @["runquota"]

proc parseMemoryBytes*(text: string): uint64 =
  ## A provider's memory size -- ``1024MiB``, ``1GiB``, ``512MB``, ``2G``,
  ## or a byte count -- in bytes. Raises ``ValueError`` on anything else.
  let t = text.strip()
  var i = 0
  while i < t.len and t[i] in {'0' .. '9'}:
    inc i
  if i == 0:
    raise newException(ValueError, "not a memory size: '" & text & "'")
  let number = parseBiggestUInt(t[0 ..< i])
  let unit = t[i .. ^1].strip().toLowerAscii()
  let multiplier =
    case unit
    of "", "b": 1'u64
    of "kib", "k": 1024'u64
    of "mib", "m": 1024'u64 * 1024
    of "gib", "g": 1024'u64 * 1024 * 1024
    of "tib", "t": 1024'u64 * 1024 * 1024 * 1024
    of "kb": 1000'u64
    of "mb": 1000'u64 * 1000
    of "gb": 1000'u64 * 1000 * 1000
    of "tb": 1000'u64 * 1000 * 1000 * 1000
    else:
      raise newException(ValueError, "unknown memory unit in '" & text & "'")
  uint64(number) * multiplier

proc vmHoldArgs*(name: string; cpuMilli: uint32; memoryBytes: uint64;
                 restartProbe: seq[string] = @[];
                 restartGraceSec = DefaultRunQuotaVmRestartGraceSec): seq[string] =
  ## ``runquota vm hold``'s arguments. With ``restartProbe`` (the provider's
  ## command printing the VM's current process, ``0`` while it is stopped,
  ## and nothing once it no longer exists), the holder follows the VM across
  ## a restart in place.
  result = @["vm", "hold", "--name", name, "--cpu-milli", $cpuMilli,
    "--memory-bytes", $memoryBytes, "--started-from-stdin"]
  if restartProbe.len > 0 and restartGraceSec > 0:
    result.add(@["--restart-grace", $restartGraceSec, "--"])
    result.add(restartProbe)

proc readLineWithin(p: Process; timeoutSec: int; line: var string): bool =
  ## One line of the holder's stdout within ``timeoutSec``; false on
  ## timeout or end of output.
  when defined(posix):
    let fd = cint(p.outputHandle)
    let deadline = epochTime() + float(timeoutSec)
    line = ""
    while true:
      let left = int((deadline - epochTime()) * 1000.0)
      if left <= 0:
        return false
      var pfd = TPollfd(fd: fd, events: POLLIN)
      let ready = poll(addr pfd, 1, cint(min(left, 1000)))
      if ready < 0:
        return false
      if ready == 0:
        continue
      var c: char
      let n = posix.read(fd, addr c, 1)
      if n <= 0:
        return false
      if c == '\n':
        return true
      line.add(c)
  else:
    raise newException(RunQuotaVmError,
      "registering a VM with RunQuota needs a POSIX host")

proc exitedWithin(p: Process; millis: int): bool =
  ## Whether ``p`` exits within ``millis``. Polls ``running`` rather than
  ## calling ``waitForExit`` with a bound, which on POSIX kills a process
  ## still running at the bound.
  let deadline = epochTime() + float(millis) / 1000.0
  while p.running():
    if epochTime() >= deadline:
      return false
    sleep(50)
  true

proc holderFailure(p: Process; what: string): ref RunQuotaVmError =
  var detail = ""
  if p.exitedWithin(1000):
    try:
      detail = p.errorStream.readAll().strip()
    except CatchableError:
      discard
  newException(RunQuotaVmError, what &
    (if detail.len > 0: ": " & detail else: ""))

proc startVmHolder*(command: seq[string]; name: string; cpuMilli: uint32;
                    memoryBytes: uint64; session: string;
                    waitSec = DefaultRunQuotaVmWaitSec;
                    restartProbe: seq[string] = @[]): RunQuotaVmHolder =
  ## Register VM ``name`` with the host daemon and wait for the grant.
  ## Raises ``RunQuotaVmError`` when the daemon cannot be reached, refuses,
  ## or does not grant within ``waitSec`` (the holder is then stopped and
  ## nothing stays registered).
  if command.len == 0:
    raise newException(RunQuotaVmError, "no runquota command")
  var env = newStringTable(modeCaseSensitive)
  for k, v in envPairs():
    env[k] = v
  if session.len > 0:
    env["RUNQUOTA_SESSION"] = session
  let p =
    try:
      startProcess(command[0], args = command[1 .. ^1] &
        vmHoldArgs(name, cpuMilli, memoryBytes, restartProbe), env = env,
        options = {poUsePath})
    except OSError as e:
      raise newException(RunQuotaVmError,
        "cannot run " & command[0] & " (the RunQuota client): " & e.msg)
  var line = ""
  if not p.readLineWithin(waitSec, line) or not line.startsWith("granted "):
    let failure = p.holderFailure("the host RunQuota daemon did not grant " &
      "VM " & name & "'s shape (" & $cpuMilli & "m CPU, " & $memoryBytes &
      " bytes) within " & $waitSec & " s")
    if p.running():
      # Stdin ending before a pid arrives makes the holder release and exit.
      p.inputStream.close()
      if not p.exitedWithin(5000):
        p.terminate()
        discard p.exitedWithin(5000)
    p.close()
    raise failure
  result = RunQuotaVmHolder(process: p, name: name,
    leaseId: uint64(parseBiggestUInt(line[8 .. ^1].strip())))

proc reportVmStarted*(holder: var RunQuotaVmHolder; pid: int; vsockCid: uint32;
                      timeoutSec = 60) =
  ## Tell the holder the VM runs as host process ``pid`` and links from
  ## ``vsockCid`` (0: no link address), and wait for ``started``. The holder
  ## is then registered for teardown.
  let p = holder.process
  try:
    p.inputStream.write($pid & (if vsockCid != 0'u32: " " & $vsockCid else: "") &
      "\n")
    p.inputStream.flush()
  except CatchableError as e:
    raise p.holderFailure("the RunQuota holder of VM " & holder.name &
      " went away before the VM's process was reported: " & e.msg)
  var line = ""
  if not p.readLineWithin(timeoutSec, line) or line != "started":
    raise p.holderFailure("the host RunQuota daemon did not accept VM " &
      holder.name & "'s start (pid " & $pid & ", vsock CID " & $vsockCid & ")")
  p.inputStream.close()
  holder.started = true
  holders[holder.name] = holder

proc abandonVmHolder*(holder: var RunQuotaVmHolder) =
  ## The VM was not started (its create failed): end the holder, which
  ## releases a registration no VM process stands behind.
  let p = holder.process
  try:
    p.inputStream.close()
  except CatchableError:
    discard
  if not p.exitedWithin(10_000):
    p.terminate()
    discard p.exitedWithin(5000)
  p.close()
  holders.del(holder.name)

proc reapVmHolder*(name: string; timeoutSec = 30): bool =
  ## After the VM ``name`` was deleted: wait for its holder to release and
  ## exit. True when there was none or it exited. A holder that outlives the
  ## wait is left running -- it releases when the VM process is gone -- and
  ## never signalled.
  if not holders.hasKey(name):
    return true
  let p = holders[name].process
  holders.del(name)
  if not p.exitedWithin(timeoutSec * 1000):
    return false
  let code = p.waitForExit()
  p.close()
  code == 0

proc vmHolderLease*(name: string): uint64 =
  ## The RunQuota lease holding VM ``name``, or 0.
  if holders.hasKey(name): holders[name].leaseId else: 0'u64

proc vmHolderPid*(name: string): int =
  ## The pid of VM ``name``'s holder process, or 0.
  if holders.hasKey(name): holders[name].process.processID else: 0
