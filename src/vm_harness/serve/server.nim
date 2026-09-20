## vm-harness serve — the DAEMON.
##
## A small authenticated network front-end over the EXISTING vm-harness CLI
## backend code. It is intentionally NOT a reimplementation: every VM
## operation is executed by spawning the SAME ``vm-harness`` binary the CLI
## runs (its own ``getAppFilename`` by default) with the client-supplied
## argv, and streaming that worker's output back. This guarantees the remote
## ``provision``/``run``/``boot``/``snapshot``/``prune``/``ephemeral-destroy``
## paths are byte-for-byte the local ones — the daemon adds only the network
## endpoint, the auth check, and the output stream framing.
##
## Endpoints (all under ``/v1``, all requiring ``Authorization: Bearer``):
##   * ``GET  /v1/info``     — protocol version + advertised backend
##                             capabilities (the RA6 manifest seed).
##   * ``POST /v1/exec``     — run a forwarded CLI invocation, STREAM output
##                             as chunked NDJSON, terminate with an exit
##                             event.
##   * ``POST /v1/shutdown`` — graceful stop.
##
## Transport rationale + the TLS/NetBird posture are documented in
## ``protocol.nim`` and ``docs/serve.md``. Over a NetBird overlay the bearer
## token is carried inside WireGuard; an optional ``-d:ssl`` TLS wrap is a
## documented follow-up hook.

import std/[json, net, nativesockets, osproc, os, streams, strutils, tables,
            times, locks, atomics, tempfiles]
when defined(windows):
  # ``terminateProcess`` / ``Handle`` for the deadline reaper's kill path.
  # ``osproc`` uses winlean internally but does not re-export it, so this
  # import is what makes ``killWorker`` compile on Windows — where the serve
  # daemon really does run (RA4: `t_vmharness_serve_win_hyperv`), even though
  # that build cannot be produced from this workstation.
  import std/winlean
else:
  import std/posix
import ./protocol, ./http, ./capability, ./enrollment
import ../types, ../auto

# Import the backend modules so ``registeredBackends`` / ``newBackend`` see
# them for the ``/v1/info`` capability report. Module-init registration is
# idempotent, so importing here (in addition to ``cli.nim``) is harmless.
{.push warning[UnusedImport]: off.}
import ../backends/noop
import ../backends/hyperv
import ../backends/wsl
import ../backends/tart
import ../backends/utm
import ../backends/qemu_windows_arm
import ../backends/lima
import ../backends/libvirt
import ../backends/incus
{.pop.}

type
  ServeConfig* = object
    listenHost*: string           ## bind address (e.g. "127.0.0.1", "::",
                                  ## or a NetBird overlay IP). NEVER a public
                                  ## interface in production.
    listenPort*: int              ## 0 ⇒ ephemeral port (reported via portFile)
    token*: string                ## required bearer token (non-empty)
    workerExe*: string            ## vm-harness binary to exec; "" ⇒ self
    workerArgPrefix*: seq[string] ## prepended to every forwarded argv
    workDir*: string              ## worker cwd; "" ⇒ inherit
    portFile*: string             ## if set, the bound port is written here
                                  ## (readiness signal for tests + ops)
    tlsCertFile*: string          ## optional (only honored under -d:ssl)
    tlsKeyFile*: string
    quiet*: bool                  ## suppress daemon stderr access logs
    # RA6 enrollment / signed capability manifest.
    enrollSecret*: string         ## per-host enrollment secret (prefer file)
    enrollSecretFile*: string     ## agenix / LoadCredential friendly
    stateDir*: string             ## where a self-bootstrapped secret persists
    identityTtlSec*: int          ## signed-identity lifetime; 0 ⇒ TTL default
    hostId*: string               ## identity ``host`` label; "" ⇒ hostname
    serveThreads*: int            ## request-handler worker threads; 0 ⇒ auto
                                  ## (``max(4, countProcessors())`` capped at
                                  ## ``MaxServeThreads``). See ``runServe``.
    execDeadlineSec*: int         ## per-``/v1/exec`` wall-clock budget; 0 ⇒
                                  ## ``DefaultExecDeadlineSec``. A worker that
                                  ## outlives it is KILLED and the client is
                                  ## told why, so a hung guest operation cannot
                                  ## hold a pool slot forever. See
                                  ## ``DefaultExecDeadlineSec`` for the default's
                                  ## derivation.

  ServeContext = ref object
    ## Shared across the acceptor and every worker thread by reference. ``cfg``,
    ## ``enrollSecret`` and ``keyId`` are written ONCE at startup and read-only
    ## thereafter, so they are safe to share unsynchronized. ``running``,
    ## ``idleWorkers`` and ``activeThreads`` are the only mutable-after-startup
    ## fields and are therefore ``Atomic`` (see ``runServe`` for the dispatch
    ## and shutdown protocols).
    cfg: ServeConfig
    running: Atomic[bool]         ## cleared by /v1/shutdown; polled by threads
    activeThreads: Atomic[int]    ## threads still running (workers + acceptor)
    poolSize: int                 ## worker count; written once at startup and
                                  ## read-only thereafter, so the saturation log
                                  ## can name the pool rather than the thread
                                  ## total (which also counts the acceptor)
    idleWorkers: Atomic[int]      ## workers available to take a connection.
                                  ## The acceptor RESERVES one before handing a
                                  ## connection over; failing to reserve is what
                                  ## makes saturation an immediate 503 instead
                                  ## of a connection rotting in the backlog.
    enrollSecret: string          ## resolved once at startup (may = "")
    keyId: string                 ## derived from the secret; "" if none

