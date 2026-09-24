# SPDX-FileCopyrightText: 2026 Metacraft Labs / Schelling Point Labs
# SPDX-License-Identifier: Apache-2.0
## Hermetic regression gate for the libvirt baseline write-lock bug
## (gosti/fix-libvirt-baseline-writelock).
##
## BUG: ``crud create_vm`` on the libvirt backend could not complete
## single-shot. ``crud.createVm`` calls ``provisionBaseline(spec)`` and
## then IMMEDIATELY ``revertToBaselineWithUserData(...)``, which
## CoW-clones the baseline's qcow2 (``qemu-img create -b <baseline-disk>``
## + ``virsh start`` of the overlay). The qcow2-import branch of
## ``provisionBaseline`` used to ``virsh start`` the freshly-imported
## baseline, leaving a running QEMU that held the 'write' lock on the
## backing disk — so the clone failed with "Failed to get shared 'write'
## lock. Is another process using the image?". A baseline is a *template*
## and must be left DEFINED-BUT-OFF so clones can back onto its disk.
##
## This gate proves the fix without a live libvirtd: it puts stub
## ``virsh`` / ``virt-install`` / ``qemu-img`` binaries on PATH (the
## backend resolves them via ``poUsePath``), drives the real
## ``provisionBaseline`` qcow2-import branch, and asserts that
##   (1) the baseline domain is left SHUT OFF (defined, not running), and
##   (2) NO ``virsh start`` was issued against the baseline.
## Against the pre-fix code assertion (2) fails, so this is a genuine
## regression guard, not a tautology.
##
## Mocking justification: the ONLY test doubles are the three CLI
## binaries the backend shells out to. They are stubbed (not a mock
## object) because the branch under test is a pure sequence of subprocess
## invocations against a hypervisor we cannot stand up hermetically; the
## backend code itself — argv construction, ordering, the post-import
## power state decision — runs unmodified and is exactly what we assert
## on. Everything else (filesystem, PATH resolution, the backend object)
## is real.

import std/[os, strutils, tempfiles, unittest]
import vm_harness

when defined(linux):
  proc writeStub(dir, name, body: string) =
    let path = dir / name
    writeFile(path, "#!/usr/bin/env bash\n" & body)
    setFilePermissions(path, {fpUserRead, fpUserWrite, fpUserExec,
                              fpGroupRead, fpGroupExec,
                              fpOthersRead, fpOthersExec})

  suite "libvirt baseline is left off after qcow2-import provision":
    test "provisionBaseline (qcow2 import) leaves the baseline DEFINED-BUT-OFF":
      let stubDir = createTempDir("vmh-stub-bin-", "")
      let poolDir = createTempDir("vmh-pool-", "")
      let stateDir = createTempDir("vmh-stub-state-", "")
      defer:
        removeDir(stubDir); removeDir(poolDir); removeDir(stateDir)

      let logPath = stateDir / "argv.log"
      let marker = stateDir / "domain-defined"
      putEnv("VMH_STUB_LOG", logPath)
      putEnv("VMH_STUB_MARKER", marker)

      # Stateful ``virsh``: the domain does not exist until ``virt-install``
      # "defines" it (drops the marker); thereafter it is reported "shut
      # off". This lets ``provisionBaseline``'s idempotency probe find no
      # domain, proceed, and lets the post-import power-state check see an
      # off template.
      writeStub(stubDir, "virsh", """
echo "virsh $*" >> "$VMH_STUB_LOG"
sub=""
skip=0
for a in "$@"; do
  if [ "$skip" = 1 ]; then skip=0; continue; fi
  case "$a" in
    --connect) skip=1;;
    -*) ;;
    *) if [ -z "$sub" ]; then sub="$a"; fi;;
  esac
done
case "$sub" in
  dominfo)  [ -f "$VMH_STUB_MARKER" ] && exit 0 || exit 1;;
  domstate) if [ -f "$VMH_STUB_MARKER" ]; then echo "shut off"; exit 0; else echo ""; exit 1; fi;;
  list)     [ -f "$VMH_STUB_MARKER" ] && basename "$VMH_STUB_MARKER"; exit 0;;
  *) exit 0;;
esac
""")
      writeStub(stubDir, "virt-install", """
echo "virt-install $*" >> "$VMH_STUB_LOG"
: > "$VMH_STUB_MARKER"
exit 0
""")
      writeStub(stubDir, "qemu-img", """
echo "qemu-img $*" >> "$VMH_STUB_LOG"
for last in "$@"; do :; done
: > "$last" 2>/dev/null || true
exit 0
""")

      putEnv("PATH", stubDir & ":" & getEnv("PATH"))

      # A real (pre-built) qcow2 baseline drives the fast import path.
      let sourceQcow2 = stateDir / "golden.qcow2"
      writeFile(sourceQcow2, "not-a-real-qcow2-but-fileExists-true")

      let b = newLibvirtBackend()
      var spec: BaselineSpec
      spec.name = "windows-test-baseline"
      spec.sourceImage = sourceQcow2
      spec.imagePoolDir = poolDir

      b.provisionBaseline(spec)

      # (1) The baseline is DEFINED (idempotency probe would no-op) …
      check b.domainExists(spec.name)
      # … and OFF — a template whose disk a CoW clone can back onto.
      check b.domainState(spec.name) == "shut off"

      # (2) No ``virsh start`` was ever issued against the baseline. This
      # is the assertion the pre-fix code fails.
      let recorded = readFile(logPath)
      for line in recorded.splitLines():
        let s = line.strip()
        if s.len == 0: continue
        check not (s.startsWith("virsh ") and (" start " in (s & " ")))

      # Sanity: the import path really ran (guards against the test
      # silently short-circuiting before the branch under test).
      check "virt-install " in recorded
      check "qemu-img create" in recorded
else:
  # The fixed branch is ``when defined(linux)``-only; nothing to assert
  # off-Linux, but keep a green, non-empty suite so the gate is uniform.
  suite "libvirt baseline off (non-linux stub)":
    test "skipped off Linux":
      check true
