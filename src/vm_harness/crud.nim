## Generic-CRUD façade over the ``VmBackend`` lifecycle (GOSTI2 PR-1).
##
## gosti's native contract is the baseline/gate model: a backend
## *provisions* a long-lived baseline image and *reverts* fast per-gate
## clones from it (see ``types.nim`` and ``orchestrator.runGate``). The
## future ``ah-vm`` Rust binding, however, drives gosti as a subprocess
## through a *generic CRUD* vocabulary — the shape of the Rust
## ``VmOrchestrator`` trait:
##
##   create_vm / start_vm / stop_vm / delete_vm / get_vm / list_vms /
##   exec / copy_to_vm / copy_from_vm / ssh_endpoint /
##   snapshot / restore_snapshot / list_snapshots
##
## This module is the ADAPTER between those two vocabularies. It does NOT
## reimplement any backend behaviour — every verb is a thin wrapper that
## calls the existing ``VmBackend`` methods and marshals the result into a
## STABLE, machine-readable shape (the ``VmState`` enum, ``VmInfo``,
## ``SshEndpoint``, and a fixed JSON envelope). The CLI ``crud`` subcommand
## group (``cli.nim``) and the hermetic gate (``tests/unit/t_crud_facade``)
## both drive the backend exclusively through here, so the contract the
## Rust binding parses is exercised by exactly one code path.
##
## ---------------------------------------------------------------------------
## Verb → ``VmBackend`` mapping (the design decisions PR-1 commits to)
## ---------------------------------------------------------------------------
##
## gosti has no "defined-but-stopped instance" concept at the ``VmBackend``
## layer: ``provisionBaseline`` builds a *template*, and ``revertToBaseline``
## is what materialises a *running instance*. A generic-CRUD "VM" is an
## instance, so the façade keeps an in-process registry mapping the caller's
## logical VM name to the live ``VmHandle`` reverted for it:
##
##   ===============  =========================================================
##   CRUD verb        VmBackend realisation
##   ===============  =========================================================
##   create_vm        provisionBaseline(spec)  [idempotent: ensure template]
##                    + revertToBaseline(baseline) → VmHandle  [start instance]
##                    ⇒ state Running. (gosti folds start into revert; there
##                    is no stopped-created instance to hand back.)
##   start_vm         Idempotent when the instance is already running
##                    (startAndAwaitReady). After a stop_vm released the
##                    handle, re-materialise it via revertToBaseline.
##   stop_vm(force)   stopAndCleanup(vm, deleteVm = false); handle released,
##                    state Stopped. (force is accepted for trait parity; the
##                    backend method never raises, so it is advisory today.)
##   delete_vm(force) stopAndCleanup(vm, deleteVm = true) + drop the registry
##                    entry. The VM no longer resolves.
##   get_vm           Registry lookup → VmInfo (state + ssh endpoint).
##   list_vms         Every registry entry → seq[VmInfo].
##   exec             execInGuest(vm, env, argv) → ExecResult.
##   copy_to_vm       copyToGuest(vm, hostPath, guestPath).
##   copy_from_vm     copyFromGuest(vm, guestPath, hostPath).
##   ssh_endpoint     Project the VmHandle's ip/port/user/auth → SshEndpoint.
##   snapshot         backend.snapshot(handle.name, snap) → opaque id.
##   restore_snapshot backend.restoreSnapshot(handle.name, snap).
##   list_snapshots   backend.listSnapshots(handle.name).
##   ===============  =========================================================
##
## Snapshot verbs address the backend by the instance's real name
## (``VmHandle.name``, e.g. libvirt's domain), not the caller's logical name,
## so they line up with what the hypervisor actually stores.
##
## Scope caveat (documented, deliberately NOT solved in PR-1): the registry
## is process-local. A real Rust binding that invokes the CLI once per verb
## needs the running-instance set to survive across invocations — that is a
## persistence follow-up (handle reconstruction from hypervisor state, as
## ``instances.nim`` already does for durable libvirt instances). PR-1 is
## additive and hermetic: the gate drives a single long-lived session
## in-process through the ``noop`` backend, which is all the CONTRACT
## (JSON schema + exit codes + verb dispatch) needs to be pinned down.

