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
