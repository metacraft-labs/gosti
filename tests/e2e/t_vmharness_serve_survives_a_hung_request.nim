## t_vmharness_serve_survives_a_hung_request — the hung-request survival gate.
##
## Runner-Fleet-M3-ARM-Wave milestone MA12. This is the gate for the defect
## that took `vm-harness serve` off the air TWICE in production (high-mem-server
## and gpu-server-001), each time with the daemon still reported `active` by
## `systemctl` and its port still `LISTEN`ing, and once for NINETEEN HOURS.
##
## THE PROPERTY UNDER TEST, in two layers, because the production failure was
## the second one and only the second one:
##
##   (1) ONE hung `/v1/exec` must not stop a concurrent request being served.
##       This is what the accept-loop thread pool buys, and it is falsifiable
##       against the pre-pool SERIAL accept loop (`VMH_HUNG_TEST_THREADS=1`
##       makes the pool one-deep, which is serial-equivalent).
##
##   (2) When EVERY pool slot is occupied by a hung `/v1/exec`, a further
##       request must still get an ANSWER — an immediate, diagnostic HTTP 503 —
##       instead of its completed TCP handshake rotting in the listen backlog
##       until the client's own deadline expires. THIS is the production
##       signature: `ss -lnt` showed `Recv-Q 4097` against `Send-Q 4096` on a
##       LISTEN socket, i.e. a full accept backlog, and callers reported
##       connect/response TIMEOUTS rather than refusals. A bounded pool alone
##       does NOT give this — it merely raises the number of hung requests
##       needed from 1 to N — so layer (2) is falsifiable against the
##       thread-pool-only daemon exactly as layer (1) is against the serial one.
##
##   (3) The daemon must RECOVER: once the hung requests are released, the same
##       daemon serves normally again. A gate that only proved the 503 would be
##       satisfied by a daemon that had permanently given up.
##
## Mock policy (design doc §9.1): NO hypervisor and NO backend is exercised.
## The daemon's worker is this same test binary re-execed in a trivial `__work`
## role, so what is measured is ONLY serve's accept/dispatch behaviour. The
## daemon, the TCP transport, the HTTP framing, the bearer auth and the
## saturation reply are all REAL. A "hung" request is a worker that sleeps far
## longer than the test's own measurement window — a real process holding a
## real pool slot, not a stubbed-out flag.
##
## Test topology (processes, no in-test threads — mirrors the roundtrip and
## concurrency gates): the compiled binary re-execs ITSELF in three roles:
##   * `<binary> __serve <host> <port> <tokenFile> <portFile> <threads>`
##     runs the daemon (worker = this same binary in the `__work` role);
##   * `<binary> __work hang <sec>` sleeps `sec` seconds, then exits 0;
##   * `<binary> __work quick` prints a line and exits 0;
##   * `<binary> __hang <host> <port> <tokenFile> <sec> <doneFile>` is a
##     standalone client that fires ONE hanging exec and records its exit code,
##     run as a separate PROCESS so it genuinely pins a pool slot for `sec`.

import std/[net, os, osproc, strutils, tempfiles, times, unittest]
import vm_harness
import vm_harness/serve/http as serveHttp

# ---------------------------------------------------------------------------
# Auxiliary self-exec roles. Checked BEFORE the unittest runner so a re-exec
# never re-enters the suite.

when isMainModule:
  let params = commandLineParams()
  if params.len >= 2 and params[0] == "__work":
    if params[1] == "hang" and params.len >= 3:
      stdout.writeLine("hang-start")
      stdout.flushFile()
      sleep(parseInt(params[2]) * 1000)
      stdout.writeLine("hang-done")
      quit(0)
    else:
      stdout.writeLine("quick-ok")
      quit(0)
  elif params.len >= 6 and params[0] == "__serve":
    let cfg = ServeConfig(
      listenHost: params[1],
      listenPort: parseInt(params[2]),
      token: readFile(params[3]).strip(),
      workerExe: getAppFilename(),
      workerArgPrefix: @["__work"],
      portFile: params[4],
      serveThreads: parseInt(params[5]),
      quiet: true)
    runServe(cfg)
    quit(0)
  elif params.len >= 6 and params[0] == "__hang":
    # host port tokenFile hangSec doneFile
    let addr0 = params[1] & ":" & params[2]
    let cl = newServeClient(addr0, readFile(params[3]).strip())
    let code = cl.execStream(@["hang", params[4]],
                             proc(ev: ExecEvent) = discard)
    writeFile(params[5], $code)
    quit(0)

# ---------------------------------------------------------------------------
# Helpers.

const PoolThreads = 4
  ## The pool size this gate runs the daemon with. Small on purpose: layer (2)
  ## has to SATURATE the pool, and saturating the production default
  ## (`max(4, countProcessors())`) would mean spawning one hanging client per
  ## core. Four is the production FLOOR (`resolveThreadCount`), so this is a
  ## real production configuration, not a test-only degenerate one.

