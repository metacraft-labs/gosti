# SPDX-FileCopyrightText: 2026 Metacraft Labs / Schelling Point Labs
# SPDX-License-Identifier: Apache-2.0
## MockBackend — a full, deterministic, in-memory ``VmBackend`` (GOSTI2 PR-2).
##
## PR-1 pinned the generic-CRUD *contract* (JSON envelope + frozen exit codes)
## by driving every verb through the minimal ``NoopBackend`` — a call-recording
## fixture that performs no real work and models no VM state. PR-2 promotes the
## mock story to a FULL, deterministic backend so the WHOLE contract is richly
## exercisable offline: a real lifecycle state machine, snapshots that persist
## within a session and can be listed/restored, and canned-but-consistent
## ``VmInfo`` / ``SshEndpoint`` / ``ExecResult`` data.
##
## This is what later hermetic tests and the future ``ah-vm`` Rust binding's
## integration tests lean on: a backend that behaves like a real hypervisor's
## *observable* contract (state transitions, snapshot persistence, guest
## filesystem) without a hypervisor, a network, or a subprocess in sight.
##
## Relationship to ``NoopBackend`` (why a SEPARATE backend, not an enrichment):
## ``NoopBackend`` is deliberately a minimal scaffolding fixture (design doc
## §9.1) whose exact behaviour several existing e2e gates depend on (fresh
## per-revert instance names, always-exit-0 exec, no state machine). MockBackend
## is purely additive — it leaves every existing backend and every existing gate
## untouched and models a richer, deterministic contract on the side.
##
## Determinism guarantees (the properties the gate asserts):
##
## - Instance names are a PURE function of the baseline (``mock-vm-<baseline>``),
##   not wall-clock — so a create→delete→create round-trip is reproducible and a
##   gate can address the instance without capturing a random name.
## - ``execInGuest`` returns a result that is a pure function of its ``argv`` and
##   ``env`` (a canned ``mock-exec: <cmd>`` echo, exit 0, fixed ``elapsedMs``).
## - ``ssh_endpoint`` is a fixed host/port/user/auth for every running instance.
## - Snapshots persist in-process, are listed in creation order, and capture the
##   guest filesystem at snapshot time; ``restoreSnapshot`` rolls the guest
##   filesystem back to that captured state — so a
##   copy→snapshot→copy→restore→copy_from round-trip is internally consistent.
##
## State machine (as applicable to the ``VmBackend`` methods that exist):
##
##     provisionBaseline        registers a template (no instance yet)
##     revertToBaseline         Stopped → Starting → Running   (materialise)
##     startAndAwaitReady       Starting → Running (idempotent when Running)
##     stopAndCleanup           Running → Stopped               (never raises)
##
## ``mvsPaused`` / ``mvsError`` are modelled in the enum for wire-parity with the
## façade's ``VmState`` but are NOT reachable through any ``VmBackend`` method
## (the concept has no pause verb, and every categorised failure is raised, not
## parked in a state) — they exist so a future suspend/resume primitive has a
## home without a type change. This is documented rather than faked.
##
## Registration: MockBackend deliberately does NOT register itself in
## ``auto.factoryRegistry``, so it is never advertised (serve ``/v1/info``, the
## capability manifest) and never auto-selected. It is reachable two ways:
##
## - in-process, as the PR-2 gates do: ``newMockBackend()`` wrapped in a
##   ``CrudSession``. Its ``id`` defaults to ``biNoop`` there, so those
##   envelopes report ``"backend": "noop"`` as they always have;
## - from the CLI, only when a caller names ``--backend mock``: the CLI builds
##   it as ``newMockBackend(biMock)`` and, for ``crud`` verbs, switches it to
##   FILE-BACKED mode (``attachStateFile``) so the fleet persists across
##   invocations. That is the hermetic-consumer fixture of design doc §8.6,
##   together with its fault injection (``VMH_MOCK_FAIL`` /
##   ``VMH_MOCK_UNAVAILABLE``).

import std/[algorithm, json, options, os, strutils, tables]
import ../types

