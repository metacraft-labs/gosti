# SPDX-FileCopyrightText: 2026 Metacraft Labs / Schelling Point Labs
# SPDX-License-Identifier: Apache-2.0
## Incus backend — ephemeral per-job Linux SYSTEM CONTAINERS.
##
## This is the container-based analog of the libvirt backend (which runs
## per-job Windows/Linux VMs on KVM). Incus system containers launch in
## well under a second and cost a fraction of a VM, so the ephemeral loop
## (fresh container per job → run one job → destroy) is far cheaper than
## the libvirt path. Plain containers need no ``/dev/kvm``; a trusted host
## controller may explicitly attach it for a nested-virtualisation class.
##
## The backend is a thin adapter around the ``incus`` CLI. Command map
## (one CLI verb per VmBackend method):
##
##   probeAvailability        ``incus info``
##   provisionBaseline        ``incus image list <alias>`` (ensure present)
##   provisionEphemeralClone  default ``incus launch <base> <name>`` (+
##                            optional ``--ephemeral`` and raw ``incus config
##                            set`` keys); operator capabilities instead use
##                            ``incus init`` → fixed config/device → ``incus
##                            start``. The runner bootstrap payload is
##                            delivered + launched over ``incus exec`` after
##                            readiness (``injectAndRunBootstrap``), NOT via
##                            cloud-init.
##   startAndAwaitReady       poll ``incus exec <name> -- true`` until it
##                            succeeds (container Running + init up)
##   execInGuest              ``incus exec <name> -- <cmd>``
##   copyToGuest              ``incus file push <host> <name>/<guest>``
##   copyFromGuest            ``incus file pull <name>/<guest> <host>``
##   stopAndCleanup           ``incus delete --force <name>``  (no residue —
##                            the per-container storage volume goes with it)
##
## Snapshot methods map onto ``incus snapshot`` / ``incus restore`` /
## ``incus delete <name>/<snap>``.
##
## *Socket access:* the ``incus`` CLI talks to ``/var/lib/incus/unix.socket``,
## which is group ``incus-admin``. In production the service/runner user is
## in that group (declared in the host's NixOS config) so a plain ``incus``
## invocation works. When the current login session pre-dates the group
## grant (or in a sandbox), export ``VMH_INCUS_CMD="sudo -n incus"`` and the
## backend prefixes every call with it. The command vector is configurable
## via ``newIncusBackend(incusCmd = ...)`` for tests.
##
## *Compile-time portability:* like the other backends this module compiles
## on any host so the small unit tests can run anywhere; ``probeAvailability``
## returns false on non-Linux hosts / when ``incus`` is absent.

import std/[options, os, osproc, streams, strtabs,
            strutils, tables, times]
import ../types
import ../auto
import ../ephemeral_inventory

# ---------------------------------------------------------------------------
# Backend type.

type
  IncusBackend* = ref object of VmBackend
    ## Adapter around the ``incus`` CLI.
    incusCmd*: seq[string]
      ## The command vector used to invoke incus, e.g. ``@["incus"]`` or
      ## ``@["sudo", "incus"]``. Defaults to ``@["incus"]``; overridden by
      ## the ``VMH_INCUS_CMD`` env var (space-split) when set.
    baseImage*: string
      ## Default base image alias/fingerprint used by
      ## ``provisionEphemeralClone`` when the spec doesn't override it.
      ## Defaults to ``vmh-base``.
    storagePool*: string
      ## Storage pool the ephemeral containers land in (used by the
      ## no-residual-volume assertion). Defaults to ``default``.
    execUser*: string
      ## User the in-guest ``incus exec`` runs as. Empty ⇒ incus default
      ## (root). Kept for parity with the SSH-user seam on other backends.
    readyTimeoutSec*: int
      ## How long ``startAndAwaitReady`` polls for ``incus exec -- true``.

  EphemeralIncusSpec* = object
    ## Inputs for one per-job ephemeral container.
    name*: string          ## container name (must be unique per job)
    baseImage*: string     ## base image alias/fingerprint to launch
                           ## from; empty ⇒ backend default ``baseImage``
    ephemeral*: bool       ## pass ``--ephemeral`` to ``incus launch``
                           ## so the daemon auto-removes the container
                           ## on stop (defence in depth; explicit
                           ## ``delete --force`` in stopAndCleanup is
                           ## still the reliable teardown)
    profiles*: seq[string] ## optional profiles (``--profile p``); empty
                           ## ⇒ the ``default`` profile
    userData*: string      ## optional bootstrap payload (GARM's rendered
                           ## runner registration script). NOTE: on incus
                           ## this is NOT consumed via cloud-init — the
                           ## guest API is served on ``/dev/incus/sock``
                           ## while a cloud-init built for LXD probes
                           ## ``/dev/lxd/sock``, so its datasource never
                           ## initialises and injected user-data is never
                           ## executed. The payload is instead delivered +
                           ## launched DETACHED via ``incus exec`` once the
                           ## container is exec-ready (see
                           ## ``injectAndRunBootstrap``). This field carries
                           ## the payload; the CLI drives the exec-injection.
    config*: Table[string, string]
      ## optional raw ``incus config set`` keys
      ## (e.g. ``security.nesting`` ,
      ## ``cloud-init.vendor-data``). Callers are trusted host-side
      ## controllers; guest input is never interpreted as config keys.
    securityNesting*: bool
      ## Operator-controlled nested-container capability. When true, the
      ## container is initialised STOPPED, then receives security.nesting and
      ## the mknod/setxattr syscall intercepts before its first start.
    nestedKvm*: bool
      ## Operator-controlled nested-virtualisation capability. When true, the
      ## container is initialised STOPPED, security.nesting is enabled, and a
      ## fixed /dev/kvm unix-char device is attached before its first start.
      ## The device path/type/mode are not caller-selectable.

const
  DefaultIncusBaseImage* = "vmh-base"
  DefaultIncusStoragePool* = "default"
  DefaultIncusReadyTimeoutSec* = 60
  IncusBootstrapGuestPath* = "/root/garm-bootstrap.sh"
    ## In-guest path the bootstrap payload is delivered to (root-only, 0700).
  IncusBootstrapLogPath* = "/var/log/garm-bootstrap.log"
    ## In-guest log the detached bootstrap's stdout/stderr is redirected to;
    ## deliberately NOT streamed back (the runner foregrounds and never ends).

proc resolveIncusCmd(incusCmd: seq[string]): seq[string] =
  ## Honour the ``VMH_INCUS_CMD`` env var (space-split) when the caller
  ## left the default. Lets the gate run under ``sudo incus`` in a session
  ## that pre-dates the ``incus-admin`` group grant without changing the
  ## production registration (plain ``incus``).
  if incusCmd != @["incus"]:
    return incusCmd
  let envCmd = getEnv("VMH_INCUS_CMD")
  if envCmd.len > 0:
    return envCmd.splitWhitespace()
  return incusCmd

