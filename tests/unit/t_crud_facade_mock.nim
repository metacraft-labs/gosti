## Hermetic gate for the generic-CRUD façade over the FULL deterministic
## mock backend (GOSTI2 PR-2).
##
## PR-1's gate (``t_crud_facade``) pinned the CONTRACT — the stable JSON
## envelope and the frozen exit-code table — driving every verb through the
## minimal ``NoopBackend``. This gate does the complementary job: it round-trips
## every CRUD verb through the RICH ``MockBackend`` and asserts that the
## modelled behaviour is internally consistent —
##
##   1. the lifecycle state machine (create → Running, stop → Stopped,
##      start re-materialises to Running, delete removes the instance), asserted
##      both through the CRUD JSON *and* through the backend's finer
##      Stopped→Starting→Running transition log;
##   2. snapshots persist within the session, list in creation order, and a
##      restore rolls the guest filesystem back to snapshot time (a
##      copy→snapshot→copy→restore→copy_from consistency chain);
##   3. the canned-but-consistent ``VmInfo`` / ``SshEndpoint`` / ``ExecResult``
##      data is stable and deterministic across calls.
##
## No hypervisor, no network, no subprocess: a single long-lived ``CrudSession``
## over one ``MockBackend`` supplies all state in-memory. This is the same
## in-process ``runCrud`` code path the CLI's ``crud`` subcommand reaches, and
## the substrate later hermetic tests + the future ``ah-vm`` Rust binding's
## integration tests lean on.

import std/[json, os, tables, tempfiles, unittest]
import vm_harness

proc params(name = ""): CrudParams =
  ## Bare params with only a name; individual tests fill the rest.
  CrudParams(name: name, guestOs: goLinux, guestArch: gaX86_64,
             env: initTable[string, string]())

proc assertError(r: CrudResponse, kind: CrudErrorKind) =
  check r.exitCode == exitCode(kind)
  check not r.json["ok"].getBool
  check r.json["error"]["kind"].getStr == $kind
  check r.json["error"]["code"].getInt == exitCode(kind)
  check r.json["error"]["message"].kind == JString

suite "CRUD façade over mock — canned data is stable + deterministic":
  setup:
    let backend = newMockBackend()
    let session = newCrudSession(backend)

  test "create_vm returns a well-formed VmInfo (Running) with canned ssh":
    let r = runCrud(session, "create_vm", params("vm1"))
    check r.exitCode == 0
    check r.json["ok"].getBool
    let info = r.json["data"]["vm"]
    check info["name"].getStr == "vm1"
    check info["backend"].getStr == "noop"   # MockBackend tags id biNoop
    check info["state"].getStr == "running"
    check info["baseline"].getStr == "vm1"
    let ssh = info["ssh"]
    check ssh.kind == JObject
    check ssh["host"].getStr == MockSshHost
    check ssh["port"].getInt == MockSshPort
    check ssh["user"].getStr == MockSshUser
    check ssh["auth"].getStr == "keyfile"     # mock uses a keyfile auth

  test "ssh_endpoint is identical across two calls (stable/canned)":
    discard runCrud(session, "create_vm", params("vm1"))
    let a = runCrud(session, "ssh_endpoint", params("vm1"))
    let b = runCrud(session, "ssh_endpoint", params("vm1"))
    check a.exitCode == 0
    check a.json["data"]["ssh"] == b.json["data"]["ssh"]
    check a.json["data"]["ssh"]["host"].getStr == MockSshHost
    check a.json["data"]["ssh"]["auth"].getStr == "keyfile"

  test "exec echoes a deterministic result (pure function of argv)":
    discard runCrud(session, "create_vm", params("vm1"))
    var p = params("vm1")
    p.argv = @["/bin/echo", "hi"]
    let a = runCrud(session, "exec", p)
    let b = runCrud(session, "exec", p)
    check a.exitCode == 0
    check a.json["data"]["exit_code"].getInt == 0
    check a.json["data"]["stdout"].getStr == "mock-exec: /bin/echo hi\n"
    check a.json["data"]["elapsed_ms"].getInt == MockExecElapsedMs
    # Deterministic: same inputs → byte-identical output.
    check a.json["data"] == b.json["data"]

suite "CRUD façade over mock — lifecycle state machine":
  setup:
    let backend = newMockBackend()
    let session = newCrudSession(backend)

  test "create drives Stopped → Starting → Running (finer than the JSON)":
    let r = runCrud(session, "create_vm", params("vm1"))
    check r.json["data"]["vm"]["state"].getStr == "running"
    # The backend's transition log exposes the intermediate Starting the CRUD
    # envelope (running/stopped only) cannot show.
    let inst = instanceName("vm1")
    check backend.vmState(inst) == mvsRunning
    check backend.transitionLog(inst) ==
      @[mvsStopped, mvsStarting, mvsRunning]

  test "stop → get shows Stopped + null ssh; start re-materialises Running":
    discard runCrud(session, "create_vm", params("vm1"))
    let inst = instanceName("vm1")

    let stopR = runCrud(session, "stop_vm", params("vm1"))
    check stopR.exitCode == 0
    check stopR.json["data"]["vm"]["state"].getStr == "stopped"
    check stopR.json["data"]["vm"]["ssh"].kind == JNull
    check backend.vmState(inst) == mvsStopped

    let startR = runCrud(session, "start_vm", params("vm1"))
    check startR.exitCode == 0
    check startR.json["data"]["vm"]["state"].getStr == "running"
    check startR.json["data"]["vm"]["ssh"].kind == JObject
    check backend.vmState(inst) == mvsRunning
    # Full transition history: create(3) + stop(1) + start(2).
    check backend.transitionLog(inst) == @[
      mvsStopped, mvsStarting, mvsRunning,   # create
      mvsStopped,                            # stop
      mvsStarting, mvsRunning]               # start

  test "get_vm reflects the running instance; list_vms grows":
    let empty = runCrud(session, "list_vms", params())
    check empty.json["data"]["vms"].len == 0
    discard runCrud(session, "create_vm", params("vm1"))
    discard runCrud(session, "create_vm", params("vm2"))
    let two = runCrud(session, "list_vms", params())
    check two.json["data"]["vms"].len == 2
    let g = runCrud(session, "get_vm", params("vm1"))
    check g.json["data"]["vm"]["state"].getStr == "running"

  test "delete removes the instance from façade AND backend":
    discard runCrud(session, "create_vm", params("vm1"))
    let inst = instanceName("vm1")
    check inst in backend.liveInstances()
    let delR = runCrud(session, "delete_vm", params("vm1"))
    check delR.exitCode == 0
    check delR.json["data"]["deleted"].getBool
    check inst notin backend.liveInstances()
    # A subsequent get no longer resolves.
    check runCrud(session, "get_vm", params("vm1")).exitCode ==
      exitCode(cekNotFound)

  test "instance name is deterministic across delete → recreate":
    discard runCrud(session, "create_vm", params("vm1"))
    let first = instanceName("vm1")
    discard runCrud(session, "delete_vm", params("vm1"))
    discard runCrud(session, "create_vm", params("vm1"))
    check instanceName("vm1") == first
    check first in backend.liveInstances()

