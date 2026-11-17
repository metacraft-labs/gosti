# SPDX-FileCopyrightText: 2026 Metacraft Labs / Schelling Point Labs
# SPDX-License-Identifier: Apache-2.0
## An Incus VM registered with the host RunQuota daemon
## (``registerWithHostRunQuota``): the shape it registers, the order of the
## create (the host grants the shape BEFORE the VM starts, and learns the
## VM's process and vsock CID after), the refusals, and the CLI flags.
##
## Mock justification: native copies of this test stand in for the Incus
## executable and for the ``runquota`` client and record their exact argv in
## one log, so the order of every call can be asserted without an Incus
## daemon or a RunQuota daemon. The backend, the environment, the filesystem
## and the subprocess boundary (pipes, the holder's line protocol) are real.
## The same capability against real Incus VMs, a real ``runquotad`` on the
## host and one in the guest is ``tests/e2e/t_incus_vm_runquota_link.nim``.

import std/[json, os, osproc, strutils, tables, tempfiles, unittest]
import gosti
import gosti/cli

const
  IncusFixtureName = "incus-fixture"
  RunQuotaFixtureName = "runquota-fixture"

let self = getAppFilename().extractFilename
if self == IncusFixtureName or self == RunQuotaFixtureName:
  let cfg = parseFile(getAppFilename() & ".json")
  let command = commandLineParams().join(" ")
  proc record(line: string) =
    let log = open(cfg["log"].getStr(), fmAppend)
    log.writeLine(line)
    log.close()
  if self == RunQuotaFixtureName:
    record("runquota " & command & " RUNQUOTA_SESSION=" &
      getEnv("RUNQUOTA_SESSION"))
    if cfg["refuse"].getBool():
      stderr.writeLine("registration refused: no room")
      quit(1)
    stdout.writeLine("granted 5")
    stdout.flushFile()
    var line = ""
    if not stdin.readLine(line):
      record("runquota stdin closed")
      quit(0)
    record("runquota started " & line)
    stdout.writeLine("started")
    stdout.flushFile()
    quit(0)
  record(command)
  if cfg["fail"].getStr().len > 0 and command.startsWith(cfg["fail"].getStr()):
    quit(17)
  if command.startsWith("info "):
    quit(1)
  if command.startsWith("query /1.0/instances/"):
    stdout.write("{\"pid\": 4242, \"status\": \"Running\"}")
  if command.endsWith("volatile.vsock_id"):
    stdout.write("77\n")
  if command.startsWith("list ") and cfg.hasKey("list"):
    stdout.write(cfg["list"].getStr())
  quit(0)

proc writeFixture(path, logPath: string; failPrefix = ""; refuse = false;
                  list = "") =
  copyFileWithPermissions(getAppFilename(), path)
  writeFile(path & ".json",
    $(%*{"log": logPath, "fail": failPrefix, "refuse": refuse, "list": list}))

proc lineIndex(lines: seq[string], wanted: string): int =
  for i, line in lines:
    if line == wanted:
      return i
  -1

template withEnv(key, value: string; body: untyped) =
  let hadIt = existsEnv(key)
  let previous = getEnv(key)
  if value.len > 0: putEnv(key, value) else: delEnv(key)
  try:
    body
  finally:
    if hadIt: putEnv(key, previous) else: delEnv(key)

proc newFixtures(work: string; failPrefix = "";
                 refuse = false): (IncusBackend, seq[string], string) =
  let logPath = work / "argv.log"
  writeFixture(work / IncusFixtureName, logPath, failPrefix)
  writeFixture(work / RunQuotaFixtureName, logPath, refuse = refuse)
  (newIncusBackend(incusCmd = @[work / IncusFixtureName],
    baseImage = "vm-base"), @[work / RunQuotaFixtureName], logPath)

proc vmSpec(command: seq[string]; cpus = 2; memoryMB = 1024): EphemeralIncusSpec =
  EphemeralIncusSpec(name: "rqvm", virtualMachine: true,
    registerWithHostRunQuota: true, runquotaCommand: command,
    config: incusEphemeralLimits(cpus, memoryMB))

