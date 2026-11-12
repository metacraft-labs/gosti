# SPDX-FileCopyrightText: 2026 Metacraft Labs / Schelling Point Labs
# SPDX-License-Identifier: Apache-2.0
## `run --ephemeral` on a gosti-run backend must reap only ITS OWN stale
## clones, never another instance's running guest.
##
## THE DEFECT THIS PINS (m3, 2026-11-12). Two GARM controllers create
## tart-linux-arm guests on the same host. The per-host GARM passes
## `--ephemeral-prefix repro-vm-tart-linux-garm-<id>`; the central GARM's
## remote provider calls `run --ephemeral --backend tart-linux-arm --baseline
## garm-<id> …` with no prefix. `provisionBaseline` "reaps stale ephemerals"
## by stopping and deleting every VM whose name started with the backend's
## prefix — for the central path the default `repro-vm-tart-linux`, a prefix
## of every per-host guest's name. Each central-pool create therefore killed
## every running per-host CI guest mid-job ("The self-hosted runner lost
## communication with the server").
##
## What is asserted, through the exact sequence `run --ephemeral` drives
## (`parseCliOpts` → `vmRunEphemeralSpec` → `provisionBaseline` →
## `revertToBaseline`), with no explicit prefix and `--baseline garm-mine`:
##
## * another instance's VM (`repro-vm-tart-linux-garm-other-…`), a
##   default-prefix VM, and one whose baseline merely EXTENDS ours
##   (`garm-mine2`) are neither stopped nor deleted;
## * a stale clone of our own baseline, and its snapshot, ARE reaped;
## * the new clone is named `repro-vm-tart-linux-garm-mine-<ms>-<pid>`;
## * an explicit `--ephemeral-prefix` is used as given;
## * the utm backend honours the scoped prefix and the same ownership rule.
##
## MOCK JUSTIFICATION (workspace policy). `tart`, `utmctl`, `sshpass` and
## `ssh` are replaced by native executable fixtures passed through the
## backends' command-path fields. Tart and UTM run only on Apple-silicon macOS
## and this deterministic suite runs on Linux x64 CI as well, so the real
## binaries cannot be exercised here. The fakes print a configured VM listing
## and record every invocation, so the assertions are on the argv the backend
## really issued — which is exactly where the defect was: a `stop`/`delete`
## of a VM the backend did not own.

import std/[json, os, strutils, tables, tempfiles, unittest]
import ../native_command_fixture
import gosti/backends/tart
import gosti/backends/utm
import gosti/cli
import gosti/ephemeral_names
import gosti/types

const NativeSuffix = when defined(windows): ".exe" else: ""

let fixtureName = getAppFilename().extractFilename
if fixtureName in ["tart-reap" & NativeSuffix, "ssh-reap" & NativeSuffix,
                   "utmctl-reap" & NativeSuffix]:
  let d = getAppFilename().parentDir
  let args = commandLineParams()
  let kind = fixtureName.split('-')[0]
  let log = open(d / (kind & ".log"), fmAppend)
  log.writeLine(args.join(" "))
  log.close()
  case kind
  of "tart":
    case args[0]
    of "list":
      echo "Source Name Disk Size SizeOnDisk State"
      for n in readFile(d / "vms.txt").splitLines():
        if n.len > 0: echo "local " & n & " 50 20 20 running"
    of "ip": echo "192.0.2.10"
    of "get": echo """{"Disk": 200}"""
    else: discard
  of "utmctl":
    case args[0]
    of "status": echo "stopped"
    of "list":
      echo "UUID                                 Status   Name"
      var i = 0
      for n in readFile(d / "vms.txt").splitLines():
        if n.len > 0:
          inc i
          echo "00000000-0000-0000-0000-" & align($i, 12, '0') &
               " started  " & n
    else: discard
  else:
    echo "ready"
  quit(0)