suite "CRUD façade over mock — snapshots persist + restore is consistent":
  setup:
    let backend = newMockBackend()
    let session = newCrudSession(backend)

  test "snapshot → list_snapshots (creation order) → restore round-trip":
    discard runCrud(session, "create_vm", params("vm1"))
    for name in ["clean", "warmed"]:
      var sp = params("vm1")
      sp.snapshot = name
      let sr = runCrud(session, "snapshot", sp)
      check sr.exitCode == 0
      check sr.json["data"]["snapshot"]["name"].getStr == name
      # Opaque id is the instance-addressed handle name, per the mock contract.
      check sr.json["data"]["snapshot"]["id"].getStr ==
        instanceName("vm1") & "@" & name

    let listR = runCrud(session, "list_snapshots", params("vm1"))
    check listR.exitCode == 0
    let names = listR.json["data"]["snapshots"]
    check names.kind == JArray
    check names.len == 2
    check names[0].getStr == "clean"     # creation order preserved
    check names[1].getStr == "warmed"

    var rp = params("vm1")
    rp.snapshot = "clean"
    let restoreR = runCrud(session, "restore_snapshot", rp)
    check restoreR.exitCode == 0
    check restoreR.json["data"]["restored"].getBool

  test "restore rolls the guest filesystem back to snapshot time":
    discard runCrud(session, "create_vm", params("vm1"))
    let host = createTempDir("vmh-mock-crud-", "")
    defer: removeDir(host)
    writeFile(host / "a.txt", "AAA")
    writeFile(host / "b.txt", "BBB")

    # Copy a.txt, snapshot it, then copy b.txt AFTER the snapshot.
    var toA = params("vm1")
    toA.srcPath = host / "a.txt"; toA.destPath = "/data/a.txt"
    check runCrud(session, "copy_to_vm", toA).exitCode == 0

    var snap = params("vm1"); snap.snapshot = "only-a"
    check runCrud(session, "snapshot", snap).exitCode == 0

    var toB = params("vm1")
    toB.srcPath = host / "b.txt"; toB.destPath = "/data/b.txt"
    check runCrud(session, "copy_to_vm", toB).exitCode == 0

    # Before restore: b.txt is present in the guest.
    var fromB = params("vm1")
    fromB.srcPath = "/data/b.txt"; fromB.destPath = host / "outB.txt"
    check runCrud(session, "copy_from_vm", fromB).exitCode == 0
    check readFile(host / "outB.txt") == "BBB"

    # Restore the pre-b.txt snapshot.
    check runCrud(session, "restore_snapshot", snap).exitCode == 0

    # After restore: b.txt is gone (copy_from is a backend-error), a.txt remains.
    var fromB2 = params("vm1")
    fromB2.srcPath = "/data/b.txt"; fromB2.destPath = host / "outB2.txt"
    assertError(runCrud(session, "copy_from_vm", fromB2), cekBackendError)

    var fromA = params("vm1")
    fromA.srcPath = "/data/a.txt"; fromA.destPath = host / "outA.txt"
    check runCrud(session, "copy_from_vm", fromA).exitCode == 0
    check readFile(host / "outA.txt") == "AAA"

suite "CRUD façade over mock — failure envelopes":
  setup:
    let backend = newMockBackend()
    let session = newCrudSession(backend)

  test "get_vm on a missing VM is not-found (exit 3)":
    assertError(runCrud(session, "get_vm", params("ghost")), cekNotFound)

  test "create_vm of a duplicate name is bad-args (exit 2)":
    discard runCrud(session, "create_vm", params("vm1"))
    assertError(runCrud(session, "create_vm", params("vm1")), cekBadArgs)

  test "exec on a stopped VM is backend-error (exit 5)":
    discard runCrud(session, "create_vm", params("vm1"))
    discard runCrud(session, "stop_vm", params("vm1"))
    var p = params("vm1")
    p.argv = @["/bin/echo", "hi"]
    assertError(runCrud(session, "exec", p), cekBackendError)

  test "restore_snapshot of a missing snapshot is not-found (exit 3)":
    discard runCrud(session, "create_vm", params("vm1"))
    var p = params("vm1")
    p.snapshot = "no-such-snap"
    assertError(runCrud(session, "restore_snapshot", p), cekNotFound)
