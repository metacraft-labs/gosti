# SPDX-FileCopyrightText: 2026 Metacraft Labs / Schelling Point Labs
# SPDX-License-Identifier: Apache-2.0
## t_crud_store — the crud store's building blocks (design doc §8.6).
##
##   * where the store lives (the configured-location precedence chain);
##   * which logical names are valid keys (rejected, never sanitized);
##   * record round-trip, sorted listing, and that store internals (the
##     mock's ``.fleet.json``) are never listed as VMs;
##   * the per-name lock: exclusive, times out as ``CrudBusyError``, and a
##     lock left by a dead process is broken;
##   * each real backend's ``instancePresence`` DECISION: "gone" only on a
##     successful answer that lacks the instance; a failed probe is
##     ``ipUnknown`` — never read as absence.
##
## Mock policy: none. The store runs against a real temp directory; the
## presence decisions are pure functions over the exact CLI output shapes.

import std/[json, options, os, osproc, strutils, tempfiles, unittest]
import vm_harness/[types, crud_store]
import vm_harness/backends/[incus, libvirt, tart, hyperv]

proc withEnv(pairs: openArray[(string, string)], body: proc()) =
  var saved: seq[(string, string, bool)]
  for (k, v) in pairs:
    saved.add((k, getEnv(k), existsEnv(k)))
    if v.len > 0: putEnv(k, v) else: delEnv(k)
  try:
    body()
  finally:
    for (k, v, had) in saved:
      if had: putEnv(k, v) else: delEnv(k)

suite "crud store location":
  test "--state-dir wins, then the configured chain":
    withEnv([("VMH_CRUD_STATE_DIR", "/x/crud-explicit"),
             ("VMH_EPHEMERAL_STATE_DIR", "/x/eph"),
             ("STATE_DIRECTORY", "/x/sd"), ("XDG_STATE_HOME", "/x/xdg")]) do:
      check crudStateRoot("/x/flag") == "/x/flag/crud"
      check crudStateRoot() == "/x/crud-explicit"
    withEnv([("VMH_CRUD_STATE_DIR", ""), ("VMH_EPHEMERAL_STATE_DIR", "/x/eph"),
             ("STATE_DIRECTORY", "/x/sd"), ("XDG_STATE_HOME", "/x/xdg")]) do:
      check crudStateRoot() == "/x/eph/crud"
    withEnv([("VMH_CRUD_STATE_DIR", ""), ("VMH_EPHEMERAL_STATE_DIR", ""),
             ("STATE_DIRECTORY", "/x/sd:/x/other"),
             ("XDG_STATE_HOME", "/x/xdg")]) do:
      check crudStateRoot() == "/x/sd/crud"
    when not defined(windows):
      withEnv([("VMH_CRUD_STATE_DIR", ""), ("VMH_EPHEMERAL_STATE_DIR", ""),
               ("STATE_DIRECTORY", ""), ("XDG_STATE_HOME", "/x/xdg")]) do:
        check crudStateRoot() == "/x/xdg/vm-harness/crud"

suite "crud store names":
  test "valid names are accepted":
    for n in ["vm1", "A", "a.b-c_d", "0" & "x".repeat(63)]:
      validateCrudName(n)
  test "invalid names are rejected, not sanitized":
    for n in ["", ".hidden", "-x", "../x", "a/b", "a b", "x".repeat(65),
              "é"]:
      expect CrudNameError:
        validateCrudName(n)

suite "crud store records":
  test "save / load / list / remove round-trip; internals are not listed":
    let root = createTempDir("vmh-crud-store-", "")
    defer: removeDir(root)
    let store = newCrudStore(root / "crud")
    check store.list("mock").len == 0          # missing dir ⇒ none yet
    check store.load("mock", "vm1").isNone
    store.save(CrudStoredVm(name: "vm2", backend: "mock", baseline: "b",
                            state: "stopped", handle: none(JsonNode)))
    store.save(CrudStoredVm(name: "vm1", backend: "mock", baseline: "b",
                            state: "running",
                            handle: some(%*{"name": "mock-vm-b"})))
    writeFile(store.mockFleetPath(), "{}")
    let all = store.list("mock")
    check all.len == 2
    check all[0].name == "vm1" and all[1].name == "vm2"
    let one = store.load("mock", "vm1").get()
    check one.state == "running"
    check one.handle.get(){"name"}.getStr == "mock-vm-b"
    check store.list("libvirt").len == 0        # per-backend namespaces
    store.remove("mock", "vm1")
    check store.load("mock", "vm1").isNone

  test "an unparsable record raises instead of reading as absent":
    let root = createTempDir("vmh-crud-store-bad-", "")
    defer: removeDir(root)
    let store = newCrudStore(root / "crud")
    createDir(store.backendDir("mock"))
    writeFile(store.recordPath("mock", "vm1"), "{not json")
    expect CatchableError:
      discard store.load("mock", "vm1")
    expect CatchableError:
      discard store.list("mock")

