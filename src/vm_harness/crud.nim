# SPDX-FileCopyrightText: 2026 Metacraft Labs / Schelling Point Labs
# SPDX-License-Identifier: Apache-2.0
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
## Cross-invocation state (design doc §8.6): a session built with a
## ``CrudStore`` (the CLI always does) persists the registry in the crud store
## and reconciles every loaded handle against the hypervisor via
## ``VmBackend.instancePresence``, so one process per verb sees one consistent
## set of VMs. A session with no store keeps the registry in-process, which is
## what the in-process gates (``t_crud_facade*``) drive.

import std/[json, options, tables]
import ./types, ./crud_store, ./ephemeral_handle

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
    ## Holds the backend and the instance registry. With ``store`` nil the
    ## registry is process-local (one session drives many verbs in-process);
    ## with a store it is the persisted crud store (design doc §8.6).
    backend*: VmBackend
    registry: Table[string, VmRecord]
    store*: CrudStore
    lockTimeoutSec*: int         ## per-VM lock wait (store mode only)

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

proc newCrudSession*(backend: VmBackend, store: CrudStore = nil,
                     lockTimeoutSec = 10): CrudSession =
  ## Construct a façade session around an already-resolved backend. Pass a
  ## ``store`` to persist the registry across invocations (§8.6).
  CrudSession(backend: backend, registry: initTable[string, VmRecord](),
              store: store, lockTimeoutSec: lockTimeoutSec)

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
    ssh: (if rec.handle != nil and rec.state == vsRunning:
            some(toSshEndpoint(rec.handle))
          else: none(SshEndpoint)))

# ---------------------------------------------------------------------------
# Internal lookups.

# ---------------------------------------------------------------------------
# Registry access. Every verb goes through these four procs, so the verbs are
# identical in process-local and crud-store mode.

proc reconcile(session: CrudSession, stored: CrudStoredVm): VmRecord =
  ## Rebuild a record from disk and derive its state from the hypervisor
  ## (§8.6): running/stopped follow the backend, a vanished instance is
  ## ``error``, and "could not ask" (``ipUnknown``, or a probe that raised)
  ## leaves the recorded state standing — never read as absence.
  result = VmRecord(name: stored.name, baseline: stored.baseline,
                    state: (if stored.state == $vsRunning: vsRunning
                            else: vsStopped))
  if stored.handle.isSome:
    result.handle = handleFromJson(stored.handle.get(), session.backend)
    var presence = ipUnknown
    try:
      presence = session.backend.instancePresence(result.handle)
    except CatchableError:
      presence = ipUnknown
    case presence
    of ipRunning: result.state = vsRunning
    of ipStopped: result.state = vsStopped
    of ipGone: result.state = vsError
    of ipUnknown: discard

proc fetch(session: CrudSession, name: string): Option[VmRecord] =
  if session.store == nil:
    if name in session.registry: return some(session.registry[name])
    return none(VmRecord)
  let stored = session.store.load($session.backend.id, name)
  if stored.isNone: return none(VmRecord)
  some(session.reconcile(stored.get()))

proc put(session: CrudSession, rec: VmRecord) =
  if session.store == nil:
    session.registry[rec.name] = rec
    return
  # ``error`` is derived, never stored: persist what the façade last did.
  session.store.save(CrudStoredVm(
    name: rec.name, backend: $session.backend.id, baseline: rec.baseline,
    state: (if rec.state == vsStopped: $vsStopped else: $vsRunning),
    handle: (if rec.handle != nil: some(handleToJson(rec.handle))
             else: none(JsonNode))))

proc drop(session: CrudSession, name: string) =
  if session.store == nil:
    session.registry.del(name)
  else:
    session.store.remove($session.backend.id, name)

proc allRecords(session: CrudSession): seq[VmRecord] =
  if session.store == nil:
    for rec in session.registry.values: result.add(rec)
  else:
    for stored in session.store.list($session.backend.id):
      result.add(session.reconcile(stored))

proc requireRecord(session: CrudSession, name: string): VmRecord =
  ## Registry lookup that maps a miss to the stable ``not-found`` failure.
  if name.len == 0:
    raise newCrudError(cekBadArgs, "vm name is required")
  let rec = session.fetch(name)
  if rec.isNone:
    raise newCrudError(cekNotFound, "vm '" & name & "' not found")
  rec.get()

