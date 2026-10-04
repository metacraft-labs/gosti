# SPDX-FileCopyrightText: 2026 Metacraft Labs / Schelling Point Labs
# SPDX-License-Identifier: Apache-2.0
#
# The Incus create path's timeouts are operator-tunable (with load-tolerant
# defaults) and creates of one base image can be capped host-wide. On a
# loaded host the old fixed 120/30/60 s timeouts killed creates that would
# have succeeded, and every retry added incusd load (2026-10-01).

## No mocks: the shared slot controls use real files and a separate native
## child. The OS must release its lock when that child terminates.
import std/[os, osproc, streams, tempfiles, unittest]
import vm_harness/backends/incus

if commandLineParams() == @["--hold-create-slot"]:
  let fd = acquireCreateSlot("child", 1, 1)
  doAssert fd >= 0
  echo "held"
  stdout.flushFile()
  discard stdin.readLine()
  quit(0) # deliberately leave the descriptor open: the OS releases it.

proc withEnv(name, value: string, body: proc ()) =
  let previous = getEnv(name)
  let had = existsEnv(name)
  putEnv(name, value)
  try: body()
  finally:
    if had: putEnv(name, previous) else: delEnv(name)

suite "Incus create tuning":
  test "defaults are load-tolerant":
    for n in ["VMH_INCUS_INIT_TIMEOUT_SEC", "VMH_INCUS_CONFIG_TIMEOUT_SEC",
              "VMH_INCUS_START_TIMEOUT_SEC", "VMH_INCUS_CREATE_CONCURRENCY"]:
      delEnv(n)
    check incusInitTimeoutSec() == 600
    check incusConfigTimeoutSec() == 120
    check incusStartTimeoutSec() == 300
    check incusCreateConcurrency() == 0

  test "positive overrides apply; junk and non-positive fall back":
    withEnv("VMH_INCUS_INIT_TIMEOUT_SEC", "900", proc () =
      check incusInitTimeoutSec() == 900)
    withEnv("VMH_INCUS_INIT_TIMEOUT_SEC", "0", proc () =
      check incusInitTimeoutSec() == DefaultIncusInitTimeoutSec)
    withEnv("VMH_INCUS_CONFIG_TIMEOUT_SEC", "abc", proc () =
      check incusConfigTimeoutSec() == DefaultIncusConfigTimeoutSec)
    withEnv("VMH_INCUS_CREATE_CONCURRENCY", " 2 ", proc () =
      check incusCreateConcurrency() == 2)

  test "unlimited concurrency takes no slot":
    check acquireCreateSlot("img", 0, 1) == -1

  test "slots are exclusive and released on close":
    let dir = getTempDir() / ("vmh-create-slots-" & $getCurrentProcessId())
    createDir(dir)
    putEnv("VMH_INCUS_CREATE_LOCK_DIR", dir)
    defer:
      delEnv("VMH_INCUS_CREATE_LOCK_DIR")
      removeDir(dir)
    let base = "t-incus-create-tuning-" & $getCurrentProcessId()
    let a = acquireCreateSlot(base, 2, 1)
    let b = acquireCreateSlot(base, 2, 1)
    check a >= 0
    check b >= 0
    # Both slots held: a third waits out its 1 s budget and proceeds
    # unthrottled (-1) rather than failing the create.
    check acquireCreateSlot(base, 2, 1) == -1
    releaseCreateSlot(a)
    let c = acquireCreateSlot(base, 2, 1)
    check c >= 0
    releaseCreateSlot(b)
    releaseCreateSlot(c)

  test "a child holds a host-wide slot until process exit":
    let dir = createTempDir("vmh-create-child-", "")
    defer: removeDir(dir)
    withEnv("VMH_INCUS_CREATE_LOCK_DIR", dir, proc () =
      let child = startProcess(getAppFilename(), args = @["--hold-create-slot"],
        options = {poStdErrToStdOut})
      defer:
        if child.running:
          child.terminate()
          discard child.waitForExit()
        child.close()
      require child.outputStream.readLine() == "held"
      check acquireCreateSlot("child", 1, 1) == -1
      child.inputStream.writeLine("exit")
      child.inputStream.flush()
      require child.waitForExit(5000) == 0
      let recovered = acquireCreateSlot("child", 1, 1)
      check recovered >= 0
      releaseCreateSlot(recovered))

  test "the lock dir defaults to a writable location, not /run/lock":
    delEnv("VMH_INCUS_CREATE_LOCK_DIR")
    let saved = getEnv("RUNTIME_DIRECTORY")
    putEnv("RUNTIME_DIRECTORY", "/run/vm-harness-serve")
    check incusCreateLockDir() == "/run/vm-harness-serve"
    delEnv("RUNTIME_DIRECTORY")
    check incusCreateLockDir() == getTempDir()
    if saved.len > 0: putEnv("RUNTIME_DIRECTORY", saved)