type
  MockVmState* = enum
    ## Lifecycle state of one mock instance. String values mirror the façade's
    ## wire tokens so a gate can compare against the CRUD JSON directly.
    mvsStopped = "stopped"
    mvsStarting = "starting"
    mvsRunning = "running"
    mvsPaused = "paused"      ## reserved; not reachable via any VmBackend method
    mvsError = "error"        ## reserved; not reachable via any VmBackend method

  MockSnapshot = object
    ## One persisted snapshot: an opaque id plus the guest filesystem captured
    ## at snapshot time (so restore can roll the guest back deterministically).
    id: string
    guestFs: Table[string, string]

  MockVm = ref object
    ## One instance in the in-memory fleet, keyed in ``MockBackend.vms`` by its
    ## deterministic instance name.
    name: string
    baseline: string
    state: MockVmState
    guestFs: Table[string, string]          ## guest path → file contents
    snapshots: OrderedTable[string, MockSnapshot] ## name → snapshot (ordered)
    transitions: seq[MockVmState]            ## ordered state-transition log

  MockBackend* = ref object of VmBackend
    ## A full deterministic in-memory backend. All state lives in these tables;
    ## nothing touches a hypervisor, the network, or a subprocess.
    baselines: Table[string, BaselineSpec]   ## provisioned templates
    vms: Table[string, MockVm]               ## instance name → instance
    calls*: seq[string]                      ## chronological method-call log
    provisionSpecs*: seq[BaselineSpec]       ## PR-3: every spec provisionBaseline
                                             ## received, in order — so a gate can
                                             ## assert --user-data/--mount/
                                             ## --ssh-user reached the create path.
    execArgvLog*: seq[seq[string]]           ## PR-3: the exact argv every
                                             ## execInGuest received (AFTER the
                                             ## CRUD-layer --cwd/--run-as/--timeout
                                             ## wrap) — so a gate can assert the
                                             ## produced wrapper argv verbatim.
    stateFile*: string                       ## file-backed mode (design doc §8.6):
                                             ## when non-empty, the whole fleet is
                                             ## loaded from / saved to this file so
                                             ## one ``vm-harness crud`` process per
                                             ## verb sees one consistent fleet.

# ---------------------------------------------------------------------------
# Canned, stable guest-reachability data. These are constants on purpose: the
# whole point of the mock is that ``ssh_endpoint`` never varies.

const
  MockSshHost* = "10.0.2.15"
  MockSshPort* = 22
  MockSshUser* = "mock"
  MockSshKeyPath* = "/mock/.ssh/id_ed25519"
  MockExecElapsedMs* = 5

proc instanceName*(baseline: string): string =
  ## The deterministic instance name a given baseline materialises to. Exposed
  ## so a gate can address the instance (for snapshot / introspection) without
  ## having to capture the name returned by ``revertToBaseline``.
  "mock-vm-" & baseline

proc newMockBackend*(id = biNoop): MockBackend =
  ## Construct a fresh, empty mock backend. No temp dirs, no I/O — a MockBackend
  ## is self-contained in-memory state until ``attachStateFile`` is called.
  ##
  ## ``id`` defaults to ``biNoop`` (the in-process gates' historical tag, see
  ## the module header). The CLI constructs it as ``biMock`` for
  ## ``--backend mock`` so the envelope and the crud store say ``"mock"``.
  MockBackend(
    id: id,
    hostPlatform: detectHostPlatform(),
    supportedGuests: {goLinux, goWindows, goMacos},
    baselines: initTable[string, BaselineSpec](),
    vms: initTable[string, MockVm](),
    calls: @[],
    provisionSpecs: @[],
    execArgvLog: @[])

# ---------------------------------------------------------------------------
# Public introspection surface. A hermetic gate asserts the finer state-machine
# transitions (which the CRUD JSON, only surfacing running/stopped, cannot
# show) through these read-only accessors.

proc vmState*(b: MockBackend, instance: string): MockVmState =
  ## Current state of the named instance. Raises if it does not exist.
  if instance notin b.vms:
    raise newException(KeyError, "no mock instance named '" & instance & "'")
  b.vms[instance].state

