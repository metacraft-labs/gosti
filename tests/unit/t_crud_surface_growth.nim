## Hermetic gate for the generic-CRUD SURFACE GROWTH (GOSTI2 PR-3).
##
## PR-1 pinned the CRUD contract (envelope + exit codes) and PR-2 gave it a rich
## deterministic ``MockBackend``. PR-3 GROWS the ``crud`` surface so the ah-vm
## (agent-harbor) binding can forward the ``VmCreateOptions`` / ``ExecOptions``
## it previously had to drop — the binding now FAILS CLOSED on anything gosti
## cannot express, so this gate proves the new inputs are expressible end to end:
##
##   create_vm:  --user-data <path>  (cloud-init user-data — the important one)
##               --mount host:guest  (repeatable)
##               --ssh-user <user>
##   exec:       --cwd <dir>  --run-as <user>  --timeout <sec>
##
## Two halves, both hermetic (no hypervisor, no network, no subprocess):
##
##   1. PARSE — ``parseCliOpts`` lifts the new flags off the ``crud`` argv into
##      the ``CliOpts`` fields ``cmdCrud`` maps 1:1 onto ``CrudParams``
##      (--user-data → userDataFile, --mount → mounts, --ssh-user → sshUser,
##      --cwd → cwd, --run-as → runAs, --timeout → execTimeout).
##   2. WIRING — driving ``runCrud`` over the ``MockBackend``:
##        * exec's --cwd/--run-as/--timeout produce the exact portable argv WRAP
##          (asserted against the argv the mock actually received — no VmBackend
##          change is involved), and
##        * create_vm's --user-data/--mount/--ssh-user reach the ``BaselineSpec``
##          the create path hands the backend (the mock records every spec).
##
## The frozen envelope + exit-code table (0/2/3/4/5, 1) is unchanged — exec still
## returns the same ExecResult schema; the wrap is invisible to the contract.

import std/[json, options, os, strutils, tables, tempfiles, unittest]
import vm_harness
import vm_harness/cli

proc params(name = ""): CrudParams =
  CrudParams(name: name, guestOs: goLinux, guestArch: gaX86_64,
             env: initTable[string, string]())

# ---------------------------------------------------------------------------
# 1. PARSE — the new flags land in CliOpts (the source cmdCrud maps to
#    CrudParams). --user-data / --ssh-user reuse the pre-existing fields.

suite "CRUD surface growth — flags parse off the crud argv":
  test "create_vm flags: --user-data / --mount (repeatable) / --ssh-user":
    let ud = createTempDir("vmh-pr3-", "")
    defer: removeDir(ud)
    let udFile = ud / "user-data.yaml"
    writeFile(udFile, "#cloud-config\nruncmd:\n  - echo agent\n")
    let opts = parseCliOpts(@[
      "crud", "create_vm", "vm1",
      "--user-data", udFile,
      "--mount", "/host/work:/work",
      "--mount", "/host/cache:/cache",
      "--ssh-user", "agent"])
    check opts.subcommand == "crud"
    check opts.cmd == @["create_vm", "vm1"]
    check opts.userDataFile == udFile
    check opts.mounts.len == 2
    check opts.mounts[0] == (host: "/host/work", guest: "/work")
    check opts.mounts[1] == (host: "/host/cache", guest: "/cache")
    check opts.sshUser == "agent"

  test "exec flags: --cwd / --run-as / --timeout (argv after --)":
    let opts = parseCliOpts(@[
      "crud", "exec", "vm1",
      "--cwd", "/work",
      "--run-as", "builder",
      "--timeout", "45",
      "--", "make", "-j4"])
    check opts.cmd == @["exec", "vm1", "make", "-j4"]
    check opts.cwd == "/work"
    check opts.runAs == "builder"
    check opts.execTimeout == 45

  test "--timeout rejects a negative value (parse-time bad-args)":
    expect ValueError:
      discard parseCliOpts(@["crud", "exec", "vm1", "--timeout", "-5"])

# ---------------------------------------------------------------------------
# 2a. WIRING — exec argv WRAP. ``wrapExecArgv`` is a pure function; assert each
#     option's wrap verbatim, then assert the SAME bytes reach the backend
#     through the full ``runCrud`` exec path (the mock records raw argv).

suite "CRUD surface growth — exec argv wrapping (pure)":
  const base = @["/bin/echo", "hi there"]

  test "no options leaves argv untouched":
    check wrapExecArgv(base, "", "", 0) == base

  test "--cwd wraps in a positional-arg cd (no shell quoting of the dir)":
    check wrapExecArgv(base, "/work", "", 0) ==
      @["sh", "-c", "cd \"$1\" && shift && exec \"$@\"", "sh", "/work"] & base

  test "--run-as wraps in su with argv as positional params":
    check wrapExecArgv(base, "", "builder", 0) ==
      @["su", "builder", "-c", "exec \"$@\"", "sh"] & base

  test "--timeout prefixes the coreutils timeout":
    check wrapExecArgv(base, "", "", 30) ==
      @["timeout", "30"] & base

  test "all three compose as timeout( su-U( cd-D( argv ) ) )":
    let cwdWrap =
      @["sh", "-c", "cd \"$1\" && shift && exec \"$@\"", "sh", "/work"] & base
    let runAsWrap = @["su", "builder", "-c", "exec \"$@\"", "sh"] & cwdWrap
    let full = @["timeout", "30"] & runAsWrap
    check wrapExecArgv(base, "/work", "builder", 30) == full

