# SPDX-FileCopyrightText: 2026 Metacraft Labs / Schelling Point Labs
# SPDX-License-Identifier: Apache-2.0
## The Tart backend honours an explicitly requested CPU count and memory size
## for every per-job clone.
##
## Before this gate the backend cloned the golden and booted it with the
## golden's own sizing whatever ``--cpus`` / ``--memory-mb`` said. The
## cirruslabs Ubuntu golden boots with 4 CPUs / 4096 MB, and CI jobs that link
## several large debug test binaries at once were OOM-killed (exit 137) with no
## way for the host to give the guest more.
##
## What is asserted, through the backend's public lifecycle
## (``provisionBaseline`` + ``revertToBaseline``):
##
## * explicit values are applied with ``tart set <vm> --cpu N --memory MiB``
##   on the STOPPED clone, after the clone and before ``tart run``, for Linux
##   and macOS guests alike;
## * only the explicitly requested value is applied when just one is given;
## * values the CLI filled in as defaults (``cpusDefaulted`` /
##   ``memoryMBDefaulted``) are NOT applied, so an omitted flag keeps the
##   golden's sizing rather than shrinking a 4-CPU golden to the default 2;
## * zero values (the CRUD façade forwards 0 for an omitted size) apply
##   nothing;
## * a ``tart set`` that Tart rejects fails the revert loudly and deletes the
##   clone, which never boots;
## * the CLI marks omitted ``--cpus`` / ``--memory-mb`` as defaults and
##   explicit ones as requests, and that spec reaches ``tart set`` (the chain
##   ``run --ephemeral`` drives: ``applyDefaults`` → ``provisionBaseline`` →
##   ``revertToBaseline``).
##
## MOCK JUSTIFICATION (workspace policy). ``tart``, ``sshpass`` and ``ssh`` are
## replaced by native executable fixtures passed through the backend's
## command-path fields. Tart only runs on Apple Silicon macOS and this
## deterministic suite runs on Linux x64 CI as well, so the real binary cannot
## be exercised here. The fake implements exactly the CLI surface the backend
## drives, records every invocation so the test asserts on the argv the
## backend really issued, and can be told to reject a ``tart set --cpu`` /
## ``--memory`` the way real Tart rejects a count outside the guest's
## supported range. The real-Tart counterpart is the CI fleet's Tart
## ephemeral-run host gate, which runs outside this repository.

import std/[json, os, strutils, tempfiles, unittest]
import ../native_command_fixture
import vm_harness/backends/tart
import vm_harness/cli
import vm_harness/types

const NativeSuffix = when defined(windows): ".exe" else: ""

let fixtureName = getAppFilename().extractFilename
if fixtureName in ["tart-size" & NativeSuffix, "ssh-size" & NativeSuffix]:
  let d = getAppFilename().parentDir
  let args = commandLineParams()
  let isTart = fixtureName == "tart-size" & NativeSuffix
  let log = open(d / (if isTart: "tart.log" else: "ssh.log"), fmAppend)
  log.writeLine(args.join(" "))
  log.close()
  if isTart:
    case args[0]
    of "list": echo "Source Name Disk Size SizeOnDisk State"
    of "set":
      if ("--cpu" in args or "--memory" in args) and
          fileExists(d / "reject-size"):
        stderr.writeLine("Error: VM should have at least 1 CPUs")
        quit(1)
    of "ip": echo "192.0.2.10"
    else: discard
  else:
    echo "ready"
  quit(0)

# newTartBackend reads the host's shared-store variables into its default
# shared directories (tests/unit/t_tart_shared_dirs.nim covers that). With one
# set, a macOS clone would try to mount it over SSH at the fixture's
# unroutable address. Shared directories are not under test here.
delEnv("MCL_RUNNER_SHARED_NIX_STORE")
delEnv("MCL_RUNNER_SHARED_REPRO_STORE")

proc sizeFixtureCommand(dir, name: string): string =
  result = dir / (name & NativeSuffix)
  copyFileWithPermissions(getAppFilename(), result)

type Fixture = object
  dir: string
  log: string
  backend: TartBackend

proc newFixture(guestOs: GuestOs, rejectSize = false): Fixture =
  result.dir = createTempDir("vmh-tart-size-", "")
  result.log = result.dir / "tart.log"
  if rejectSize:
    writeFile(result.dir / "reject-size", "")
  let tart = sizeFixtureCommand(result.dir, "tart-size")
  let sshpass = commandFixture(result.dir / "sshpass", %*{"forwardSkip": 2})
  let ssh = sizeFixtureCommand(result.dir, "ssh-size")
  result.backend = newTartBackend(guestOs = guestOs, tartCmd = tart,
    sshpassCmd = sshpass, sshCmd = ssh, bootTimeoutSec = 5,
    sshReadyTimeoutSec = 10, ephemeralPrefix = "vmh-size-test")

