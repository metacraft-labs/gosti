# SPDX-FileCopyrightText: 2026 Metacraft Labs / Schelling Point Labs
# SPDX-License-Identifier: Apache-2.0
## The Tart backend honours the requested disk size of a per-job clone.
##
## A cirruslabs Linux golden ships a 20 GB disk. Before this gate the Tart
## backend cloned it and booted it unchanged whatever ``--disk-gb`` said, and
## CI jobs on the m3 arm64 runners died with ``No space left on device``.
##
## What is asserted, through the backend's public lifecycle
## (``provisionBaseline`` + ``revertToBaseline``):
##
## * a Linux clone smaller than the request is grown with
##   ``tart set <vm> --disk-size <GB>`` while it is still stopped;
## * a clone that is already large enough is left alone;
## * an explicitly requested size below the image's is refused with
##   ``TartDiskSizeTooSmallError`` and the clone is deleted, never booted;
## * a DEFAULTED size below the image's keeps the image's size;
## * macOS clones are never resized (the guest cannot use the space without a
##   recovery-mode repartition);
## * after boot the guest's root filesystem is verified to have grown, and is
##   grown in-guest (growpart + resize2fs) when cloud-init did not.
##
## MOCK JUSTIFICATION (workspace policy). ``tart``, ``sshpass`` and ``ssh`` are
## replaced by native executable fixtures passed through the backend's command-path
## fields. Tart only runs on Apple Silicon macOS and this deterministic suite
## runs on Linux x64 CI as well, so the real binary cannot be exercised here.
## The fakes implement exactly the CLI surface the backend drives — ``tart
## get --format json`` reports the same ``Disk`` field real Tart prints, and
## ``tart set --disk-size`` refuses to shrink as real Tart does — and record
## every invocation so the test asserts on the argv the backend really issued.
## The real-Tart counterpart is the host gate
## ``checks/t_vmharness_tart_ephemeral_run.sh`` in metacraft-labs/infra.

import std/[json, os, strutils, tables, tempfiles, unittest]
import ../native_command_fixture
import vm_harness/backends/tart
import vm_harness/cli
import vm_harness/types

const NativeSuffix = when defined(windows): ".exe" else: ""

let fixtureName = getAppFilename().extractFilename
if fixtureName in ["tart-disk" & NativeSuffix, "ssh-disk" & NativeSuffix]:
  let d = getAppFilename().parentDir
  let args = commandLineParams()
  let isTart = fixtureName == "tart-disk" & NativeSuffix
  let log = open(d / (if isTart: "tart.log" else: "ssh.log"), fmAppend)
  log.writeLine(args.join(" "))
  log.close()
  if isTart:
    case args[0]
    of "list": echo "Source Name Disk Size SizeOnDisk State"
    of "get":
      echo $(%*{"CPU": 4, "Disk": parseInt(readFile(d / "disk")),
                 "Running": false, "State": "stopped"})
    of "set":
      if args.len >= 4 and args[2] == "--disk-size":
        if parseInt(args[3]) < parseInt(readFile(d / "disk")):
          stderr.writeLine("Error: new disk size should be larger than the current disk size")
          quit(1)
        writeFile(d / "disk", args[3])
    of "ip": echo "192.0.2.10"
    else: discard
  else:
    let command = args.join(" ")
    if "growpart" in command:
      let size = readFile(d / "growpart-size")
      if parseBiggestInt(size) > 0: writeFile(d / "rootfs", size)
    elif "df -P" in command: echo readFile(d / "rootfs")
    else: echo "ready"
  quit(0)

proc diskFixtureCommand(dir, name: string): string =
  result = dir / (name & NativeSuffix)
  copyFileWithPermissions(getAppFilename(), result)

type Fixture = object
  dir: string
  log: string
  sshLog: string
  backend: TartBackend

proc newFixture(guestOs: GuestOs, imageGB: int,
                rootFsBytes = 0'i64, growpartGrowsTo = 0'i64): Fixture =
  ## ``imageGB`` is the golden's disk size, inherited by every clone.
  ## ``rootFsBytes`` is what ``df`` reports for ``/`` in the guest; when
  ## ``growpartGrowsTo`` is non-zero an in-guest growpart run changes it.
  result.dir = createTempDir("vmh-tart-disk-", "")
  result.log = result.dir / "tart.log"
  result.sshLog = result.dir / "ssh.log"
  let d = result.dir
  writeFile(d / "disk", $imageGB)
  writeFile(d / "rootfs", $rootFsBytes)
  writeFile(d / "growpart-size", $growpartGrowsTo)
  let tart = diskFixtureCommand(d, "tart-disk")
  let sshpass = commandFixture(d / "sshpass", %*{"forwardSkip": 2})
  let ssh = diskFixtureCommand(d, "ssh-disk")
  result.backend = newTartBackend(guestOs = guestOs, tartCmd = tart,
    sshpassCmd = sshpass, sshCmd = ssh, bootTimeoutSec = 5,
    sshReadyTimeoutSec = 10, ephemeralPrefix = "vmh-disk-test")

