# SPDX-FileCopyrightText: 2026 Metacraft Labs / Schelling Point Labs
# SPDX-License-Identifier: Apache-2.0
## Deterministic Incus capability lifecycle contract.
##
## A real subprocess shim records the exact Incus argv. This is deliberately
## not a fake backend: it drives IncusBackend's real process boundary and tests
## the host command contract without requiring an Incus daemon in universal CI.

import std/[os, strutils, tables, tempfiles, unittest]
import vm_harness

proc writeIncusShim(path, logPath: string; failExact = "";
                    statMode = "666"; rejectReady = false) =
  var body =
    "#!/bin/sh\n" &
    "printf '%s\\n' \"$*\" >> '" & logPath & "'\n"
  if failExact.len > 0:
    body.add("if [ \"$*\" = '" & failExact & "' ]; then exit 17; fi\n")
  if rejectReady:
    body.add("case \"$*\" in 'exec '*' -- true') exit 18 ;; esac\n")
  body.add(
    "case \"$*\" in\n" &
    "  info\\ *) exit 1 ;;\n" &
    "  exec\\ *\\ --\\ stat\\ -c\\ %a\\ /dev/kvm) printf '" &
      statMode & "\\n' ;;\n" &
    "esac\n")
  writeFile(path, body)
  setFilePermissions(path, {fpUserRead, fpUserWrite, fpUserExec})

proc lineIndex(lines: seq[string], wanted: string): int =
  for i, line in lines:
    if line == wanted:
      return i
  -1

