# SPDX-FileCopyrightText: 2026 Metacraft Labs / Schelling Point Labs
# SPDX-License-Identifier: Apache-2.0
## `run --detach-script`: the guest script is launched detached and followed
## through SHORT, independent probe sessions, so a stalled SSH connection no
## longer takes the runner down.
##
## THE DEFECT THIS PINS. The per-host GARM's local provider ran the runner
## bootstrap in the foreground of ONE SSH session for the job's whole life. On
## m3 a macOS job in "Setup Nix" lost that session ("Read from remote host
## 192.168.64.6: Operation timed out"); sshd's hangup took the runner with it,
## the run's cleanup deleted the guest, and GitHub reported "lost communication
## with the server" ten minutes later.
##
## TEST DOUBLE, AND WHY. `LocalShellBackend` overrides only `execInGuest`, and
## runs each argv as a REAL local process — real shells, real background jobs,
## real pid/exit files. The one thing it fakes is an SSH outage: while
## `outageProbes > 0`, a call returns what ssh returns when it cannot reach the
## guest (exit 255, no output) without running anything. Reproducing a real
## mid-connection stall needs a guest and a network to break, which is the
## host tier's job; what is checkable here — and what this change decides — is
## how the follower treats such a failure.

import std/[os, osproc, posix, strutils, tables, tempfiles, unittest]
import vm_harness/types
import vm_harness/detached_bootstrap

proc runCleanSession(cmd: seq[string]): (string, int) =
  ## Run argv with only stdio inherited, as sshd starts a session. Not
  ## `execCmdEx`: on macOS osproc's capture-pipe ends are inheritable, so a
  ## backgrounded child would hold the pipe and the launch would appear to
  ## block for the script's whole life.
  var fds: array[2, cint]
  doAssert posix.pipe(fds) == 0
  let pid = posix.fork()
  if pid == 0:
    discard posix.dup2(fds[1], 1)
    discard posix.dup2(fds[1], 2)
    discard posix.dup2(posix.open("/dev/null", O_RDONLY), 0)
    for fd in 3.cint .. 1023.cint:
      discard posix.close(fd)
    var cargs = allocCStringArray(cmd)
    discard posix.execv(cmd[0].cstring, cargs)
    posix.exitnow(127)
  discard posix.close(fds[1])
  var output = ""
  var buf: array[4096, char]
  while true:
    let n = posix.read(fds[0], addr buf[0], buf.len)
    if n <= 0: break
    for i in 0 ..< n: output.add(buf[i])
  discard posix.close(fds[0])
  var status: cint
  discard posix.waitpid(pid, status, 0)
  (output, int(WEXITSTATUS(status)))

type LocalShellBackend = ref object of VmBackend
  outageProbes: int
  probes: int

method execInGuest*(b: LocalShellBackend, vm: VmHandle,
                    env: Table[string, string], cmd: seq[string],
                    stdin: string = "", timeoutSec: int = 600): ExecResult =
  let isProbe = cmd.len >= 3 and "kill -0" in cmd[2]
  if isProbe:
    inc b.probes
    if b.outageProbes > 0:
      dec b.outageProbes
      return ExecResult(exitCode: 255, stdout: "", stderr: "")
  let (output, code) = runCleanSession(cmd)
  ExecResult(exitCode: code, stdout: output, stderr: "")

proc scriptWith(body: string): (string, string) =
  let dir = createTempDir("vmh-detach-script-", "-test")
  let path = dir / "garm-bootstrap.sh"
  writeFile(path, "#!/bin/sh\n" & body & "\n")
  (dir, path)

suite "classifying a status probe":
  test "sentinels decide; a bare SSH failure is unreachable, not failed":
    check classifyBootstrapStatus(ExecResult(exitCode: 0,
      stdout: BootstrapRunning & "\n")).state == dsRunning
    let ok = classifyBootstrapStatus(ExecResult(exitCode: 0,
      stdout: BootstrapExitedOk & "\n"))
    check ok.state == dsExited
    check ok.exitCode == 0
    let bad = classifyBootstrapStatus(ExecResult(exitCode: 1,
      stdout: BootstrapFailedPrefix & "42\nlog tail\n"))
    check bad.state == dsExited
    check bad.exitCode == 42
    check classifyBootstrapStatus(ExecResult(exitCode: 1,
      stdout: "bootstrap: not running\n")).state == dsVanished
    # What ssh produces when the guest is unreachable: exit 255, no sentinel.
    check classifyBootstrapStatus(ExecResult(exitCode: 255)).state == dsUnreachable
    check classifyBootstrapStatus(ExecResult(exitCode: -1,
      stderr: "vm-harness: process timed out after 60s")).state == dsUnreachable

suite "following a detached script":
  let vm = VmHandle(name: "local", extra: initTable[string, string]())

  test "the script's own exit status is the result":
    for (body, want) in [("sleep 2; exit 0", 0), ("sleep 1; exit 7", 7)]:
      let (dir, path) = scriptWith(body)
      let b = LocalShellBackend()
      let r = runDetachedScript(b, vm, goMacos, path, timeoutSec = 60,
                                pollSec = 1, unreachableGraceSec = 10)
      checkpoint body & " -> " & $r.exitCode & " " & r.stdout & r.stderr
      check r.exitCode == want
      removeDir(dir)

  test "a transient SSH outage does not end the job":
    # THE REGRESSION: in the foreground model the first failed session WAS the
    # end of the runner. Here three probes in a row fail and the script still
    # runs to its own conclusion.
    let (dir, path) = scriptWith("sleep 6; exit 0")
    let b = LocalShellBackend(outageProbes: 3)
    let r = runDetachedScript(b, vm, goMacos, path, timeoutSec = 60,
                              pollSec = 1, unreachableGraceSec = 30)
    check r.exitCode == 0
    check b.probes > 3
    removeDir(dir)

  test "a guest unreachable past the grace window ends the run":
    let (dir, path) = scriptWith("sleep 30")
    let b = LocalShellBackend(outageProbes: 1000)
    let r = runDetachedScript(b, vm, goLinux, path, timeoutSec = 60,
                              pollSec = 1, unreachableGraceSec = 3)
    check r.exitCode == 255
    check "unreachable" in r.stderr
    let pid = readFile(path & ".pid").strip()
    discard execCmd("pkill -P " & pid & " >/dev/null 2>&1; kill " & pid &
                    " >/dev/null 2>&1")
    removeDir(dir)

  test "Windows guests are refused, not silently run in the foreground":
    expect ValueError:
      discard runDetachedScript(LocalShellBackend(), vm, goWindows,
                                "C:\\garm-bootstrap.ps1", timeoutSec = 10)