const MaxServeThreads = 32
  ## Ceiling on the auto-sized worker pool. Each worker either waits on the
  ## dispatch queue or forwards to an isolated child process, so the pool exists
  ## to overlap request *latency* (a long-running exec must not stall unrelated
  ## connections), not to saturate CPU — a modest ceiling is plenty.

const DefaultExecDeadlineSec* = 46800
  ## Wall-clock budget for ONE ``/v1/exec``, after which the worker process is
  ## killed and the client told so. Thirteen hours.
  ##
  ## Why so generous: this endpoint's longest legitimate caller is the central
  ## GARM provider's runner CREATE, which forwards ``--timeout-sec 43200`` (12
  ## hours) on the argv — see ``runnerTimeoutSec`` in nixos-modules'
  ## ``garm-provider-vmharness/src/internal/backend/vmharness.go``, whose comment
  ## records why: GitHub Actions jobs may run for six hours by default, and the
  ## one-shot guest must outlive the job it carries. A deadline at or below that
  ## would KILL LIVE CI RUNNERS, which is a far worse failure than the one this
  ## bounds. The extra hour over 43200 covers the create path's own overhead on
  ## either side of the job — guest boot and SSH-ready (``DefaultReadyTimeoutSec``
  ## = 300s in ``pool.nim``), provisioning, and teardown.
  ##
  ## What it is therefore NOT: a latency bound. It is a LEAK bound — it
  ## guarantees a wedged ``ephemeral-destroy`` eventually releases its pool slot
  ## instead of holding it forever (19 hours, observed). The thing that bounds
  ## the OUTAGE is the saturation 503 plus the platform watchdog in
  ## nixos-modules' ``vm-harness-serve`` units; all three layers are needed and
  ## none substitutes for another.
  ##
  ## Override with ``serve --exec-deadline-sec <n>``; 0 selects this default.

var serveLogLock: Lock
  ## Serializes ``daemonLog`` stderr writes so whole access-log lines from
  ## concurrent accept-loop threads do not interleave. Initialized in
  ## ``runServe`` before any worker is spawned.

proc daemonLog(ctx: ServeContext, msg: string) {.gcsafe.} =
  ## Emit one access-log line to stderr. Callable from every accept-loop
  ## thread. ``{.gcsafe.}`` is asserted because the body touches only the
  ## passed-in ``ctx``, the process-global (thread-safe) ``stderr`` handle, and
  ## a plain, non-GC ``Lock`` — no GC-managed globals.
  if ctx.cfg.quiet:
    return
  {.cast(gcsafe).}:
    withLock serveLogLock:
      stderr.writeLine("[vm-harness serve] " & msg)

proc hostnameOrUnknown(): string =
  ## Best-effort host name for the identity ``host`` label. Nim's stdlib has no
  ## portable ``getHostname``; try ``$HOSTNAME``, then ``/proc/sys/kernel/hostname``
  ## (Linux) / ``/etc/hostname``, else "unknown".
  let env = getEnv("HOSTNAME").strip()
  if env.len > 0: return env
  for p in ["/proc/sys/kernel/hostname", "/etc/hostname"]:
    try:
      if fileExists(p):
        let h = readFile(p).strip()
        if h.len > 0: return h
    except CatchableError: discard
  "unknown"

proc probeHypervisors(): seq[tuple[id: string, available: bool,
                                   guests: seq[string]]] =
  ## Probe every registered backend once: id, availability, supported guests.
  ## Shared by the ``/v1/info`` seed and the RA6 ``/v1/manifest`` (so both
  ## report the SAME hypervisor set this daemon can drive).
  for id in registeredBackends():
    var available = false
    var guests: seq[string] = @[]
    try:
      let b = newBackend(id)
      available = (try: b.probeAvailability() except CatchableError: false)
      for g in b.supportedGuests: guests.add($g)
    except CatchableError:
      discard
    result.add((id: $id, available: available, guests: guests))

proc infoJson(): JsonNode =
  ## Build the ``/v1/info`` capability report: the protocol version, the
  ## host platform, and every registered backend with a probed
  ## availability flag + its supported guests. This is the seed the RA6
  ## capability manifest grows from (the FULL, signed manifest is
  ## ``/v1/manifest``).
  let host = try: $detectHostPlatform() except CatchableError: "unknown"
  var backends = newJArray()
  for h in probeHypervisors():
    backends.add(%*{"id": h.id, "available": h.available, "guests": h.guests})
  result = %*{
    "service": ServiceName,
    "protocol": ProtocolVersion,
    "host": host,
    "backends": backends}

proc hostCapabilityManifest*(): JsonNode =
  ## THIS host's UNSIGNED capability manifest (the ``manifest`` payload the
  ## signed identity carries). Exposed for ``vm-harness manifest`` (local
  ## introspection + the RC1 label-derivation source) without needing a
  ## running daemon or an enrollment secret.
  toJson(detectHostCapabilities(probeHypervisors()))