const HealthyStatus = 401
  ## What a LIVE daemon answers the unauthenticated liveness probe with. 401 is
  ## a success here, not a failure: it proves the daemon accepted, dispatched,
  ## read and replied. See `probeLiveness` for why the probe is unauthenticated.

const SaturatedStatus = 503
  ## What a daemon with every handler busy answers, straight from the acceptor.

proc waitForPort(portFile: string, timeoutSec = 10.0): int =
  ## Poll the daemon's port-file until it reports its bound port.
  let deadline = epochTime() + timeoutSec
  while epochTime() < deadline:
    if fileExists(portFile):
      let raw = readFile(portFile).strip()
      if raw.len > 0:
        try: return parseInt(raw)
        except ValueError: discard
    sleep(50)
  raise newException(IOError, "daemon did not report a port within timeout")

type ProbeOutcome = object
  ## What a single bounded probe of the daemon actually got back. The
  ## distinction between `timedOut` and a real `status` is the whole point of
  ## layer (2): the production failure produced the FORMER where the fixed
  ## daemon produces the latter.
  timedOut: bool        ## no response within the probe budget
  status: int           ## HTTP status when one arrived (0 if none)
  elapsed: float

proc probeLiveness(host: string, port: int, budgetSec: float): ProbeOutcome =
  ## Issue ONE bounded liveness request and report what came back.
  ##
  ## WHAT IS PROBED, and why it is not `/v1/info`. The probe is an
  ## UNAUTHENTICATED `GET /v1/info`, whose correct answer is 401. That answer
  ## still requires the whole path this gate is about — accept, dispatch to a
  ## worker, read the request, write a response — but it is rejected at the auth
  ## gate before any dispatch work, so it costs the daemon nothing.
  ##
  ## An AUTHENTICATED `/v1/info` would be the wrong instrument: it probes every
  ## registered hypervisor backend synchronously on every call. MEASURED on this
  ## host 2026-09-18, against the daemon this gate runs: 16.7s authenticated
  ## versus 5ms unauthenticated. A liveness probe that expensive cannot tell a
  ## wedged daemon from a slow one, which is the exact confusion this gate
  ## exists to remove. (The same reasoning governs the watchdog's probe in
  ## nixos-modules' `vm-harness-serve` units, which likewise treats 401 as
  ## healthy.)
  ##
  ## The read uses `net.recv`'s TIMEOUT overload rather than
  ## `http.readResponseHead`: the latter blocks indefinitely, and a daemon that
  ## ACCEPTS BUT NEVER ANSWERS is precisely the production failure being
  ## detected. A bounded read makes that failure measurable instead of hanging
  ## the test runner — which is how it hung its callers in production.
  let t0 = epochTime()
  result = ProbeOutcome(timedOut: true, status: 0, elapsed: 0.0)
  var sock = newSocket()
  try:
    sock.connect(host, Port(port), timeout = int(budgetSec * 1000))
    sock.sendRequest("GET", "/v1/info", host & ":" & $port)
    # Read just enough to carry the status line and take the status off it.
    #
    # EXACTLY `StatusPrefixLen` bytes, not "up to": Nim's timeout overload of
    # `recv` raises TimeoutError unless the FULL requested size arrives, so
    # asking for a whole buffer's worth would time out on every healthy
    # response (they are shorter than that). Sixteen bytes is the longest
    # prefix guaranteed present in ANY HTTP/1.1 status line — "HTTP/1.1 200 OK"
    # is already 15, and the status code sits at a fixed offset — so this is
    # both always satisfiable and always sufficient.
    const StatusPrefixLen = 16
    var buf = ""
    let remainingMs = max(1, int((budgetSec - (epochTime() - t0)) * 1000))
    discard sock.recv(buf, StatusPrefixLen, timeout = remainingMs)
    let parts = buf.splitWhitespace()
    if parts.len >= 2 and parts[0].startsWith("HTTP/"):
      result.status = parseInt(parts[1])
      result.timedOut = false
  except CatchableError:
    result.timedOut = true
  finally:
    try: sock.close() except CatchableError: discard
    result.elapsed = epochTime() - t0

# ---------------------------------------------------------------------------