proc newIncusBackend*(incusCmd: seq[string] = @["incus"],
                      baseImage: string = DefaultIncusBaseImage,
                      storagePool: string = DefaultIncusStoragePool,
                      execUser: string = "",
                      readyTimeoutSec: int =
                        DefaultIncusReadyTimeoutSec): IncusBackend =
  ## Construct an IncusBackend. Defaults match the host layout: the
  ## ``vmh-base`` Debian image, the ``default`` storage pool, ``incus`` on
  ## PATH (overridable via ``VMH_INCUS_CMD``).
  result = IncusBackend(
    id: biIncus,
    hostPlatform: detectHostPlatform(),
    supportedGuests: {goLinux},
    incusCmd: resolveIncusCmd(incusCmd),
    baseImage: baseImage,
    storagePool: storagePool,
    execUser: execUser,
    readyTimeoutSec: readyTimeoutSec)

# ---------------------------------------------------------------------------
# Process invocation helper. Mirrors ``runProcessCapture`` in the other
# backend modules (standalone so this slice doesn't drag their deps).

proc runProcessCapture(cmd: seq[string], cwd: string = "",
                       timeoutSec: int = 0,
                       env: Table[string, string] = initTable[string, string](),
                       stdinData: string = ""): ExecResult =
  if cmd.len == 0:
    raise newException(ValueError, "runProcessCapture: empty cmd")
  let start = epochTime()
  var procEnv: StringTableRef = nil
  if env.len > 0:
    procEnv = newStringTable(modeStyleInsensitive)
    for k, v in env:
      procEnv[k] = v
  var p = startProcess(cmd[0], workingDir = cwd, args = cmd[1 .. ^1],
                       env = procEnv,
                       options = {poUsePath, poStdErrToStdOut})
  defer: p.close()
  # ALWAYS close the child's stdin (after writing any stdinData). Nim's
  # startProcess hands the child a stdin PIPE whose write end stays open until
  # we close it; leaving it open makes any tool that slurps an optional config
  # from a non-tty stdin block forever on EOF. ``incus create``/``launch`` does
  # exactly this — ``cmd/incus/create.go`` calls ``io.ReadAll(os.Stdin)`` when
  # stdin is not a terminal — so an un-closed stdin wedges every launch
  # indefinitely (the read loop below then never sees the deadline because the
  # blocking read never returns). Closing stdin gives the child immediate EOF.
  block:
    let s = p.inputStream
    if s != nil:
      try:
        if stdinData.len > 0:
          s.write(stdinData)
        s.close()
      except CatchableError: discard
  let outStream = p.outputStream
  var stdout = ""
  let deadline = if timeoutSec > 0: epochTime() + timeoutSec.float else: 0.0
  while true:
    var chunk = newString(4096)
    let n = outStream.readData(addr chunk[0], chunk.len)
    if n > 0:
      chunk.setLen(n)
      stdout.add(chunk)
    elif n == 0:
      if not p.running:
        break
      if timeoutSec > 0 and epochTime() > deadline:
        p.terminate()
        return ExecResult(
          exitCode: -1,
          stdout: stdout,
          stderr: "vm-harness: process timed out after " & $timeoutSec & "s",
          elapsedMs: int((epochTime() - start) * 1000))
      sleep(50)
  let code = p.waitForExit(timeout = -1)
  ExecResult(
    exitCode: code,
    stdout: stdout,
    stderr: "",
    elapsedMs: int((epochTime() - start) * 1000))

# ---------------------------------------------------------------------------
# incus CLI primitives.

proc incusArgs(b: IncusBackend, sub: openArray[string]): seq[string] =
  ## Build a full ``<incusCmd...> <sub...>`` invocation.
  result = b.incusCmd
  for s in sub: result.add(s)

proc runIncus*(b: IncusBackend, sub: openArray[string],
               timeoutSec: int = 120,
               env: Table[string, string] = initTable[string, string](),
               stdinData: string = ""): ExecResult =
  runProcessCapture(b.incusArgs(sub), timeoutSec = timeoutSec,
                    env = env, stdinData = stdinData)

proc containerExists*(b: IncusBackend, name: string): bool =
  ## ``incus info <name>`` exits 0 iff the container is defined.
  let r = b.runIncus(@["info", name], timeoutSec = 30)
  r.exitCode == 0

proc listContainerNames*(b: IncusBackend): seq[string] =
  ## ``incus list --format csv -c n`` — every container the daemon knows
  ## about (running or stopped). Used by the ephemeral gate to assert NO
  ## residual per-job container survives teardown. Returns an empty seq on
  ## error. NOTE: this lists ALL containers on the host — callers assert
  ## only on their OWN job names, never on unrelated production containers.
  let r = b.runIncus(@["list", "--format", "csv", "-c", "n"], timeoutSec = 30)
  if r.exitCode != 0:
    return @[]
  for line in r.stdout.splitLines():
    let s = line.strip()
    if s.len > 0:
      result.add(s)

proc containerState*(b: IncusBackend, name: string): string =
  ## ``incus list <name> --format csv -c s`` — the RUNNING/STOPPED status
  ## string, or "" when the container doesn't exist.
  let r = b.runIncus(@["list", name, "--format", "csv", "-c", "s"],
                     timeoutSec = 30)
  if r.exitCode != 0:
    return ""
  result = r.stdout.strip()

proc storageVolumeExists*(b: IncusBackend, name: string): bool =
  ## Whether a ``container/<name>`` storage volume still exists on the
  ## backend's pool. After ``incus delete --force`` the per-container
  ## volume must be gone — the ephemeral gate's no-residue assertion.
  let r = b.runIncus(@["storage", "volume", "list", b.storagePool,
                       "--format", "csv"], timeoutSec = 30)
  if r.exitCode != 0:
    return false
  for line in r.stdout.splitLines():
    let cols = line.split(',')
    # Rows look like: ``container,<name>,,filesystem,<usedby>``.
    if cols.len >= 2 and cols[0].strip() == "container" and
       cols[1].strip() == name:
      return true
  false

const
  DefaultDestroyBudgetSec* = 240
    ## How long ``destroyContainerVerified`` keeps retrying one teardown.
    ## Bounded on purpose: the caller (GARM, through the provider) retries a
    ## FAILED delete with its own backoff, so a long ZFS-busy spell costs a few
    ## failed attempts rather than one request pinning a serve slot for half an
    ## hour. What must never happen is the old behaviour — reporting success.
  IncusDeleteTimeoutSec* = 300
    ## Per-attempt ``incus delete --force`` budget. The previous 60s was below
    ## what a ZFS ``destroy -r`` takes on a loaded pool, and the timeout path
    ## TERMINATED the client mid-delete — after the stop, before the destroy —
    ## which is precisely how a container is left STOPPED.

proc deleteContainer*(b: IncusBackend, name: string): ExecResult =
  ## ``incus delete --force <name>`` — force-stop + delete in one shot.
  ## Idempotent-ish: incus returns non-zero for a missing container, which
  ## the caller treats as already-clean.
  b.runIncus(@["delete", "--force", name], timeoutSec = IncusDeleteTimeoutSec)

