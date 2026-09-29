# SPDX-FileCopyrightText: 2026 Metacraft Labs / Schelling Point Labs
# SPDX-License-Identifier: Apache-2.0
## Mock justification: the child implements swtpm's startup boundary without
## emulating TPM commands. Delayed readiness and a permanently unready helper
## cannot be requested from real swtpm. Processes, Unix sockets, termination
## and reaping are real; guest TPM commands remain in the existing host tests.

import std/[monotimes, net, os, posix, strutils, tempfiles, times, unittest]
import vm_harness

if paramCount() > 0 and paramStr(1) == "socket":
  writeFile("helper.pid", $getCurrentProcessId())
  let delay = parseInt(readFile("delay-ms"))
  if delay < 0:
    quit(23)
  sleep(delay)
  var path = ""
  for arg in commandLineParams():
    if arg.startsWith("type=unixio,path="):
      path = arg["type=unixio,path=".len .. ^1]
  writeFile("helper.socket", path)
  var listener = newSocket(net.AF_UNIX, net.SOCK_STREAM, net.IPPROTO_IP)
  listener.bindUnix(path)
  listener.listen()
  sleep(60_000)
  quit(0)

proc stopFixture(pid: int) =
  if pid > 0:
    discard posix.kill(Pid(pid), SIGKILL)
    var status: cint
    discard posix.waitpid(Pid(pid), status, 0)
    forgetChildExit(pid)

suite "QEMU Windows ARM swtpm startup":
  test "a live helper can become ready after the former three-second bound":
    let root = createTempDir("gosti-tpm-delay-", "")
    defer: removeDir(root)
    writeFile(root / "delay-ms", "3500")
    let backend = newQemuWindowsArmBackend(swtpmCmd = getAppFilename())
    var pid = 0
    defer:
      if fileExists(root / "helper.pid"):
        stopFixture(parseInt(readFile(root / "helper.pid")))
      if fileExists(root / "helper.socket"):
        removeFile(readFile(root / "helper.socket"))
    pid = backend.startSwtpmInBackground(root)
    check pid == parseInt(readFile(root / "helper.pid"))
    check pidAlive(pid)
    # A connect proves the file is a listening Unix socket.
    var client = newSocket(net.AF_UNIX, net.SOCK_STREAM, net.IPPROTO_IP)
    defer: client.close()
    client.connectUnix(readFile(root / "helper.socket"))

  test "an unready helper is terminated and reaped before the error returns":
    let root = createTempDir("gosti-tpm-timeout-", "")
    defer: removeDir(root)
    writeFile(root / "delay-ms", "60000")
    let backend = newQemuWindowsArmBackend(swtpmCmd = getAppFilename())
    defer:
      if fileExists(root / "helper.pid"):
        stopFixture(parseInt(readFile(root / "helper.pid")))
    expect VmHarnessError:
      discard backend.startSwtpmInBackground(root, timeoutMs = 10_000)
    require fileExists(root / "helper.pid")
    let pid = parseInt(readFile(root / "helper.pid"))
    check not pidAlive(pid)
    var status: cint
    check posix.waitpid(Pid(pid), status, WNOHANG) == Pid(-1)

  test "an exited helper fails promptly without waiting for the deadline":
    let root = createTempDir("gosti-tpm-exit-", "")
    defer: removeDir(root)
    writeFile(root / "delay-ms", "-1")
    let backend = newQemuWindowsArmBackend(swtpmCmd = getAppFilename())
    let started = getMonoTime()
    var message = ""
    try:
      discard backend.startSwtpmInBackground(root)
    except VmHarnessError as e:
      message = e.msg
    check "exited before creating socket" in message
    check (getMonoTime() - started).inSeconds < 20