proc transitionLog*(b: MockBackend, instance: string): seq[MockVmState] =
  ## The ordered list of states the instance has passed through. Lets a gate
  ## assert Stopped → Starting → Running rather than only the endpoint state.
  if instance notin b.vms:
    raise newException(KeyError, "no mock instance named '" & instance & "'")
  b.vms[instance].transitions

proc guestFileExists*(b: MockBackend, instance, guestPath: string): bool =
  ## True when the (in-memory) guest filesystem currently holds ``guestPath``.
  instance in b.vms and guestPath in b.vms[instance].guestFs

proc isProvisioned*(b: MockBackend, baseline: string): bool =
  baseline in b.baselines

proc liveInstances*(b: MockBackend): seq[string] =
  ## Instance names currently registered (in any state). Deterministic order is
  ## not guaranteed (Table iteration); sort in the gate if order matters.
  for name in b.vms.keys:
    result.add(name)

# ---------------------------------------------------------------------------
# Internal helpers.

proc transitionTo(vm: MockVm, s: MockVmState) =
  vm.state = s
  vm.transitions.add(s)

# ---------------------------------------------------------------------------
# File-backed mode (design doc §8.6). The fleet is one JSON document; every
# mutating method rewrites it (write-then-rename). The CLI holds a
# backend-wide crud-store lock around each invocation, so read-modify-write
# is not racy between concurrent ``vm-harness crud`` processes.

const MockFleetSchema* = "vm-harness/mock-fleet/1"

proc fsToJson(fs: Table[string, string]): JsonNode =
  result = newJObject()
  var keys: seq[string]
  for k in fs.keys: keys.add(k)
  keys.sort()
  for k in keys: result[k] = %fs[k]

proc fsFromJson(n: JsonNode): Table[string, string] =
  result = initTable[string, string]()
  if n != nil and n.kind == JObject:
    for k, v in n: result[k] = v.getStr("")

proc fleetToJson(b: MockBackend): JsonNode =
  var baselines: seq[string]
  for name in b.baselines.keys: baselines.add(name)
  baselines.sort()
  var names: seq[string]
  for name in b.vms.keys: names.add(name)
  names.sort()
  var vms = newJArray()
  for name in names:
    let vm = b.vms[name]
    var snaps = newJArray()
    for sname, snap in vm.snapshots:
      snaps.add(%*{"name": sname, "id": snap.id, "guestFs": fsToJson(snap.guestFs)})
    var trans = newJArray()
    for t in vm.transitions: trans.add(%($t))
    vms.add(%*{"name": vm.name, "baseline": vm.baseline, "state": $vm.state,
                "guestFs": fsToJson(vm.guestFs), "snapshots": snaps,
                "transitions": trans})
  %*{"schema": MockFleetSchema, "baselines": baselines, "vms": vms}

proc parseMockState(s: string): MockVmState =
  for st in MockVmState:
    if $st == s: return st
  mvsError

proc loadFleet(b: MockBackend, doc: JsonNode) =
  b.baselines = initTable[string, BaselineSpec]()
  for n in doc{"baselines"}.getElems():
    b.baselines[n.getStr] = BaselineSpec(name: n.getStr)
  b.vms = initTable[string, MockVm]()
  for v in doc{"vms"}.getElems():
    var vm = MockVm(name: v{"name"}.getStr, baseline: v{"baseline"}.getStr,
                    state: parseMockState(v{"state"}.getStr),
                    guestFs: fsFromJson(v{"guestFs"}),
                    snapshots: initOrderedTable[string, MockSnapshot](),
                    transitions: @[])
    for sn in v{"snapshots"}.getElems():
      vm.snapshots[sn{"name"}.getStr] =
        MockSnapshot(id: sn{"id"}.getStr, guestFs: fsFromJson(sn{"guestFs"}))
    for t in v{"transitions"}.getElems():
      vm.transitions.add(parseMockState(t.getStr))
    b.vms[vm.name] = vm

proc persist(b: MockBackend) =
  ## No-op in in-memory mode.
  if b.stateFile.len == 0: return
  createDir(b.stateFile.parentDir)
  let tmp = b.stateFile & ".tmp." & $getCurrentProcessId()
  writeFile(tmp, b.fleetToJson.pretty & "\n")
  moveFile(tmp, b.stateFile)