proc provision(f: Fixture, cpus, memoryMB: int, cpusDefaulted = false,
               memoryMBDefaulted = false) =
  # diskGB stays 0 so the disk-size path (t_tart_disk_resize) issues nothing.
  f.backend.provisionBaseline(BaselineSpec(
    name: "golden", sourceImage: "ghcr.io/example/golden:latest",
    cpus: cpus, memoryMB: memoryMB, cpusDefaulted: cpusDefaulted,
    memoryMBDefaulted: memoryMBDefaulted))

proc tartCalls(f: Fixture): seq[string] =
  for line in readFile(f.log).splitLines():
    if line.len > 0: result.add(line)

proc indexOfPrefix(calls: seq[string], prefix: string): int =
  for i, c in calls:
    if c.startsWith(prefix): return i
  -1

proc sizeCalls(f: Fixture): seq[string] =
  for c in f.tartCalls():
    if c.startsWith("set ") and (" --cpu " in c or " --memory " in c):
      result.add(c)

suite "Tart per-job CPU and memory":
  for guestOs in [goLinux, goMacos]:
    test "explicit sizes are set on the stopped clone before it boots (" &
        $guestOs & ")":
      let f = newFixture(guestOs)
      defer: removeDir(f.dir)
      f.provision(cpus = 8, memoryMB = 16384)
      let vm = f.backend.revertToBaseline("golden")
      let calls = f.tartCalls()
      let clone = calls.indexOfPrefix("clone ")
      let size = calls.indexOfPrefix("set " & vm.name & " --cpu 8 --memory 16384")
      let run = calls.indexOfPrefix("run ")
      check clone >= 0
      check size > clone
      check run > size
      check f.sizeCalls().len == 1

  test "only the explicitly requested value is applied":
    let f = newFixture(goLinux)
    defer: removeDir(f.dir)
    f.provision(cpus = 2, memoryMB = 12288, cpusDefaulted = true)
    let vm = f.backend.revertToBaseline("golden")
    check f.sizeCalls() == @["set " & vm.name & " --memory 12288"]

  test "defaulted sizes keep the golden's sizing":
    # The CLI fills in 2 CPUs / 4096 MiB for an omitted flag; applying them
    # would shrink the 4-CPU cirruslabs golden.
    let f = newFixture(goLinux)
    defer: removeDir(f.dir)
    f.provision(cpus = 2, memoryMB = 4096, cpusDefaulted = true,
                memoryMBDefaulted = true)
    discard f.backend.revertToBaseline("golden")
    check f.sizeCalls().len == 0
    check f.tartCalls().indexOfPrefix("run ") >= 0

  test "zero sizes apply nothing":
    let f = newFixture(goLinux)
    defer: removeDir(f.dir)
    f.provision(cpus = 0, memoryMB = 0)
    discard f.backend.revertToBaseline("golden")
    check f.sizeCalls().len == 0

  test "a rejected size fails the clone, which is deleted and never booted":
    let f = newFixture(goLinux, rejectSize = true)
    defer: removeDir(f.dir)
    f.provision(cpus = 64, memoryMB = 16384)
    var raised = false
    try:
      discard f.backend.revertToBaseline("golden")
    except VmHarnessError as e:
      raised = true
      check "--cpu 64" in e.msg
      check "at least" in e.msg
    check raised
    let calls = f.tartCalls()
    check f.sizeCalls().len == 1
    check calls.indexOfPrefix("run ") == -1
    check calls.indexOfPrefix("delete vmh-size-test-") >
          calls.indexOfPrefix("set vmh-size-test-")

suite "CLI CPU and memory reach the Tart backend":
  test "omitted --cpus / --memory-mb are DEFAULTS, explicit ones are not":
    var defaulted: BaselineSpec
    applyDefaults(defaulted, parseCliOpts(@["run", "--ephemeral",
      "--backend", "tart-linux-arm", "--baseline", "garm-x"]))
    check defaulted.cpus == 2
    check defaulted.memoryMB == 4096
    check defaulted.cpusDefaulted
    check defaulted.memoryMBDefaulted

    var explicit: BaselineSpec
    applyDefaults(explicit, parseCliOpts(@["run", "--ephemeral",
      "--backend", "tart-linux-arm", "--baseline", "garm-x",
      "--vcpu", "6", "--memory-gb", "16"]))
    check explicit.cpus == 6
    check explicit.memoryMB == 16384
    check not explicit.cpusDefaulted
    check not explicit.memoryMBDefaulted

  test "an explicit --cpus/--memory-mb spec produces tart set; an omitted one does not":
    for (argv, expected) in [
        (@["--cpus", "6", "--memory-mb", "12288"], "--cpu 6 --memory 12288"),
        (newSeq[string](), "")]:
      let f = newFixture(goLinux)
      defer: removeDir(f.dir)
      var spec: BaselineSpec
      applyDefaults(spec, parseCliOpts(@["run", "--ephemeral",
        "--backend", "tart-linux-arm", "--baseline", "garm-x"] & argv))
      spec.sourceImage = "ghcr.io/example/golden:latest"
      spec.diskGB = 0
      f.backend.provisionBaseline(spec)
      let vm = f.backend.revertToBaseline("garm-x")
      if expected.len > 0:
        check f.sizeCalls() == @["set " & vm.name & " " & expected]
      else:
        check f.sizeCalls().len == 0