proc manifestJson(ctx: ServeContext): JsonNode =
  ## Build the RA6 signed identity + capability manifest served by
  ## ``GET /v1/manifest``. The capability manifest is self-reported from the
  ## host (``capability.detectHostCapabilities``); the identity is signed with
  ## the host's enrollment secret (``enrollment.sign``) and is SHORT-LIVED
  ## (``identityTtlSec``) so a controller re-fetches after expiry.
  let caps = detectHostCapabilities(probeHypervisors())
  let host = if ctx.cfg.hostId.len > 0: ctx.cfg.hostId
             else: hostnameOrUnknown()
  let ttl = if ctx.cfg.identityTtlSec > 0: ctx.cfg.identityTtlSec
            else: DefaultIdentityTtlSec
  let id = buildIdentity(ctx.enrollSecret, host, toJson(caps),
                         getTime().toUnix(), ttl)
  toJson(sign(ctx.enrollSecret, id))

# ---------------------------------------------------------------------------
# Per-request deadline enforcement.
#
# ``handleExec`` streams its worker's output with a BLOCKING ``readLine``. There
# is no portable way to give that read a timeout, and a worker that has stopped
# producing output but not exited (a hung ``ephemeral-destroy``, the observed
# production case) leaves the handler parked in it forever — which is how one
# request came to hold a pool slot for 19 hours.
#
# So the deadline is enforced from OUTSIDE the handler: each worker thread
# publishes its child's kill token and deadline into a fixed slot, and ONE
# reaper thread kills whatever has overrun. Killing the child EOFs the pipe,
# which releases the handler's ``readLine`` through its normal exit path — no
# special-casing in the streaming loop, and no second way out of it.
#
# The registry is a fixed array indexed by worker slot rather than a
# lock-guarded table: a worker owns its slot exclusively for the life of the
# daemon, so plain atomics are sufficient and the reaper cannot contend with a
# request path.

var
  execKillToken: array[MaxServeThreads, Atomic[int]]
    ## Per-slot OS handle for the in-flight worker; 0 ⇒ no worker in flight.
  execDeadlineAt: array[MaxServeThreads, Atomic[int64]]
    ## Unix time by which that worker must have finished.
  execWasReaped: array[MaxServeThreads, Atomic[bool]]
    ## Set by the reaper so the handler can tell "the worker died" from "WE
    ## killed the worker", and say which in the event stream.

proc processKillToken(p: Process): int =
  ## The OS token by which ``p`` can be killed from ANOTHER thread: its pid, on
  ## every platform.
  ##
  ## Deliberately an ``int`` and not the ``Process`` ref: the reaper runs on a
  ## different thread from the handler that spawned the child, and passing a
  ## GC-managed ref across that boundary is exactly the kind of sharing the
  ## rest of this module is careful to avoid. A pid is a plain value.
  ##
  ## A pid rather than a Windows HANDLE because ``osproc`` exports no handle
  ## accessor — ``processID`` is the only process identity it makes public, on
  ## either platform — so the Windows branch of ``killWorker`` reopens the pid
  ## instead.
  p.processID

proc killWorker(token: int) =
  ## Best-effort hard kill of an overrun worker. SIGKILL rather than SIGTERM:
  ## the worker has already proven it is not responding, and the whole point is
  ## to guarantee the pipe EOFs and the pool slot comes back.
  ##
  ## RESIDUAL RACE, stated rather than papered over. The reaper CLAIMS the slot
  ## (``compareExchange`` to 0) before killing, so a handler that finished
  ## normally cannot also be reported as reaped — its own disarm makes the
  ## claim fail. What the claim does NOT close is the reverse order: if the
  ## child exits of its own accord in the window between the claim and this
  ## kill, and the handler reaps the zombie in that same window, the pid could
  ## in principle be recycled and this signal delivered elsewhere. The window is
  ## microseconds, it requires the child to exit within it after running for the
  ## full deadline (thirteen hours by default), and closing it properly would
  ## mean holding the child's ``Process`` across threads — the very thing this
  ## design avoids. Accepted deliberately; on Windows the handle makes it moot.
  if token == 0:
    return
  try:
    when defined(windows):
      # No handle was retained (see ``processKillToken``), so reopen the pid
      # with the minimum right needed and release it again.
      let h = openProcess(PROCESS_TERMINATE, 0, DWORD(token))
      if h != Handle(0):
        discard terminateProcess(h, 1)
        discard closeHandle(h)
    else:
      discard posix.kill(Pid(token), SIGKILL)
  except CatchableError:
    discard

