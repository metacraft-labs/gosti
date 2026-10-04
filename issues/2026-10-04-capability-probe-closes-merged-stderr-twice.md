# Capability probes still close merged stdout/stderr more than once

| Field | Value |
| --- | --- |
| Status | Open; repair authorized by the current local-fixes stabilization |
| Observed in | `b80f9a8`, `src/vm_harness/serve/capability.nim`, `runOk` |
| Expectation | `docs/serve.md`: concurrent authenticated info, manifest and exec requests retain their own resources and complete normally |

`runOk` spawns with `poStdErrToStdOut`, then its defer closes the input,
output and error streams and calls `Process.close`. On POSIX, stdout and
stderr share a descriptor. Calling `errorStream` after closing stdout can
adopt another thread's newly opened descriptor with that number; closing it
then damages the other request. The same defect was fixed for exec workers
in `releaseWorkerStdio`, but this capability-probe copy retains it. On Windows,
the standard library owns the process output-handle closes; closing its
streams separately also violates that ownership.

This is a source finding, not yet a reproduced capability-probe failure.
Before this record, `agents` and `dev` refs were refreshed and current and
historical issue subjects were searched for capability, descriptor, close,
merged and fd findings. The existing broad test-portability issue does not
record this remaining call site.

## Repair and verification

Move the already qualified merged-pipe cleanup into a shared helper used by
both exec workers and capability probes. Preserve the existing worker cleanup
API, stage hooks and assertions. Close each owned descriptor once, retaining
the standard Windows handle owner. The helper does not change child lifetime
or request scheduling.

Exercise the real `runOk` path using a self-executed child and deterministic
descriptor reuse immediately after stdout closes. No mock process or file
descriptor is acceptable. The old cleanup must close a planted descriptor and
fail; the shared cleanup must preserve it. Keep real stdout/stderr and exit
status checks, then repeat the full native/Repro suites and platform matrix.

## Local repair evidence

At `a2efbda` plus the shared-cleanup repair, both real capability-probe cases
pass on macOS ARM64: successful and unsuccessful children retain their exit
results, and every descriptor planted during cleanup remains `/dev/null`.
An isolated copy of the original capability code, with only the same post-close
callback added, fails both cases by closing the planted stdout descriptor.
Its original exit-result checks still pass. This confirms the source finding.

The existing three worker descriptor-hygiene cases also pass through the shared
helper without changing their bodies. Full lint and REUSE checks pass. These
focused results do not replace complete native/Repro or Windows qualification.
