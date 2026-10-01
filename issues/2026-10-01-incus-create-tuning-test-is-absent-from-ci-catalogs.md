# Incus create tuning test is absent from both CI catalogs

Status: open. Observed at `348be66f497cd0efb35388c84de72bc82f33d077`.

PR #67 adds `tests/unit/t_incus_create_tuning.nim`, but neither
`scripts/run-tests.sh` nor `repro.nim` references it. The passing workflows at
`de2a970` therefore do not execute its five timeout, environment and real flock
assertion cases. The merge at `348be66` has the same tree.

The [README build contract](../README.md#development) says the Reprobuild graph
models every deterministic test. [AGENTS.md](../AGENTS.md#developing-vm-harness)
identifies both deterministic CI entrypoints. This fixture requires POSIX
flock, but no running Incus service or guest. Include it in the native catalog
and the POSIX Reprobuild catalog, retaining its assertions and real lock calls.

Fetched `agents`, `dev` and `stable` at `348be66`; searched open issues and
archived catalog/inventory issues before recording. The earlier provisioning
records do not cover this newly added test.