proc deadlineReaper(arg: ptr ServeContext) {.thread.} =
  ## Kill any worker that has outlived its deadline. One thread for the whole
  ## daemon; it wakes once a second, which is far finer than the hours-scale
  ## budget it enforces and costs nothing while idle.
  ##
  ## Takes its context by ``ptr`` for the same reason every other thread here
  ## does: ``createThread``'s argument must not itself be GC-managed.
  let ctx = arg[]
  {.cast(gcsafe).}:
    while ctx.running.load():
      let now = getTime().toUnix()
      for slot in 0 ..< MaxServeThreads:
        var token = execKillToken[slot].load()
        if token == 0:
          continue
        let due = execDeadlineAt[slot].load()
        if due == 0 or now < due:
          continue
        # Claim the kill before performing it, so a handler that finishes
        # concurrently cannot be reported as reaped. ``compareExchange`` takes
        # its expected value by ``var`` and overwrites it on failure, hence the
        # mutable local.
        if execKillToken[slot].compareExchange(token, 0):
          execWasReaped[slot].store(true)
          daemonLog(ctx, "exec deadline exceeded on slot " & $slot &
                    " — killing worker " & $token)
          killWorker(token)
      sleep(1000)

proc authorized(ctx: ServeContext, req: HttpRequest): bool =
  ## Constant-time bearer-token check. A missing header, wrong scheme, or
  ## wrong token all fail identically.
  let header = req.headers.getOrDefault(AuthHeader, "")
  let presented = parseBearer(header)
  # constantTimeEq still runs on an empty presented token, so a missing
  # Authorization header is rejected in (near) constant time too.
  constantTimeEq(ctx.cfg.token, presented)

proc userDataTempDir(): string =
  ## Daemon-owned directory holding per-request user-data seed files. Created
  ## lazily; individual files are unique (``createTempFile``) and removed as
  ## soon as their worker exits, so this only ever holds in-flight seeds.
  getTempDir() / "vm-harness-serve" / "userdata"

proc applyUserData*(argv: seq[string], userData: string,
                    dir: string): tuple[argv: seq[string], path: string] =
  ## Bridge the wire ``userData`` bytes to the local ``--user-data <path>`` CLI
  ## contract without a new backend-specific code path:
  ##
  ##   * When ``userData`` is empty, or ``argv`` ALREADY carries a
  ##     ``--user-data`` flag (the caller pinned its own file), the argv is
  ##     returned unchanged and ``path`` is "" (nothing to clean up).
  ##   * Otherwise the bytes are written to a fresh ``0600`` file under ``dir``
  ##     and ``--user-data <path>`` is appended. The returned ``path`` MUST be
  ##     deleted by the caller once the worker has exited.
  ##
  ## The contents are treated as a secret (they may carry a runner registration
  ## token): the file is owner-only and the bytes are never logged. Only the
  ## resulting PATH ever appears in the argv (and therefore in the access log).
  if userData.len == 0 or "--user-data" in argv:
    return (argv, "")
  createDir(dir)
  let (f, path) = createTempFile("seed-", ".userdata", dir)
  try:
    try:
      f.write(userData)
    finally:
      f.close()
  except CatchableError:
    # A write/close failure must not leave a partial, token-bearing seed file
    # behind: the path is never returned to the caller, so it could not be
    # cleaned up otherwise. Delete it before re-raising.
    try: removeFile(path) except CatchableError: discard
    raise
  when defined(posix):
    # createTempFile already uses an owner-only mode on POSIX; assert it
    # explicitly so the contract holds regardless of the umask/stdlib version.
    setFilePermissions(path, {fpUserRead, fpUserWrite})
  (argv & @["--user-data", path], path)