proc tryListContainers*(b: IncusBackend): InventoryResult =
  ## Every instance the incus daemon knows about, with its state — or
  ## ``ok = false`` when incus could not answer.
  ##
  ## Unlike ``listContainerNames`` (empty-on-error, fine for a no-residue
  ## ASSERTION) this is safe to act on: a daemon that is down, a socket this
  ## user cannot reach, or a missing ``incus`` binary is "I do not know", and
  ## is reported as such rather than as an empty host.
  var r: ExecResult
  try:
    r = b.runIncus(@["list", "--format", "csv", "-c", "ns"], timeoutSec = 60)
  except CatchableError as err:
    return inventoryFailure("could not run incus: " & err.msg)
  if r.exitCode != 0:
    return inventoryFailure("incus list exited " & $r.exitCode & ": " &
                            r.stdout.strip() & r.stderr.strip())
  try:
    inventorySuccess(parseIncusListCsv(r.stdout))
  except ValueError as err:
    inventoryFailure(err.msg)

proc containerPresent(b: IncusBackend, name: string): bool =
  ## Exact-name presence check that RAISES when incus cannot answer. (``incus
  ## info`` would conflate "absent" with "daemon unreachable", and ``incus list
  ## <name>`` is a prefix filter.)
  let inv = b.tryListContainers()
  if not inv.ok:
    raise newVmHarnessError($b.id, lpCleanup,
      "cannot determine whether container " & name & " exists: " & inv.message)
  for e in inv.entries:
    if e.name == name: return true
  false

proc destroyContainerVerified*(b: IncusBackend, name: string;
                               budgetSec = DefaultDestroyBudgetSec;
                               sleeper: proc (ms: int) = nil) =
  ## Delete ``name`` and PROVE it is gone, retrying transient failures with
  ## backoff. Absence (before or after) is success; anything else that
  ## outlives ``budgetSec`` RAISES, so ``ephemeral-destroy`` exits non-zero and
  ## the caller keeps the instance on its retry list instead of forgetting a
  ## container that still exists.
  ##
  ## ``sleeper`` is injectable so the unit gate can run the backoff schedule
  ## without waiting it out.
  let injected = sleeper != nil
  let doSleep = if injected: sleeper else: (proc (ms: int) = sleep(ms))
  let started = epochTime()
  var sleptMs = 0
  # Time spent = wall clock, plus the backoff an injected sleeper did not
  # really wait (so a test's schedule consumes the budget like production's).
  proc spentSec(): float =
    epochTime() - started + (if injected: sleptMs.float / 1000.0 else: 0.0)
  var delayMs = 2000
  var attempt = 0
  var lastOutput = ""
  while true:
    if not b.containerPresent(name):
      return
    inc attempt
    let r = b.runIncus(@["delete", "--force", name],
                       timeoutSec = IncusDeleteTimeoutSec)
    lastOutput = (r.stdout & r.stderr).strip()
    if r.exitCode == 0 and not b.containerPresent(name):
      return
    let transient = isTransientIncusDeleteError(lastOutput) or r.exitCode == -1
    stderr.writeLine("[vm-harness] incus delete " & name & " attempt " &
      $attempt & " failed (exit " & $r.exitCode & ", " &
      (if transient: "transient" else: "unexpected") & "): " & lastOutput)
    if spentSec() + (delayMs.float / 1000.0) > budgetSec.float:
      break
    doSleep(delayMs)
    sleptMs += delayMs
    delayMs = min(delayMs * 2, 30_000)
  raise newVmHarnessError($b.id, lpCleanup,
    "incus delete " & name & " did not complete after " & $attempt &
    " attempt(s) in " & $budgetSec & "s; the container still exists " &
    "(last output: " & lastOutput & ")")

proc startContainer*(b: IncusBackend, name: string) =
  ## Start an existing container without replacing it. Already-running is a
  ## successful no-op; a missing container remains a hard operator error.
  let state = b.containerState(name)
  if state.len == 0:
    raise newVmHarnessError($b.id, lpStartup,
      "IncusBackend.startContainer: container not found: " & name)
  if state == "RUNNING":
    return
  let r = b.runIncus(@["start", name], timeoutSec = 60)
  if r.exitCode != 0:
    raise newVmHarnessError($b.id, lpStartup,
      "incus start " & name & " failed (exit " & $r.exitCode & "): " &
      r.stdout)

proc stopContainer*(b: IncusBackend, name: string) =
  ## Stop an existing container without deleting its storage or snapshots.
  let state = b.containerState(name)
  if state.len == 0:
    raise newVmHarnessError($b.id, lpCleanup,
      "IncusBackend.stopContainer: container not found: " & name)
  if state == "STOPPED":
    return
  let r = b.runIncus(@["stop", "--force", name], timeoutSec = 60)
  if r.exitCode != 0:
    raise newVmHarnessError($b.id, lpCleanup,
      "incus stop " & name & " failed (exit " & $r.exitCode & "): " &
      r.stdout)

# ---------------------------------------------------------------------------
# Network + NIC-device primitives — the S2 (network-primitive) surface. These
# map Incus managed networks and per-container NIC attachment onto the CLI in
# the same style the deployment rehearsal wires the topology (managed bridge
# with ``ipv4.nat`` + ``ipv6.address=none``; extra segments attached as
# ``eth1``/``eth2`` NIC devices). Each is a thin ``runIncus`` wrapper following
# the existing error-raising convention; ``networkExists`` / ``listNetworks`` /
# ``listDevices`` let the resource driver's ``observe`` check existence first so
# apply stays idempotent-friendly.

proc networkExists*(b: IncusBackend, name: string): bool =
  ## ``incus network info <name>`` exits 0 iff the managed network is defined.
  let r = b.runIncus(@["network", "info", name], timeoutSec = 30)
  r.exitCode == 0

proc createNetwork*(b: IncusBackend, name, cidr: string;
                    config: Table[string, string] =
                      initTable[string, string]()): ExecResult =
  ## ``incus network create <name> ipv4.address=<cidr> ipv4.nat=true
  ##   ipv6.address=none [<k>=<v> ...]`` — a managed bridge with the topology's
  ## network config style (the deployment rehearsal uses ipv4.nat + ipv6 none).
  ## ``cidr`` is passed verbatim as ``ipv4.address`` (Incus reads a CIDR-form
  ## address as the gateway + subnet). Extra ``config`` keys are appended as
  ## additional ``k=v`` settings (they override the defaults if they repeat a
  ## key, since Incus takes the last value). Raises on non-zero exit.
  if name.len == 0:
    raise newException(ValueError, "createNetwork: empty name")
  if cidr.len == 0:
    raise newException(ValueError, "createNetwork: empty cidr")
  var sub = @["network", "create", name,
              "ipv4.address=" & cidr,
              "ipv4.nat=true",
              "ipv6.address=none"]
  for k, v in config:
    sub.add(k & "=" & v)
  result = b.runIncus(sub, timeoutSec = 60)
  if result.exitCode != 0:
    raise newVmHarnessError($b.id, lpProvisioning,
      "incus network create " & name & " failed (exit " &
      $result.exitCode & "): " & result.stdout)