# Shared directories are not under test; with these set a clone would try to
# mount them over SSH at the fixture's unroutable address.
delEnv("MCL_RUNNER_SHARED_NIX_STORE")
delEnv("MCL_RUNNER_SHARED_REPRO_STORE")

const
  OtherInstance = "repro-vm-tart-linux-garm-other-1789000000000-4242"
    ## A per-host GARM guest, running a CI job.
  DefaultPrefixed = "repro-vm-tart-linux-1789000000001-4243"
    ## A guest minted with the bare default prefix (an older central create).
  ExtendsOurs = "repro-vm-tart-linux-garm-mine2-1789000000002-4244"
    ## A different instance whose name merely extends ours.
  OwnStale = "repro-vm-tart-linux-garm-mine-1789000000003-4245"
    ## An earlier attempt of THIS instance — the leftover the reap is for.
  OwnStaleSnap = OwnStale & "-snap-base"

proc selfFixture(dir, name: string): string =
  result = dir / (name & NativeSuffix)
  copyFileWithPermissions(getAppFilename(), result)

proc logLines(path: string): seq[string] =
  if not fileExists(path): return
  for line in readFile(path).splitLines():
    if line.len > 0: result.add(line)

proc touched(calls: seq[string], verb, vm: string): bool =
  ## Whether the backend issued `<verb> … <vm>` naming exactly that VM.
  for c in calls:
    let parts = c.splitWhitespace()
    if parts.len > 0 and parts[0] == verb and vm in parts: return true
  false

proc runOpts(extra: seq[string] = @[]): CliOpts =
  parseCliOpts(@["run", "--ephemeral", "--backend", "tart-linux-arm",
    "--baseline", "garm-mine", "--source-image", "ghcr.io/example/g:1",
    "--keep"] & extra)