import std/[json, options, tables]
import ./types

type
  VmState* = enum
    ## Lifecycle state reported by ``get_vm`` / ``list_vms``. String values
    ## are the stable wire tokens the Rust ``VmState`` enum mirrors; do not
    ## rename them without versioning the contract.
    vsStopped = "stopped"
    vsStarting = "starting"
    vsRunning = "running"
    vsPaused = "paused"
    vsError = "error"

  SshEndpoint* = object
    ## Where and how to reach the guest over SSH. Projected straight from the
    ## backend's ``VmHandle``.
    host*: string                ## guest IP/host ("" when the backend has none)
    port*: int
    user*: string
    auth*: string                ## "none" | "password" | "keyfile"

  VmInfo* = object
    ## Machine-readable description of one VM in the façade registry.
    name*: string                ## caller's logical VM name (the CRUD identity)
    backend*: string             ## BackendId string (e.g. "noop", "libvirt")
    baseline*: string            ## baseline/template the instance derives from
    state*: VmState
    ssh*: Option[SshEndpoint]     ## present only while a live handle exists

  CrudErrorKind* = enum
    ## Failure categories, each pinned to a stable process exit code (see
    ## ``exitCode``). Distinct codes let the Rust binding branch on the
    ## outcome without parsing human text.
    cekBadArgs = "bad-args"                    ## exit 2
    cekNotFound = "not-found"                  ## exit 3
    cekBackendUnavailable = "backend-unavailable" ## exit 4
    cekBackendError = "backend-error"          ## exit 5
    cekInternal = "internal"                   ## exit 1

  CrudError* = object of CatchableError
    ## Raised by the verb procs and caught by ``runCrud`` to build the error
    ## envelope. ``kind`` selects both the wire token and the exit code.
    kind*: CrudErrorKind

  VmRecord = object
    ## One entry in the in-process instance registry.
    name: string                 ## caller's logical name (registry key)
    baseline: string
    handle: VmHandle             ## live handle while Running; nil once stopped
    state: VmState

  CrudParams* = object
    ## Parsed inputs a verb may consult. The CLI and the gate populate this
    ## the same way so both reach ``runCrud`` with identical data.
    name*: string                ## VM name (identity for every verb)
    baseline*: string            ## defaults to ``name`` when empty
    sourceImage*: string
    cpus*: int
    memoryMB*: int
    diskGB*: int
    guestOs*: GuestOs
    guestArch*: GuestArch
    snapshot*: string            ## snapshot name for the snapshot verbs
    env*: Table[string, string]  ## environment for ``exec``
    argv*: seq[string]           ## command for ``exec``
    srcPath*: string             ## copy source (host for to, guest for from)
    destPath*: string            ## copy destination
    force*: bool                 ## stop_vm / delete_vm advisory force
    # --- GOSTI2 PR-3: create_vm surface growth (VmCreateOptions forwarding) ---
    userData*: string            ## ``create_vm --user-data`` — cloud-init
                                 ## user-data CONTENT (the CLI reads the file;
                                 ## the gate sets it directly). Flows into
                                 ## ``BaselineSpec.userData``.
    mounts*: seq[tuple[host: string, guest: string]]
                                 ## ``create_vm --mount host:guest`` (repeatable).
                                 ## Flows into ``BaselineSpec.mounts``.
    sshUser*: string             ## ``create_vm --ssh-user`` — preferred guest
                                 ## login. Flows into ``BaselineSpec.sshUser``.
    # --- GOSTI2 PR-3: exec surface growth (ExecOptions forwarding) ------------
    # These are realised by CRUD-LAYER argv WRAPPING (see ``wrapExecArgv``); they
    # need no ``VmBackend`` change — the guest just runs a portable POSIX-sh /
    # coreutils wrapper around the caller's argv.
    cwd*: string                 ## ``exec --cwd D`` — run argv with CWD = D.
    runAs*: string               ## ``exec --run-as U`` — run argv as user U.
    execTimeoutSec*: int         ## ``exec --timeout N`` — guest-side wall-clock
                                 ## kill after N seconds (0 ⇒ no limit).

  CrudSession* = ref object
    ## Holds the backend and the process-local instance registry. One session
    ## drives many verbs; the gate reuses a single session for a full
    ## lifecycle so in-memory state (which VMs are running) persists.
    backend*: VmBackend
    registry: Table[string, VmRecord]

  CrudResponse* = object
    ## The single value ``runCrud`` returns: the JSON the CLI echoes on
    ## stdout and the exit code the process returns. Both callers use these
    ## verbatim, so the CLI and the in-process gate agree byte-for-byte.
    exitCode*: int
    json*: JsonNode