proc handleExec(ctx: ServeContext, client: Socket, req: HttpRequest,
                slot: int) =
  ## Parse the forwarded argv, spawn the worker (the same vm-harness
  ## binary), and stream its merged stdout/stderr as NDJSON ``log`` events
  ## followed by a terminal ``exit`` event.
  ##
  ## ``slot`` is this worker thread's index in the deadline registry. The
  ## spawned child is published there for the whole time it is streamed, so the
  ## reaper can kill it if it overruns ``execDeadlineSec`` — see the registry's
  ## comment for why the deadline cannot be enforced inside the read loop.
  var parsed: ExecRequest
  try:
    parsed = parseExecRequest(req.body)
  except ValueError as e:
    client.sendResponse(400, $(%*{"error": e.msg}))
    return

  let exe = if ctx.cfg.workerExe.len > 0: ctx.cfg.workerExe
            else: getAppFilename()
  # Materialize optional cloud-init user-data (e.g. GARM's rendered runner
  # bootstrap) to a per-request 0600 temp file and append ``--user-data
  # <path>`` so the worker reuses the local ``run --ephemeral --user-data``
  # path unchanged. ``userDataPath`` is "" when nothing was materialized.
  var args = ctx.cfg.workerArgPrefix & parsed.argv
  var userDataPath = ""
  try:
    let applied = applyUserData(args, parsed.userData, userDataTempDir())
    args = applied.argv
    userDataPath = applied.path
  except CatchableError as e:
    client.beginChunked()
    client.writeChunk(errorEvent("failed to stage user-data: " & e.msg) & "\n")
    client.writeChunk(exitEvent(127) & "\n")
    client.endChunked()
    return
  # NB: ``args`` may now end in ``--user-data <path>`` — the PATH is safe to
  # log; the user-data CONTENTS are never logged.
  daemonLog(ctx, "exec " & exe & " " & args.join(" "))

  client.beginChunked()
  var p: Process
  try:
    p = startProcess(exe, workingDir = ctx.cfg.workDir, args = args,
                     options = {poStdErrToStdOut})
  except CatchableError as e:
    if userDataPath.len > 0:
      try: removeFile(userDataPath) except CatchableError: discard
    client.writeChunk(errorEvent("failed to start worker: " & e.msg) & "\n")
    client.writeChunk(exitEvent(127) & "\n")
    client.endChunked()
    return

  # Arm the deadline. Order matters: publish the deadline BEFORE the kill
  # token, so the reaper can never see a token with a stale or zero deadline
  # and kill a brand-new worker immediately.
  let budget = if ctx.cfg.execDeadlineSec > 0: ctx.cfg.execDeadlineSec
               else: DefaultExecDeadlineSec
  execWasReaped[slot].store(false)
  execDeadlineAt[slot].store(getTime().toUnix() + budget)
  execKillToken[slot].store(processKillToken(p))

  try:
    # Feed optional stdin, then close it so stdin-reading workers don't hang.
    if parsed.stdin.len > 0:
      p.inputStream.write(parsed.stdin)
    p.inputStream.close()
    let outStream = p.outputStream
    var line = ""
    while outStream.readLine(line):
      client.writeChunk(logEvent(line) & "\n")
    let code = p.waitForExit()
    # Distinguish "the worker exited" from "we killed it for overrunning".
    # Without this the client sees only a signal exit status and has to guess,
    # which is precisely the misattribution MA8 removed from the run path.
    if execWasReaped[slot].load():
      client.writeChunk(errorEvent(
        "vm-harness serve: exec exceeded its " & $budget &
        "s deadline and the worker was killed " &
        "(raise it with serve --exec-deadline-sec)") & "\n")
    client.writeChunk(exitEvent(code) & "\n")
  except CatchableError as e:
    client.writeChunk(errorEvent("worker stream error: " & e.msg) & "\n")
    client.writeChunk(exitEvent(1) & "\n")
  finally:
    # Disarm BEFORE reaping the process object, so the reaper cannot kill a
    # token this slot no longer owns.
    execKillToken[slot].store(0)
    execDeadlineAt[slot].store(0)
    # CLOSE THE STREAMS EXPLICITLY, THEN THE PROCESS. `close(p)` alone does NOT
    # release the stdio pipes this process opened: on POSIX it reaps the child
    # and frees the handle, but the parent's read/write ends of the pipes
    # `startProcess` created stay open. MEASURED on high-mem-server: the daemon
    # held complete pipe PAIRS — fd 10 read and fd 11 write of the same inode —
    # one pair per exec, with zero live workers, climbing at the exec rate
    # (54 -> 60 pipes in 106s across six execs).
    #
    # That is a slow, unbounded leak against the process's file-descriptor
    # limit, and it is what put this daemon at 1022 open fds against systemd's
    # 1024 soft default: every central-GARM create then failed with
    # "Too many open files" while the daemon itself looked healthy. Raising the
    # limit bounds the blast radius but does not fix this — it only buys time
    # proportional to the new ceiling.
    #
    # Each close is guarded separately: a stream that was never materialised
    # (no stdin was written, say) must not prevent the others from closing.
    try: p.inputStream.close() except CatchableError: discard
    try: p.outputStream.close() except CatchableError: discard
    try: p.errorStream.close() except CatchableError: discard
    try: p.close() except CatchableError: discard
    # Delete the user-data seed as soon as the worker exits: the backend has
    # already read it (incus copies it into ``cloud-init.user-data``), so the
    # token-bearing file must not linger on disk.
    if userDataPath.len > 0:
      try: removeFile(userDataPath) except CatchableError: discard
    client.endChunked()

proc handleConnection(ctx: ServeContext, client: Socket, slot: int) =
  var req: HttpRequest
  try:
    req = client.readRequest()
  except CatchableError:
    return                        # malformed / dropped — drop silently
  # Auth gate for every /v1 route. Reject BEFORE any dispatch or work.
  if not authorized(ctx, req):
    daemonLog(ctx, "401 " & req.httpMethod & " " & req.path)
    client.sendResponse(401, $(%*{"error": "unauthorized"}))
    return
  case req.path
  of PathInfo:
    if req.httpMethod != "GET":
      client.sendResponse(405, $(%*{"error": "use GET"}))
    else:
      client.sendResponse(200, $infoJson())
  of PathManifest:
    if req.httpMethod != "GET":
      client.sendResponse(405, $(%*{"error": "use GET"}))
    elif ctx.enrollSecret.len == 0:
      # No enrollment material ⇒ the daemon cannot present a signed identity.
      client.sendResponse(503, $(%*{"error":
        "serve daemon has no enrollment secret; " &
        "provide --enroll-secret-file / --enroll-secret / $VMH_ENROLL_SECRET"}))
    else:
      client.sendResponse(200, $manifestJson(ctx))
  of PathExec:
    if req.httpMethod != "POST":
      client.sendResponse(405, $(%*{"error": "use POST"}))
    else:
      handleExec(ctx, client, req, slot)
  of PathShutdown:
    if req.httpMethod != "POST":
      client.sendResponse(405, $(%*{"error": "use POST"}))
    else:
      client.sendResponse(200, $(%*{"ok": true}))
      ctx.running.store(false)
      daemonLog(ctx, "shutdown requested")
  else:
    client.sendResponse(404, $(%*{"error": "unknown path", "path": req.path}))

