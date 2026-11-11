# gosti serve — remoting daemon

`gosti serve` is an authenticated network front-end that exposes this
host's VM/container lifecycle operations to a remote controller. It is the
**uniform network access point** for every backend (incus, libvirt, Hyper-V,
tart, …) so any host's VMs can be driven from a central controller, such as a
central GARM placing jobs on capability pools.

It is a *thin front-end, not a reimplementation*: every operation is executed
by the **same `gosti` binary** the CLI runs. The daemon adds only the
network endpoint, the auth check, and output streaming.

## Why HTTP/JSON (not gRPC)

- gosti is dependency-light (`gosti.nimble` requires only `nim`).
  HTTP/1.1 + JSON needs only `std/net` + `std/json`, already used across the
  CLI and backends. gRPC would add protobuf tooling + a Nim gRPC library to
  every build.
- A Go GARM provider speaks HTTP/JSON trivially with the Go stdlib.
- Study of Agent Harbor's `ah-remote-exec` informed two choices we adopted:
  an **auth-method** abstraction (AH's key-file / password / agent) — we take
  the bearer-token shape — and **capability tags** on a host — we expose a
  backend/capability list on `/v1/info`, and the full capability manifest on
  `/v1/manifest`. AH drives hosts over **system SSH**; gosti deliberately
  ships its own daemon so one protocol front-ends every backend uniformly.

## Protocol v1

Versioned under the `/v1` URL prefix; every message also carries a `v` field;
`/v1/info` reports `protocol`. Bump `ProtocolVersion` on any breaking change.

All routes require `Authorization: Bearer <token>`; a missing/wrong token is
rejected with **401 before any work runs** (constant-time token comparison).

| Method + path       | Body                              | Response                          |
| ------------------- | --------------------------------- | --------------------------------- |
| `GET  /v1/info`     | —                                 | JSON: protocol, host, backends[]  |
| `GET  /v1/manifest` | —                                 | signed identity + capability manifest |
| `POST /v1/exec`     | `{v, argv[], stdin?, timeoutSec?, userData?}`| chunked NDJSON event stream; `403` when the exec policy refuses the argv |
| `POST /v1/shutdown` | `{}`                              | `{ok:true}`                       |

`GET /v1/manifest` returns a **signed identity** wrapping a
machine-checkable **capability manifest** (os, arch, `x86-64-vN` level, gpu,
nested-virt, docker/podman, rr-hw-counters, the hypervisor backends this daemon
can drive). It is the source a controller derives runner labels from. See
[serve-enrollment.md](serve-enrollment.md) for the schema, the per-field
detection rules, the enrollment/identity/revocation model, and the
label-derivation contract.

`argv` is a full gosti CLI invocation *without* the program name, e.g.
`["run","--backend","incus","--baseline","job-42","--ephemeral", ...]`. The
daemon prepends its configured worker executable and runs it, so the executed
backend code is byte-for-byte the local `gosti` path.

The bearer token is an **operator/controller credential**, not a
per-workflow credential. Never place it in guest user-data or
workflow-visible state. The daemon must remain bound to the operator overlay,
and only the central fleet controller/operator may construct the argv it
sends. The nested-KVM flag has no arbitrary device/path/mode input; it always
selects the audited `/dev/kvm` mapping.

### What the token authorises (the exec policy)

The token proves who is calling; `src/gosti/serve/exec_policy.nim` bounds what
that caller may run. Every `/v1/exec` argv is checked against an allowlist
**before** user-data is staged or a worker is started. A refused argv is
answered `403 {"error": "exec refused by serve policy: <reason>"}` and nothing
runs. The allowlist is the argv the daemon's real clients send:

| Subcommand | Options admitted | Notes |
| --- | --- | --- |
| `provision` | `--backend noop`, `--baseline`, `--log-format` | the provider's noop test recipe only |
| `run --ephemeral` | `--keep`, `--backend`, `--baseline`, `--guest`, `--base-image`, `--source-image`, `--incus-profile`, `--incus-security-nesting`, `--incus-nested-kvm`, `--cpus`, `--memory-mb`, `--uefi-loader`, `--uefi-nvram-template`, `--ephemeral-prefix`, `--timeout-sec`, `--log-format`; a guest command after `--` | `--ephemeral` is required. UEFI paths must resolve, after symlinks and `..`, to a file under `/nix/store/` or `/usr/share/`. `--ephemeral-prefix` must be a plain name |
| `ephemeral-destroy` | `--backend`, `--baseline`, `--log-format` | |
| `ephemeral-label` | `--backend`, `--baseline`, `--label`, `--log-format` | |
| `ephemeral-list` | `--backend`, `--name`, `--label`, `--log-format` | |
| `crud <verb>` | `--backend`, `--baseline`, `--source-image`, `--guest`, `--cpus`, `--memory-mb`, `--disk-gb`, `--env`, `--ssh-user`, `--cwd`, `--run-as`, `--timeout`, `--lock-timeout-sec`, `--force`, `--log-format`; guest argv after `--` | every verb except `copy_to_vm` and `copy_from_vm` |

Every admitted argv must also name a concrete `--backend`: any backend id
except `wsl` and `auto`. A WSL distro is not an isolation boundary from its
Windows host (the host's drives are mounted under `/mnt` and Windows
executables run from inside it), and `auto` picks `wsl` for a Linux guest on a
Windows host. `--baseline` and `--name` must be plain names (letters, digits,
`.`, `_`, `-`; no `..`), because backends build host paths from them, such as
libvirt's `<pool>/<name>.overlay.qcow2`. No option may take `--` as its value,
and no argv element may contain a NUL byte.

Everything else is refused, in particular:

- any other subcommand (`serve`, `probe`, `prune`, `boot`, `layer`, …), and a
  non-ephemeral `run`, which writes to a caller-chosen `--output-dir`;
- every option that names a path on the daemon host: `--mount`, `--user-data`,
  `--meta-data`, `--state-dir`, `--output-dir`, `--copy-to`/`--copy-from`,
  `--golden-image`, `--kernel`/`--initrd`, `--ssh-private-key`, …, and the crud
  `copy_to_vm`/`copy_from_vm` verbs;
- `--remote`, `--auth-token` and `--auth-token-file` in **any** position,
  even after `--`, because the worker's `runCli` lifts them out before parsing.

The check walks the argv the way the worker's `parseCliOpts` does, so it is
not a string match that a spelling can slip past: `argv[0]` is the subcommand
exactly as written (no global options before it, case-sensitive), a value
option consumes the next token, `--x=y` is an unknown option, and `crud`'s
verb is the first positional whether or not it follows `--`.
`t_serve_exec_policy` checks that against the parser itself: for 40 000
seeded adversarial argvs, nothing the policy admits parses to an option that
names a host path.

**User-data** reaches a worker only as the request's inline `userData` bytes.
The daemon writes them to a fresh `0600` file it names itself and inserts
`--user-data <that path>` before the guest argv's `--`. A caller can no longer
name a daemon-host file to be read into a guest.

**Mounts** are not reachable through serve at all: no client of the daemon
sends one. The local CLI (`gosti crud create_vm --mount …`) is the operator's
own authority and is unchanged.

**Blast radius (CRED-3).** The serve bearer token lets its holder create,
label, list and destroy ephemeral guests and crud VMs on that one host, from
images, Incus profiles and the fixed nesting/nested-KVM grants the host
already has, and run commands inside those guests. It cannot run any other
`gosti` subcommand, mount or copy a host path into a guest, have the daemon
read a host file it names, or write a host file it names. An attacker who
holds it gains control of the guests on that host and can use the host's
guest capacity, not the host itself.

Known limits of that sentence, outside what this policy decides:

- **Image references.** For libvirt, Hyper-V and the gosti-run backends,
  `--source-image`/`--base-image` name a golden image file on the host. A
  caller can point them at another disk image the daemon user can read. A
  host-side allowlist of image roots would close this; it needs the
  deployments' image directories, which live in nixos-modules.
- **Incus profiles.** `--incus-profile` attaches any profile that already
  exists on the host, as the provider's configuration chooses. A profile the
  operator defined for another purpose (a privileged one, say) is reachable
  with the token. Only profiles that are safe for runner guests should exist
  on a serve host.
- **The daemon user's own groups.** The policy bounds what gosti does on the
  caller's behalf. It does not bound what the daemon user could do itself:
  `incus-admin` or `libvirtd` membership (granted by nixos-modules'
  `gosti-serve` unit) remains root-equivalent if the daemon process itself is
  compromised (SEC-1 G13, second half).
- **Embedding.** `ServeConfig.execPolicy` replaces the policy for an embedding
  whose worker is not the gosti CLI (the serve plumbing tests' fixture
  workers). The `gosti serve` command never sets it.

### `/v1/exec` event stream (NDJSON, one JSON object per chunk)

```
{"v":"1","type":"log","line":"…one merged stdout/stderr line…"}
{"v":"1","type":"log","line":"…"}
{"v":"1","type":"exit","code":0}          ← terminal
```

The `exit` event is written only after the daemon has reaped the worker and
closed its pipes, so a client may send its next request as soon as it sees
`exit` without racing the previous request's teardown (gosti#69).

`{"type":"error","message":"…"}` is emitted if the daemon cannot start the
worker. The worker's stdout and stderr are **merged**; the stream does not
frame them separately.

On Linux, the selected Nim process launcher creates all stdio and launch-error
pipes with atomic close-on-exec flags. Concurrent workers must not inherit one
another's pipe writers and delay startup or EOF. A small standard-library
compatibility module preserves the existing process API, including child
stdin when the caller's own stdin was closed. The Linux catalog tests real
overlapping launches, inherited pipe identities despite descriptor reuse, stdio
and failed execution. Qualified APIs such as `osproc.Process` remain available.

Exec workers and capability probes share one merged-pipe cleanup routine. It
closes each owned POSIX descriptor once and leaves Windows output-handle
ownership with the standard library. Real descriptor-reuse controls cover both
call paths.

## Auth & network posture

- **Bearer token.** mTLS client-certificate auth is not implemented. The
  token is provisioned via
  `--auth-token-file` (agenix / systemd `LoadCredential` friendly),
  `--auth-token`, or `$GOSTI_SERVE_TOKEN`.
- **Bind to a NetBird overlay IP only, never a public interface.** Over
  NetBird (WireGuard) the bearer token travels encrypted at the network
  layer. The control channel is authenticated and must never be exposed
  publicly.
- **Optional TLS**: compile with `-d:ssl` and pass `--tls-cert` / `--tls-key`
  to wrap the socket for deployments without an overlay. Default builds omit
  TLS to keep the dependency surface minimal.

## Running the daemon

```sh
gosti serve --listen 100.72.0.5:8873 --auth-token-file /run/creds/gosti
# readiness / health: the bound port is written to --port-file when listening.
```

### Concurrency, saturation, and the per-exec deadline

The daemon runs ONE acceptor thread that owns the listening socket, plus a
bounded pool of request handlers (`--serve-threads <n>`, default
`max(4, CPU count)` capped at 32) that the acceptor feeds. This is required by
the control driver (a central GARM), which fires many simultaneous
create/delete/retry calls: a single long-running `/v1/exec` must not stall
unrelated connections past the client's response-header timeout. Each request
already runs in its own isolated child process and touches no shared mutable
state, so coordinating *placement* across hosts remains the central GARM's job,
not this daemon's. A `/v1/shutdown` clears an atomic flag that drains the pool.

Why the acceptor is a SEPARATE thread rather than every handler calling
`accept` (which is what this daemon originally shipped with): a pool in which every member accepts bounds the damage of one
hung request to one slot, but once every slot is hung NOBODY is in `accept`,
and the kernel goes on completing handshakes into the listen backlog until it
fills. That happened twice in production — high-mem-server and gpu-server-001 —
each time leaving a daemon that `systemctl` called `active`, with its port
`LISTEN`ing, `ss -lnt` showing `Recv-Q 4097` against `Send-Q 4096`, and callers
seeing connect/response TIMEOUTS rather than refusals. One outage ran nineteen
hours.

With a dedicated acceptor the daemon always has somebody in `accept`, so it can
always answer. When no handler is free the answer is an immediate
**503 Service Unavailable** (`{"code":"handlers_saturated"}`, `Retry-After: 1`)
rather than silence — actionable for the caller and, unlike a timeout,
detectable by a health probe.

The saturation response must survive a request arriving in multiple TCP
segments. After writing the 503, the acceptor shuts down the send side and
drains incoming bytes without blocking. Closing immediately with unread bytes
can reset the connection and discard the response (RFC 9112 section 9.6).
The acceptor retains at most 64 rejected sockets, for at most one second each,
and reads at most 4 KiB per socket per pass. It checks pending closures at
least every 50 ms while idle. At capacity it retires the oldest retained
socket; failed response writes close immediately. This bounds resource use
without assigning rejection cleanup to an already saturated worker pool.
Normal dispatch and shutdown must remain prompt even when rejected peers
never send, read or close their side.

`--exec-deadline-sec <n>` (default **46800**, thirteen hours) bounds ONE
`/v1/exec`: a worker that overruns is killed and the client is told so in the
event stream. The default is sized ABOVE the longest legitimate operation, not
as a latency target — the GARM provider forwards `--timeout-sec 43200` (12h) on
runner creates because a GitHub Actions job may run six hours and the one-shot
guest must outlive it, so a shorter deadline would kill live runners. Treat it
as a LEAK bound: it guarantees a wedged `ephemeral-destroy` eventually returns
its slot instead of holding it indefinitely.

These three layers bound the damage but cannot bound the OUTAGE if the daemon
wedges for an unanticipated reason. That is the deployment's job: the
`services.gosti-serve` modules in `metacraft-labs/devops-modules` ship a health watchdog
(a systemd timer on Linux, a launchd `StartInterval` job on darwin) that probes
the listener and restarts it after repeated failures.

**Probing liveness cheaply.** Use an UNAUTHENTICATED request; a live daemon
answers `401`, and producing that 401 still exercises accept → dispatch → read
→ respond. Do NOT probe `/v1/info` authenticated on a timer: it synchronously
probes every registered hypervisor backend. Measured on aarch64-darwin
2026-09-18, against the same daemon: **16.7 s authenticated vs 5 ms
unauthenticated.**

### Client disconnects: finish the worker, never spin

A `/v1/exec` client may vanish at any point — central GARM cancels and
SIGKILLs provider processes routinely. The daemon's contract when that happens:

1. **The worker runs to completion.** A disconnect is not a cancellation. A
   `ephemeral-destroy` whose caller went away must still finish, or every
   cancelled delete would abort mid-teardown and leak a guest.
2. **The first failed write marks the client gone, and nothing is written to
   it again.** Any write error (`EPIPE`, `ECONNRESET`, a send timeout, anything)
   is final for that connection: no retry, no backoff loop. From then on the
   handler only DRAINS the worker's output — so the worker can never block on a
   full pipe — and discards it, keeping a short tail (the last 20 lines) that
   is written to the daemon's log when the worker exits, together with its exit
   code and the number of lines the client never saw.
3. **While draining, the handler blocks on the worker, not on the socket.** It
   costs no CPU beyond reading the worker's output.
4. **Every worker is reaped** (`waitpid`) by the handler that spawned it, on
   every exit path — normal exit, deadline kill, and disconnect. The daemon
   never accumulates `<defunct>` children.
5. **A client that stays connected but stops reading** is treated as gone once
   one write has been blocked for `ClientSendTimeoutSec` (300 s), by the same
   rule as (2). Without it such a client would pin the handler in `send`, the
   worker's pipe would fill, and the worker would stall until the exec
   deadline.

Every server-side write — the exec stream, buffered responses, and the
acceptor's saturation 503 — goes through one `sendAll` that raises on the first
hard error. It exists because std/net's `send(Socket, string)` cannot be used
here: with its default `SafeDisconn` flag it treats `EPIPE`/`ECONNRESET` as
"not an error" INSIDE its write-until-done loop without advancing, so a write
to a vanished peer never returns. Measured on high-mem-server: seven handler
threads at ~91% CPU each, 225,086 failed `sendto` calls in 5 s, and 16
unreaped workers (each spinning handler never reached its `waitpid`). The same
loop also resends from offset 0 after a partial write, which would corrupt the
stream. Gated by `t_gosti_serve_client_disconnect_no_spin`.

## Driving a remote host

Any subcommand the daemon's exec policy admits (see "What the token
authorises" above) can take a `--remote <host:port>` flag that forwards it to
a daemon and relays the streamed output + exit code. Anything else is refused
by the daemon and the client exits non-zero:

```sh
export GOSTI_SERVE_TOKEN=$(cat /run/creds/gosti)
gosti --remote 100.72.0.5:8873 ephemeral-list --backend incus
gosti --remote 100.72.0.5:8873 run --ephemeral --backend incus \
  --baseline job-42 --base-image gosti-base \
  --incus-security-nesting --incus-nested-kvm -- true
```

Library consumers use `ServeClient` directly:

```nim
import gosti
let c = newServeClient("100.72.0.5:8873", token)
let info = c.info()                          # capability report
let code = c.execStream(@["run", "--ephemeral", "--backend", "incus",
                          "--baseline", "job-42", "--base-image", "gosti-base",
                          "--", "true"],
                        proc(ev: ExecEvent) =
                          if ev.kind == ekLog: echo ev.line)
```

## Tests

- `tests/unit/t_serve_protocol.nim` — pure wire-contract checks (universal
  layer; in `just test` and the `repro test` catalog).
- `tests/unit/t_serve_exec_policy.nim` — the exec policy: the provider's and
  the crud façade's argv shapes are admitted; other subcommands, host-path
  options, firmware paths escaping their roots (via `..` or a symlink) and
  every bypass spelling are refused; and a seeded property ties the policy to
  the worker's parser. Pure. In `just test`.
- `tests/e2e/t_gosti_serve_exec_policy.nim` — the same through the HTTP
  handler: a refused argv is a 403 and starts no worker (observed through a
  spawn log), allowed argvs still run, and wire `userData` is staged by the
  daemon ahead of the guest argv's `--`. In `just test`.
- `tests/e2e/t_gosti_serve_roundtrip.nim` — the end-to-end gate. A remote
  client drives the provider's noop provision → destroy recipe against a real
  daemon over the authenticated endpoint; asserts that a non-ephemeral `run`
  is refused remotely (403) while the identical argv still runs locally, and
  that an unauthenticated / wrong-credential client is rejected (401). Its fake-Incus
  leg also pins authenticated forwarding of the complete fixed capability
  argv, local pre-start ordering, and exact cleanup without requiring a host
  daemon. Hermetic via a no-threads self-exec topology (the test binary
  re-execs itself as daemon and as CLI worker). In `just test`.
- `tests/e2e/t_gosti_serve_concurrency.nim` — a slow `/v1/exec` must not
  serialize unrelated connections. In `just test`.
- `tests/e2e/t_gosti_serve_survives_a_hung_request.nim` — three layers: one HUNG exec does not stop a concurrent request; a
  FULLY SATURATED pool answers 503 immediately instead of letting connections
  rot in the backlog; and the daemon recovers once the hangs drain. Falsifiable
  in both directions — `GOSTI_HUNG_TEST_THREADS=1` makes layer 1 fail
  (serial-equivalent), and the old accept-in-every-handler daemon passes
  layer 1 but fails layer 2. Hermetic (the worker is a self-exec hang/quick
  role). Before any timed probe, each hanging worker must acknowledge its
  first real streamed output within a bounded startup wait. A live client
  process or a fixed sleep does not establish that a handler is occupied.
  Startup failure fails the fixture; requests are not retried. The 40-second
  hangs and all 2.5-second response bounds remain unchanged. In `just test`.
  Its HOST tier,
  `t_gosti_serve_survives_a_hung_request_host.nim`, is READ-ONLY and
  asserts that a DEPLOYED listener answers and that its accept backlog is not
  saturated; `just test-host`, skips loudly with no deployed daemon.
- `tests/e2e/t_gosti_serve_client_disconnect_no_spin.nim` — the
  disconnect contract above. Clients abandon a chatty exec (more output than a
  pipe buffer holds) mid-stream; asserts the daemon stays idle while the worker
  finishes (CPU time over a fixed window), every worker completes, and after a
  mix of abandoned and completed execs the daemon has ZERO zombie children and
  still answers. Falsifiable: routing the writes back through std/net's
  `send(Socket, string)` makes every assertion fail. Hermetic (self-exec
  worker). In `just test`.
- `tests/e2e/t_gosti_serve_roundtrip_incus.nim` — the same remote path
  against a **real** incus ephemeral container, including authenticated
  selection of the pre-start nesting/KVM policy and guest mode verification.
  Host-gated (`just test-host`), self-skips without usable Incus/KVM; such a
  prerequisite skip is visible but is not claimed as real-host coverage.

- `tests/e2e/t_gosti_serve_enrollment.nim` — the enrollment/identity
  model and `GET /v1/manifest` (hermetic, `--backend noop`). See
  [serve-enrollment.md](serve-enrollment.md).

## Limitations

- The exec stream merges stdout and stderr; there is no framed separation.
- The per-request `timeoutSec` field on the wire is advisory: it is the CLI's
  own `--timeout-sec`. `--exec-deadline-sec` (see "Concurrency, saturation,
  and the per-exec deadline") is the daemon-side backstop for a worker that
  stops responding entirely, which no client-supplied timeout can enforce.
- The signed identity uses HMAC-SHA256 (`alg: "hmac-sha256"`); the wire format
  reserves the `alg` field for an asymmetric scheme. mTLS client-certificate
  transport auth is not implemented.

## Deploying the daemon

- **Windows / Hyper-V**: the reusable recipe is
  [serve-windows-reprobuild.md](serve-windows-reprobuild.md). The per-job
  Hyper-V ephemeral clone the daemon drives is
  `run --ephemeral --backend hyperv` (host lifecycle: New-VHD/New-VM from a
  golden VHDX → boot → JIT-probe → Remove-VM, no residue). Gate
  `t_gosti_serve_win_hyperv` (`just test-host`, Windows + Hyper-V + a
  golden VHDX); the clone logic is unit-tested by `t_hyperv_ephemeral_clone`.
- **macOS / tart**: the nix-darwin/launchd module `services.gosti-serve`
  (`modules/gosti-serve/darwin.nix` in `metacraft-labs/devops-modules`)
  runs the daemon as a root launchd job bound to the NetBird overlay only, and
  drops the per-job tart WORKER to the console user via `--worker-exe` (a
  `launchctl asuser … sudo -E -u #<uid>` wrapper — Tart links AppKit even under
  `--no-graphics` and refuses uid 0). Gate `t_gosti_serve_macos_tart`
  (`just test-host`, macOS + tart + sshpass): a remote client drives a per-job
  ephemeral tart clone (`run --backend tart-{linux-arm,macos} --baseline
  <golden> --ephemeral-prefix <p>` → boot → in-guest probe → destroy, no
  residue).
- **Linux / systemd**: the `services.gosti-serve` module (`modules/gosti-serve/default.nix`) in the same
  repository, which also ships the health watchdog described above.