const CrudVerbs* = [
  "create_vm", "start_vm", "stop_vm", "delete_vm", "get_vm", "list_vms",
  "exec", "copy_to_vm", "copy_from_vm", "ssh_endpoint",
  "snapshot", "restore_snapshot", "list_snapshots"]
  ## The stable verb vocabulary. ``list_vms`` here is the machine-readable
  ## surface; unknown verbs are a ``bad-args`` failure.

proc exitCode*(kind: CrudErrorKind): int =
  ## Stable failure-kind → process-exit-code table. This is a load-bearing
  ## part of the contract the Rust binding depends on — treat it as frozen.
  case kind
  of cekBadArgs: 2
  of cekNotFound: 3
  of cekBackendUnavailable: 4
  of cekBackendError: 5
  of cekInternal: 1

proc newCrudError(kind: CrudErrorKind, msg: string): ref CrudError =
  result = newException(CrudError, msg)
  result.kind = kind

proc newCrudSession*(backend: VmBackend): CrudSession =
  ## Construct a façade session around an already-resolved backend.
  CrudSession(backend: backend, registry: initTable[string, VmRecord]())

# ---------------------------------------------------------------------------
# Marshalling helpers. All JSON keys are part of the stable schema.

proc sshAuthToken(kind: SshAuthKind): string =
  case kind
  of saNone: "none"
  of saPassword: "password"
  of saKeyFile: "keyfile"

proc toSshEndpoint(vm: VmHandle): SshEndpoint =
  SshEndpoint(
    host: vm.ipAddress.get(""),
    port: vm.sshPort,
    user: vm.sshUser,
    auth: sshAuthToken(vm.sshAuth.kind))

proc toJson*(ep: SshEndpoint): JsonNode =
  %*{"host": ep.host, "port": ep.port, "user": ep.user, "auth": ep.auth}

proc toJson*(info: VmInfo): JsonNode =
  result = %*{
    "name": info.name,
    "backend": info.backend,
    "baseline": info.baseline,
    "state": $info.state}
  result["ssh"] =
    if info.ssh.isSome: info.ssh.get().toJson()
    else: newJNull()

proc toVmInfo(session: CrudSession, rec: VmRecord): VmInfo =
  VmInfo(
    name: rec.name,
    backend: $session.backend.id,
    baseline: rec.baseline,
    state: rec.state,
    ssh: (if rec.handle != nil: some(toSshEndpoint(rec.handle))
          else: none(SshEndpoint)))

# ---------------------------------------------------------------------------
# Internal lookups.

proc requireRecord(session: CrudSession, name: string): VmRecord =
  ## Registry lookup that maps a miss to the stable ``not-found`` failure.
  if name.len == 0:
    raise newCrudError(cekBadArgs, "vm name is required")
  if name notin session.registry:
    raise newCrudError(cekNotFound, "vm '" & name & "' not found")
  session.registry[name]

