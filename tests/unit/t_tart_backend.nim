# SPDX-FileCopyrightText: 2026 Metacraft Labs / Schelling Point Labs
# SPDX-License-Identifier: Apache-2.0
## Tart backend command construction and SSH/SCP retry behaviour.
## Mock justification: native command stand-ins replace Tart and guest SSH,
## allowing exact argv, cleanup and retry failures without a hypervisor or
## guest. Process creation, process groups, files and exit codes remain real.
##
## Golden-image SELECTION is not here: it is the MA0 gate
## ``t_vmharness_image_is_honoured`` and lives, whole, in
## ``tests/unit/t_vmharness_image_is_honoured.nim`` so that grepping the gate
## name lands on the assertions that prove it.

import std/[json, options, os, strutils, tables, tempfiles, unittest]
import ../native_command_fixture
import vm_harness/backends/tart
import vm_harness/types

when defined(posix):
  import std/posix

suite "Tart backend commands":
  when defined(macosx):
    test "defaults to the system OpenSSH transport on macOS":
      let backend = newTartBackend(guestOs = goMacos)
      check backend.sshCmd == "/usr/bin/ssh"
      check backend.scpCmd == "/usr/bin/scp"

  when defined(posix):
    test "background Tart run remains in the provider-owned process group":
      let tmp = createTempDir("vmh-tart-unit-", "")
      defer: removeDir(tmp)
      let tart = commandFixture(tmp / "tart", %*{"sleepMs": 60000})

      let backend = newTartBackend(guestOs = goMacos, tartCmd = tart)
      let pid = backend.runTartVmInBackground("ephemeral")
      defer: discard posix.kill(Pid(pid), SIGTERM)
      sleep(100)

      check getpgid(Pid(pid)) == getpgrp()

  test "clone randomizes the ephemeral MAC before boot":
    let tmp = createTempDir("vmh-tart-unit-", "")
    defer: removeDir(tmp)
    let log = tmp / "tart.log"
    let tart = commandFixture(tmp / "tart", %*{"log": log})

    let backend = newTartBackend(guestOs = goMacos, tartCmd = tart)
    backend.cloneTartVm("golden", "ephemeral")

    check readFile(log).splitLines() == @[
      "clone golden ephemeral",
      "set ephemeral --random-mac",
      ""]

  test "failed MAC randomization deletes the unusable clone":
    let tmp = createTempDir("vmh-tart-unit-", "")
    defer: removeDir(tmp)
    let log = tmp / "tart.log"
    let tart = commandFixture(tmp / "tart", %*{"log": log,
      "failFirstArg": "set", "failureCode": 9})

    let backend = newTartBackend(guestOs = goMacos, tartCmd = tart)
    expect VmHarnessError:
      backend.cloneTartVm("golden", "ephemeral")
    check "delete ephemeral" in readFile(log)

  test "SCP retries a transient authentication failure":
    let tmp = createTempDir("vmh-tart-unit-", "")
    defer: removeDir(tmp)
    let attempts = tmp / "attempts"
    let src = tmp / "payload"
    writeFile(src, "payload")
    let sshpass = commandFixture(tmp / "sshpass", %*{"forwardSkip": 2})
    let scp = commandFixture(tmp / "scp", %*{"attempts": attempts,
      "successAfter": 2, "failureCode": 1})

    let backend = newTartBackend(
      guestOs = goMacos, scpCmd = scp, sshpassCmd = sshpass)
    backend.scpCopy("192.0.2.1", src, "/tmp/payload",
      toGuest = true, recursive = false, timeoutSec = 10)
    check readFile(attempts) == "2"

  test "guest exec retries a transient authentication failure":
    let tmp = createTempDir("vmh-tart-unit-", "")
    defer: removeDir(tmp)
    let attempts = tmp / "attempts"
    let sshpass = commandFixture(tmp / "sshpass", %*{"forwardSkip": 2})
    let ssh = commandFixture(tmp / "ssh", %*{"attempts": attempts,
      "successAfter": 2, "failureCode": 255,
      "failureOutput": "Permission denied", "output": "ready\n"})

    let backend = newTartBackend(
      guestOs = goMacos, sshCmd = ssh, sshpassCmd = sshpass)
    let vm = VmHandle(
      backend: backend,
      name: "ephemeral",
      baseline: "golden",
      ipAddress: some("192.0.2.1"))
    let result = backend.execInGuest(
      vm, initTable[string, string](), @["echo", "ready"], timeoutSec = 10)

    check result.exitCode == 0
    check "ready" in result.stdout
    check readFile(attempts) == "2"
