# Sequential CRUD teardown hides the daemon exit status

| | |
|---|---|
| Status | open; diagnostic repair in progress |
| Recorded | 2026-10-03 |
| Observed in | Gosti `ae5cbfbabdf2796d48cc7cec3065a53fc3db5a72`, Linux ARM64 |
| Area | `tests/e2e/t_vmharness_serve_sequential_crud.nim`, `stopDaemon` |

## Observed

Full Repro run [37149676404](https://github.com/metacraft-labs/gosti/actions/runs/37149676404)
reports 146 successful actions, one failure and two blocked actions on Linux
ARM64. The delayed-cleanup case raises `No such process` from `terminate` in
`stopDaemon`. The following 200-request case passes. Artifact `11285125744`
preserves the report and full log. The actual daemon exit code is lost.

The helper calls `waitForExit(8000)`, then signals the process whenever the
returned code is nonzero, even if that wait already reaped it. Nim 2.2.4's
POSIX timed wait also kills and reaps a child on timeout. Therefore this trace
does not distinguish an abnormal exit from an expired shutdown deadline.
Neither cause has yet been measured. The same helper is unchanged at refreshed
`agents` `581f225`; open and deleted issue history was searched before filing.

## Expected

[Serve protocol](../docs/serve.md), the pool shutdown contract, requires the
shutdown flag to drain the pool. The release follow-up requirement LOCAL-4
preserves the existing cleanup bounds and must not hide abnormal exits.
A completed child must not be signalled again. Preserve the original eight-second
wait and three-second forced-termination bound and report the actual status.
An abnormal exit or timeout remains a test failure, not successful cleanup.

## Repair and qualification

Make teardown close its process handle on every path, distinguish a still-live
child from a reaped one, and fail explicitly with its exit status. Keep every
original timing and CRUD assertion. Add real child-process controls for already
completed successful and nonzero exits; the latter must remain a failure carrying
its original status. Enable the fixture daemon's existing diagnostic output so
another platform failure can identify its last shutdown stage. Do not increase
bounds, suppress errors, remove monitoring or reduce the 200-request workload.
The original Linux ARM failure stays open until its actual exit cause is known
and the unchanged full-suite gate passes.

## Local diagnostic repair — 2026-10-03

On macOS ARM64, the repair based on `79c941e40c7929161b4a75283b592ef52f4de400`
passes all four cases, including the two original case bodies byte for byte.
The new controls use real children that have already exited with statuses zero
and 17. Restoring only the previous teardown helper makes the status-17 control
fail with `No such process`; the repaired helper reports `daemon exited with
status 17`. Windows x64 C generation also passes. The existing eight-second
wait, three-second forced cleanup, 1.5-second ordering delay and 200-request
workload remain unchanged. Existing daemon logging is enabled for platform
diagnosis. These results qualify the diagnostic repair, not the still-unknown
Linux ARM64 shutdown cause.