proc requireRunning(rec: VmRecord): VmHandle =
  ## The verbs that touch the guest (exec/copy/ssh/snapshot) need a live
  ## handle. A stopped instance is a precondition failure, not a miss.
  if rec.handle == nil:
    raise newCrudError(cekBackendError,
      "vm '" & rec.name & "' is not running")
  rec.handle

proc buildSpec(p: CrudParams): BaselineSpec =
  ## Mirror ``cli.applyDefaults`` for the fields a create needs, without
  ## reaching into the CLI module. Zero-valued sizes fall back inside the
  ## backends (documented in ``BaselineSpec``), so we only forward what the
  ## caller set.
  BaselineSpec(
    name: (if p.baseline.len > 0: p.baseline else: p.name),
    sourceImage: p.sourceImage,
    cpus: p.cpus,
    memoryMB: p.memoryMB,
    diskGB: p.diskGB,
    guestOs: p.guestOs,
    guestArch: p.guestArch,
    # PR-3: forward the ah-vm ``VmCreateOptions`` a create needs. These are
    # OPTIONAL — a backend that cannot express them ignores them (documented on
    # ``BaselineSpec``), so every existing backend still compiles + behaves.
    userData: p.userData,
    mounts: p.mounts,
    sshUser: p.sshUser)

proc wrapExecArgv*(argv: seq[string], cwd, runAs: string,
                   timeoutSec: int): seq[string] =
  ## Realise the ``exec`` options as a portable, additive argv WRAP — no
  ## ``VmBackend`` change: the guest simply runs a POSIX-sh / coreutils wrapper
  ## around the caller's command. Applied innermost-first so the composition
  ## nests ``timeout( su-U( cd-D( argv ) ) )``:
  ##
  ## - ``--cwd D``  → ``sh -c 'cd "$1" && shift && exec "$@"' sh D <argv…>``
  ##                  (D is a positional param, never spliced into the script,
  ##                  so it needs no shell quoting).
  ## - ``--run-as U`` → ``su U -c 'exec "$@"' sh <argv…>`` (argv is passed as
  ##                    positional params to the user's login shell).
  ## - ``--timeout N`` → ``timeout N <argv…>`` (coreutils; kills the whole
  ##                     wrapped tree on expiry).
  ##
  ## Portability note: this targets a POSIX guest (``sh``, ``su``, coreutils
  ## ``timeout`` — Linux/macOS). A Windows guest has none of these, so the wrap
  ## is a no-op-safe *contract* the CRUD layer applies uniformly; a Windows
  ## backend would need its own realisation. Empty ``cwd``/``runAs`` and a
  ## non-positive ``timeoutSec`` each leave the argv untouched.
  result = argv
  if cwd.len > 0:
    result = @["sh", "-c", "cd \"$1\" && shift && exec \"$@\"", "sh", cwd] &
      result
  if runAs.len > 0:
    result = @["su", runAs, "-c", "exec \"$@\"", "sh"] & result
  if timeoutSec > 0:
    result = @["timeout", $timeoutSec] & result

# ---------------------------------------------------------------------------
# Verb implementations. Each raises ``CrudError`` on a categorised failure
# and lets an unexpected backend exception bubble to ``runCrud``.

proc createVm(session: CrudSession, p: CrudParams): JsonNode =
  if p.name.len == 0:
    raise newCrudError(cekBadArgs, "create_vm requires a vm name")
  if p.name in session.registry:
    raise newCrudError(cekBadArgs, "vm '" & p.name & "' already exists")
  let spec = buildSpec(p)
  let baseline = spec.name
  # provisionBaseline is idempotent — safe to ensure the template on every
  # create; revertToBaseline then materialises + starts the instance.
  session.backend.provisionBaseline(spec)
  let handle = session.backend.revertToBaseline(baseline)
  let rec = VmRecord(name: p.name, baseline: baseline,
                     handle: handle, state: vsRunning)
  session.registry[p.name] = rec
  %*{"vm": toJson(toVmInfo(session, rec))}