proc provision(f: Fixture, diskGB: int, defaulted = false) =
  f.backend.provisionBaseline(BaselineSpec(
    name: "golden", sourceImage: "ghcr.io/example/golden:latest",
    diskGB: diskGB, diskGBDefaulted: defaulted))

proc tartCalls(f: Fixture): seq[string] =
  for line in readFile(f.log).splitLines():
    if line.len > 0: result.add(line)

proc indexOfPrefix(calls: seq[string], prefix: string): int =
  for i, c in calls:
    if c.startsWith(prefix): return i
  -1

proc diskSizeCalls(f: Fixture): seq[string] =
  for c in f.tartCalls():
    if "--disk-size" in c: result.add(c)

const GB = 1_000_000_000'i64

suite "Tart per-job disk size":
  test "a Linux clone smaller than the request is grown before it boots":
    let f = newFixture(goLinux, imageGB = 20, rootFsBytes = 48 * GB)
    defer: removeDir(f.dir)
    f.provision(diskGB = 50)
    let vm = f.backend.revertToBaseline("golden")
    let calls = f.tartCalls()
    let resize = calls.indexOfPrefix("set " & vm.name & " --disk-size 50")
    let run = calls.indexOfPrefix("run ")
    check resize >= 0
    check run >= 0
    check resize < run
    check readFile(f.dir / "disk") == "50"

  test "a clone already at the requested size is not resized":
    let f = newFixture(goLinux, imageGB = 50, rootFsBytes = 48 * GB)
    defer: removeDir(f.dir)
    f.provision(diskGB = 50)
    discard f.backend.revertToBaseline("golden")
    check f.diskSizeCalls().len == 0

  test "an explicitly requested size below the image's is refused":
    let f = newFixture(goLinux, imageGB = 20)
    defer: removeDir(f.dir)
    f.provision(diskGB = 10)
    var raised = false
    try:
      discard f.backend.revertToBaseline("golden")
    except TartDiskSizeTooSmallError as e:
      raised = true
      check e.requestedGB == 10
      check e.imageGB == 20
      check "10" in e.msg and "20" in e.msg
    check raised
    let calls = f.tartCalls()
    check f.diskSizeCalls().len == 0
    check calls.indexOfPrefix("run ") == -1
    check calls.indexOfPrefix("delete vmh-disk-test-") >= 0

  test "a defaulted size below the image's keeps the image's size":
    let f = newFixture(goLinux, imageGB = 80, rootFsBytes = 78 * GB)
    defer: removeDir(f.dir)
    f.provision(diskGB = 50, defaulted = true)
    discard f.backend.revertToBaseline("golden")
    check f.diskSizeCalls().len == 0
    check f.tartCalls().indexOfPrefix("run ") >= 0

  test "no size requested leaves the clone alone":
    let f = newFixture(goLinux, imageGB = 20, rootFsBytes = 19 * GB)
    defer: removeDir(f.dir)
    f.provision(diskGB = 0)
    discard f.backend.revertToBaseline("golden")
    check f.diskSizeCalls().len == 0

  test "macOS clones are never resized":
    let f = newFixture(goMacos, imageGB = 20)
    defer: removeDir(f.dir)
    f.provision(diskGB = 50)
    discard f.backend.revertToBaseline("golden")
    check f.diskSizeCalls().len == 0

  test "a root filesystem cloud-init did not grow is grown in the guest":
    let f = newFixture(goLinux, imageGB = 20, rootFsBytes = 19 * GB,
                       growpartGrowsTo = 48 * GB)
    defer: removeDir(f.dir)
    f.provision(diskGB = 50)
    let vm = f.backend.revertToBaseline("golden")
    check "growpart" in readFile(f.sshLog)
    check vm.extra.getOrDefault("diskGB") == "50"

  test "a root filesystem that cannot be grown fails the boot by name":
    let f = newFixture(goLinux, imageGB = 20, rootFsBytes = 19 * GB)
    defer: removeDir(f.dir)
    f.provision(diskGB = 50)
    var raised = false
    try:
      discard f.backend.revertToBaseline("golden")
    except TartGuestDiskNotGrownError as e:
      raised = true
      check "50" in e.msg
    check raised
    check f.tartCalls().indexOfPrefix("delete vmh-disk-test-") >= 0

suite "CLI disk size reaches the backend":
  test "an omitted --disk-gb is a DEFAULT, an explicit one is not":
    # garm-provider-vmharness sends no --disk-gb for Tart, so the default is
    # what every m3 arm64 runner gets: it must grow the 20 GB golden, and it
    # must never refuse a golden that is already larger.
    var defaulted: BaselineSpec
    applyDefaults(defaulted, parseCliOpts(@["run", "--ephemeral",
      "--backend", "tart-linux-arm", "--baseline", "garm-x"]))
    check defaulted.diskGB == 50
    check defaulted.diskGBDefaulted

    var explicit: BaselineSpec
    applyDefaults(explicit, parseCliOpts(@["run", "--ephemeral",
      "--backend", "tart-linux-arm", "--baseline", "garm-x",
      "--disk-gb", "120"]))
    check explicit.diskGB == 120
    check not explicit.diskGBDefaulted
