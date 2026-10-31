# gosti serve — enrollment, signed identity, capability manifest

On top of the `/v1/info` backend list, serve exposes a **signed capability
manifest** plus a lightweight **enrollment/identity model**. Each serve host
presents (a) a signed identity and (b) a machine-checkable manifest describing
its real hardware; a controller reads it over `GET /v1/manifest`, verifies the
signature against its trust store, and **rejects an unenrolled, expired, or
revoked identity**. This manifest is the **source** for runner labels — labels
are DERIVED from proven hardware, not hand-maintained in a class name.

Gate: `t_gosti_serve_enrollment` (hermetic on Linux, `--backend noop`).

## What is served

`GET /v1/manifest` (bearer-auth like every `/v1` route) returns:

```jsonc
{
  "identity": {
    "keyId": "gosti1-3f9a2c1b7e0d4a56",     // stable, non-secret host id
    "host": "high-mem-server",
    "issuedAt": 1757440000,
    "notAfter": 1757443600,                // short-lived (TTL, default 1h)
    "alg": "hmac-sha256",
    "manifest": {
      "manifestVersion": "1",
      "os": "linux",                        // linux | windows | macos
      "arch": "x86_64",                     // x86_64 | arm64 | …
      "archLevel": "x86-64-v3",             // "" for non-x86
      "cpuCount": 32,
      "memTotalMb": 128000,
      "gpu": true,
      "nestedVirt": true,
      "docker": true,
      "podman": false,
      "rrHwCounters": true,
      "hypervisors": [
        {"id": "incus",   "available": true,  "guests": ["linux"]},
        {"id": "libvirt", "available": true,  "guests": ["windows","linux"]}
      ]
    }
  },
  "sig": "<hex HMAC-SHA256 over canonical(identity)>"
}
```

`GET /v1/info` is unchanged: protocol version + the backend
seed. `/v1/manifest` is the new, versioned, signed surface.

`gosti manifest` prints THIS host's **unsigned** manifest locally (no
daemon, no secret) — handy for debugging and as the label-derivation
source. `gosti --remote <addr> manifest` fetches the remote **signed**
identity over `/v1/manifest`.

## Capability detection — how each field is proven

Every capability is a **pure function** over an injected input
(`src/gosti/serve/capability.nim`), so it is asserted against fixtures with
no hardware present (`tests/unit/t_serve_enrollment.nim`). The impure
`detectHostCapabilities` only gathers the inputs from the live host.

| Field           | Source                                             | Rule |
|-----------------|----------------------------------------------------|------|
| `os` / `arch`   | compile-time `defined()` + `hostCPU`               | direct |
| `archLevel`     | `/proc/cpuinfo` `flags` line                        | psABI `x86-64-v{2,3,4}` feature groups; `x86-64-v1` baseline; `""` for arm64 |
| `cpuCount`      | `/proc/cpuinfo` `processor` lines / `countProcessors` | max of the two |
| `memTotalMb`    | `/proc/meminfo` `MemTotal`                          | kB → MiB |
| `gpu`           | `nvidia-smi -L` exit + `lspci`                      | `nvidia-smi` ok OR an lspci VGA/3D/Display line from a known vendor |
| `nestedVirt`    | `/sys/module/kvm_{intel,amd}/parameters/nested`    | either reports `Y`/`1` |
| `docker`/`podman` | `findExe`                                        | binary present on PATH |
| `rrHwCounters`  | `/proc/sys/kernel/perf_event_paranoid` + arch      | x86-64 AND paranoid ≤ 1 (the necessary, machine-checkable precondition; rr does further CPU-model checks at runtime) |
| `hypervisors`   | the daemon's backend registry (`probeAvailability`) | same probe as `/v1/info` |

**Stubbing when a probe binary is absent.** A missing `nvidia-smi`/`lspci`,
absent `/sys/module/kvm_*`, or unreadable `perf_event_paranoid` yields the safe
default `false` ("not proven present") — never a guess. This is the correct
default for label derivation: a host advertises only what its manifest proves.
Off-Linux, the `/proc`-based fields are best-effort, so a controller should
key on `os`/`arch` there; Windows/macOS-native detection
(CIM/`system_profiler`) is not implemented.