proc startVm(session: CrudSession, p: CrudParams): JsonNode =
  var rec = requireRecord(session, p.name)
  if rec.handle != nil:
    # Already running: gosti folds start into revert, so this is idempotent.
    session.backend.startAndAwaitReady(rec.handle)
  else:
    # Re-materialise an instance the caller previously stopped.
    rec.handle = session.backend.revertToBaseline(rec.baseline)
  rec.state = vsRunning
  session.registry[p.name] = rec
  %*{"vm": toJson(toVmInfo(session, rec))}

proc stopVm(session: CrudSession, p: CrudParams): JsonNode =
  var rec = requireRecord(session, p.name)
  if rec.handle != nil:
    session.backend.stopAndCleanup(rec.handle, deleteVm = false)
    rec.handle = nil
  rec.state = vsStopped
  session.registry[p.name] = rec
  %*{"vm": toJson(toVmInfo(session, rec))}

proc deleteVm(session: CrudSession, p: CrudParams): JsonNode =
  let rec = requireRecord(session, p.name)
  if rec.handle != nil:
    session.backend.stopAndCleanup(rec.handle, deleteVm = true)
  session.registry.del(p.name)
  %*{"name": p.name, "deleted": true, "state": $vsStopped}

proc getVm(session: CrudSession, p: CrudParams): JsonNode =
  let rec = requireRecord(session, p.name)
  %*{"vm": toJson(toVmInfo(session, rec))}

proc listVms(session: CrudSession, p: CrudParams): JsonNode =
  var arr = newJArray()
  for rec in session.registry.values:
    arr.add(toJson(toVmInfo(session, rec)))
  %*{"vms": arr}

proc execVm(session: CrudSession, p: CrudParams): JsonNode =
  let rec = requireRecord(session, p.name)
  let handle = requireRunning(rec)
  if p.argv.len == 0:
    raise newCrudError(cekBadArgs, "exec requires a command (argv)")
  # PR-3: fold --cwd/--run-as/--timeout into a portable argv wrap before the
  # backend ever sees it. No VmBackend change — the guest runs the wrapper.
  let argv = wrapExecArgv(p.argv, p.cwd, p.runAs, p.execTimeoutSec)
  let r = session.backend.execInGuest(handle, p.env, argv)
  %*{
    "exit_code": r.exitCode,
    "stdout": r.stdout,
    "stderr": r.stderr,
    "elapsed_ms": r.elapsedMs}

proc copyToVm(session: CrudSession, p: CrudParams): JsonNode =
  let rec = requireRecord(session, p.name)
  let handle = requireRunning(rec)
  if p.srcPath.len == 0 or p.destPath.len == 0:
    raise newCrudError(cekBadArgs,
      "copy_to_vm requires a host source and a guest destination path")
  session.backend.copyToGuest(handle, p.srcPath, p.destPath)
  %*{"copied": true, "source": p.srcPath, "dest": p.destPath}

proc copyFromVm(session: CrudSession, p: CrudParams): JsonNode =
  let rec = requireRecord(session, p.name)
  let handle = requireRunning(rec)
  if p.srcPath.len == 0 or p.destPath.len == 0:
    raise newCrudError(cekBadArgs,
      "copy_from_vm requires a guest source and a host destination path")
  session.backend.copyFromGuest(handle, p.srcPath, p.destPath)
  %*{"copied": true, "source": p.srcPath, "dest": p.destPath}

proc sshEndpointVm(session: CrudSession, p: CrudParams): JsonNode =
  let rec = requireRecord(session, p.name)
  let handle = requireRunning(rec)
  %*{"ssh": toJson(toSshEndpoint(handle))}

proc snapshotVm(session: CrudSession, p: CrudParams): JsonNode =
  let rec = requireRecord(session, p.name)
  let handle = requireRunning(rec)
  if p.snapshot.len == 0:
    raise newCrudError(cekBadArgs, "snapshot requires a snapshot name")
  let id = session.backend.snapshot(handle.name, p.snapshot)
  %*{"snapshot": {"vm": p.name, "name": p.snapshot, "id": id}}