suite "crud store locks":
  test "exclusive; a held lock times out as CrudBusyError":
    let root = createTempDir("vmh-crud-lock-", "")
    defer: removeDir(root)
    let store = newCrudStore(root / "crud")
    var a = store.lockVm("mock", "vm1", 1)
    expect CrudBusyError:
      discard store.lockVm("mock", "vm1", 0)
    var other = store.lockVm("mock", "vm2", 0)   # other names are independent
    release(other)
    release(a)
    var again = store.lockVm("mock", "vm1", 0)
    release(again)

  when defined(posix):
    test "a lock whose owner process is dead is broken":
      let root = createTempDir("vmh-crud-stale-", "")
      defer: removeDir(root)
      let store = newCrudStore(root / "crud")
      # A pid that certainly exited: a finished child.
      let p = startProcess("/bin/sh", args = ["-c", "exit 0"])
      let deadPid = p.processID
      discard p.waitForExit()
      p.close()
      let lockDir = store.backendDir("mock") / "vm1.lock"
      createDir(lockDir)
      writeFile(lockDir / "owner", $deadPid & " 0")
      var l = store.lockVm("mock", "vm1", 0)
      check readFile(lockDir / "owner").startsWith($getCurrentProcessId())
      release(l)

suite "instancePresence decisions (per backend)":
  test "incus: exact-name row, failure is unknown":
    check incusPresenceFrom(0, "vm1,RUNNING\nvm10,STOPPED\n", "vm1") == ipRunning
    check incusPresenceFrom(0, "vm1,FROZEN\n", "vm1") == ipRunning
    check incusPresenceFrom(0, "vm10,RUNNING\n", "vm1") == ipGone
    check incusPresenceFrom(0, "vm1,STOPPED\n", "vm1") == ipStopped
    check incusPresenceFrom(0, "", "vm1") == ipGone
    check incusPresenceFrom(1, "", "vm1") == ipUnknown
    check incusPresenceFrom(0, "garbage-without-comma\n", "vm1") == ipUnknown

  test "libvirt: listing decides existence, domstate decides running":
    check libvirtPresenceFrom(true, @["d1"], "running", "d1") == ipRunning
    check libvirtPresenceFrom(true, @["d1"], "paused", "d1") == ipRunning
    check libvirtPresenceFrom(true, @["d1"], "shut off", "d1") == ipStopped
    check libvirtPresenceFrom(true, @["d2"], "", "d1") == ipGone
    check libvirtPresenceFrom(false, @[], "", "d1") == ipUnknown
    check libvirtPresenceFrom(true, @["d1"], "", "d1") == ipUnknown

  test "tart: row lookup, unreadable listing is unknown":
    let rows = some(@[TartVmListing(name: "t1", state: "running"),
                      TartVmListing(name: "t2", state: "stopped")])
    check tartPresenceFrom(rows, "t1") == ipRunning
    check tartPresenceFrom(rows, "t2") == ipStopped
    check tartPresenceFrom(rows, "t3") == ipGone
    check tartPresenceFrom(none(seq[TartVmListing]), "t1") == ipUnknown

  test "hyperv: marker means gone, failure is unknown":
    check hypervPresenceFrom(0, "Running\r\n") == ipRunning
    check hypervPresenceFrom(0, "Off\r\n") == ipStopped
    check hypervPresenceFrom(0, HyperVGoneMarker & "\r\n") == ipGone
    check hypervPresenceFrom(1, "") == ipUnknown
    check hypervPresenceFrom(0, "") == ipUnknown
    # The name is single-quote-escaped into the script.
    check "'o''brien'" in buildPresenceCommand("o'brien")
