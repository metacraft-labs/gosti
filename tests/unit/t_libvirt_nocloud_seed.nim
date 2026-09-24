# SPDX-FileCopyrightText: 2026 Metacraft Labs / Schelling Point Labs
# SPDX-License-Identifier: Apache-2.0
## Hermetic gate for the libvirt NoCloud cloud-init seed (GOSTI2 honor-userdata
## follow-up): a real backend BUILDS a NoCloud "cidata" seed from the caller's
## cloud-init user-data and ATTACHES it to the domain definition.
##
## No mocks, no hypervisor, no libvirtd, no network, no subprocess. Everything
## under test is a pure function:
##
##   * ``buildNoCloudIso`` / ``writeNoCloudIso`` — the ISO9660 seed builder
##     (``user-data`` + ``meta-data`` under a ``CIDATA`` volume label). We
##     round-trip the caller's user-data through the produced bytes.
##   * ``buildEphemeralDomainXml`` — the pure domain-XML renderer. With
##     ``EphemeralCloneSpec.noCloudSeedIso`` set it must emit a read-only CD-ROM
##     device pointing at the seed ISO, so a cloud-init guest auto-detects the
##     ``cidata`` datasource on first boot.
##   * ``LibvirtBackend.honorsUserData`` — the capability signal the CRUD guard
##     consults; must be true for libvirt (and false on the base/other backends,
##     asserted via the mock).
##
## Booting a real cloud-init guest end-to-end (proving the injected user-data
## actually executes) needs a cloud-init-enabled golden image and a live
## libvirtd; that is out of scope here and tracked as a real-VM follow-up. This
## gate proves the seam up to "the seed is built and attached to the domain
## definition", which is exactly the GOSTI2 deliverable.

import std/[strutils, os, tempfiles, unittest]
import vm_harness

const SampleUserData =
  "#cloud-config\n" &
  "runcmd:\n" &
  "  - /opt/actions-runner/config.sh --token AABBCCDD-REGISTRATION\n"

suite "libvirt NoCloud seed — build + round-trip":
  test "buildNoCloudIso round-trips the user-data and carries the CIDATA label":
    let iso = buildNoCloudIso(SampleUserData, "instance-id: ci-1\n")
    check iso.len > 0
    # The seed is stored uncompressed, so the user-data bytes appear verbatim
    # in the ISO extent — a hermetic round-trip of the injected payload.
    let blob = cast[string](iso)
    check SampleUserData in blob
    check "instance-id: ci-1" in blob
    # ISO9660 PVD volume identifier doubles as the filesystem label udev
    # surfaces; cloud-init's NoCloud datasource probes for exactly "cidata".
    check "CIDATA" in blob
    # The root directory names the two files cloud-init reads by exact name.
    check "user-data" in blob
    check "meta-data" in blob

  test "writeNoCloudIso writes a non-empty seed file with the same payload":
    let dir = createTempDir("vmh-seed-", "")
    defer: removeDir(dir)
    let path = dir / "seed.iso"
    writeNoCloudIso(path, SampleUserData, "instance-id: ci-2\n")
    check fileExists(path)
    let bytes = readFile(path)
    check bytes.len > 0
    check SampleUserData in bytes

# ---------------------------------------------------------------------------
# The domain-XML renderer must ATTACH the seed as a read-only CD-ROM. This is
# the "attached to the domain definition" half of the deliverable.

suite "libvirt NoCloud seed — attached to the domain XML":
  let b = newLibvirtBackend()

  test "with a seed ISO the domain XML references it as a read-only cdrom":
    let seedIso = "/storage/libvirt/ci-abc123.cidata.iso"
    let spec = EphemeralCloneSpec(
      name: "ci-abc123",
      goldenImage: "/storage/libvirt/base.qcow2",
      noCloudSeedIso: seedIso)
    let xml = b.buildEphemeralDomainXml(spec, "/storage/libvirt/ci-abc123.overlay.qcow2",
                                        "/tmp/ci-abc123.serial.log")
    # A CD-ROM device pointing at the exact seed ISO, read-only, on its own
    # target (sdb — sda is the Windows config-drive slot, so the two coexist).
    check "device='cdrom'" in xml
    check ("<source file='" & seedIso & "'/>") in xml
    check "dev='sdb'" in xml
    # It must be read-only so the guest cannot mutate the seed.
    let seedBlock = xml[xml.find(seedIso) - 200 .. min(xml.len - 1, xml.find(seedIso) + 200)]
    check "<readonly/>" in seedBlock

  test "without a seed ISO no cidata cdrom is emitted (behaviour-preserving)":
    let spec = EphemeralCloneSpec(
      name: "plain",
      goldenImage: "/storage/libvirt/base.qcow2")
    let xml = b.buildEphemeralDomainXml(spec, "/storage/libvirt/plain.overlay.qcow2",
                                        "/tmp/plain.serial.log")
    check "cidata" notin xml
    check "dev='sdb'" notin xml

  test "the per-instance seed path is named after the domain":
    check b.noCloudSeedIsoPathFor("ci-abc123").endsWith("ci-abc123.cidata.iso")

  test "back-to-back ephemeral names are unique (same-ms concurrency guard)":
    # The domain name, the .cidata.iso seed path and the .overlay.qcow2 overlay
    # all derive from this one name, so two same-millisecond creates MUST NOT
    # collide. The atomic counter (+ per-process salt) guarantees it even when
    # the ms timestamp is identical.
    var seen: seq[string]
    for _ in 0 ..< 1000:
      seen.add(ephemeralInstanceName("base"))
    check seen.len == 1000
    # No duplicates across a tight loop (identical baseline, mostly same ms).
    var uniq: seq[string]
    for n in seen:
      check n notin uniq
      uniq.add(n)
    check ephemeralInstanceName("base") != ephemeralInstanceName("base")

# ---------------------------------------------------------------------------
# The capability signal the CRUD guard keys on.

suite "libvirt NoCloud seed — capability signal":
  test "libvirt honorsUserData is true; a plain mock backend is false":
    let lv: VmBackend = newLibvirtBackend()
    let mk: VmBackend = newMockBackend()
    check lv.honorsUserData()
    check not mk.honorsUserData()
    # No backend attaches mounts yet, so --mount stays fail-closed everywhere.
    check not lv.honorsMounts()
    check not mk.honorsMounts()