suite "ephemeral clone names":
  test "a clone is owned only by the prefix that minted it":
    let p = "repro-vm-tart-linux-garm-mine"
    check ownsEphemeralName(p, ephemeralName(p, 1789000000003'i64, 4245))
    check ownsEphemeralName(p, OwnStaleSnap)
    check not ownsEphemeralName(p, ExtendsOurs)
    check not ownsEphemeralName(p, OtherInstance)
    check not ownsEphemeralName(p, p)
    check not ownsEphemeralName(p, p & "-1789-")
    check not ownsEphemeralName(p, p & "-abc-12")
    check not ownsEphemeralName("", OwnStale)
    # The bare default prefix owns its own clones, but no per-instance one.
    check ownsEphemeralName("repro-vm-tart-linux", DefaultPrefixed)
    check not ownsEphemeralName("repro-vm-tart-linux", OtherInstance)
    check not ownsEphemeralName("repro-vm-tart-linux", OwnStale)

  test "the per-instance prefix is the backend prefix plus the baseline":
    check instanceEphemeralPrefix("repro-vm-tart-linux", "garm-mine") ==
          "repro-vm-tart-linux-garm-mine"
    # A baseline is caller-supplied; it never smuggles a path into a VM name.
    check instanceEphemeralPrefix("p", "../x y") == "p-___x_y"
    check instanceEphemeralPrefix("p", "") == "p-_"

suite "run --ephemeral reaps only its own instance's clones (tart)":
  proc setup(): (string, TartBackend) =
    let dir = createTempDir("gosti-reap-scope-", "")
    writeFile(dir / "vms.txt", [OtherInstance, DefaultPrefixed, ExtendsOurs,
                                OwnStale, OwnStaleSnap].join("\n"))
    let tartCmd = selfFixture(dir, "tart-reap")
    let ssh = selfFixture(dir, "ssh-reap")
    let sshpass = commandFixture(dir / "sshpass", %*{"forwardSkip": 2})
    # The registry's construction: the backend default prefix, no override.
    let b = newTartBackend(guestOs = goLinux, tartCmd = tartCmd,
      sshpassCmd = sshpass, sshCmd = ssh, bootTimeoutSec = 5,
      sshReadyTimeoutSec = 10, useDefaultGolden = false)
    check b.ephemeralPrefix == DefaultEphemeralPrefixLinuxArm
    (dir, b)

  test "no --ephemeral-prefix: other instances survive, own stale is reaped":
    let (dir, b) = setup()
    defer: removeDir(dir)
    let opts = runOpts()
    let spec = vmRunEphemeralSpec(opts, b, "ghcr.io/example/g:1")
    check spec.backendOptions["ephemeralPrefix"] ==
          "repro-vm-tart-linux-garm-mine"
    b.provisionBaseline(spec)
    let vm = b.revertToBaseline(opts.baseline)
    let calls = logLines(dir / "tart.log")
    for foreign in [OtherInstance, DefaultPrefixed, ExtendsOurs]:
      checkpoint foreign
      check not calls.touched("stop", foreign)
      check not calls.touched("delete", foreign)
    for own in [OwnStale, OwnStaleSnap]:
      checkpoint own
      check calls.touched("stop", own)
      check calls.touched("delete", own)
    check ownsEphemeralName("repro-vm-tart-linux-garm-mine", vm.name)
    check calls.touched("clone", vm.name)

  test "an explicit --ephemeral-prefix is used as given":
    let (dir, b) = setup()
    defer: removeDir(dir)
    let opts = runOpts(@["--ephemeral-prefix", "repro-vm-tart-linux-garm-mine"])
    let spec = vmRunEphemeralSpec(opts, b, "ghcr.io/example/g:1")
    check spec.backendOptions["ephemeralPrefix"] ==
          "repro-vm-tart-linux-garm-mine"
    let custom = vmRunEphemeralSpec(
      runOpts(@["--ephemeral-prefix", "proj-x"]), b, "ghcr.io/example/g:1")
    check custom.backendOptions["ephemeralPrefix"] == "proj-x"
    b.provisionBaseline(spec)
    let calls = logLines(dir / "tart.log")
    # The exact-shape rule holds for an explicit prefix too: `garm-mine2`
    # merely extends it and is another instance's guest.
    for foreign in [OtherInstance, ExtendsOurs]:
      checkpoint foreign
      check not calls.touched("stop", foreign)
      check not calls.touched("delete", foreign)
    check calls.touched("delete", OwnStale)

suite "run --ephemeral reaps only its own instance's clones (utm)":
  test "utm honours the scoped prefix and the ownership rule":
    let dir = createTempDir("gosti-reap-scope-utm-", "")
    defer: removeDir(dir)
    let other = "repro-vm-utm-windows-garm-other-1789000000000-4242"
    let own = "repro-vm-utm-windows-garm-mine-1789000000003-4245"
    let extends = "repro-vm-utm-windows-garm-mine2-1789000000002-4244"
    writeFile(dir / "vms.txt", [other, own, extends].join("\n"))
    let b = newUtmBackend(utmctlCmd = selfFixture(dir, "utmctl-reap"))
    var opts = runOpts()
    opts.backend = "utm-windows-arm"
    let spec = vmRunEphemeralSpec(opts, b, "golden-bundle")
    check spec.backendOptions["ephemeralPrefix"] ==
          "repro-vm-utm-windows-garm-mine"
    b.provisionBaseline(spec)
    check b.ephemeralPrefix == "repro-vm-utm-windows-garm-mine"
    let calls = logLines(dir / "utmctl.log")
    # utmctl addresses VMs by uuid: row 1 is `other`, row 2 is `own`,
    # row 3 is `extends`.
    let otherUuid = "00000000-0000-0000-0000-000000000001"
    let ownUuid = "00000000-0000-0000-0000-000000000002"
    let extendsUuid = "00000000-0000-0000-0000-000000000003"
    for foreign in [otherUuid, extendsUuid]:
      checkpoint foreign
      check not calls.touched("stop", foreign)
      check not calls.touched("delete", foreign)
    check calls.touched("stop", ownUuid)
    check calls.touched("delete", ownUuid)