## Enrollment / identity / revocation model

- **Per-host enrollment secret.** A 256-bit secret, resolved (in precedence
  order) from `--enroll-secret` > `--enroll-secret-file` > `$GOSTI_ENROLL_SECRET`
  > a secret persisted under `--state-dir` (self-bootstrapped on first run for
  dev). Production provisions it via agenix / systemd `LoadCredential`, exactly
  like the bearer token.
- **keyId** = `"gosti1-" & sha256(secret)[0..15]` — a stable, non-secret host
  identifier, safe to log. The daemon prints it at startup
  (`identity keyId gosti1-… (enroll this keyId on the controller)`).
- **Enrollment** = recording that host's secret in the controller's `TrustStore`
  (`store.enroll(secret)` learns `keyId → secret`). An unenrolled keyId is
  rejected.
- **Signature.** The daemon signs each identity with a detached
  **HMAC-SHA256** over the canonical (sorted-key, compact) JSON of the identity.
  The controller recomputes it with the enrolled secret and compares in
  constant time.
- **Expiry.** Identities are short-lived (`--identity-ttl-sec`, default 3600).
  The controller caches one and re-fetches after `notAfter`; a stale cached
  identity fails verification.
- **Revocation.** `store.revoke(keyId)` — a revoked (or unknown) keyId is
  rejected before the MAC is even checked.

`verify()` decides identity/enrollment status **before** the cryptographic MAC,
and checks expiry **last** (only a signature-valid identity's clock is
trustworthy): `unenrolled` / `revoked` → `bad-payload` (alg/version) →
`bad-signature` → `expired` → `ok`.


### Why symmetric (HMAC), deliberately

The serve endpoint is **already** authenticated + confidential: a bearer token
over a NetBird (WireGuard) overlay, never exposed publicly. This identity
signature is therefore **not** a second transport-auth — it is
capability/identity **advertisement**: its job is tamper-evidence,
host-identity binding, expiry, and revocation on top of a transport that
already provides confidentiality and endpoint auth.

gosti is deliberately dependency-light (`gosti.nimble` requires only
`nim`); Nim's stdlib ships no asymmetric primitive, and linking OpenSSL /
vendoring a curve for a capability-advertisement signature is disproportionate.
So the signature is a vendored, fully test-vectored pure-Nim HMAC-SHA256
(`src/gosti/serve/hmac.nim`, checked against NIST SHA-256 + RFC 4231
vectors). The wire format carries an `alg` field so an asymmetric scheme such
as **Ed25519** (the controller then holds only public keys, and a compromised
controller store cannot forge) can be added as a versioned, non-breaking change.

## The label-derivation contract

A controller consumes THIS manifest. The canonical derivation:

| Manifest field                    | Derived runner label(s) |
|-----------------------------------|-------------------------|
| `os`                              | `linux` / `windows` / `macos` |
| `arch`                            | `x64` (x86_64) / `arm64` |
| `archLevel`                       | `x86-64-v2` / `x86-64-v3` / `x86-64-v4` (a host that proves v3 also satisfies v2) |
| `gpu == true`                     | `gpu` |
| `nestedVirt == true`              | `nested` |
| `docker == true`                  | `docker` |
| `podman == true`                  | `podman` |
| `rrHwCounters == true`            | `rr-hw-counters` |
| `hypervisors[].id` where available| `incus` / `libvirt` / `hyperv` / `tart` |


**Contract for a label linter:** every label a host advertises MUST be a subset
of what its (signed, verified) manifest proves — `advertised ⊆ derived`. The
controller fetches `/v1/manifest`, `verify()`s it, and only then trusts the
manifest to derive labels; an unverifiable manifest yields no labels. Because the
manifest is `manifestVersion`-pinned and signed, the derivation is stable and
tamper-evident.

## Deploying it

A deployment provisions a per-host enrollment secret alongside the serve
bearer token (agenix, delivered via systemd `LoadCredential` on Linux, launchd
on macOS, or the Windows service profile) and passes it as
`--enroll-secret-file`, then records each host's keyId in the controller's
trust store. Revocation is revoking that keyId. `gosti manifest` and
`gosti --remote <addr> manifest` expose the manifest for inspection and
for prototyping the derivation.