proc deleteNetwork*(b: IncusBackend, name: string): ExecResult =
  ## ``incus network delete <name>``. Idempotent-ish: Incus returns non-zero
  ## for a missing network, which the caller treats as already-clean.
  b.runIncus(@["network", "delete", name], timeoutSec = 60)

proc listNetworks*(b: IncusBackend): seq[string] =
  ## ``incus network list --format csv -c n`` — every network the daemon knows
  ## about (managed + the physical/unmanaged ones it can see). Returns an empty
  ## seq on error. NOTE: this lists ALL networks on the host — callers assert
  ## only on their OWN throwaway names, never on live bridges (incusbr0/lxdbr0).
  let r = b.runIncus(@["network", "list", "--format", "csv", "-c", "n"],
                     timeoutSec = 30)
  if r.exitCode != 0:
    return @[]
  for line in r.stdout.splitLines():
    let s = line.strip()
    if s.len > 0:
      result.add(s)

proc networkConfigGet*(b: IncusBackend, name, key: string): string =
  ## ``incus network get <name> <key>`` — a single managed-network config
  ## value (e.g. ``ipv4.address``), stripped. Empty on error / unset. Lets a
  ## caller assert the CIDR actually took effect.
  let r = b.runIncus(@["network", "get", name, key], timeoutSec = 30)
  if r.exitCode != 0:
    return ""
  result = r.stdout.strip()

proc addDeviceToContainer*(b: IncusBackend, container, nic,
                           network: string): ExecResult =
  ## ``incus config device add <container> <nic> nic network=<network>
  ##   name=<nic>`` — attach a managed-network NIC to a container as device
  ## ``<nic>`` with the in-guest interface name ``<nic>`` (matching the
  ## rehearsal's ``eth1``/``eth2`` additional-segment wiring). Raises on
  ## non-zero exit.
  if container.len == 0 or nic.len == 0 or network.len == 0:
    raise newException(ValueError,
      "addDeviceToContainer: container/nic/network must be non-empty")
  let r = b.runIncus(@["config", "device", "add", container, nic, "nic",
                       "network=" & network, "name=" & nic], timeoutSec = 60)
  if r.exitCode != 0:
    raise newVmHarnessError($b.id, lpProvisioning,
      "incus config device add " & container & " " & nic & " failed (exit " &
      $r.exitCode & "): " & r.stdout)
  result = r

proc removeDevice*(b: IncusBackend, container, nic: string): ExecResult =
  ## ``incus config device remove <container> <nic>``. Idempotent-ish:
  ## removing a missing device returns non-zero, treated as already-clean.
  b.runIncus(@["config", "device", "remove", container, nic], timeoutSec = 60)

proc listDevices*(b: IncusBackend, container: string): seq[string] =
  ## ``incus config device list <container>`` — the NIC/disk/... device names
  ## explicitly attached to the container (one per line). Returns an empty seq
  ## on error. Used to assert a declared NIC actually attached.
  let r = b.runIncus(@["config", "device", "list", container], timeoutSec = 30)
  if r.exitCode != 0:
    return @[]
  for line in r.stdout.splitLines():
    let s = line.strip()
    if s.len > 0:
      result.add(s)

# ---------------------------------------------------------------------------
# provisionEphemeralClone + teardown (the per-job core).

proc applyConfig(b: IncusBackend, name: string, spec: EphemeralIncusSpec) =
  ## Apply any raw ``incus config set`` keys from ``spec.config``.
  ##
  ## NOTE: ``spec.userData`` is deliberately NOT written to
  ## ``cloud-init.user-data`` here. On incus the guest API lives on
  ## ``/dev/incus/sock`` while the golden's cloud-init probes
  ## ``/dev/lxd/sock``, so its datasource never comes up and the injected
  ## user-data is never executed. The bootstrap payload is instead delivered
  ## and launched over ``incus exec`` after the container is exec-ready — see
  ## ``injectAndRunBootstrap``. Keeping the token OUT of the container config
  ## (``incus config show`` would otherwise expose it) is a bonus.
  for k, v in spec.config:
    let r = b.runIncus(@["config", "set", name, k, v], timeoutSec = 30)
    if r.exitCode != 0:
      raise newVmHarnessError($b.id, lpProvisioning,
        "incus config set " & k & " failed (exit " & $r.exitCode & "): " &
        r.stdout)

proc setRequiredConfig(b: IncusBackend, name, key, value: string) =
  let r = b.runIncus(@["config", "set", name, key, value], timeoutSec = 30)
  if r.exitCode != 0:
    raise newVmHarnessError($b.id, lpProvisioning,
      "incus config set " & key & " failed (exit " & $r.exitCode & "): " &
      r.stdout)

proc applyOperatorCapabilities(b: IncusBackend, name: string,
                               spec: EphemeralIncusSpec) =
  ## Apply the fixed, operator-selected capability set while the container is
  ## still stopped. These booleans intentionally do not expose arbitrary
  ## device paths, device types, modes, or Incus config values.
  if spec.securityNesting:
    for key in ["security.nesting",
                "security.syscalls.intercept.mknod",
                "security.syscalls.intercept.setxattr"]:
      b.setRequiredConfig(name, key, "true")
  elif spec.nestedKvm:
    # Nested KVM implies nesting, but does not need the Docker-specific
    # mknod/setxattr intercepts unless securityNesting was selected too.
    b.setRequiredConfig(name, "security.nesting", "true")

  if spec.nestedKvm:
    let r = b.runIncus(@["config", "device", "add", name, "kvm", "unix-char",
                         "source=/dev/kvm", "path=/dev/kvm", "mode=0666"],
                       timeoutSec = 60)
    if r.exitCode != 0:
      raise newVmHarnessError($b.id, lpProvisioning,
        "incus config device add kvm failed (exit " & $r.exitCode & "): " &
        r.stdout)