proc attachStateFile*(b: MockBackend, path: string) =
  ## Switch to file-backed mode: load the fleet from ``path`` if it exists
  ## (an empty fleet otherwise) and save every later mutation there.
  b.stateFile = path
  if fileExists(path):
    b.loadFleet(parseFile(path))

# ---------------------------------------------------------------------------
# Fault injection, for consumers testing their error mapping (design doc
# §8.6): ``VMH_MOCK_FAIL=<op>[,<op>…]`` makes the named operations raise a
# categorised backend failure (→ ``backend-error``, exit 5), and
# ``VMH_MOCK_UNAVAILABLE=1`` makes the backend unavailable (→ exit 4).

const
  MockFailEnv* = "VMH_MOCK_FAIL"
  MockUnavailableEnv* = "VMH_MOCK_UNAVAILABLE"

proc mockUnavailable*(): bool =
  getEnv(MockUnavailableEnv).len > 0 and getEnv(MockUnavailableEnv) != "0"

proc injectFault(b: MockBackend, op: string, phase: LifecyclePhase) =
  let spec = getEnv(MockFailEnv)
  if spec.len == 0: return
  for want in spec.split(','):
    if want.strip() == op:
      raise newVmHarnessError($b.id, phase,
        "injected failure (" & MockFailEnv & "=" & op & ")")

# ---------------------------------------------------------------------------
# Lifecycle methods.

method probeAvailability*(b: MockBackend): bool =
  b.calls.add("probeAvailability")
  not mockUnavailable()

method provisionBaseline*(b: MockBackend, spec: BaselineSpec) =
  ## Idempotent: register the template if absent. No instance is created here
  ## (mirrors the real backends — provision builds a template, revert boots it).
  b.calls.add("provisionBaseline:" & spec.name)
  b.provisionSpecs.add(spec)   ## PR-3: record every spec so a gate can assert
                               ## the create options (--user-data/--mount/
                               ## --ssh-user) flowed through unchanged.
  b.injectFault("provision", lpProvisioning)
  if spec.name notin b.baselines:
    b.baselines[spec.name] = spec
  b.persist()

method revertToBaseline*(b: MockBackend, baselineName: string): VmHandle =
  ## Materialise (or re-materialise) the instance for ``baselineName`` and boot
  ## it: Stopped → Starting → Running. Requires a provisioned baseline.
  b.calls.add("revertToBaseline:" & baselineName)
  b.injectFault("revert", lpRevert)
  if baselineName notin b.baselines:
    raise newVmHarnessError($b.id, lpRevert,
      "Baseline '" & baselineName & "' was never provisioned")
  let name = instanceName(baselineName)
  var vm =
    if name in b.vms:
      b.vms[name]
    else:
      MockVm(name: name, baseline: baselineName, state: mvsStopped,
             guestFs: initTable[string, string](),
             snapshots: initOrderedTable[string, MockSnapshot](),
             transitions: @[mvsStopped])
  transitionTo(vm, mvsStarting)
  transitionTo(vm, mvsRunning)
  b.vms[name] = vm
  b.persist()
  VmHandle(
    backend: b,
    name: name,
    baseline: baselineName,
    ipAddress: some(MockSshHost),
    sshPort: MockSshPort,
    sshUser: MockSshUser,
    sshAuth: SshAuth(kind: saKeyFile, keyPath: MockSshKeyPath),
    extra: initTable[string, string]())

method startAndAwaitReady*(b: MockBackend, vm: VmHandle, timeoutSec: int = 120) =
  ## Idempotent readiness poll. A Running instance stays Running; anything else
  ## transitions Starting → Running.
  b.calls.add("startAndAwaitReady:" & vm.name)
  if vm.name notin b.vms:
    raise newVmHarnessError($b.id, lpStartup,
      "startAndAwaitReady: unknown instance '" & vm.name & "'")
  b.injectFault("start", lpStartup)
  let inst = b.vms[vm.name]
  if inst.state != mvsRunning:
    transitionTo(inst, mvsStarting)
    transitionTo(inst, mvsRunning)
  b.persist()