# ---------------------------------------------------------------------------
# Accept / dispatch.
#
# ONE acceptor thread owns the listening socket; N worker threads handle
# requests, fed by a dispatch queue. The split is the point.
#
# The obvious alternative — every worker calling ``accept`` on the shared
# listening socket — is what this daemon shipped with, and it is NOT sufficient.
# It bounds the damage of a hung request to one pool slot instead of the whole
# daemon, but once all N slots are hung NOBODY is in ``accept`` any more, and
# the kernel goes on completing handshakes into the listen backlog until it
# fills. That is the production signature exactly: a LISTEN socket with
# ``Recv-Q 4097`` against ``Send-Q 4096``, a daemon systemd still calls
# ``active``, and clients seeing connect/response TIMEOUTS rather than
# refusals — for 19 hours on one host.
#
# With a dedicated acceptor, the daemon always has somebody in ``accept``, so
# it can always give an ANSWER. When no worker is free that answer is an
# immediate 503 naming the saturation, which is both actionable for the caller
# (retry elsewhere) and detectable by the platform watchdog. A silent timeout
# is neither.

type
  Acceptor = object
    ## Immutable bundle handed (by ``ptr``) to the acceptor and every worker
    ## thread. A SINGLE instance is shared: ``ctx`` is a ref whose mutable
    ## fields are atomic, and ``server`` is the ONE listening socket — now
    ## touched ONLY by the acceptor thread.
    ctx: ServeContext
    server: Socket
    domain: Domain                ## listener's address family, needed to
                                  ## rebuild an accepted fd inside a worker

  WorkerArg = object
    ## Per-worker startup bundle: the shared acceptor plus THIS worker's
    ## exclusive deadline-registry slot.
    acc: ptr Acceptor
    slot: int

var dispatchQueue: Channel[int]
  ## Accepted connections, as raw socket handles, from the acceptor to the
  ## workers.
  ##
  ## A handle (a plain integer) rather than the ``Socket`` object: ``Socket`` is
  ## a GC-managed ref, and handing refs between threads is the one thing this
  ## module consistently refuses to do. Nim's ``net`` sockets have no destructor
  ## that would close the fd when the acceptor's wrapper goes out of scope, so
  ## ownership transfers cleanly with the integer and the worker rebuilds a
  ## ``Socket`` around it.
  ##
  ## A negative value is the shutdown sentinel; ``runServe`` sends one per
  ## worker.

const SaturatedBody = """{"error":"vm-harness serve: all request handlers are busy; retry","code":"handlers_saturated"}"""

proc rejectSaturated(client: Socket) =
  ## Answer a connection the pool has no capacity for, and close it.
  ##
  ## Runs ON THE ACCEPTOR THREAD, so it must not block for any reason — a
  ## stalled write here would recreate the very backlog stall the acceptor
  ## exists to prevent. The fd is therefore put in non-blocking mode first: the
  ## response is a couple of hundred bytes and fits in a fresh socket's send
  ## buffer in practice, and in the pathological case where it does not, the
  ## write fails immediately and the client gets a close instead of a hang.
  ## Both outcomes are prompt and neither costs the acceptor anything.
  try:
    client.getFd().setBlocking(false)
    var msg = "HTTP/1.1 503 Service Unavailable\r\n"
    msg.add("Content-Type: application/json\r\n")
    msg.add("Content-Length: " & $SaturatedBody.len & "\r\n")
    msg.add("Retry-After: 1\r\n")
    msg.add("Connection: close\r\n")
    msg.add("\r\n")
    msg.add(SaturatedBody)
    client.send(msg)
  except CatchableError:
    discard

proc resolveThreadCount(cfg: ServeConfig): int =
  ## The worker pool size. An explicit ``--serve-threads`` wins (clamped to
  ## ``MaxServeThreads``); otherwise auto-size to ``max(4, countProcessors())``
  ## capped at ``MaxServeThreads``. Four is a floor so even a single-core host
  ## can overlap a slow exec with unrelated short requests.
  if cfg.serveThreads > 0:
    return min(cfg.serveThreads, MaxServeThreads)
  result = max(4, countProcessors())
  if result > MaxServeThreads:
    result = MaxServeThreads