proc restoreSnapshotVm(session: CrudSession, p: CrudParams): JsonNode =
  let rec = requireRecord(session, p.name)
  let handle = requireRunning(rec)
  if p.snapshot.len == 0:
    raise newCrudError(cekBadArgs, "restore_snapshot requires a snapshot name")
  # Pre-check membership so a missing snapshot is a clean ``not-found`` rather
  # than a backend-shaped error whose message we would have to parse.
  if p.snapshot notin session.backend.listSnapshots(handle.name):
    raise newCrudError(cekNotFound,
      "snapshot '" & p.snapshot & "' not found for vm '" & p.name & "'")
  session.backend.restoreSnapshot(handle.name, p.snapshot)
  %*{"vm": p.name, "snapshot": p.snapshot, "restored": true}

proc listSnapshotsVm(session: CrudSession, p: CrudParams): JsonNode =
  let rec = requireRecord(session, p.name)
  let handle = requireRunning(rec)
  var arr = newJArray()
  for s in session.backend.listSnapshots(handle.name):
    arr.add(%s)
  %*{"vm": p.name, "snapshots": arr}

# ---------------------------------------------------------------------------
# The single dispatch entry point. The CLI and the gate both call this, so
# the verb table, the success envelope, and the error envelope are shared.

proc runCrud*(session: CrudSession, verb: string, p: CrudParams): CrudResponse =
  ## Execute one CRUD verb and return the stable envelope + exit code.
  ##
  ## Success envelope:
  ##   {"ok": true,  "verb": "<verb>", "data": <verb-specific object>}
  ## Failure envelope:
  ##   {"ok": false, "verb": "<verb>",
  ##    "error": {"code": <int>, "kind": "<kind>", "message": "<text>"}}
  ##
  ## The exit code is 0 on success, else ``exitCode(error.kind)``.
  var data: JsonNode
  try:
    data =
      case verb
      of "create_vm": createVm(session, p)
      of "start_vm": startVm(session, p)
      of "stop_vm": stopVm(session, p)
      of "delete_vm": deleteVm(session, p)
      of "get_vm": getVm(session, p)
      of "list_vms": listVms(session, p)
      of "exec": execVm(session, p)
      of "copy_to_vm": copyToVm(session, p)
      of "copy_from_vm": copyFromVm(session, p)
      of "ssh_endpoint": sshEndpointVm(session, p)
      of "snapshot": snapshotVm(session, p)
      of "restore_snapshot": restoreSnapshotVm(session, p)
      of "list_snapshots": listSnapshotsVm(session, p)
      else:
        raise newCrudError(cekBadArgs, "unknown crud verb '" & verb & "'")
  except CrudError as e:
    return CrudResponse(
      exitCode: exitCode(e.kind),
      json: %*{"ok": false, "verb": verb,
               "error": {"code": exitCode(e.kind), "kind": $e.kind,
                         "message": e.msg}})
  except BackendUnavailableError as e:
    return CrudResponse(
      exitCode: exitCode(cekBackendUnavailable),
      json: %*{"ok": false, "verb": verb,
               "error": {"code": exitCode(cekBackendUnavailable),
                         "kind": $cekBackendUnavailable, "message": e.msg}})
  except VmHarnessError as e:
    # Any other categorised harness failure (revert/exec/copy/snapshot inside
    # the backend) surfaces as a generic ``backend-error``.
    return CrudResponse(
      exitCode: exitCode(cekBackendError),
      json: %*{"ok": false, "verb": verb,
               "error": {"code": exitCode(cekBackendError),
                         "kind": $cekBackendError, "message": e.msg}})
  except CatchableError as e:
    return CrudResponse(
      exitCode: exitCode(cekInternal),
      json: %*{"ok": false, "verb": verb,
               "error": {"code": exitCode(cekInternal),
                         "kind": $cekInternal, "message": e.msg}})
  CrudResponse(
    exitCode: 0,
    json: %*{"ok": true, "verb": verb, "data": data})
