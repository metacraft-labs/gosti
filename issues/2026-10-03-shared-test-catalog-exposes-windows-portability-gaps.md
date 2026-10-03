# Shared test catalog exposes Windows portability gaps

Measured at Gosti `6cb1f1afe10f666337011d3bfdf25a551f28be0a`, Windows x64
[job 111175214559](https://github.com/metacraft-labs/gosti/actions/runs/37113296364/job/111175214559).
The expanded Reprobuild suite reaches its tests and reports 24 failed actions.
This job's failure is separate from the MSYS2 bootstrap outage on other runners.

## Expected behavior

[LOCAL-1 and LOCAL-4](https://github.com/metacraft-labs/metacraft-pm/blob/8af8f4fba25d4f2d2d4add44f292db94f3d4cd16/infrastructure/tool-release-local-followups.md)
require a shared deterministic catalog and preserved assertions. The
[design](../docs/design.md) distinguishes host-specific hypervisors from portable
VM, storage and CLI behavior. Portable checks must run on Windows. Host-specific
fixtures must state their actual prerequisites; a runtime skip cannot prevent
the compiler from compiling unsupported POSIX calls.

## Observed failures

- `t_guest_sees_tpm_device` exits early outside Linux but still compiles `kill`
  and `SIGKILL`. Keep every Linux assertion and make the existing platform
  boundary apply during compilation.
- CRUD and libvirt snapshot tests compare native paths with hard-coded `/`
  separators. Recipe controls assume LF and misread CRLF checkouts.
- swtpm/QEMU fixtures call `bindUnix`; a disk-size fixture explicitly refuses
  non-POSIX hosts; Tart stdout capture uses POSIX descriptors. Shell fixture
  launch paths also fail in Tart and Incus tests.
- Process liveness in overlay/prune tests rejects a live Windows PID; Incus
  slot tests call a POSIX-only locking path. These need separate contract checks.
- The layer-GC fixture cannot find its required real `qemu-img`.
- Shell installer/ISO controls exit `-1073740791`; the concurrency control
  misses its unchanged timing and liveness requirements.

Do not make these gates optional or replace real storage/process checks with
synthetic success. Port supported boundaries, preserve host applicability and
qualify runtime changes on Windows. The original report is retained at
`/tmp/gosti-windows-x64-current-failure.log` on the development host.

## Archive search

Fetched `agents` (`6cb1f1a`) and `dev`, then searched open and deleted issue
history for catalog, Windows, paths, TPM and process signals. The older
`2026-09-28-libvirt-tests-assume-posix-paths-and-executables.md` covers previous
libvirt fixtures; the current report includes newly selected test programs and
other independent boundaries.

## Repairs being qualified

`446c8fd` fixes LF checkout bytes, native CRUD/snapshot paths and the existing
Linux TPM compile-time boundary. The next patch preserves live Windows PIDs
through a real process handle and a zero-time wait, treating uncertain access
as alive. Its child control tests the live state and the exited state while the
parent retains its handle; Windows exit code 259 must still count as exited.
See [OpenProcess](https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-openprocess)
and [WaitForSingleObject](https://learn.microsoft.com/en-us/windows/win32/api/synchapi/nf-synchapi-waitforsingleobject).
QEMU boot arguments now receive the existing name/media validation before the
platform availability check. The prune fixture selects the OS's actual temp
variable and preserves its original environment.

Native executable fixtures replace shell stand-ins in the Incus capability,
Tart command/image/disk, Tart orphan and libvirt domain-enumeration tests.
Their process boundaries and every existing assertion remain; real qcow2
fixtures still require qemu-img. Windows stdout capture uses CRT descriptors,
which are distinct from Windows OS handles. These changes have focused macOS
execution and Windows C-generation checks; native Windows results remain
pending. No failing program is removed from either catalog.

## Windows Incus create slots

The Windows branch of `acquireCreateSlot` previously always returned -1,
so the declared cap never engaged there. Preserve the existing count, timeout
and release contract using an exclusive Windows file share held by a
non-inherited CRT descriptor. `_wsopen_s` supports Unicode paths, and the OS
releases the share on exit. Sharing violations remain contention; other open
failures retain the existing explicit diagnostic. See the
[Microsoft CRT contract](https://learn.microsoft.com/en-us/cpp/c-runtime-library/reference/sopen-s-wsopen-s).
The unchanged same-process exclusivity cases and a new real-child exit/recovery
case pass on macOS at `a783ea6` plus this patch. Windows C generation also passes;
native Windows execution remains required.

## Qualification and Windows command layout

At `a1f67746f5062c26c1f7ba1b3c50c3a6d08af662`, full native and Reprobuild
macOS suites pass 786 cases with the same six existing skips. All 142 actions
succeed and all 71 test programs launch; case names and outcomes match exactly.

The command-name test also required the POSIX installation layout on Windows,
although the Windows release already publishes two byte-identical executables.
The release builder and test now share `scripts/install-binaries.ps1`.
POSIX retains every symlink assertion. Windows requires the two `.exe` files,
identical bytes, matching help and a real daemon through the compatibility name.
At `a1f6774` plus this patch, all three command cases pass on macOS and Windows
C generation succeeds. A real PowerShell run on this Mac installs the built
CLI, verifies both byte-identical aliases and their help, and rejects a missing
source. This is not a claim of native Windows execution.

## Real Windows qcow2 prerequisite

The Reprobuild test actions now declare `qemu-img` on Windows too. The Windows
CI environment installs the actual UCRT64 image utility and its dependencies
through MSYS2's pinned setup action before capturing the Reprobuild environment.
Only its native binary directory is exposed. The existing x64-emulation lane on
ARM64 hosts is retained. MSYS2 authenticates the packages through pacman; the
Reprobuild action records the resolved executable identity.

The required real layer-GC suite passes through Reprobuild on macOS at
`2ceccc8` plus this declaration patch (two successful launched actions), and
workflow actionlint passes. Native Windows provisioning and execution still
require the next Windows CI run. No qcow2 fixture is replaced or skipped.

Sources: [MSYS2 setup action](https://github.com/msys2/setup-msys2),
[QEMU image utility package](https://packages.msys2.org/packages/mingw-w64-ucrt-x86_64-qemu-image-util).

## Follow-up from Windows x64 at a783ea606

[Job 111190807834](https://github.com/metacraft-labs/gosti/actions/runs/37118835650/job/111190807834)
now reports fourteen failed actions, reduced from the earlier twenty-four.
The native command-fixture, path, PID and Linux-TPM repairs remove the earlier
failures they targeted. The new real child with exit status 259 does terminate
and `pidAlive` correctly reports it dead, but Nim's Windows `waitForExit` returns
-1 for that status even after the handle is signaled. Its control now checks the
real signaled process handle and `GetExitCodeProcess` directly, still requiring
exactly 259. It retains the same 5-second bound and the live/dead assertions.

Additional fixture repairs retain all assertions: native path joins for Tart
state resolution; an actual child environment for the Linux recipe shell
instead of a POSIX assignment evaluated by cmd.exe; and a native curl stand-in.
Both shell fixtures retain their real Bash execution, normalize Windows script
path separators, and print the resolved executable and output on abnormal exit.
Their output drains until EOF even if a Windows pipe returns a short read.

At `ce45e80` plus this patch, the four focused native macOS programs pass 34 cases
and generate Windows C. The final shell-only changes pass 15 cases and repeat
Windows C generation. Native Windows validation remains required.

Remaining failures include five POSIX-dependent fixture builds, the previously
identified prerequisites/layout fixes awaiting CI, abnormal Bash termination
(C0000409), and unchanged serve concurrency/saturation gates. The fast-request
batch measured 5.437 seconds against its existing 2.5-second bound; the saturated
pool also timed out instead of returning 503. No timeout or correctness
requirement has been relaxed, and neither Windows runtime failure is attributed
solely from its timing.

## Fixture host contract and portable coverage

At `04a7afa`, the native and Reprobuild macOS suites each pass 786 cases,
with six unchanged platform skips, 142 successful actions and 71 launched
programs. Their case names and outcomes match exactly.

The remaining QWA fixture compile errors arise from the macOS-host backend's
Unix monitor and QMP sockets. Windows ARM in the name denotes the guest;
`QemuWindowsArmBackend.hostPlatform` is `hpMacosArm`, and its availability
probe is false outside macOS. The deterministic lifecycle fixture also runs
on Linux using those real POSIX boundaries. It does not implement a Windows
host backend.

Repair design: declare the actual POSIX prerequisite in the shared catalog
for the Unix socket/lifecycle fixtures. First move portable disk-size policy,
guest-growth and Hyper-V command contracts into their own all-platform test
program. Likewise extract portable golden policy, recipe, manifest, argv and
filesystem cases from the QWA lifecycle fixture into an all-platform program.
Preserve every moved test body and every existing POSIX lifecycle assertion;
compare the combined case inventory before and after. Keep the existing
all-platform QWA backend and overlay controls. Do not replace the actual Unix
socket exchanges with synthetic success or claim Windows host support.

At `ba14e65f65df83b0e8eb475c403747dfef263574` plus this split, lint and the
full native and Reprobuild macOS suites pass: 786 cases, the same six platform
skips, 146 successful actions and all 73 test programs launched. Per-case names
and outcomes match between runners. A byte comparison confirms that every one
of the 98 test bodies in the two split files is unchanged. The new all-platform
programs carry 11 disk-size and 42 golden-contract cases. Their Windows C
generation succeeds. Five POSIX lifecycle programs remain in the deterministic
catalog with their actual platform requirement; they retain all real socket,
process, image, timing and cleanup assertions. Native Windows CI remains required.

## Remaining Windows x64 failures at 4a14028

[Job 111204804217](https://github.com/metacraft-labs/gosti/actions/runs/37123551244/job/111204804217)
now fails five of 67 selected test programs. The prior Bash, Incus, native
command layout and host-specific compilation failures are absent. Three
remaining daemon programs crash at `runServe` line 1069, inside
`Channel.close -> deallocShared -> addToSharedFreeList`, after joining the
acceptor. That thread sends the first message and therefore allocates the
channel's lazy buffer. Under ORC it owns that allocation, so teardown on the
main thread after its exit dereferences the retired allocator. The slow/fast
concurrency case also misses its original 2.5-second/liveness checks (6.760s);
its cause remains separate until measured. Saturated-pool 503 and recovery
controls now pass.

The golden-contract test rejects real SHA-256 command output on Windows.
`fileSha256` requires the first whitespace-delimited token to have length 64;
GNU checksum tools prefix a backslash when escaping Windows path separators,
so a valid checksum token can have length 65. Reproduce with real escaped
filenames and preserve the known-content digest controls before changing this
parser. The layer-GC sweep reports 2.7 GB allocated for each sparse overlay:
`allocatedBytesOf` deliberately substitutes apparent size on Windows, and the
fixture extends files without explicitly requesting NTFS sparse allocation.
Its allocation assertions must remain mandatory.

Repair design within LOCAL-1/LOCAL-4:

- Replace the daemon's lazily allocated standard channel with a bounded POD
  socket-handle queue whose fixed storage and synchronization objects outlive
  every worker. Preserve idle-slot reservation, saturation 503, sentinels and
  join-before-close. Qualify FIFO, bounded backpressure, worker teardown, and the
  existing daemon/concurrency tests without altered waits.
- Accept the checksum tool's single leading escape marker and require exactly
  64 hexadecimal digest characters. Exercise actual files with escaped names,
  retaining all existing provenance/content assertions.
- Report Windows allocated space through the native compressed/sparse-file
  size API. Mark the real Windows fixture sparse before extending it. Keep the
  same 22 real qcow2 overlays, apparent sizes, liveness and reclaimed-byte gates.
  Native Windows CI remains required for the Windows APIs and daemon failure.

At `ef54e59` plus the repair, full local lint and the native macOS suite pass
788 cases with the same six platform skips. The two new queue cases exercise
real sender threads, FIFO wraparound, backpressure at capacity and teardown
after the sender exits. The existing escaped-filename checksum control fails
against the old parser and passes with the repair. All 42 golden contracts and
the real layer-GC fixtures pass. Windows C generation for the layer and serve
programs succeeds; native Windows qualification remains required.

The concurrency control now prints each fast request's first-log and completion
latency without changing its five requests, 2.5-second batch limit, slow-worker
liveness or shutdown assertions. Its local focused run passes both cases. This
diagnostic will distinguish delayed worker output from delayed stream completion
on the failing Windows runner; the source of that timing failure is still open.

## Warm graph catalog invalidation

At `419c38d`, the native runner selects 74 programs, but the local Reprobuild
0.2.2 driver built from clean `c14b1e61` reuses a provider graph with 146 actions
(73 programs). The new queue program is absent even though the catalog itself
is read by the provider when it runs. `loadTestCatalog` uses ordinary file and
directory reads without registering them as provider evaluation inputs. The
warm snapshot therefore misses a catalog-only change. This violates LOCAL-1's
requirement that both runners select the same deterministic programs.

Repair design: declare the catalog's actual file read and the three scanned
test-directory memberships through the provider input API. Keep the shared
parser and every execution requirement. A real warm-graph mutation must detect
an added catalog entry and an unregistered source without clearing caches;
restore both fixture changes afterwards. Require 74 executed programs and
per-case native/Repro parity for this candidate.

At `7965592` plus the provider-input repair, real warm-graph controls pass
without clearing caches. Adding a catalog entry executes its newly registered
program. A catalog-only duplicate fails validation. Adding only an unregistered
source also fails validation, proving directory membership invalidation separately.
Every mutation is restored and the original queue program passes afterwards.
The diagnostic invocation counter was not used as an acceptance condition;
actual selected actions, process launches, outputs and rejection messages were
checked. Full-suite parity remains the final local gate.

## Windows x64 qualification at `9fd0842`

[Reprobuild job 111215656675](https://github.com/metacraft-labs/gosti/actions/runs/37127368268/job/111215656675)
now passes the checksum, 22-overlay sparse allocation, queue and daemon
shutdown cases. Two programs fail: Tart SCP retry and serve concurrency.
The five fast requests take 2.677, 2.055, 2.036, 2.101 and 1.957 seconds,
with nearly all time before their first log. The batch takes 10.826 seconds
and the five-second worker has finished, so all original timing/liveness
assertions correctly fail. SCP reports its existing three-second process
timeout after two attempts. No deadline changed.

Refreshed agents/dev before this measurement and searched open/archive
concurrency records. Next diagnostic compares identical fixture executables
with native execution and real io-mon injection on Windows, retaining their
hashes, all assertions, and the serial one-worker negative control. Only
that comparison can attribute the delay to the daemon, process startup, or
monitor initialization; current timings alone cannot.

## Isolated Repro action evidence

Shared-actions run `37132358264` at `975ca4bc` measured Gosti `9fd0842` with the
same Reprobuild `1f85ace0`, GCC 16.1 and `windows-osproc-jobobject` backend as
full CI. Its retained artifact `11277683601` records both actions successful;
the actual test output has all five fast requests at 58–85 ms. The diagnostic
itself waited for an inherited output pipe after Repro had written its report;
its replacement uses Gosti's existing foreground capture script, matching CI.
That diagnostic cancellation is not a failed product assertion.

Together with the standalone native/debug-monitor/release-monitor controls at
shared-actions `79b77ac`, this narrows the full-suite delay to the concurrent
execution context. Schedule the Tart and serve-concurrency measurement programs
after all test compilations and other test executions, then one at a time.
Retain the shared catalog, automatic monitoring, original deadlines and all
assertions. The deliberate dispatch-lock mutation still fails `< 2.5`; no
serialized server becomes acceptable. Full Windows CI must qualify this ordering.

Replacement diagnostic `37133661896` at shared-actions `ad5b16c` completed
successfully for Gosti `9fd0842`: both focused Repro actions and both direct
executions passed, including all four Tart cases and both concurrency cases.

Local macOS qualification of `79cc9a9` plus the ordering change completed all
148 actions and launched all 74 programs. Its 788 passing cases and six existing
skips match the preceding full native/Repro qualification exactly. The action
trace places Tart after the other 146 actions, and serve concurrency after
Tart completes. No fixture source, assertion, deadline or monitor policy changed.


## Saturation response transport failure at afcaf89

Full Windows x64 run `37134778300`, job `111237481247`, at
`afcaf890dfbd21568eb58642b5ed95b257a6c42b` has 133 successful actions,
one failure and two blocked timing programs. The failure is now the saturation
case in `t_vmharness_serve_survives_a_hung_request`: `timedOut=true` and status
zero. The elapsed `< 2.5` assertion passes despite the probe's six-second read
budget, so the shared `except CatchableError` path may have caught an immediate
transport error. The one-hung-worker, recovery and shutdown cases all pass.
Tart and serve concurrency are blocked by this prerequisite failure; they did
not execute and are not counted as passing.

Artifact `11278823350` retains the complete failure report. Add the caught
exception and elapsed time to the existing saturation checkpoint before
attributing this to contention or changing scheduling. Keep every deadline,
worker, request and assertion. The acceptor currently sends 503 and closes the
socket without reading request bytes; connection reset is a hypothesis pending
a real transport diagnostic, not an established root cause.


### Saturation response teardown reproduced on macOS

At `c7cd6fa1f3002ae39baf542d2f5578e6e4bbf9dc`, the actual compiled daemon
with four real sleeping workers resets a valid request sent in two writes.
Three repetitions each at 1, 10 and 50 ms between the request line and headers
raise `BrokenPipeError(32)` before the client can consume the 503. Three
zero-delay controls receive 503. The workers finish and authenticated shutdown
succeeds. This independently reproduces an actual transport defect; the pending
Windows diagnostic must still attribute its original failure.

`rejectSaturated` sends its response without consuming the request, and the
acceptor immediately closes. RFC 9112 section 9.6 describes the resulting TCP
reset risk and staged close. The existing `docs/serve.md` saturation contract
requires a prompt usable 503. Extend that contract with bounded nonblocking
receive-side draining after the response and a send-side shutdown, retaining
the unchanged timing assertions. Tests must exercise segmented requests,
nonreading peers, saturation recovery and shutdown against the real daemon.


The bounded staged-close repair passes the six-case real-daemon program on
macOS at `2f4cf9b` plus the repair patch. The original four cases retain all
assertions and deadlines. Two additional cases require segmented requests to
receive 503 and exercise 80 silent rejected peers, followed by socket expiry,
recovery and shutdown. Restoring the original server source while compiling
the same new tests fails both new cases with `Broken pipe`; the original
recovery and shutdown cases still pass. Normal lint and Windows C generation
pass. Full native/Reprobuild and native Windows qualification remain required.


### ISO prerequisite must fail closed on POSIX

At `d23d90175493ae7ad78f585a8581e4c7bce848f8`, the full native macOS suite
executes 790 successful cases and six existing platform skips. The full Repro
graph launches all 148 actions successfully, but its case audit finds 789
successes and seven skips: the real config-drive ISO case did not run.
`xorriso` is already declared on that execute action. Its cached provisioning
receipt points to absent `/nix/store/x49dj1x6zzpdrpfml14qh5652ik9vv15-libisoburn-1.5.6`.
This matches the existing Reprobuild tool-retention issue. A new persistent
local root restores that exact declared selector for qualification; this is
not a fix of Reprobuild's provisioning cache.

LOCAL-1 and LOCAL-4 in the authorized tool-release follow-up requirements
require honest native/Repro test coverage. On POSIX, where the development
shell and recipe declare an ISO utility, absence must fail the real ISO case
instead of silently skipping it. Windows retains its existing optional-tool
behavior. All ISO layout, volume-label and payload assertions stay unchanged.
A missing-tool negative control must fail on macOS.


The strengthened ISO prerequisite passes all 49 cases natively and under
Repro on macOS at `d540960` plus the guard patch. Removing all three ISO
executables from an otherwise real tool PATH fails at `require haveIsoTool`;
it no longer reports a successful skip. The pinned xorriso selector is retained
at `/tmp/gosti-catalog-tool-roots/xorriso` during local qualification.

The saturation repair at `d23d9017` passes all six cases in the original
Windows x64 Repro context and in three direct repetitions in shared-actions
[37138570818](https://github.com/metacraft-labs/metacraft-github-actions/actions/runs/37138570818).
The preceding `c7cd6fa1` fails the focused Repro saturation probe with an
immediate empty response in run `37137334706`; three direct repetitions pass.
The first ARM comparison did not reach tests because its supplemental workflow
omitted the production x64-emulation architecture setting. That diagnostic
configuration is corrected; run `37139647990` repeats the same product source
on ARM. Production platform gates and their assertions remain unchanged.


## Reconfiguring a native fixture must preserve its executable

At `ede6c8fdef98c8638dc113f51a381f4552cbd3a2`, full Windows ARM emulation
[run 37140405939](https://github.com/metacraft-labs/gosti/actions/runs/37140405939)
reports 133 successful actions, one failure and two blocked timing programs.
The valid API response case passes. The following invalid-response case fails
in `commandFixture`: copying the same test binary over `curl.exe` returns
Windows sharing violation, before the recipe or its assertions execute.
Artifact `11282367351` retains the stack and failure report. The other four
platform lanes pass. Refreshed `agents`/`dev` and searched open and archived
fixture and `curl.exe` records before adding this evidence.

LOCAL-1 and LOCAL-4 require these portable recipe assertions to run unchanged.
The fixture executable is identical between the two calls; only its JSON
response changes. Reuse an existing executable only after byte-for-byte
comparison with the importing test binary. If absent or different, retain
the ordinary copy and its failure behavior. Always write the requested sidecar.
A regression must invoke both configurations through a real process, prove the
second call preserves the executable modification time, and prove a different
existing executable is replaced. No cleanup failure, lock or assertion may be
ignored. Windows ARM qualification remains necessary.

At `ad41f04` plus the content-reuse patch, all ten recipe cases pass on macOS.
The unchanged original helper fails the new timestamp-preservation assertion
when compiled with the same test source. A separate case starts with different
bytes and requires their replacement plus the new sidecar. On Windows the
reconfiguration case additionally holds a real read-sharing handle that denies
writes, making overwrite rejection independent of translation-cache timing.
Windows C generation and local lint pass; runtime qualification is pending.
The original eight cases and their assertions remain.


At `ae5cbfbabdf2796d48cc7cec3065a53fc3db5a72`, supplemental Windows ARM
[run 37148867357](https://github.com/metacraft-labs/metacraft-github-actions/actions/runs/37148867357)
passes all ten cases in a launched Repro action, including the real
read-sharing handle. All three direct executions of that same binary fail the
second-response and unusable-response assertions: each sees `2.337.0` after
another response was requested. There is no sharing-violation exception in
these direct runs. The cause is not yet established; the successful Repro
execution does not qualify direct execution. Retained `results.json`, the
Repro report and all three native logs distinguish these outcomes.

The next diagnostic must record the exact executable and sidecar paths, the
configuration written and read by actual child processes, and Bash command
resolution. Preserve every response assertion and the executable-reuse
control. Do not introduce retries, delays, service changes or a cache bypass
to make stale response data appear correct.


### Establish the fixture after Bash startup

The actual `actions/runner` latest release queried on 2026-10-03 is `v2.337.0`,
matching the value returned by all three failed direct runs. This makes selection
of the real network curl a plausible cause, not proof of stale sidecar reads.
Git for Windows [documents its wrapper](https://gitforwindows.org/git-wrapper.html):
`Git/bin/bash.exe` adjusts PATH before starting `Git/usr/bin/bash.exe`. The
full diagnostic at shared `4b8073d` is still checking actual command resolution.
Do not attribute the failure to data caching without that evidence.

The recipe fixture must establish its selected command directory inside Bash,
after any wrapper/startup changes, and require that `command -v curl` denotes
the intended native fixture before invoking the recipe. This is part of the
existing hermetic API-response boundary, not a change to the recipe itself.
Preserve all ten current cases and add a real `BASH_ENV` startup script that
puts a competing native curl first. Both commands are private fixtures with
separate invocation logs; the intended one must run and the competing one must
not. Removing the post-startup PATH setup must fail this control without ever
contacting the real API. Test paths must retain spaces/quoting support. Runtime
Windows qualification still decides whether this addresses the observed failure.