suite "an Incus VM registered with the host RunQuota daemon":
  test "memory sizes in a provider's spellings":
    check parseMemoryBytes("1024MiB") == 1024'u64 * 1024 * 1024
    check parseMemoryBytes("2GiB") == 2'u64 * 1024 * 1024 * 1024
    check parseMemoryBytes("512MB") == 512'u64 * 1000 * 1000
    check parseMemoryBytes("4096") == 4096'u64
    expect ValueError:
      discard parseMemoryBytes("lots")
    expect ValueError:
      discard parseMemoryBytes("5 parsecs")

  test "the shape is limits.cpu and limits.memory, both required":
    var cpu: uint32
    var memory: uint64
    check vmShapeFromSpec(vmSpec(@[]), cpu, memory) == ""
    check cpu == 2000'u32
    check memory == 1024'u64 * 1024 * 1024
    var noMemory = vmSpec(@[])
    noMemory.config.del(IncusLimitsMemoryKey)
    check vmShapeFromSpec(noMemory, cpu, memory).len > 0
    var cpuSet = vmSpec(@[])
    cpuSet.config[IncusLimitsCpuKey] = "0-3"
    check vmShapeFromSpec(cpuSet, cpu, memory).len > 0

  test "the holder is asked for exactly the VM's shape":
    check vmHoldArgs("rqvm", 2000, 1073741824) == @["vm", "hold", "--name",
      "rqvm", "--cpu-milli", "2000", "--memory-bytes", "1073741824",
      "--started-from-stdin"]
    # With a probe, the holder follows the VM across a restart in place.
    check vmHoldArgs("rqvm", 2000, 1073741824, @["probe", "x"]) == @["vm",
      "hold", "--name", "rqvm", "--cpu-milli", "2000", "--memory-bytes",
      "1073741824", "--started-from-stdin", "--restart-grace",
      $DefaultRunQuotaVmRestartGraceSec, "--", "probe", "x"]

  test "the restart probe: the QEMU pid while running, 0 while stopped, nothing once gone":
    let work = createTempDir("gosti-incus-rqvm-probe", "")
    defer: removeDir(work)
    let logPath = work / "argv.log"
    for (listed, expected) in [("RUNNING,4242\n", "4242"),
                               ("STOPPED,\n", "0"),
                               ("", "")]:
      writeFixture(work / IncusFixtureName, logPath, list = listed)
      let b = newIncusBackend(incusCmd = @[work / IncusFixtureName])
      let probe = b.vmRestartProbe("rqvm")
      let (output, code) = execCmdEx(quoteShellCommand(probe))
      checkpoint("listed " & listed.escape & ": " & output.escape)
      check code == 0
      check output.strip() == expected
    # The name is an argument of the list filter, anchored, never part of
    # the script.
    check readFile(logPath).strip().splitLines()[^1] == "list ^rqvm$ -c sp --format csv"

  test "registration is for VMs, and a VM is not given the socket proxy":
    var container = vmSpec(@[])
    container.virtualMachine = false
    check runquotaSpecProblem(container).len > 0
    var proxied = vmSpec(@[])
    proxied.registerWithHostRunQuota = false
    proxied.shareHostRunQuota = true
    check runquotaSpecProblem(proxied).len > 0
    check runquotaSpecProblem(vmSpec(@[])) == ""

  test "granted before start, then the VM's pid and CID, in that order":
    let work = createTempDir("gosti-incus-rqvm", "")
    defer: removeDir(work)
    let (b, command, logPath) = newFixtures(work)
    var vm: VmHandle
    withEnv("RUNQUOTA_SESSION", "agent-session-7"):
      vm = b.provisionEphemeralClone(vmSpec(command))
    let lines = readFile(logPath).strip().splitLines()
    checkpoint(lines.join("\n"))
    let initPos = lines.lineIndex("init vm-base rqvm --vm")
    let holdPos = lines.lineIndex("runquota " & vmHoldArgs("rqvm", 2000,
      1073741824, b.vmRestartProbe("rqvm")).join(" ") &
      " RUNQUOTA_SESSION=agent-session-7")
    let startPos = lines.lineIndex("start rqvm")
    let queryPos = lines.lineIndex("query /1.0/instances/rqvm/state")
    let reportPos = lines.lineIndex("runquota started 4242 77")
    check initPos >= 0
    check initPos < holdPos
    check holdPos < startPos
    check startPos < queryPos
    check queryPos < reportPos
    check vm.extra["virtualMachine"] == "true"
    check vm.extra["runquotaLease"] == "5"
    b.stopAndCleanup(vm, deleteVm = true)
    check reapVmHolder("rqvm")

  test "a refused registration starts nothing and removes the instance":
    let work = createTempDir("gosti-incus-rqvm-refused", "")
    defer: removeDir(work)
    let (b, command, logPath) = newFixtures(work, refuse = true)
    expect GostiError:
      discard b.provisionEphemeralClone(vmSpec(command))
    let lines = readFile(logPath).strip().splitLines()
    checkpoint(lines.join("\n"))
    check lines.lineIndex("start rqvm") < 0
    check lines.lineIndex("delete --force rqvm") >= 0

  test "a VM that fails to start releases its registration":
    let work = createTempDir("gosti-incus-rqvm-nostart", "")
    defer: removeDir(work)
    let (b, command, logPath) = newFixtures(work, failPrefix = "start ")
    expect GostiError:
      discard b.provisionEphemeralClone(vmSpec(command))
    let lines = readFile(logPath).strip().splitLines()
    checkpoint(lines.join("\n"))
    # The holder saw its stdin end without a pid: it releases and exits.
    check lines.lineIndex("runquota stdin closed") >= 0
    check lines.lineIndex("delete --force rqvm") >= 0

  test "an unregistrable spec is refused before anything is made":
    let work = createTempDir("gosti-incus-rqvm-bad", "")
    defer: removeDir(work)
    let (b, command, logPath) = newFixtures(work)
    var spec = vmSpec(command)
    spec.config.del(IncusLimitsCpuKey)
    expect InvalidSpecError:
      discard b.provisionEphemeralClone(spec)
    check not fileExists(logPath) or
      readFile(logPath).find("init ") < 0

  test "the flags reach the spec only for an Incus VM":
    let opts = parseCliOpts(@["run", "--ephemeral", "--backend", "incus",
      "--baseline", "rqvm", "--incus-vm", "--incus-register-host-runquota",
      "--incus-runquota-session", "g"])
    check opts.incusVm
    check opts.incusRegisterHostRunQuota
    check opts.incusRunQuotaSession == "g"
    expect ValueError:
      discard parseCliOpts(@["run", "--ephemeral", "--backend", "incus",
        "--baseline", "rqvm", "--incus-register-host-runquota"])
    expect ValueError:
      discard parseCliOpts(@["run", "--ephemeral", "--backend", "incus",
        "--baseline", "rqvm", "--incus-vm", "--incus-share-host-runquota"])
    expect ValueError:
      discard parseCliOpts(@["run", "--ephemeral", "--backend", "noop",
        "--baseline", "rqvm", "--incus-vm"])
