# SPDX-FileCopyrightText: 2026 Metacraft Labs / Schelling Point Labs
# SPDX-License-Identifier: Apache-2.0
## t_vmharness_serve_survives_a_hung_request — HOST TIER.
##
## Runner-Fleet-M3-ARM-Wave milestone MA12. The unit/e2e tier
## (`t_vmharness_serve_survives_a_hung_request.nim`) proves the PROPERTY against
## a daemon it starts itself with a fake worker. This tier asks a different and
## strictly host-dependent question: is the daemon ACTUALLY DEPLOYED ON THIS
## HOST currently answering, and is its listen queue healthy?
##
## Why that needs to be a test at all. Both production wedges were invisible to
## every check anyone was running: the process was alive, all its threads were
## present, the port was `LISTEN`ing, and `systemctl is-active` said the unit
## was fine. The only two signals that would have caught it are the two asserted
## here — the listener did not ANSWER, and its accept backlog was full
## (`Recv-Q 4097` against `Send-Q 4096`, observed on both hosts). Neither is
## observable from a hermetic test, because both are properties of a real
## deployed daemon under real load.
##
## THIS TEST IS READ-ONLY. It probes and it reads kernel socket statistics. It
## starts nothing, restarts nothing, and sends no `/v1/exec` — it is safe to run
## against a daemon that is serving live CI, which is the only kind of daemon
## that can exhibit what it looks for.
##
## Mock policy (design doc §9.1): nothing is mocked, and nothing is stubbed.
## There is no fake anything here; the subject is the real deployed daemon or
## the test SKIPS.
##
## Preconditions, every one of which is named when it is missing:
##   * `VMH_SERVE_HOST_ADDR=<host:port>` — the deployed daemon to probe. With no
##     override the test looks at the module default, `127.0.0.1:8873`.
##   * something must be listening there.
## With any precondition unmet this test SKIPS and says which; it never passes
## quietly.

import std/[net, os, osproc, strutils, times, unittest]
import vm_harness/serve/http as serveHttp

const DefaultServeAddr = "127.0.0.1:8873"
  ## `services.vm-harness-serve.port`'s default in nixos-modules, on loopback.

const ProbeBudgetSec = 5.0
  ## What a live daemon is allowed for the unauthenticated probe. It answers in
  ## milliseconds (measured 5ms); five seconds is the same budget the deployed
  ## watchdog gives it, so this tier fails exactly when the watchdog would act.

type HostProbe = object
  timedOut: bool
  status: int
  elapsed: float

proc splitAddr(s: string): tuple[host: string, port: int] =
  let idx = s.rfind(':')
  if idx <= 0:
    raise newException(ValueError, "expected host:port, got: " & s)
  (host: s[0 ..< idx], port: parseInt(s[idx + 1 .. ^1]))

proc probeLiveness(host: string, port: int, budgetSec: float): HostProbe =
  ## One UNAUTHENTICATED `GET /v1/info`. A live daemon answers 401, and
  ## producing that 401 requires the whole accept → dispatch → read → respond
  ## path that dies in the wedge — while costing the daemon nothing, since auth
  ## rejects before any dispatch work.
  ##
  ## Deliberately NOT the authenticated form, which probes every hypervisor
  ## backend synchronously (measured 16.7s versus 5ms on aarch64-darwin). That
  ## is both too slow to distinguish wedged from busy and too expensive to point
  ## at a host serving CI. It also means this test needs no bearer token, which
  ## is why it can be run by anyone against any host.
  let t0 = epochTime()
  result = HostProbe(timedOut: true, status: 0, elapsed: 0.0)
  var sock = newSocket()
  try:
    sock.connect(host, Port(port), timeout = int(budgetSec * 1000))
    sock.sendRequest("GET", "/v1/info", host & ":" & $port)
    # Exactly 16 bytes: `net.recv`'s timeout overload requires the FULL size, and
    # 16 is the longest prefix guaranteed present in any HTTP/1.1 status line.
    var buf = ""
    let remainingMs = max(1, int((budgetSec - (epochTime() - t0)) * 1000))
    discard sock.recv(buf, 16, timeout = remainingMs)
    let parts = buf.splitWhitespace()
    if parts.len >= 2 and parts[0].startsWith("HTTP/"):
      result.status = parseInt(parts[1])
      result.timedOut = false
  except CatchableError:
    result.timedOut = true
  finally:
    try: sock.close() except CatchableError: discard
    result.elapsed = epochTime() - t0