proc requireRunning(rec: VmRecord): VmHandle =
  ## The verbs that touch the guest (exec/copy/ssh/snapshot) need a live
  ## instance. A stopped or vanished instance is a precondition failure, not a
  ## miss.
  if rec.state == vsError:
    raise newCrudError(cekBackendError,
      "vm '" & rec.name & "' no longer exists on the hypervisor " &
      "(state error); delete_vm or start_vm it")
  if rec.handle == nil or rec.state != vsRunning:
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
  if session.fetch(p.name).isSome:
    raise newCrudError(cekBadArgs, "vm '" & p.name & "' already exists")
  let spec = buildSpec(p)
  let baseline = spec.name
  # provisionBaseline is idempotent — safe to ensure the template on every
  # create; the revert seam then materialises + starts the instance. We drive
  # the per-INSTANCE seam (revertToBaselineWithUserData) so a backend that
  # honours cloud-init boots this instance with spec.userData (each ephemeral
  # CI runner carries its own registration token). Backends that do not model
  # cloud-init inherit the seam's default, which ignores userData and behaves
  # exactly like revertToBaseline — so this is behaviour-preserving for them.
  session.backend.provisionBaseline(spec)
  let handle =
    session.backend.revertToBaselineWithUserData(baseline, spec.userData)
  let rec = VmRecord(name: p.name, baseline: baseline,
                     handle: handle, state: vsRunning)
  session.put(rec)
  %*{"vm": toJson(toVmInfo(session, rec))}

proc startVm(session: CrudSession, p: CrudParams): JsonNode =
  var rec = requireRecord(session, p.name)
  if rec.handle != nil and rec.state != vsError:
    # Running (idempotent) or stopped by the hypervisor with the instance
    # still defined: ask the backend to (re)start it and wait for readiness.
    session.backend.startAndAwaitReady(rec.handle)
  else:
    # Stopped via stop_vm (handle released), or the instance vanished behind
    # our back (state error): re-materialise it from the template.
    rec.handle = session.backend.revertToBaseline(rec.baseline)
  rec.state = vsRunning
  session.put(rec)
  %*{"vm": toJson(toVmInfo(session, rec))}

proc stopVm(session: CrudSession, p: CrudParams): JsonNode =
  var rec = requireRecord(session, p.name)
  if rec.handle != nil:
    session.backend.stopAndCleanup(rec.handle, deleteVm = false)
    rec.handle = nil
  rec.state = vsStopped
  session.put(rec)
  %*{"vm": toJson(toVmInfo(session, rec))}

proc deleteVm(session: CrudSession, p: CrudParams): JsonNode =
  let rec = requireRecord(session, p.name)
  if rec.handle != nil:
    session.backend.stopAndCleanup(rec.handle, deleteVm = true)
  session.drop(p.name)
  %*{"name": p.name, "deleted": true, "state": $vsStopped}

proc getVm(session: CrudSession, p: CrudParams): JsonNode =
  let rec = requireRecord(session, p.name)
  %*{"vm": toJson(toVmInfo(session, rec))}

proc listVms(session: CrudSession, p: CrudParams): JsonNode =
  var arr = newJArray()
  for rec in session.allRecords():
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
  var lock: CrudLock
  try:
    if session.store != nil and verb != "list_vms" and verb in CrudVerbs and
       p.name.len > 0:
      # One writer per VM across processes (§8.6). list_vms reads the
      # atomically-replaced records without a lock.
      lock = session.store.lockVm($session.backend.id, p.name,
                                  session.lockTimeoutSec)
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
  except CrudNameError as e:
    return CrudResponse(
      exitCode: exitCode(cekBadArgs),
      json: %*{"ok": false, "verb": verb,
               "error": {"code": exitCode(cekBadArgs), "kind": $cekBadArgs,
                         "message": e.msg}})
  except CrudBusyError as e:
    return CrudResponse(
      exitCode: exitCode(cekBackendError),
      json: %*{"ok": false, "verb": verb,
               "error": {"code": exitCode(cekBackendError),
                         "kind": $cekBackendError, "message": e.msg}})
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
  finally:
    release(lock)
  CrudResponse(
    exitCode: 0,
    json: %*{"ok": true, "verb": verb, "data": data})