method execInGuest*(b: MockBackend, vm: VmHandle,
                   env: Table[string, string],
                   cmd: seq[string],
                   stdin: string = "",
                   timeoutSec: int = 600): ExecResult =
  ## Deterministic echo: stdout is a pure function of the command (and any env
  ## keys, sorted for reproducibility). Requires a running instance.
  b.calls.add("execInGuest:" & cmd.join(" "))
  b.execArgvLog.add(cmd)   ## PR-3: capture the exact (wrapped) argv verbatim.
  b.injectFault("exec", lpExec)
  if vm.name notin b.vms or b.vms[vm.name].state != mvsRunning:
    raise newVmHarnessError($b.id, lpExec,
      "execInGuest: instance '" & vm.name & "' is not running")
  var envPart = ""
  if env.len > 0:
    var keys: seq[string]
    for k in env.keys: keys.add(k)
    keys.sort()
    var parts: seq[string]
    for k in keys: parts.add(k & "=" & env[k])
    envPart = "[" & parts.join(" ") & "] "
  ExecResult(
    exitCode: 0,
    stdout: "mock-exec: " & envPart & cmd.join(" ") & "\n",
    stderr: "",
    elapsedMs: MockExecElapsedMs)

method copyToGuest*(b: MockBackend, vm: VmHandle,
                   hostPath: string, guestPath: string) =
  ## Read the real host file into the in-memory guest filesystem. The guest side
  ## is pure memory; the host side is a genuine read so a gate can round-trip a
  ## real file (matching how ``t_crud_facade`` exercises copy).
  b.calls.add("copyToGuest:" & hostPath & "->" & guestPath)
  b.injectFault("copy", lpCopy)
  if vm.name notin b.vms or b.vms[vm.name].state != mvsRunning:
    raise newVmHarnessError($b.id, lpCopy,
      "copyToGuest: instance '" & vm.name & "' is not running")
  if not fileExists(hostPath):
    raise newVmHarnessError($b.id, lpCopy, "Source path not found: " & hostPath)
  b.vms[vm.name].guestFs[guestPath] = readFile(hostPath)
  b.persist()

method copyFromGuest*(b: MockBackend, vm: VmHandle,
                     guestPath: string, hostPath: string) =
  ## Write an in-memory guest file back out to a real host path.
  b.calls.add("copyFromGuest:" & guestPath & "->" & hostPath)
  b.injectFault("copy", lpCopy)
  if vm.name notin b.vms or b.vms[vm.name].state != mvsRunning:
    raise newVmHarnessError($b.id, lpCopy,
      "copyFromGuest: instance '" & vm.name & "' is not running")
  if guestPath notin b.vms[vm.name].guestFs:
    raise newVmHarnessError($b.id, lpCopy, "Guest path not found: " & guestPath)
  writeFile(hostPath, b.vms[vm.name].guestFs[guestPath])

method installArgvTraceShim*(b: MockBackend, vm: VmHandle, shim: ArgvTraceShim) =
  ## Model the shim by seeding an (empty) trace-log file in the guest fs.
  b.calls.add("installArgvTraceShim:" & shim.wrappedBinaryName)
  if vm.name in b.vms:
    b.vms[vm.name].guestFs[shim.traceLogPath] = ""
    b.persist()

method uninstallArgvTraceShim*(b: MockBackend, vm: VmHandle,
                              wrappedBinaryName: string) =
  b.calls.add("uninstallArgvTraceShim:" & wrappedBinaryName)

method stopAndCleanup*(b: MockBackend, vm: VmHandle, deleteVm: bool = true) =
  ## Running → Stopped. When ``deleteVm`` the instance is forgotten entirely.
  ## Per the base contract this method NEVER raises and is re-entrant.
  try:
    b.calls.add("stopAndCleanup:" & vm.name & (if deleteVm: ":delete" else: ""))
    if vm.name in b.vms:
      let inst = b.vms[vm.name]
      if inst.state != mvsStopped:
        transitionTo(inst, mvsStopped)
      if deleteVm:
        b.vms.del(vm.name)
    b.persist()
  except CatchableError:
    discard

