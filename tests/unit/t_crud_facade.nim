## Hermetic gate for the generic-CRUD façade (GOSTI2 PR-1).
##
## Drives EVERY CRUD verb through the ``noop`` backend — the one allowed mock
## per the test methodology (design doc §9.1) — and asserts the two halves of
## the contract the ah-vm Rust binding depends on:
##
##   1. the STABLE JSON envelope (field presence + JSON types), and
##   2. the STABLE per-kind exit codes.
##
## No hypervisor, no network: a single long-lived ``CrudSession`` over one
## ``NoopBackend`` supplies the running-instance state, so the full
## create→exec→snapshot→stop→start→delete lifecycle runs in-process. This is
## the same in-process code path the CLI's ``crud`` subcommand reaches (both
## call ``runCrud``), so asserting the envelope here pins the bytes the CLI
## emits and the exit code it returns.

import std/[json, options, os, strutils, tables, tempfiles, unittest]
import vm_harness

proc params(name = ""): CrudParams =
  ## Bare params with only a name; individual tests fill the rest.
  CrudParams(name: name, guestOs: goLinux, guestArch: gaX86_64,
             env: initTable[string, string]())

proc assertError(r: CrudResponse, kind: CrudErrorKind) =
  ## Assert the stable failure envelope + exit code for a given kind.
  check r.exitCode == exitCode(kind)
  check not r.json["ok"].getBool
  check r.json["error"]["kind"].getStr == $kind
  check r.json["error"]["code"].getInt == exitCode(kind)
  check r.json["error"]["message"].kind == JString

# ---------------------------------------------------------------------------
# Two tiny stub backends whose methods raise — the vehicle for the exit-code
# arms NoopBackend can never reach (it implements every method successfully).
# create_vm is the driver: it calls provisionBaseline first, so overriding
# that one method is enough to route a verb into runCrud's exception handlers.

type
  UnavailableBackend = ref object of VmBackend
    ## Every operation reports the backend cannot run here → exit 4.
  ExplodingBackend = ref object of VmBackend
    ## Raises a plain, uncategorised error → the internal arm, exit 1.

method provisionBaseline(b: UnavailableBackend, spec: BaselineSpec) =
  raise newException(BackendUnavailableError,
    "stub backend is unavailable on this host")

method provisionBaseline(b: ExplodingBackend, spec: BaselineSpec) =
  raise newException(ValueError, "stub backend hit an unexpected fault")

suite "CRUD façade — exit-code contract":
  test "exitCode maps every failure kind to its stable code":
    check exitCode(cekBadArgs) == 2
    check exitCode(cekNotFound) == 3
    check exitCode(cekBackendUnavailable) == 4
    check exitCode(cekBackendError) == 5
    check exitCode(cekInternal) == 1

suite "CRUD façade — happy-path lifecycle over noop":
  setup:
    let backend = newNoopBackend()
    let session = newCrudSession(backend)

  test "create_vm returns ok + a well-formed VmInfo (Running)":
    var p = params("vm1")
    let r = runCrud(session, "create_vm", p)
    check r.exitCode == 0
    check r.json["ok"].getBool
    check r.json["verb"].getStr == "create_vm"
    let info = r.json["data"]["vm"]
    check info["name"].getStr == "vm1"
    check info["backend"].getStr == "noop"
    check info["state"].getStr == "running"
    check info["baseline"].kind == JString
    # ssh endpoint present + typed while the instance is running.
    check info["ssh"].kind == JObject
    check info["ssh"]["host"].getStr == "127.0.0.1"
    check info["ssh"]["port"].getInt == 22
    check info["ssh"]["user"].getStr == "noop"
    check info["ssh"]["auth"].getStr == "none"

  test "get_vm reflects the created instance":
    discard runCrud(session, "create_vm", params("vm1"))
    let r = runCrud(session, "get_vm", params("vm1"))
    check r.exitCode == 0
    check r.json["ok"].getBool
    check r.json["data"]["vm"]["name"].getStr == "vm1"
    check r.json["data"]["vm"]["state"].getStr == "running"

  test "list_vms is an array and starts empty":
    let empty = runCrud(session, "list_vms", params())
    check empty.exitCode == 0
    check empty.json["ok"].getBool
    check empty.json["data"]["vms"].kind == JArray
    check empty.json["data"]["vms"].len == 0
    discard runCrud(session, "create_vm", params("vm1"))
    discard runCrud(session, "create_vm", params("vm2"))
    let two = runCrud(session, "list_vms", params())
    check two.json["data"]["vms"].len == 2

  test "exec returns the ExecResult schema":
    discard runCrud(session, "create_vm", params("vm1"))
    var p = params("vm1")
    p.argv = @["/bin/echo", "hi"]
    let r = runCrud(session, "exec", p)
    check r.exitCode == 0
    check r.json["ok"].getBool
    let d = r.json["data"]
    check d["exit_code"].getInt == 0
    check d["stdout"].kind == JString
    check "echo" in d["stdout"].getStr
    check d["stderr"].kind == JString
    check d["elapsed_ms"].kind == JInt

  test "copy_to_vm + copy_from_vm round-trip a real file":
    discard runCrud(session, "create_vm", params("vm1"))
    let host = createTempDir("vmh-crud-", "")
    defer: removeDir(host)
    writeFile(host / "payload.txt", "hello")
    var toP = params("vm1")
    toP.srcPath = host / "payload.txt"
    toP.destPath = "/data/payload.txt"
    let toR = runCrud(session, "copy_to_vm", toP)
    check toR.exitCode == 0
    check toR.json["data"]["copied"].getBool
    var fromP = params("vm1")
    fromP.srcPath = "/data/payload.txt"
    fromP.destPath = host / "out.txt"
    let fromR = runCrud(session, "copy_from_vm", fromP)
    check fromR.exitCode == 0
    check readFile(host / "out.txt") == "hello"

  test "ssh_endpoint projects the handle":
    discard runCrud(session, "create_vm", params("vm1"))
    let r = runCrud(session, "ssh_endpoint", params("vm1"))
    check r.exitCode == 0
    let ep = r.json["data"]["ssh"]
    check ep["host"].getStr == "127.0.0.1"
    check ep["port"].getInt == 22
    check ep["user"].getStr == "noop"
    check ep["auth"].getStr == "none"

  test "snapshot → list_snapshots → restore_snapshot round-trip":
    discard runCrud(session, "create_vm", params("vm1"))
    var snapP = params("vm1")
    snapP.snapshot = "clean"
    let snapR = runCrud(session, "snapshot", snapP)
    check snapR.exitCode == 0
    check snapR.json["data"]["snapshot"]["name"].getStr == "clean"
    check snapR.json["data"]["snapshot"]["id"].getStr == "clean"

    let listR = runCrud(session, "list_snapshots", params("vm1"))
    check listR.exitCode == 0
    check listR.json["data"]["snapshots"].kind == JArray
    check listR.json["data"]["snapshots"][0].getStr == "clean"

    let restoreR = runCrud(session, "restore_snapshot", snapP)
    check restoreR.exitCode == 0
    check restoreR.json["data"]["restored"].getBool

  test "stop_vm releases the handle then start_vm re-materialises it":
    discard runCrud(session, "create_vm", params("vm1"))
    let stopR = runCrud(session, "stop_vm", params("vm1"))
    check stopR.exitCode == 0
    check stopR.json["data"]["vm"]["state"].getStr == "stopped"
    # ssh endpoint is null once the instance is not running.
    check stopR.json["data"]["vm"]["ssh"].kind == JNull

    let startR = runCrud(session, "start_vm", params("vm1"))
    check startR.exitCode == 0
    check startR.json["data"]["vm"]["state"].getStr == "running"
    check startR.json["data"]["vm"]["ssh"].kind == JObject

  test "delete_vm removes the instance from the registry":
    discard runCrud(session, "create_vm", params("vm1"))
    let delR = runCrud(session, "delete_vm", params("vm1"))
    check delR.exitCode == 0
    check delR.json["data"]["deleted"].getBool
    # A subsequent get_vm no longer resolves.
    let getR = runCrud(session, "get_vm", params("vm1"))
    check getR.exitCode == exitCode(cekNotFound)