suite "CRUD surface growth — exec wrap reaches the backend verbatim":
  setup:
    let backend = newMockBackend()
    let session = newCrudSession(backend)
    discard runCrud(session, "create_vm", params("vm1"))

  test "the wrapped argv is exactly what execInGuest received":
    var p = params("vm1")
    p.argv = @["/bin/echo", "hi"]
    p.cwd = "/work"
    p.runAs = "builder"
    p.execTimeoutSec = 30
    let r = runCrud(session, "exec", p)
    # Contract unchanged: same ExecResult schema + exit 0.
    check r.exitCode == 0
    check r.json["ok"].getBool
    check r.json["data"]["exit_code"].getInt == 0
    check r.json["data"]["elapsed_ms"].kind == JInt
    # The backend saw the fully wrapped argv, not the bare command.
    check backend.execArgvLog.len == 1
    check backend.execArgvLog[0] ==
      wrapExecArgv(@["/bin/echo", "hi"], "/work", "builder", 30)
    # And the mock's deterministic echo reflects the wrapper (timeout is the
    # outermost program the guest actually runs).
    check r.json["data"]["stdout"].getStr.startsWith("mock-exec: timeout 30 ")

  test "bare exec (no options) still forwards the unwrapped argv":
    var p = params("vm1")
    p.argv = @["/bin/true"]
    check runCrud(session, "exec", p).exitCode == 0
    check backend.execArgvLog[0] == @["/bin/true"]

# ---------------------------------------------------------------------------
# 2b. WIRING — create_vm options.
#
# --user-data and --mount are PLUMBED-BUT-GUARDED: they parse into the spec, but
# NO gosti backend honours ``BaselineSpec.userData``/``.mounts`` yet, so
# ``cmdCrud`` FAILS CLOSED (backend-unavailable, exit 4) rather than reporting
# success for a VM that would boot without cloud-init / without the shares —
# the exact silent-wrong the ah-vm binding's fail-closed guard exists to
# prevent. The guard is exercised through the CLI-level ``cmdCrud`` (via
# ``dispatch``) since that is where it lives. --ssh-user is genuinely advisory
# and DOES reach the spec (asserted through the backend-agnostic runCrud path).

suite "CRUD surface growth — create_vm --user-data/--mount FAIL CLOSED":
  # Drive the guard through the real CLI path: parseCliOpts lifts the flags off
  # the ``crud`` argv, and ``crudCreateGuard`` (what ``cmdCrud`` consults BEFORE
  # resolving a backend) decides. Hermetic — no backend, no hypervisor.

  test "--user-data on create_vm is backend-unavailable (exit 4), not ok":
    let ud = createTempDir("vmh-pr3-fc-", "")
    defer: removeDir(ud)
    let udFile = ud / "cloud.yaml"
    writeFile(udFile, "#cloud-config\nruncmd:\n  - /opt/agent/bootstrap.sh\n")
    let opts = parseCliOpts(@["crud", "create_vm", "vm1", "--user-data", udFile])
    let g = crudCreateGuard("create_vm", opts)
    check g.isSome
    let r = g.get()
    check r.exitCode == exitCode(cekBackendUnavailable)
    check r.exitCode == 4
    check not r.json["ok"].getBool
    check r.json["verb"].getStr == "create_vm"
    check r.json["error"]["kind"].getStr == $cekBackendUnavailable
    check r.json["error"]["code"].getInt == 4
    check "user-data" in r.json["error"]["message"].getStr

  test "--mount on create_vm is backend-unavailable (exit 4), not ok":
    let opts = parseCliOpts(
      @["crud", "create_vm", "vm1", "--mount", "/host/work:/work"])
    let g = crudCreateGuard("create_vm", opts)
    check g.isSome
    check g.get().exitCode == 4
    check not g.get().json["ok"].getBool
    check g.get().json["error"]["kind"].getStr == $cekBackendUnavailable
    check "mount" in g.get().json["error"]["message"].getStr

  test "a plain create_vm (no guarded options) is NOT guarded":
    let opts = parseCliOpts(@["crud", "create_vm", "vm1"])
    check crudCreateGuard("create_vm", opts).isNone

  test "the guard is create_vm-only — other verbs are never guarded":
    # --user-data/--mount on a non-create verb are meaningless but must not trip
    # the guard (it keys on the verb, so e.g. exec is untouched).
    let opts = parseCliOpts(
      @["crud", "exec", "vm1", "--mount", "/h:/g", "--", "true"])
    check crudCreateGuard("exec", opts).isNone

suite "CRUD surface growth — create_vm --ssh-user reaches the spec (advisory)":
  setup:
    let backend = newMockBackend()
    let session = newCrudSession(backend)

  test "--ssh-user flows into BaselineSpec (accept-advisory, no guard)":
    var p = params("vm1")
    p.sshUser = "agent"
    let r = runCrud(session, "create_vm", p)
    check r.exitCode == 0
    check r.json["ok"].getBool
    check backend.provisionSpecs.len == 1
    check backend.provisionSpecs[0].sshUser == "agent"

  test "create_vm without --ssh-user leaves the spec field empty":
    discard runCrud(session, "create_vm", params("plain"))
    check backend.provisionSpecs[0].sshUser == ""