proc convergeNestedKvmAccess(b: IncusBackend, name: string) =
  ## Incus requests mode=0666 on the unix-char device, but host udev state and
  ## cloud-init group convergence can still leave the guest node at 0660.
  ## Before returning a nested-KVM runner to its controller, wait for exec,
  ## converge the guest-local mode, verify the exact mode, and actually open
  ## the character device read/write so a cgroup/device-policy denial cannot
  ## masquerade as usable KVM.
  let deadline = epochTime() + b.readyTimeoutSec.float
  var ready = false
  while epochTime() < deadline:
    let r = b.runIncus(@["exec", name, "--", "true"], timeoutSec = 15)
    if r.exitCode == 0:
      ready = true
      break
    sleep(200)
  if not ready:
    raise newVmHarnessError($b.id, lpStartup,
      "incus container " & name &
      " did not become exec-ready for nested KVM setup")

  let chmodRes = b.runIncus(@["exec", name, "--", "chmod", "0666", "/dev/kvm"],
                            timeoutSec = 30)
  if chmodRes.exitCode != 0:
    raise newVmHarnessError($b.id, lpStartup,
      "nested KVM access setup on " & name & " failed (exit " &
      $chmodRes.exitCode & "): " & chmodRes.stdout)
  # A root `test -r -w` would be a false proof because root can bypass mode
  # bits. Assert the node's numeric mode instead, which is independent of the
  # user selected by the runner image and proves access for its unprivileged
  # process as well.
  let accessRes = b.runIncus(@["exec", name, "--", "stat", "-c", "%a",
                              "/dev/kvm"], timeoutSec = 30)
  if accessRes.exitCode != 0 or accessRes.stdout.strip() != "666":
    raise newVmHarnessError($b.id, lpStartup,
      "nested KVM device in " & name & " does not have mode 0666")
  let openRes = b.runIncus(@["exec", name, "--", "sh", "-c",
                            "exec 3<>/dev/kvm"], timeoutSec = 30)
  if openRes.exitCode != 0:
    raise newVmHarnessError($b.id, lpStartup,
      "nested KVM device in " & name & " cannot be opened read/write (exit " &
      $openRes.exitCode & "): " & openRes.stdout)

proc provisionEphemeralClone*(b: IncusBackend,
                              spec: EphemeralIncusSpec): VmHandle =
  ## Materialise ONE fresh per-job container from the base image.
  ##
  ## Default steps retain the original exact command shape:
  ##   1. ``incus launch <base> <name> [--ephemeral] [--profile p ...]``
  ##      — a brand-new container whose rootfs is a fresh copy of the base
  ##      image. Nothing from a prior job can bleed in.
  ##   2. optional raw ``incus config set <name> <k> <v>`` keys from
  ##      ``spec.config``. The bootstrap payload (``spec.userData``) is NOT
  ##      applied here — it is delivered + launched over ``incus exec`` after
  ##      the container is exec-ready (see ``injectAndRunBootstrap``), because
  ##      incus does not drive the golden's cloud-init datasource.
  ##
  ## Operator-selected security nesting or nested KVM instead uses the
  ## ordered, pre-start path ``init -> config/device -> start``. This prevents
  ## cloud-init or any other guest process from running before the fixed host
  ## capability policy is attached. Defaults remain false and preserve the
  ## launch path byte-for-byte.
  ##
  ## The returned handle is marked ``ephemeral=true`` so ``stopAndCleanup``
  ## (the DeleteInstance path) force-deletes the container AND its storage
  ## volume, leaving no residue.
  if spec.name.len == 0:
    raise newException(ValueError,
      "provisionEphemeralClone: spec.name is empty")
  let base = if spec.baseImage.len > 0: spec.baseImage else: b.baseImage
  if base.len == 0:
    raise newException(ValueError,
      "provisionEphemeralClone: no base image (spec.baseImage empty and " &
      "backend baseImage unset)")
  if b.containerExists(spec.name):
    raise newVmHarnessError($b.id, lpProvisioning,
      "provisionEphemeralClone: container '" & spec.name &
      "' already exists; per-job clones require a fresh name")

  let needsPreStartCapabilities = spec.securityNesting or spec.nestedKvm
  var launchArgs = @[
    (if needsPreStartCapabilities: "init" else: "launch"), base, spec.name]
  if spec.ephemeral:
    launchArgs.add("--ephemeral")
  for p in spec.profiles:
    launchArgs.add("--profile")
    launchArgs.add(p)
  let launchRes = b.runIncus(launchArgs, timeoutSec = 120)
  if launchRes.exitCode != 0:
    # Best-effort teardown of any half-built container.
    discard b.deleteContainer(spec.name)
    raise newVmHarnessError($b.id, lpProvisioning,
      "incus " & launchArgs[0] & " " & base & " " & spec.name &
      " failed (exit " &
      $launchRes.exitCode & "): " & launchRes.stdout)

  try:
    b.applyConfig(spec.name, spec)
    if needsPreStartCapabilities:
      b.applyOperatorCapabilities(spec.name, spec)
      let startRes = b.runIncus(@["start", spec.name], timeoutSec = 60)
      if startRes.exitCode != 0:
        raise newVmHarnessError($b.id, lpStartup,
          "incus start " & spec.name & " failed (exit " &
          $startRes.exitCode & "): " & startRes.stdout)
      if spec.nestedKvm:
        b.convergeNestedKvmAccess(spec.name)
  except CatchableError as e:
    discard b.deleteContainer(spec.name)
    raise e

  var extra = initTable[string, string]()
  extra["container"] = spec.name
  extra["ephemeral"] = "true"
  extra["baseImage"] = base
  extra["storagePool"] = b.storagePool
  result = VmHandle(
    backend: b,
    name: spec.name,
    baseline: base,
    ipAddress: none(string),
    sshPort: 0,
    sshUser: b.execUser,
    sshAuth: SshAuth(kind: saNone),
    extra: extra)