proc workerLoop(arg: ptr WorkerArg) {.thread.} =
  ## One request handler. Takes accepted connections off the dispatch queue
  ## until it receives the shutdown sentinel.
  ##
  ## Concurrency safety:
  ## * The only socket this thread touches is the one it just took ownership
  ##   of; the listening socket belongs to the acceptor alone.
  ## * ``handleConnection``/``handleExec`` use only local variables, that
  ##   thread-owned socket, an isolated child PROCESS, and read-only ``ctx``
  ##   fields — no shared mutable state between connections.
  ## * ``slot`` is exclusive to this thread for the life of the daemon, so its
  ##   deadline-registry entry needs no lock.
  ##
  ## The ``{.cast(gcsafe).}`` covers the read-only-after-startup backend
  ## registry (``/v1/info`` / ``/v1/manifest``) whose closure table Nim
  ## conservatively flags; the reasoning above is the justification.
  let ctx = arg.acc.ctx
  let domain = arg.acc.domain
  let slot = arg.slot
  {.cast(gcsafe).}:
    while true:
      # Announce availability, then block until the acceptor hands us work.
      # The acceptor decrements this counter to RESERVE us, so it is never
      # incremented here for a connection already in flight.
      discard ctx.idleWorkers.fetchAdd(1)
      let handle = dispatchQueue.recv()
      if handle < 0:
        # Shutdown sentinel. The reservation we just published is ours to
        # withdraw.
        discard ctx.idleWorkers.fetchSub(1)
        break
      var client = newSocket(SocketHandle(handle), domain, SOCK_STREAM,
                             IPPROTO_TCP)
      try:
        handleConnection(ctx, client, slot)
      except CatchableError as e:
        daemonLog(ctx, "connection error: " & e.msg)
      finally:
        try: client.close() except CatchableError: discard
    discard ctx.activeThreads.fetchSub(1)

proc acceptorLoop(arg: ptr Acceptor) {.thread.} =
  ## The daemon's single accept loop. Accept, reserve a worker, hand the
  ## connection over — or, when every worker is busy, answer 503 immediately.
  ##
  ## Everything on this thread is O(1) and non-blocking apart from ``accept``
  ## itself. That is the invariant that makes the saturation reply possible:
  ## no request's work, however long, ever runs here.
  let ctx = arg.ctx
  let server = arg.server
  {.cast(gcsafe).}:
    while ctx.running.load():
      var client: Socket
      var accepted = false
      try:
        server.accept(client)
        accepted = true
      except CatchableError:
        discard
      if not accepted:
        continue
      # A shutdown may have landed while we were parked in accept (including
      # the self-connect wakeup below). Drop the connection without dispatch.
      if not ctx.running.load():
        try: client.close() except CatchableError: discard
        break
      # Reserve a worker. ``fetchSub`` returns the value BEFORE the
      # subtraction, so a result of <= 0 means there was nothing to reserve
      # and the decrement must be undone. Only this one thread reserves, so
      # the check and the claim cannot race with each other.
      if ctx.idleWorkers.fetchSub(1) <= 0:
        discard ctx.idleWorkers.fetchAdd(1)
        daemonLog(ctx, "503 all " & $ctx.poolSize &
                  " request handlers busy — rejecting connection")
        rejectSaturated(client)
        try: client.close() except CatchableError: discard
        continue
      # Ownership of the fd passes to a worker; do NOT close it here.
      dispatchQueue.send(int(client.getFd()))
    discard ctx.activeThreads.fetchSub(1)

proc selfConnectHost(listenHost: string): string =
  ## The address to connect to in order to wake a parked ``accept`` on THIS
  ## daemon's listening socket. Wildcard binds are reached via loopback.
  case listenHost
  of "", "0.0.0.0": "127.0.0.1"
  of "::", "[::]": "::1"
  else: listenHost

proc wakeOnce(host: string, port: int) =
  ## Open and immediately close one connection to unblock a worker parked in
  ## ``accept``. Best-effort: any failure is ignored (the worker may already
  ## have left its loop).
  try:
    let s = dial(host, Port(port))
    s.close()
  except CatchableError:
    discard