suite "t_vmharness_serve_survives_a_hung_request":
  let work = createTempDir("vmh-hung-", "")
  let tokenFile = work / "token"
  let portFile = work / "port"
  let token = "hung-test-bearer-4f21"
  writeFile(tokenFile, token)

  # Falsifiability seam, mirroring the concurrency gate's:
  # `VMH_HUNG_TEST_THREADS=1` forces a ONE-deep pool, which behaves exactly
  # like the pre-MA12 SERIAL accept loop. Layer (1) below fails under it. The
  # default is the production floor.
  let threadArg = getEnv("VMH_HUNG_TEST_THREADS", $PoolThreads)
  let poolSize = parseInt(threadArg)

  let daemon = startProcess(
    getAppFilename(),
    args = @["__serve", "127.0.0.1", "0", tokenFile, portFile, threadArg],
    options = {poParentStreams})
  var port = 0
  try:
    port = waitForPort(portFile)
  except CatchableError:
    daemon.terminate()
    raise

  # How long a "hung" worker hangs. It must outlast every measurement below
  # with a wide margin, so that anything the daemon does during the test is
  # attributable to the hang and not to the hang ending.
  const HangSec = 40
  # The budget one probe gets. Generous next to a healthy daemon's answer
  # (milliseconds) and tiny next to HangSec, so the two regimes cannot be
  # confused by load on the test host.
  const ProbeBudgetSec = 6.0

  var hangers: seq[Process] = @[]

  proc startHanger(idx: int): Process =
    ## Fire one hanging /v1/exec from its OWN process so it genuinely pins a
    ## pool slot for HangSec seconds.
    startProcess(
      getAppFilename(),
      args = @["__hang", "127.0.0.1", $port, tokenFile, $HangSec,
               work / ("hang-done-" & $idx)],
      options = {poParentStreams})

  test "layer 1: one hung exec does not stop a concurrent request":
    # Baseline: the daemon answers before anything is hung.
    let before = probeLiveness("127.0.0.1", port, ProbeBudgetSec)
    check not before.timedOut
    check before.status == HealthyStatus

    # Pin exactly ONE pool slot with a hung exec.
    hangers.add(startHanger(0))
    sleep(1500)                     # let it connect and occupy a worker
    check hangers[0].running

    # The property: a concurrent request is still served, promptly.
    let during = probeLiveness("127.0.0.1", port, ProbeBudgetSec)
    check not during.timedOut
    check during.status == HealthyStatus
    # "Promptly" means it did not wait for the hung exec. Threshold sits far
    # below HangSec so the two regimes are cleanly separated.
    check during.elapsed < 2.5
    # And the hung exec is genuinely still hung, so the assertion above really
    # was made under the hung condition.
    check hangers[0].running

  test "layer 2: a SATURATED pool answers 503 instead of timing out":
    # Skip loudly rather than pass quietly when the falsifiability seam has
    # shrunk the pool: with one slot, layer 1 already saturated it.
    if poolSize < 2:
      checkpoint("SKIP layer 2: VMH_HUNG_TEST_THREADS=" & $poolSize &
                 " leaves no spare slot to saturate distinctly from layer 1")
      skip()
    else:
      # Occupy EVERY remaining pool slot. One is already hung from layer 1.
      for i in 1 ..< poolSize:
        hangers.add(startHanger(i))
      # Give every hanger time to connect and be dispatched to a worker.
      sleep(2500)
      for h in hangers:
        check h.running

      # THE PRODUCTION SIGNATURE. With every worker hung, the pre-MA12 daemon
      # left this connection in the accept backlog and the client timed out.
      # The fixed daemon answers immediately with a diagnostic 503.
      let saturated = probeLiveness("127.0.0.1", port, ProbeBudgetSec)
      check not saturated.timedOut          # <- fails on the unfixed daemon
      check saturated.status == SaturatedStatus
      # Immediate, not "eventually": the reply must come from the acceptor, not
      # from a worker that happened to free up.
      check saturated.elapsed < 2.5
      # The hung execs are still hung, so the 503 really was measured under
      # saturation rather than after the hangs drained.
      for h in hangers:
        check h.running

  test "layer 3: the daemon recovers once the hung requests drain":
    # Let every hanging exec finish on its own (they are `sleep`s, not
    # deadlocks) and confirm the daemon serves normally again. Without this a
    # daemon that answered 503 forever would satisfy layer 2.
    for h in hangers:
      discard h.waitForExit(timeout = (HangSec + 30) * 1000)
    for i in 0 ..< hangers.len:
      let doneFile = work / ("hang-done-" & $i)
      check fileExists(doneFile)
      check readFile(doneFile).strip == "0"   # the hung exec itself succeeded

    let after = probeLiveness("127.0.0.1", port, ProbeBudgetSec)
    check not after.timedOut
    check after.status == HealthyStatus
    check after.elapsed < 2.5

    # And a real exec round-trips again through the recovered daemon.
    let client = newServeClient("127.0.0.1:" & $port, token)
    var got = ""
    let code = client.execStream(@["quick"], proc(ev: ExecEvent) =
      if ev.kind == ekLog: got.add(ev.line))
    check code == 0
    check "quick-ok" in got

    for h in hangers:
      h.close()

  test "graceful shutdown stops the daemon":
    let client = newServeClient("127.0.0.1:" & $port, token)
    client.shutdown()
    check daemon.waitForExit(timeout = 15000) == 0

  # Fixture teardown.
  if daemon.running:
    daemon.terminate()