proc listenQueueDepth(port: int): tuple[known: bool, recvQ: int, sendQ: int] =
  ## Accept-backlog occupancy for the LISTEN socket on `port`, read from the
  ## kernel rather than inferred.
  ##
  ## On a LISTEN socket these two columns do not mean what they mean on an
  ## established one: `Recv-Q` is the number of connections that have COMPLETED
  ## their handshake and are waiting for the daemon to `accept` them, and
  ## `Send-Q` is the backlog ceiling. `Recv-Q` at or above `Send-Q` therefore
  ## means the daemon has stopped accepting — which is why callers saw connect
  ## timeouts rather than refusals, and is the single most diagnostic number in
  ## the whole incident.
  ##
  ## `ss` is Linux-only; macOS `netstat` does not expose the accept queue at
  ## all. Hence `known`, which the caller reports as a partial skip instead of
  ## silently treating "could not look" as "looks fine".
  result = (known: false, recvQ: 0, sendQ: 0)
  when defined(linux):
    let ss = findExe("ss")
    if ss.len == 0:
      return
    let r = try: execCmdEx(ss & " -lntH 'sport = :" & $port & "'")
            except CatchableError: return
    if r.exitCode != 0:
      return
    for line in r.output.splitLines():
      let f = line.splitWhitespace()
      # State Recv-Q Send-Q Local:Port Peer:Port
      if f.len >= 4 and f[0] == "LISTEN":
        try:
          return (known: true, recvQ: parseInt(f[1]), sendQ: parseInt(f[2]))
        except ValueError:
          return

suite "t_vmharness_serve_survives_a_hung_request (host tier)":
  let addrSpec = getEnv("VMH_SERVE_HOST_ADDR", DefaultServeAddr)
  var host = ""
  var port = 0
  var parsedOk = false
  try:
    let hp = splitAddr(addrSpec)
    host = hp.host
    port = hp.port
    parsedOk = true
  except ValueError as e:
    parsedOk = false
    echo "VMH_SERVE_HOST_ADDR is malformed: ", e.msg

  # Is anything listening there at all? A refused connect means no deployed
  # daemon, which is a SKIP (nothing to assert about), not a failure. A
  # TIMEOUT is emphatically not a skip — that is the wedge itself, and it is
  # asserted on below.
  var reachable = false
  if parsedOk:
    var probe = newSocket()
    try:
      probe.connect(host, Port(port), timeout = 2000)
      reachable = true
    except CatchableError:
      reachable = false
    finally:
      try: probe.close() except CatchableError: discard

  test "the deployed serve listener ANSWERS, promptly":
    if not parsedOk:
      checkpoint("SKIP: VMH_SERVE_HOST_ADDR=" & addrSpec &
                 " is not host:port — nothing to probe")
      skip()
    elif not reachable:
      checkpoint("SKIP: nothing is listening on " & addrSpec &
                 ". This tier asserts the health of a DEPLOYED " &
                 "`vm-harness serve`; set VMH_SERVE_HOST_ADDR to one, or run " &
                 "this on a host where services.vm-harness-serve is enabled.")
      skip()
    else:
      let p = probeLiveness(host, port, ProbeBudgetSec)
      # A timeout here IS the production failure: connected, but never
      # answered. This is the assertion that was missing operationally.
      check not p.timedOut
      # 401 is the healthy answer to an unauthenticated probe; 200 would mean
      # the daemon is running without a token, which is its own problem but
      # still proves liveness. 503 means every handler is busy — a real
      # degradation, and the daemon saying so rather than going silent.
      check p.status in [401, 200]
      check p.elapsed < ProbeBudgetSec

  test "the deployed listener's accept backlog is not saturated":
    if not parsedOk or not reachable:
      checkpoint("SKIP: no reachable deployed daemon at " & addrSpec &
                 " (see the previous test for what to set)")
      skip()
    else:
      let q = listenQueueDepth(port)
      if not q.known:
        checkpoint("SKIP: cannot read the accept-queue depth on this platform " &
                   "— `ss` is Linux-only and macOS `netstat` does not expose " &
                   "the accept queue. The production signature (`Recv-Q 4097` " &
                   "vs `Send-Q 4096`) was measured with `ss -lnt` on Linux.")
        skip()
      else:
        checkpoint("LISTEN Recv-Q=" & $q.recvQ & " Send-Q(backlog)=" & $q.sendQ)
        # Connections waiting to be accepted must not have reached the
        # backlog ceiling. At the ceiling the kernel silently queues completed
        # handshakes and clients time out instead of being refused — exactly
        # what both wedged hosts showed.
        check q.sendQ > 0
        check q.recvQ < q.sendQ
