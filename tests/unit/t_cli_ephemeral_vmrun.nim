# SPDX-FileCopyrightText: 2026 Metacraft Labs / Schelling Point Labs
# SPDX-License-Identifier: Apache-2.0
## `run --ephemeral` must dispatch on the BACKEND, and the vm-harness-run
## backends must not fall through to libvirt.
##
## THE DEFECT THIS PINS. `cmdRunEphemeral` dispatched `incus` and `hyperv` and
## sent everything else into a hardcoded `biLibvirt` body that demands
## `--golden-image`. The central GARM's remote (RB1) provider drives every
## backend with `run --ephemeral --backend <target> … --keep`, so for
## `tart-macos`, `tart-linux-arm` and `qemu-windows-arm` every single
## CreateInstance died with "run --ephemeral: --golden-image is required" —
## a message naming a flag the provider has no reason to send, for a backend
## the libvirt path cannot drive at all. m3's linux-arm64, macos-arm64 and
## windows-arm64 POOLS therefore sat with every runner in `error` while the
## same guest classes served CI happily through the per-host GARM, which uses
## the local-exec path instead.
##
## WHY THESE ASSERTIONS AND NOT A LIFECYCLE TEST. Actually booting a tart or
## QEMU guest needs a golden and a macOS host, which is the host tier's job
## (`scripts/run-host-tests.sh`). What is checkable here — and what actually
## broke — is the ROUTING and the two pieces of state that make a kept
## instance reclaimable. A test that only asserted "tart is in the dispatch
## set" would pass against a stub; these drive the real code paths.

import std/[json, options, os, strutils, tables, tempfiles, unittest]
import vm_harness/cli
import vm_harness/types
import vm_harness/ephemeral_handle

suite "ephemeral dispatch for vm-harness-run backends":

  test "the vm-harness-run backends are the ones GARM drives by local exec":
    # If this set and the provider's local-exec backend list ever disagree, one
    # controller can create a guest class the other cannot, which is the whole
    # bug class this change exists to close.
    check biTartMacos in VmRunEphemeralBackends
    check biTartLinuxArm in VmRunEphemeralBackends
    check biQemuWindowsArm in VmRunEphemeralBackends
    check biUtmWindowsArm in VmRunEphemeralBackends
    # Backends with their OWN ephemeral lifecycle must NOT be in it — adding
    # one would silently take incus or hyperv off its dedicated path.
    check biIncus notin VmRunEphemeralBackends
    check biHyperv notin VmRunEphemeralBackends
    check biLibvirt notin VmRunEphemeralBackends

  test "every backend routes to its own ephemeral lifecycle":
    # THE REGRESSION, stated directly: before this change the three below
    # resolved to epLibvirt, so the central GARM's remote provider could not
    # create a single tart or QEMU guest.
    check ephemeralPathFor("tart-macos") == epVmRun
    check ephemeralPathFor("tart-linux-arm") == epVmRun
    check ephemeralPathFor("qemu-windows-arm") == epVmRun
    check ephemeralPathFor("utm-windows-arm") == epVmRun
    # Unchanged routes.
    check ephemeralPathFor("incus") == epIncus
    check ephemeralPathFor("hyperv") == epHyperV
    check ephemeralPathFor("libvirt") == epLibvirt

  test "an unknown backend still falls to libvirt, not to a parse error":
    # Dispatch matches on the string precisely so an unknown --backend keeps
    # failing where it always did. Parsing first would raise "Unknown backend"
    # from the dispatcher, a different error from a different layer.
    check ephemeralPathFor("not-a-backend") == epLibvirt
    check ephemeralPathFor("") == epLibvirt

  test "the golden comes from the flags the provider actually sends":
    # garm-provider-vmharness forwards the golden as --source-image /
    # --base-image, never --golden-image.
    check resolveEphemeralGolden("", "/g/src", "", "tart-macos") == "/g/src"
    check resolveEphemeralGolden("", "", "oci:base", "tart-linux-arm") == "oci:base"
    # An explicit --golden-image wins, matching the hyperv path's precedence.
    check resolveEphemeralGolden("/g/explicit", "/g/src", "oci:base",
                                 "qemu-windows-arm") == "/g/explicit"

  test "a missing golden names the flags the caller can pass":
    # The old libvirt fallthrough said "--golden-image is required", pointing
    # every reader at a flag the provider has no reason to send and away from
    # the real fault — that the request had been routed to libvirt at all.
    for backend in ["tart-macos", "tart-linux-arm", "qemu-windows-arm"]:
      var msg = ""
      try:
        discard resolveEphemeralGolden("", "", "", backend)
      except ValueError as e:
        msg = e.msg
      check msg.len > 0
      check backend in msg          # which lane failed
      check "--source-image" in msg # and what to do about it
      check "--base-image" in msg
      check not msg.contains("run --ephemeral: --golden-image is required")

