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