suite "CRUD façade — failure envelopes over noop":
  setup:
    let backend = newNoopBackend()
    let session = newCrudSession(backend)

  test "get_vm on a missing VM is not-found (exit 3)":
    assertError(runCrud(session, "get_vm", params("ghost")), cekNotFound)

  test "create_vm without a name is bad-args (exit 2)":
    assertError(runCrud(session, "create_vm", params()), cekBadArgs)

  test "create_vm of a duplicate name is bad-args (exit 2)":
    discard runCrud(session, "create_vm", params("vm1"))
    assertError(runCrud(session, "create_vm", params("vm1")), cekBadArgs)

  test "an unknown verb is bad-args (exit 2)":
    assertError(runCrud(session, "frobnicate", params("vm1")), cekBadArgs)

  test "exec on a stopped VM is backend-error (exit 5)":
    discard runCrud(session, "create_vm", params("vm1"))
    discard runCrud(session, "stop_vm", params("vm1"))
    var p = params("vm1")
    p.argv = @["/bin/echo", "hi"]
    assertError(runCrud(session, "exec", p), cekBackendError)

  test "exec without argv is bad-args (exit 2)":
    discard runCrud(session, "create_vm", params("vm1"))
    assertError(runCrud(session, "exec", params("vm1")), cekBadArgs)

  test "snapshot without a name is bad-args (exit 2)":
    discard runCrud(session, "create_vm", params("vm1"))
    assertError(runCrud(session, "snapshot", params("vm1")), cekBadArgs)

  test "restore_snapshot of a missing snapshot is not-found (exit 3)":
    discard runCrud(session, "create_vm", params("vm1"))
    var p = params("vm1")
    p.snapshot = "no-such-snap"
    assertError(runCrud(session, "restore_snapshot", p), cekNotFound)

suite "CRUD façade — backend-unavailable and internal arms":
  # These two arms are unreachable through NoopBackend (which implements every
  # method), so they are driven end-to-end through runCrud with stub backends
  # that raise — closing the full frozen exit-code table (0/2/3/4/5, 1).
  test "a BackendUnavailableError maps to backend-unavailable (exit 4)":
    let session = newCrudSession(
      UnavailableBackend(id: biNoop, hostPlatform: hpLinux,
                         supportedGuests: {goLinux}))
    let r = runCrud(session, "create_vm", params("vm1"))
    assertError(r, cekBackendUnavailable)
    check r.exitCode == 4

  test "an uncategorised error maps to internal (exit 1)":
    let session = newCrudSession(
      ExplodingBackend(id: biNoop, hostPlatform: hpLinux,
                       supportedGuests: {goLinux}))
    let r = runCrud(session, "create_vm", params("vm1"))
    assertError(r, cekInternal)
    check r.exitCode == 1