suite "kept-instance handles survive the process that made them":

  setup:
    let root = createTempDir("vmh-eph-", "-test")
    putEnv(EphemeralStateDirEnv, root)

  teardown:
    delEnv(EphemeralStateDirEnv)

  test "a handle round-trips with everything stopAndCleanup needs":
    # These three `extra` keys ARE the teardown for qemu-windows-arm. Losing
    # any of them leaks a running QEMU, a swtpm and a multi-GB overlay that
    # nothing knows how to reclaim.
    var extra = initTable[string, string]()
    extra["qemuPid"] = "4242"
    extra["swtpmPid"] = "4243"
    extra["vmDir"] = "/private/var/lib/vm-harness/qemu-windows-arm/instances/repro-vm-x"
    let vm = VmHandle(
      backend: nil,
      name: "repro-vm-qemu-windows-arm-1789745025315-96801",
      baseline: "/golden/win-arm-runner",
      ipAddress: some("127.0.0.1"),
      sshPort: 55022,
      sshUser: "runner",
      sshAuth: SshAuth(kind: saPassword, password: "provisioning-pw"),
      extra: extra)
    saveEphemeralHandle("qemu-windows-arm", "garm-abc123", vm)

    let back = loadEphemeralHandle("qemu-windows-arm", "garm-abc123", nil)
    check back.isSome
    let got = back.get
    check got.name == vm.name
    check got.sshPort == 55022
    check got.sshUser == "runner"
    check got.ipAddress == some("127.0.0.1")
    check got.sshAuth.kind == saPassword
    check got.sshAuth.password == "provisioning-pw"
    check got.extra["qemuPid"] == "4242"
    check got.extra["swtpmPid"] == "4243"
    check got.extra["vmDir"] == extra["vmDir"]

  test "a record holding a password is not world-readable":
    let vm = VmHandle(backend: nil, name: "n", baseline: "b",
                      ipAddress: none(string), sshPort: 22, sshUser: "u",
                      sshAuth: SshAuth(kind: saPassword, password: "s3cret"),
                      extra: initTable[string, string]())
    saveEphemeralHandle("tart-macos", "garm-perm", vm)
    let perms = getFilePermissions(handlePath("tart-macos", "garm-perm"))
    check fpGroupRead notin perms
    check fpOthersRead notin perms

  test "no record is a no-op, because GARM retries deletes":
    # A delete for an instance that is already gone must not error, or the
    # controller retries forever against nothing.
    check loadEphemeralHandle("tart-macos", "never-existed", nil).isNone
    forgetEphemeralHandle("tart-macos", "never-existed")  # must not raise

  test "forget removes the record":
    let vm = VmHandle(backend: nil, name: "n", baseline: "b",
                      ipAddress: none(string), sshPort: 0, sshUser: "u",
                      sshAuth: SshAuth(kind: saNone),
                      extra: initTable[string, string]())
    saveEphemeralHandle("tart-linux-arm", "garm-gone", vm)
    check loadEphemeralHandle("tart-linux-arm", "garm-gone", nil).isSome
    forgetEphemeralHandle("tart-linux-arm", "garm-gone")
    check loadEphemeralHandle("tart-linux-arm", "garm-gone", nil).isNone

  test "a baseline cannot escape the state root":
    # --baseline is attacker-adjacent input that becomes a FILENAME: it comes
    # from the controller over the wire. A traversal must be neutralised, not
    # merely unlikely.
    let vm = VmHandle(backend: nil, name: "n", baseline: "b",
                      ipAddress: none(string), sshPort: 0, sshUser: "u",
                      sshAuth: SshAuth(kind: saNone),
                      extra: initTable[string, string]())
    saveEphemeralHandle("tart-macos", "../../../../etc/passwd", vm)
    let p = handlePath("tart-macos", "../../../../etc/passwd")
    # The property that matters: the record lands in ONE known directory under
    # the root, named by ONE path component. Separators in the key are what
    # would make it escape, so assert on the shape of the resolved path rather
    # than on the absence of a substring.
    check p.startsWith(ephemeralStateRoot())
    check p.parentDir == ephemeralStateRoot() / "tart-macos"
    check not p.extractFilename.contains(DirSep)
    check not p.extractFilename.contains("..")
    check fileExists(p)
    # And nothing was created outside the root.
    check not fileExists("/etc/passwd.json")

suite "the detached bootstrap must outlive its SSH session":

  test "Windows uses Win32_Process.Create, never Start-Process":
    # Measured on m3: Windows OpenSSH puts every process of a session into a
    # job object and kills the job at session end, so a Start-Process child is
    # gone seconds after the session closes — which for a runner bootstrap
    # means the guest registers and then dies. Win32_Process.Create is created
    # by the WMI provider host, outside that job.
    let argv = buildDetachedBootstrapCommand(goWindows, "C:\\garm-bootstrap.ps1")
    let joined = argv.join(" ")
    check "Win32_Process" in joined
    check "Create" in joined
    check "Start-Process" notin joined
    check "C:\\garm-bootstrap.ps1" in joined
    # sshd's DefaultShell is powershell, so an OUTER parse expands `$` inside
    # double quotes before the inner command exists. A `$` here is a live bug,
    # not a style point — the same trap buildSysprepRemoteCommand documents.
    check '$' notin joined

  test "unix detaches and releases all three streams":
    for guest in [goLinux, goMacos]:
      let argv = buildDetachedBootstrapCommand(guest, "/tmp/garm-bootstrap.sh")
      let joined = argv.join(" ")
      check "nohup" in joined
      check joined.endsWith("echo started") or "&" in joined
      # Holding the session's stdout keeps the SSH channel open, so execInGuest
      # would block for the runner's whole life — the exact foreground
      # behaviour the ephemeral path exists to avoid.
      check ">/dev/null" in joined
      check "2>&1" in joined
      check "</dev/null" in joined
      check "chmod +x" in joined