suite "Incus ephemeral operator capabilities":
  test "defaults preserve the original launch argv byte-for-byte":
    let work = createTempDir("vmh-incus-default", "")
    defer: removeDir(work)
    let logPath = work / "argv.log"
    let shim = work / "incus"
    writeIncusShim(shim, logPath)
    let b = newIncusBackend(incusCmd = @[shim], baseImage = "vmh-base")

    discard b.provisionEphemeralClone(EphemeralIncusSpec(name: "plain"))
    let lines = readFile(logPath).strip().splitLines()
    check lines == @["info plain", "launch vmh-base plain"]
    check lines.join("\n").find("security.nesting") < 0
    check lines.join("\n").find("/dev/kvm") < 0

  test "default launch keeps legacy option ordering; user-data never reaches incus config":
    let work = createTempDir("vmh-incus-default-options", "")
    defer: removeDir(work)
    let logPath = work / "argv.log"
    let shim = work / "incus"
    writeIncusShim(shim, logPath)
    let b = newIncusBackend(incusCmd = @[shim], baseImage = "vmh-base")

    discard b.provisionEphemeralClone(EphemeralIncusSpec(
      name: "plain-options",
      ephemeral: true,
      profiles: @["runner", "network"],
      userData: "cloud-payload"))
    let lines = readFile(logPath).strip().splitLines()
    # The bootstrap payload is NOT written to ``cloud-init.user-data``: on
    # incus the golden's cloud-init never sees its datasource, so the payload
    # is delivered over ``incus exec`` instead (``injectAndRunBootstrap``),
    # which also keeps the registration token out of ``incus config show``.
    check lines == @[
      "info plain-options",
      "launch vmh-base plain-options --ephemeral --profile runner " &
        "--profile network",
    ]
    check lines.join("\n").find("cloud-init.user-data") < 0
    check lines.join("\n").find("cloud-payload") < 0
    check lines.join("\n").find("security.nesting") < 0
    check lines.join("\n").find("/dev/kvm") < 0

  test "nesting and KVM are configured in fixed order before first start":
    let work = createTempDir("vmh-incus-capabilities", "")
    defer: removeDir(work)
    let logPath = work / "argv.log"
    let shim = work / "incus"
    writeIncusShim(shim, logPath)
    let b = newIncusBackend(incusCmd = @[shim], baseImage = "runner-base")

    discard b.provisionEphemeralClone(EphemeralIncusSpec(
      name: "nested", securityNesting: true, nestedKvm: true))
    let lines = readFile(logPath).strip().splitLines()
    let initPos = lines.lineIndex("init runner-base nested")
    let nestingPos = lines.lineIndex(
      "config set nested security.nesting true")
    let mknodPos = lines.lineIndex(
      "config set nested security.syscalls.intercept.mknod true")
    let setxattrPos = lines.lineIndex(
      "config set nested security.syscalls.intercept.setxattr true")
    let devicePos = lines.lineIndex(
      "config device add nested kvm unix-char source=/dev/kvm " &
      "path=/dev/kvm mode=0666")
    let startPos = lines.lineIndex("start nested")
    let chmodPos = lines.lineIndex("exec nested -- chmod 0666 /dev/kvm")
    let verifyPos = lines.lineIndex("exec nested -- stat -c %a /dev/kvm")
    let openPos = lines.lineIndex("exec nested -- sh -c exec 3<>/dev/kvm")
    check initPos >= 0
    check initPos < nestingPos
    check nestingPos < mknodPos
    check mknodPos < setxattrPos
    check setxattrPos < devicePos
    check devicePos < startPos
    check startPos < chmodPos
    check chmodPos < verifyPos
    check verifyPos < openPos
    check lines.join("\n").find("launch runner-base nested") < 0

  test "resource limits are applied before first start alongside nesting":
    let work = createTempDir("vmh-incus-limits", "")
    defer: removeDir(work)
    let logPath = work / "argv.log"
    let shim = work / "incus"
    writeIncusShim(shim, logPath)
    let b = newIncusBackend(incusCmd = @[shim], baseImage = "runner-base")

    discard b.provisionEphemeralClone(EphemeralIncusSpec(
      name: "capped",
      config: incusEphemeralLimits(6, 16384),
      securityNesting: true))
    let lines = readFile(logPath).strip().splitLines()
    let initPos = lines.lineIndex("init runner-base capped")
    let cpuPos = lines.lineIndex("config set capped limits.cpu 6")
    let memPos = lines.lineIndex("config set capped limits.memory 16384MiB")
    let nestingPos = lines.lineIndex("config set capped security.nesting true")
    let startPos = lines.lineIndex("start capped")
    check initPos >= 0
    check cpuPos > initPos
    check memPos > initPos
    check nestingPos > initPos
    check cpuPos < startPos
    check memPos < startPos
    check nestingPos < startPos
    check lines.join("\n").find("launch runner-base capped") < 0

  test "resource limits alone take the pre-start path without capabilities":
    let work = createTempDir("vmh-incus-limits-only", "")
    defer: removeDir(work)
    let logPath = work / "argv.log"
    let shim = work / "incus"
    writeIncusShim(shim, logPath)
    let b = newIncusBackend(incusCmd = @[shim], baseImage = "runner-base")

    discard b.provisionEphemeralClone(EphemeralIncusSpec(
      name: "cpu-only", config: incusEphemeralLimits(4, 0)))
    let lines = readFile(logPath).strip().splitLines()
    check lines == @[
      "info cpu-only",
      "init runner-base cpu-only",
      "config set cpu-only limits.cpu 4",
      "start cpu-only",
    ]

  test "nested KVM alone implies nesting without Docker intercepts":
    let work = createTempDir("vmh-incus-kvm-only", "")
    defer: removeDir(work)
    let logPath = work / "argv.log"
    let shim = work / "incus"
    writeIncusShim(shim, logPath)
    let b = newIncusBackend(incusCmd = @[shim], baseImage = "runner-base")

    discard b.provisionEphemeralClone(EphemeralIncusSpec(
      name: "kvm-only", nestedKvm: true))
    let joined = readFile(logPath)
    check "config set kvm-only security.nesting true" in joined
    check "config device add kvm-only kvm unix-char source=/dev/kvm " &
      "path=/dev/kvm mode=0666" in joined
    check "security.syscalls.intercept.mknod" notin joined
    check "security.syscalls.intercept.setxattr" notin joined

  test "fixed capability policy overrides conflicting raw config before start":
    let work = createTempDir("vmh-incus-fixed-policy", "")
    defer: removeDir(work)
    let logPath = work / "argv.log"
    let shim = work / "incus"
    writeIncusShim(shim, logPath)
    let b = newIncusBackend(incusCmd = @[shim], baseImage = "runner-base")
    var rawConfig = initTable[string, string]()
    rawConfig["security.nesting"] = "false"

    discard b.provisionEphemeralClone(EphemeralIncusSpec(
      name: "fixed-policy",
      config: rawConfig,
      securityNesting: true,
      nestedKvm: true))
    let lines = readFile(logPath).strip().splitLines()
    let callerValue = lines.lineIndex(
      "config set fixed-policy security.nesting false")
    let fixedValue = lines.lineIndex(
      "config set fixed-policy security.nesting true")
    let startPos = lines.lineIndex("start fixed-policy")
    check callerValue >= 0
    check callerValue < fixedValue
    check fixedValue < startPos

  test "device-attachment failure cleans up and never starts the guest":
    let work = createTempDir("vmh-incus-device-fail", "")
    defer: removeDir(work)
    let logPath = work / "argv.log"
    let shim = work / "incus"
    let failing = "config device add no-device kvm unix-char " &
      "source=/dev/kvm path=/dev/kvm mode=0666"
    writeIncusShim(shim, logPath, failExact = failing)
    let b = newIncusBackend(incusCmd = @[shim], baseImage = "runner-base")

    expect VmHarnessError:
      discard b.provisionEphemeralClone(EphemeralIncusSpec(
        name: "no-device", nestedKvm: true))
    let lines = readFile(logPath).strip().splitLines()
    check failing in lines
    check "start no-device" notin lines
    check lines[^1] == "delete --force no-device"

  test "post-start access failure cleans up the started container":
    let work = createTempDir("vmh-incus-access-fail", "")
    defer: removeDir(work)
    let logPath = work / "argv.log"
    let shim = work / "incus"
    let failing = "exec inaccessible -- stat -c %a /dev/kvm"
    writeIncusShim(shim, logPath, failExact = failing)
    let b = newIncusBackend(incusCmd = @[shim], baseImage = "runner-base")

    expect VmHarnessError:
      discard b.provisionEphemeralClone(EphemeralIncusSpec(
        name: "inaccessible", nestedKvm: true))
    let lines = readFile(logPath).strip().splitLines()
    check "start inaccessible" in lines
    check failing in lines
    check lines[^1] == "delete --force inaccessible"

  test "every capability lifecycle command failure targets exact cleanup":
    let failures = @[
      (suffix: "init", command: "init runner-base fail-init"),
      (suffix: "raw-config", command:
        "config set fail-raw-config limits.cpu 2"),
      (suffix: "nesting", command:
        "config set fail-nesting security.nesting true"),
      (suffix: "device", command:
        "config device add fail-device kvm unix-char source=/dev/kvm " &
          "path=/dev/kvm mode=0666"),
      (suffix: "start", command: "start fail-start"),
      (suffix: "chmod", command:
        "exec fail-chmod -- chmod 0666 /dev/kvm"),
      (suffix: "stat", command:
        "exec fail-stat -- stat -c %a /dev/kvm"),
      (suffix: "open", command:
        "exec fail-open -- sh -c exec 3<>/dev/kvm"),
    ]
    for failure in failures:
      let work = createTempDir("vmh-incus-failure-" & failure.suffix, "")
      let logPath = work / "argv.log"
      let shim = work / "incus"
      writeIncusShim(shim, logPath, failExact = failure.command)
      let b = newIncusBackend(incusCmd = @[shim], baseImage = "runner-base")
      let name = "fail-" & failure.suffix
      var rawConfig = initTable[string, string]()
      if failure.suffix == "raw-config":
        rawConfig["limits.cpu"] = "2"
      var raised = false
      try:
        discard b.provisionEphemeralClone(EphemeralIncusSpec(
          name: name,
          config: rawConfig,
          securityNesting: true,
          nestedKvm: true))
      except VmHarnessError:
        raised = true
      check raised
      let lines = readFile(logPath).strip().splitLines()
      check failure.command in lines
      check lines[^1] == "delete --force " & name
      for line in lines:
        if line.startsWith("delete "):
          check line == "delete --force " & name
      removeDir(work)

  test "readiness failure and wrong numeric mode both clean exact container":
    block readinessFailure:
      let work = createTempDir("vmh-incus-readiness-failure", "")
      defer: removeDir(work)
      let logPath = work / "argv.log"
      let shim = work / "incus"
      writeIncusShim(shim, logPath, rejectReady = true)
      let b = newIncusBackend(incusCmd = @[shim], baseImage = "runner-base",
                              readyTimeoutSec = 0)
      expect VmHarnessError:
        discard b.provisionEphemeralClone(EphemeralIncusSpec(
          name: "fail-ready", nestedKvm: true))
      let lines = readFile(logPath).strip().splitLines()
      check "start fail-ready" in lines
      check lines[^1] == "delete --force fail-ready"

    block wrongMode:
      let work = createTempDir("vmh-incus-wrong-mode", "")
      defer: removeDir(work)
      let logPath = work / "argv.log"
      let shim = work / "incus"
      writeIncusShim(shim, logPath, statMode = "660")
      let b = newIncusBackend(incusCmd = @[shim], baseImage = "runner-base")
      expect VmHarnessError:
        discard b.provisionEphemeralClone(EphemeralIncusSpec(
          name: "wrong-mode", nestedKvm: true))
      let lines = readFile(logPath).strip().splitLines()
      check "exec wrong-mode -- stat -c %a /dev/kvm" in lines
      check lines[^1] == "delete --force wrong-mode"
