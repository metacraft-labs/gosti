# Windows CI waits for log-pipeline EOF after build actions finish

Status: in-progress. Recorded 2026-09-29.

## Observed

At Gosti `94d3b05`, the retained Windows x64 and ARM64 Reprobuild logs end with
`checked=2/2 built=2/2 running=0 executed`; their steps remained active until
superseded CI was cancelled. At `32b9175`, Windows x64
[job 109427556338](https://github.com/metacraft-labs/gosti/actions/runs/36574789846/job/109427556338)
remains in `Repro build` more than an hour after that step started. These
interrupted runs are not successful build evidence.

Both CI commands pipe Reprobuild through `tee`, which needs EOF from every
inherited writer before it exits. The selected Reprobuild `90dc4321` starts
RunQuota through `std/osproc.startProcess` and deliberately keeps the shared
Windows daemon alive after the invocation. Its open
[daemon pipe issue](../../reprobuild-specs/issues/2026-09-28-auto-started-runquotad-outlives-a-terminated-repro-and-holds-its-callers-pipe.md)
records the descriptor-inheritance mechanism and a similar Windows pipeline
symptom. Direct pipe-owner attribution on these Gosti workers is unavailable;
the Windows root cause remains a hypothesis until the real-command control.

## Expected and repair

[Release validation](../../metacraft-specs/infrastructure/gosti-io-mon-runquota-releases.md)
requires every ordinary build and test command to finish successfully. Capture
Windows command output in a regular log file, wait for the foreground command,
then print the file and return that command's exit status. An independent
background service holding the file must not become a prerequisite for CI
completion. Preserve the complete commands, RunQuota scheduling, errors and
artifact collection; retain streamed POSIX logs.

Validate the capture wrapper with a real child process that exits nonzero
while its own child holds stdout, then run the full Windows Reprobuild gate.
This is a CI logging repair; it does not claim to fix Reprobuild's daemon
inheritance issue. Fetched dev `af517b4`, checked ancestry, and searched current
and deleted Gosti issues for tee, pipes and log capture before recording.

A local real-process control verifies the logging boundary: the foreground
program exits 7 after launching a child that retains stdout. The old pipeline
continues waiting until that child is terminated. `capture-ci-command.sh`
returns 7 promptly, emits the foreground output, and leaves the still-live
child to its owner. Its success path also returns zero. Evidence is retained
in `/tmp/gosti-ci-log-control/`; full Windows Reprobuild CI remains required.