proc injectAndRunBootstrap*(b: IncusBackend, vm: VmHandle, payload: string,
                            guestPath: string = IncusBootstrapGuestPath,
                            logPath: string = IncusBootstrapLogPath,
                            networkTimeoutSec: int = 120) =
  ## Deliver the runner bootstrap ``payload`` into an already-exec-ready
  ## container and launch it DETACHED. This replaces the cloud-init datasource
  ## path that incus does not drive.
  ##
  ## The payload is GARM's rendered ``#!/bin/bash`` registration script (it
  ## sets the callback/metadata URLs + bearer token, then downloads and runs
  ## the actions runner in the FOREGROUND). Because incus serves its guest API
  ## on ``/dev/incus/sock`` while the golden's cloud-init probes
  ## ``/dev/lxd/sock``, that datasource never comes up and the injected
  ## user-data is never executed — so we deliver and start the script directly.
  ##
  ## Delivery: the payload is streamed on STDIN into an in-guest ``cat`` (never
  ## placed on the argv), so the registration TOKEN it carries never reaches a
  ## command line, the host process table, or this backend's command log. The
  ## file is created root-only (``umask 077`` + explicit ``chmod 0700``).
  ##
  ## Launch: ``setsid --fork`` starts the script in a NEW session, detached
  ## from the exec channel, with stdout/stderr redirected to an in-guest log
  ## and stdin closed. The ``incus exec`` call therefore RETURNS PROMPTLY — it
  ## does not block on ``run.sh`` (which foregrounds, listening for jobs) —
  ## which is what the ``run --ephemeral --keep`` = "launch + return" contract
  ## needs. The runner log is deliberately NOT streamed back (it never ends).
  when defined(linux):
    if payload.len == 0:
      raise newException(ValueError, "injectAndRunBootstrap: empty payload")
    # 1. Deliver the payload root-only, contents on STDIN (never on the argv).
    let deliver = b.execInGuest(vm, initTable[string, string](),
      @["sh", "-c",
        "umask 077 && cat > '" & guestPath & "' && chmod 0700 '" &
        guestPath & "'"],
      stdin = payload, timeoutSec = 60)
    if deliver.exitCode != 0:
      # The payload travelled on stdin; keep the message generic regardless so
      # nothing derived from the payload/token can leak into an error string.
      raise newVmHarnessError($b.id, lpProvisioning,
        "injectAndRunBootstrap: delivering bootstrap into '" & vm.name &
        "' failed (exit " & $deliver.exitCode & ")")
    # 1.5 Wait for the guest NETWORK before launching. `startAndAwaitReady`
    # only proves `incus exec -- true` (init far enough to exec); it does NOT
    # prove DHCP has assigned an address or that DNS resolves. GARM's bootstrap
    # curls the metadata/callback URLs and downloads the runner the instant it
    # starts, so launching it before the network is up makes its first request
    # fail (curl exit 7 / "HTTP 000000") and the script aborts — the runner
    # never registers. Poll from the host for a default route AND working DNS
    # (the runner download needs name resolution), then launch. On timeout fail
    # the create so the controller recreates rather than leaving a dead guest.
    block awaitNet:
      let netDeadline = epochTime() + networkTimeoutSec.float
      var lastRc = -1
      while epochTime() < netDeadline:
        let probe = b.execInGuest(vm, initTable[string, string](),
          @["sh", "-c",
            "ip route 2>/dev/null | grep -q '^default' && " &
            "getent hosts github.com >/dev/null 2>&1"],
          timeoutSec = 15)
        lastRc = probe.exitCode
        if lastRc == 0:
          break awaitNet
        sleep(1000)
      if lastRc != 0:
        raise newVmHarnessError($b.id, lpStartup,
          "injectAndRunBootstrap: guest '" & vm.name & "' network not ready " &
          "(no default route / DNS) within " & $networkTimeoutSec & "s")
    # 2. Launch DETACHED so the exec call returns and run.sh keeps running.
    let launch = b.execInGuest(vm, initTable[string, string](),
      @["setsid", "--fork", "bash", "-lc",
        "'" & guestPath & "' > '" & logPath & "' 2>&1 </dev/null"],
      timeoutSec = 60)
    if launch.exitCode != 0:
      raise newVmHarnessError($b.id, lpProvisioning,
        "injectAndRunBootstrap: launching bootstrap in '" & vm.name &
        "' failed (exit " & $launch.exitCode & ")")
  else:
    raise newException(BackendUnavailableError,
      "IncusBackend.injectAndRunBootstrap requires a Linux host")

# ---------------------------------------------------------------------------
# VmBackend method overrides.

method probeAvailability*(b: IncusBackend): bool =
  ## ``incus info`` succeeds ⇒ the daemon is reachable through our command
  ## vector. Never raises (the auto-selector treats a raise as "no").
  when defined(linux):
    try:
      let r = b.runIncus(@["info"], timeoutSec = 30)
      return r.exitCode == 0
    except CatchableError:
      return false
  else:
    return false

method provisionBaseline*(b: IncusBackend, spec: BaselineSpec) =
  ## Ensure the base image exists. ``spec.sourceImage`` (when set) names the
  ## image alias/fingerprint to check; otherwise the backend default
  ## ``baseImage``. Idempotent — no-op when the image is already present.
  ## Provisioning a *new* image (pulling from a remote) is a host-init
  ## concern (IM0) done out-of-band; this method only verifies presence so
  ## the per-job path fails fast with a clear message.
  when defined(linux):
    let alias = if spec.sourceImage.len > 0: spec.sourceImage else: b.baseImage
    if alias.len == 0:
      raise newVmHarnessError($b.id, lpProvisioning,
        "provisionBaseline: no image alias (spec.sourceImage empty and " &
        "backend baseImage unset)")
    let r = b.runIncus(@["image", "list", alias, "--format", "csv", "-c", "l"],
                       timeoutSec = 30)
    if r.exitCode != 0 or r.stdout.strip().len == 0:
      raise newVmHarnessError($b.id, lpProvisioning,
        "provisionBaseline: base image '" & alias & "' not found in the " &
        "local image store. Pull it first (e.g. `incus image copy " &
        "images:debian/12 local: --alias " & alias & "`).")
  else:
    raise newException(BackendUnavailableError,
      "IncusBackend.provisionBaseline requires a Linux host")

method startAndAwaitReady*(b: IncusBackend, vm: VmHandle,
                          timeoutSec: int = 120) =
  ## Wait until the container is Running and its init is far enough along
  ## that ``incus exec -- true`` succeeds. Containers reach this in well
  ## under a second, but a short poll makes the contract robust.
  when defined(linux):
    let budget = if timeoutSec > 0: timeoutSec else: b.readyTimeoutSec
    let deadline = epochTime() + budget.float
    while epochTime() < deadline:
      if b.containerState(vm.name) == "RUNNING":
        let r = b.runIncus(@["exec", vm.name, "--", "true"], timeoutSec = 15)
        if r.exitCode == 0:
          return
      sleep(200)
    raise (ref GuestBootFailureError)(
      backend: $b.id, phase: lpStartup,
      msg: "IncusBackend.startAndAwaitReady: container '" & vm.name &
           "' did not become exec-ready within " & $budget & "s",
      cause: nil)
  else:
    raise newException(BackendUnavailableError,
      "IncusBackend.startAndAwaitReady requires a Linux host")

method execInGuest*(b: IncusBackend, vm: VmHandle,
                   env: Table[string, string],
                   cmd: seq[string],
                   stdin: string = "",
                   timeoutSec: int = 600): ExecResult =
  ## ``incus exec <name> [--env K=V ...] [--user <uid?>] -- <cmd...>``.
  ## The argv is passed through verbatim after ``--`` (no shell quoting
  ## games — incus exec forwards the vector directly to execvp in the
  ## container), which is cleaner than the SSH backends' cmd-line joining.
  when defined(linux):
    if cmd.len == 0:
      raise newException(ValueError, "execInGuest: empty cmd")
    var sub = @["exec", vm.name]
    for k, v in env:
      sub.add("--env")
      sub.add(k & "=" & v)
    if b.execUser.len > 0:
      sub.add("--user")
      sub.add(b.execUser)
    sub.add("--")
    for a in cmd:
      sub.add(a)
    return b.runIncus(sub, timeoutSec = timeoutSec, stdinData = stdin)
  else:
    raise newException(BackendUnavailableError,
      "IncusBackend.execInGuest requires a Linux host")