# ---------------------------------------------------------------------------
# Snapshot store. Snapshots persist for the life of the backend (a session),
# are addressed by the instance name (matching how the façade calls them with
# ``VmHandle.name``), and capture the guest filesystem so restore is meaningful.

proc requireInstance(b: MockBackend, vmName, op: string): MockVm =
  if vmName notin b.vms:
    raise newVmHarnessError($b.id, lpProvisioning,
      op & ": unknown instance '" & vmName & "'")
  b.vms[vmName]

method snapshot*(b: MockBackend, vmName: string, snapshotName: string): string =
  b.calls.add("snapshot:" & vmName & ":" & snapshotName)
  b.injectFault("snapshot", lpProvisioning)
  let inst = requireInstance(b, vmName, "snapshot")
  if snapshotName in inst.snapshots:
    raise newVmHarnessError($b.id, lpProvisioning,
      "snapshot '" & snapshotName & "' already exists for VM '" & vmName & "'")
  # Capture the guest filesystem at snapshot time (a copy, so later mutations to
  # the live fs do not leak into the stored snapshot).
  var captured = initTable[string, string]()
  for path, content in inst.guestFs:
    captured[path] = content
  let id = vmName & "@" & snapshotName
  inst.snapshots[snapshotName] = MockSnapshot(id: id, guestFs: captured)
  b.persist()
  id

method restoreSnapshot*(b: MockBackend, vmName: string, snapshotName: string) =
  b.calls.add("restoreSnapshot:" & vmName & ":" & snapshotName)
  b.injectFault("restore", lpRevert)
  let inst = requireInstance(b, vmName, "restoreSnapshot")
  if snapshotName notin inst.snapshots:
    raise newVmHarnessError($b.id, lpRevert,
      "snapshot '" & snapshotName & "' not found for VM '" & vmName & "'")
  # Roll the guest filesystem back to the captured state (a copy again).
  var restored = initTable[string, string]()
  for path, content in inst.snapshots[snapshotName].guestFs:
    restored[path] = content
  inst.guestFs = restored
  b.persist()

method listSnapshots*(b: MockBackend, vmName: string): seq[string] =
  b.calls.add("listSnapshots:" & vmName)
  if vmName notin b.vms: return @[]
  for name in b.vms[vmName].snapshots.keys:
    result.add(name)

method removeSnapshot*(b: MockBackend, vmName, snapshotName: string) =
  ## Idempotent: removing a missing snapshot is a no-op, per the base contract.
  b.calls.add("removeSnapshot:" & vmName & ":" & snapshotName)
  if vmName in b.vms and snapshotName in b.vms[vmName].snapshots:
    b.vms[vmName].snapshots.del(snapshotName)
    b.persist()

method snapshotRunning*(b: MockBackend, vmName, snapshotName: string): string =
  ## Memory-state variant. For the mock there is no distinct RAM image to
  ## capture, so it behaves like ``snapshot`` but is logged separately so a gate
  ## can verify the façade/orchestrator dispatched to the right method.
  b.calls.add("snapshotRunning:" & vmName & ":" & snapshotName)
  let inst = requireInstance(b, vmName, "snapshotRunning")
  if snapshotName in inst.snapshots:
    raise newVmHarnessError($b.id, lpProvisioning,
      "snapshot '" & snapshotName & "' already exists for VM '" & vmName & "'")
  var captured = initTable[string, string]()
  for path, content in inst.guestFs:
    captured[path] = content
  let id = vmName & "@" & snapshotName
  inst.snapshots[snapshotName] = MockSnapshot(id: id, guestFs: captured)
  b.persist()
  id

method instancePresence*(b: MockBackend, vm: VmHandle): InstancePresence =
  ## The mock's own fleet is the "hypervisor": an instance absent from it is
  ## gone (e.g. deleted from the fleet file behind the crud store's back).
  if vm.name notin b.vms: return ipGone
  case b.vms[vm.name].state
  of mvsRunning, mvsStarting, mvsPaused: ipRunning
  of mvsStopped: ipStopped
  of mvsError: ipUnknown