proc runServe*(cfg: ServeConfig) =
  ## Bind, listen, and serve connections until a ``/v1/shutdown`` is received.
  ##
  ## Structure: ONE acceptor thread owning the listening socket, plus a bounded
  ## pool of worker threads (``resolveThreadCount``) fed by ``dispatchQueue``,
  ## plus one deadline reaper. Concurrency is required by the control driver (a
  ## central GARM), which fires many simultaneous create/delete/retry calls: a
  ## single long-running ``/v1/exec`` must not stall unrelated connections past
  ## the client's response-header timeout. Per-host mutation ordering is the
  ## driver's concern, not this daemon's — each request already runs in an
  ## isolated child process.
  ##
  ## The three layers that keep a hung request from taking the daemon down,
  ## none of which replaces another:
  ##   1. the worker pool, so one hung request costs one slot, not the daemon;
  ##   2. the dedicated acceptor, so a FULLY saturated pool still answers —
  ##      503 immediately, rather than connections silently filling the listen
  ##      backlog (the production failure);
  ##   3. the per-exec deadline, so a wedged worker eventually gives its slot
  ##      back instead of holding it indefinitely.
  ## Bounding the OUTAGE when all of that is still not enough is the platform
  ## watchdog's job, in nixos-modules' ``vm-harness-serve`` units.
  ##
  ## Shutdown protocol: the ``/v1/shutdown`` handler clears the atomic
  ## ``running`` flag. The main thread polls it, wakes the acceptor (parked in
  ## ``accept``) with one self-connect, then sends one sentinel per worker and
  ## joins. Shutdown is prompt but not instantaneous — a worker mid-exec
  ## finishes that exec first.
  if cfg.token.len == 0:
    raise newException(ValueError,
      "vm-harness serve: a non-empty auth token is required " &
      "(--auth-token / --auth-token-file / $VMH_SERVE_TOKEN)")
  let ctx = ServeContext(cfg: cfg)
  ctx.running.store(true)
  initLock(serveLogLock)
  # Resolve the enrollment secret ONCE at startup so the daemon's identity is
  # stable for its lifetime. Missing material is non-fatal: /v1/exec + /v1/info
  # still work (RA1 back-compat); only /v1/manifest requires it (503 otherwise).
  ctx.enrollSecret =
    try:
      resolveEnrollmentSecret(cfg.enrollSecret, cfg.enrollSecretFile, cfg.stateDir)
    except CatchableError as e:
      raise newException(ValueError, "vm-harness serve: " & e.msg)
  if ctx.enrollSecret.len > 0:
    ctx.keyId = keyIdFor(ctx.enrollSecret)
  var server = newSocket()
  server.setSockOpt(OptReuseAddr, true)
  let host = if cfg.listenHost.len > 0: cfg.listenHost else: "127.0.0.1"
  server.bindAddr(Port(cfg.listenPort), host)
  server.listen()
  let (_, boundPort) = server.getLocalAddr()
  if cfg.portFile.len > 0:
    writeFile(cfg.portFile, $(boundPort.int))
  daemonLog(ctx, "listening on " & host & ":" & $(boundPort.int) &
            " (worker " &
            (if cfg.workerExe.len > 0: cfg.workerExe else: "self") & ")")
  if ctx.keyId.len > 0:
    # The keyId is the non-secret identity to ENROLL centrally (operator step).
    daemonLog(ctx, "identity keyId " & ctx.keyId &
              " (enroll this keyId on the controller)")
  else:
    daemonLog(ctx, "no enrollment secret — /v1/manifest disabled")
  when defined(ssl):
    if cfg.tlsCertFile.len > 0 and cfg.tlsKeyFile.len > 0:
      # Optional TLS wrap (compile with -d:ssl). Over NetBird the WireGuard
      # tunnel already encrypts; this is for deployments without an overlay.
      let sslCtx = newContext(certFile = cfg.tlsCertFile,
                              keyFile = cfg.tlsKeyFile)
      wrapSocket(sslCtx, server)

  # Spawn the worker pool, the acceptor, and the deadline reaper. They share
  # the one ``Acceptor``; it (and the per-worker ``WorkerArg``s) outlive every
  # thread because we join before returning.
  let threadCount = resolveThreadCount(cfg)
  let deadlineSec = if cfg.execDeadlineSec > 0: cfg.execDeadlineSec
                    else: DefaultExecDeadlineSec
  daemonLog(ctx, "request handlers: " & $threadCount &
            " worker threads + 1 acceptor; exec deadline " &
            $deadlineSec & "s")
  dispatchQueue.open()
  # activeThreads counts the threads that must be joined and that decrement it
  # on exit: the workers plus the acceptor.
  ctx.activeThreads.store(threadCount + 1)
  ctx.poolSize = threadCount
  ctx.idleWorkers.store(0)          # each worker publishes its own availability
  # ``domain`` must match the listening socket's family, because each worker
  # rebuilds a ``Socket`` around the raw fd the acceptor hands it. ``server``
  # comes from ``newSocket()``, which is AF_INET, so this is that family — not
  # a guess. An IPv6 listener would have to change both together.
  var acc = Acceptor(ctx: ctx, server: server, domain: AF_INET)
  var ctxForReaper = ctx

  var workerArgs = newSeq[WorkerArg](threadCount)
  var workers = newSeq[Thread[ptr WorkerArg]](threadCount)
  for i in 0 ..< threadCount:
    workerArgs[i] = WorkerArg(acc: addr acc, slot: i)
    createThread(workers[i], workerLoop, addr workerArgs[i])

  var acceptor: Thread[ptr Acceptor]
  createThread(acceptor, acceptorLoop, addr acc)

  var reaper: Thread[ptr ServeContext]
  createThread(reaper, deadlineReaper, addr ctxForReaper)

  # Wait for a /v1/shutdown (which clears ``running`` on some worker thread).
  while ctx.running.load():
    sleep(100)

  # Wake the acceptor if it is parked in ``accept``, and keep waking it until
  # it has actually left its loop.
  #
  # RETRIED rather than attempted once: ``wakeOnce`` is best-effort and
  # swallows its errors, so a single self-connect that loses a race or is
  # refused would leave the acceptor parked in ``accept`` forever and the
  # ``joinThread`` below would never return — turning a graceful shutdown into
  # a hang. The acceptor decrements ``activeThreads`` on its way out, so the
  # pool count is the completion signal.
  let wakeHost = selfConnectHost(host)
  while ctx.activeThreads.load() > threadCount:
    wakeOnce(wakeHost, boundPort.int)
    sleep(20)
  joinThread(acceptor)

  # Retire the workers. One sentinel each; a worker mid-exec takes its own
  # once that exec returns, which is why this is sent AFTER the acceptor has
  # stopped handing out new connections.
  for _ in 0 ..< threadCount:
    dispatchQueue.send(-1)
  for t in workers.mitems:
    joinThread(t)

  joinThread(reaper)
  dispatchQueue.close()
  server.close()
  daemonLog(ctx, "stopped")