method copyToGuest*(b: IncusBackend, vm: VmHandle,
                   hostPath: string, guestPath: string) =
  ## ``incus file push [-r] <host> <name><guest>``.
  when defined(linux):
    if not fileExists(hostPath) and not dirExists(hostPath):
      raise newVmHarnessError($b.id, lpCopy,
        "IncusBackend.copyToGuest: source not found: " & hostPath)
    var sub = @["file", "push"]
    if dirExists(hostPath):
      sub.add("-r")
    sub.add(hostPath)
    sub.add(vm.name & guestPath)
    let r = b.runIncus(sub, timeoutSec = 300)
    if r.exitCode != 0:
      raise newVmHarnessError($b.id, lpCopy,
        "incus file push failed (exit " & $r.exitCode & "): " & r.stdout)
  else:
    raise newException(BackendUnavailableError,
      "IncusBackend.copyToGuest requires a Linux host")

method copyFromGuest*(b: IncusBackend, vm: VmHandle,
                     guestPath: string, hostPath: string) =
  ## ``incus file pull [-r] <name><guest> <host>``.
  when defined(linux):
    createDir(parentDir(hostPath))
    var sub = @["file", "pull", "-r", vm.name & guestPath, hostPath]
    let r = b.runIncus(sub, timeoutSec = 300)
    if r.exitCode != 0:
      raise newVmHarnessError($b.id, lpCopy,
        "incus file pull failed (exit " & $r.exitCode & "): " & r.stdout)
  else:
    raise newException(BackendUnavailableError,
      "IncusBackend.copyFromGuest requires a Linux host")

method installArgvTraceShim*(b: IncusBackend, vm: VmHandle,
                            shim: ArgvTraceShim) =
  ## Not implemented for the Incus slice (the ephemeral runner path does
  ## not need the argv shim). A future slice can port the ``.real``-rename
  ## wrapper the hyperv backend uses, driven through ``incus exec``.
  raise newException(BackendUnavailableError,
    "IncusBackend.installArgvTraceShim is not implemented for the " &
    "ephemeral-container slice")

method uninstallArgvTraceShim*(b: IncusBackend, vm: VmHandle,
                              wrappedBinaryName: string) =
  ## No-op: nothing installed. A per-job container is destroyed wholesale.
  discard

method stopAndCleanup*(b: IncusBackend, vm: VmHandle, deleteVm: bool = true) =
  ## Safe from ``finally`` blocks: NEVER raises. When ``deleteVm`` is true
  ## the container is force-deleted (``incus delete --force``) which stops
  ## it and removes its per-container storage volume in one shot — no
  ## residue. When false the container is only stopped (kept for a later
  ## job / inspection). Idempotent: deleting a missing container is fine.
  when defined(linux):
    try:
      if deleteVm:
        discard b.deleteContainer(vm.name)
      else:
        discard b.runIncus(@["stop", "--force", vm.name], timeoutSec = 60)
    except CatchableError:
      discard
  else:
    discard

# ---------------------------------------------------------------------------
# Snapshot primitives — ``incus snapshot`` / ``incus restore`` /
# ``incus delete <name>/<snap>``. The per-job ephemeral path does not need
# these (each job gets a brand-new container from the base image), but they
# are implemented for parity so consumers that snapshot a longer-lived
# container work.

method snapshot*(b: IncusBackend, vmName: string,
    snapshotName: string): string =
  when defined(linux):
    # ``incus snapshot create <name> <snap>`` is the current subcommand form
    # (incus 6.0.x). The bare top-level ``incus snapshot <name> <snap>`` is
    # no longer accepted and errors "unknown command", so we spell out the
    # ``create`` subcommand explicitly.
    let r = b.runIncus(@["snapshot", "create", vmName, snapshotName],
                       timeoutSec = 60)
    if r.exitCode != 0:
      raise newVmHarnessError($b.id, lpProvisioning,
        "incus snapshot create " & vmName & " " & snapshotName &
        " failed (exit " & $r.exitCode & "): " & r.stdout)
    return snapshotName
  else:
    raise newException(BackendUnavailableError,
      "IncusBackend.snapshot requires a Linux host")

method snapshotRunning*(b: IncusBackend, vmName,
                        snapshotName: string): string =
  ## Incus snapshots capture the container state regardless of run status
  ## (a stateful snapshot needs CRIU; the default is a filesystem snapshot,
  ## which is what the per-gate reset model wants). Behaves as ``snapshot``.
  b.snapshot(vmName, snapshotName)

method restoreSnapshot*(b: IncusBackend, vmName, snapshotName: string) =
  when defined(linux):
    # ``incus snapshot restore <name> <snap>`` — the bare top-level
    # ``incus restore`` form is no longer accepted on incus 6.0.x.
    let r = b.runIncus(@["snapshot", "restore", vmName, snapshotName],
                       timeoutSec = 60)
    if r.exitCode != 0:
      raise newVmHarnessError($b.id, lpRevert,
        "incus snapshot restore " & vmName & " " & snapshotName &
        " failed (exit " & $r.exitCode & "): " & r.stdout)
  else:
    raise newException(BackendUnavailableError,
      "IncusBackend.restoreSnapshot requires a Linux host")

method listSnapshots*(b: IncusBackend, vmName: string): seq[string] =
  when defined(linux):
    let r = b.runIncus(@["snapshot", "list", vmName, "--format", "csv"],
                       timeoutSec = 30)
    if r.exitCode != 0:
      return @[]
    for line in r.stdout.splitLines():
      let cols = line.split(',')
      if cols.len >= 1 and cols[0].strip().len > 0:
        result.add(cols[0].strip())
  else:
    raise newException(BackendUnavailableError,
      "IncusBackend.listSnapshots requires a Linux host")

method removeSnapshot*(b: IncusBackend, vmName, snapshotName: string) =
  ## Idempotent: removing a missing snapshot is a no-op, not an error.
  when defined(linux):
    discard b.runIncus(@["delete", vmName & "/" & snapshotName],
                       timeoutSec = 60)
  else:
    discard

# ---------------------------------------------------------------------------
# Layered base images — the "install-once, reuse-everywhere" machinery on
# the container surface. A base image is a
# chain of snapshot edges: ``publishAsImage`` turns a snapshot (an edge's
# cached output) into a reusable local base image, and
# ``exportBaseline``/``importBaseline`` bridge that base image to a
# transferable on-disk bundle (the cache-payload artifact).

const IncusBaselineManifest = "incus-baseline.manifest"

proc publishAsImage*(b: IncusBackend, source: string, alias: string): string =
  ## Turn a container OR a container snapshot into a reusable LOCAL base
  ## image (``incus publish <source> --alias <alias> --reuse``). ``source``
  ## is either ``<container>`` or ``<container>/<snapshot>``.
  ##
  ## The snapshot form (``c1/edge-a``) is PREFERRED: publishing from a
  ## snapshot works while the container keeps running and does not disturb
  ## it — the clean path for the layered-base-image model where the running
  ## node is snapshotted, then that snapshot is published as the next
  ## layer's base. ``--reuse`` makes a re-publish overwrite an existing
  ## image of the same alias (idempotent republish). ``--force`` is NOT
  ## needed when publishing from a snapshot.
  ##
  ## Returns ``alias``. Raises ``newVmHarnessError`` on non-zero exit.
  when defined(linux):
    if source.len == 0:
      raise newException(ValueError, "publishAsImage: empty source")
    if alias.len == 0:
      raise newException(ValueError, "publishAsImage: empty alias")
    let r = b.runIncus(@["publish", source, "--alias", alias, "--reuse"],
                       timeoutSec = 600)
    if r.exitCode != 0:
      raise newVmHarnessError($b.id, lpProvisioning,
        "incus publish " & source & " --alias " & alias &
        " failed (exit " & $r.exitCode & "): " & r.stdout)
    return alias
  else:
    raise newException(BackendUnavailableError,
      "IncusBackend.publishAsImage requires a Linux host")

method exportBaseline*(b: IncusBackend, vmName, destDir: string;
                       baselineName: string = "") =
  ## Export a published base-image bundle (the cache payload) for ``vmName``
  ## at snapshot ``baselineName`` into ``destDir``.
  ##
  ## Steps: verify the named snapshot exists on ``vmName``; publish
  ## ``vmName/baselineName`` to a deterministic temp alias
  ## (``vmh-export-<vm>-<snap>``); ``incus image export <alias>
  ## <destDir>/<prefix>`` — on this incus (6.0.6) a CONTAINER image exports
  ## as a SINGLE unified ``<prefix>.tar.gz`` (metadata + rootfs in one
  ## gzip'd tarball), which ``importBaseline`` re-imports directly. The
  ## resulting filename is recorded in the manifest so import stays robust
  ## if a future incus splits it. The transient publish alias is deleted
  ## after export — the on-disk bundle is the artifact.
  ##
  ## ``baselineName`` is REQUIRED for incus: unlike VM backends there is no
  ## "whole snapshot tree" to export, only a specific snapshot to publish.
  when defined(linux):
    if baselineName.len == 0:
      raise newVmHarnessError($b.id, lpProvisioning,
        "IncusBackend.exportBaseline requires a snapshot name " &
        "(baselineName) — incus export publishes one named snapshot")
    if baselineName notin b.listSnapshots(vmName):
      raise newVmHarnessError($b.id, lpProvisioning,
        "exportBaseline: snapshot '" & baselineName & "' not found on " &
        "container '" & vmName & "'")
    createDir(destDir)
    let alias = "vmh-export-" & vmName & "-" & baselineName
    discard b.publishAsImage(vmName & "/" & baselineName, alias)
    # Export the published image to a deterministic file prefix.
    let filePrefix = "incus-baseline-" & vmName & "-" & baselineName
    let exportRes = b.runIncus(@["image", "export", alias,
                                 destDir / filePrefix], timeoutSec = 600)
    if exportRes.exitCode != 0:
      # Best-effort cleanup of the transient alias before surfacing.
      discard b.runIncus(@["image", "delete", alias], timeoutSec = 60)
      raise newVmHarnessError($b.id, lpProvisioning,
        "incus image export " & alias & " failed (exit " &
        $exportRes.exitCode & "): " & exportRes.stdout)
    # incus 6.0.x writes a single ``<prefix>.tar.gz`` for a container image.
    let tarball = filePrefix & ".tar.gz"
    if not fileExists(destDir / tarball):
      discard b.runIncus(@["image", "delete", alias], timeoutSec = 60)
      raise newVmHarnessError($b.id, lpProvisioning,
        "exportBaseline: expected tarball '" & tarball & "' not produced " &
        "in " & destDir & " (export output: " & exportRes.stdout & ")")
    writeFile(destDir / IncusBaselineManifest,
              "vm=" & vmName & "\n" &
              "snapshot=" & baselineName & "\n" &
              "alias=" & alias & "\n" &
              "tarball=" & tarball & "\n")
    # The bundle on disk is the artifact; the local publish alias is
    # transient — drop it so a fresh consumer genuinely re-imports.
    discard b.runIncus(@["image", "delete", alias], timeoutSec = 60)
  else:
    raise newException(BackendUnavailableError,
      "IncusBackend.exportBaseline requires a Linux host")

method importBaseline*(b: IncusBackend, srcDir: string): seq[string] =
  ## Consume a bundle produced by ``exportBaseline``: read
  ## ``incus-baseline.manifest``, ``incus image import
  ## <srcDir>/<tarball> --alias <alias>`` (single unified tarball on this
  ## incus), and return ``@[alias]`` so callers can assert the round-trip.
  ## Raises if the manifest or tarball is missing.
  when defined(linux):
    let manifest = srcDir / IncusBaselineManifest
    if not fileExists(manifest):
      raise newVmHarnessError($b.id, lpProvisioning,
        "importBaseline: manifest not found at " & manifest)
    var alias = ""
    var tarball = ""
    for line in readFile(manifest).splitLines():
      if line.startsWith("alias="):
        alias = line["alias=".len .. ^1]
      elif line.startsWith("tarball="):
        tarball = line["tarball=".len .. ^1]
    if alias.len == 0 or tarball.len == 0:
      raise newVmHarnessError($b.id, lpProvisioning,
        "importBaseline: malformed manifest (missing alias= or tarball=) " &
        "at " & manifest)
    let tarPath = srcDir / tarball
    if not fileExists(tarPath):
      raise newVmHarnessError($b.id, lpProvisioning,
        "importBaseline: bundle tarball not found at " & tarPath)
    let r = b.runIncus(@["image", "import", tarPath, "--alias", alias],
                       timeoutSec = 600)
    if r.exitCode != 0:
      raise newVmHarnessError($b.id, lpProvisioning,
        "incus image import " & tarPath & " --alias " & alias &
        " failed (exit " & $r.exitCode & "): " & r.stdout)
    return @[alias]
  else:
    raise newException(BackendUnavailableError,
      "IncusBackend.importBaseline requires a Linux host")

# ---------------------------------------------------------------------------
# Backend registration. Importing this module is enough to make
# ``--backend incus`` and ``vm-harness probe`` see the backend.

registerBackend(biIncus,
  proc(): VmBackend = newIncusBackend())

# ---------------------------------------------------------------------------
# Crud-store reconciliation (design doc §8.6).

proc incusPresenceFrom*(exitCode: int, csvNameState, name: string): InstancePresence =
  ## ``incus list <name> --format csv -c ns``. The name argument is a FILTER
  ## (it also matches ``<name>2``), so the exact row is looked up. A failed
  ## listing is "could not ask" (``ipUnknown``), never absence.
  if exitCode != 0: return ipUnknown
  var rows: seq[EphemeralEntry]
  try:
    rows = parseIncusListCsv(csvNameState)
  except ValueError:
    return ipUnknown
  for r in rows:
    if r.name == name:
      return (case r.state
              of "running": ipRunning
              of "stopped": ipStopped
              else: ipUnknown)
  ipGone

method instancePresence*(b: IncusBackend, vm: VmHandle): InstancePresence =
  let r = b.runIncus(@["list", vm.name, "--format", "csv", "-c", "ns"],
                     timeoutSec = 30)
  incusPresenceFrom(r.exitCode, r.stdout, vm.name)
