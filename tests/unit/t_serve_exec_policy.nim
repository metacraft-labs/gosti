# SPDX-FileCopyrightText: 2026 Metacraft Labs / Schelling Point Labs
# SPDX-License-Identifier: Apache-2.0
## t_serve_exec_policy — what a ``gosti serve`` bearer token may run
## (SEC-1 G13; ``src/gosti/serve/exec_policy.nim``).
##
## Pure checks of ``gostiExecPolicy``: the provider's and the crud façade's
## real argv shapes are admitted, and every way found to reach a host path or
## another subcommand is refused — global options before the subcommand,
## ``--`` tricks, ``=``-joined options, repeated subcommands and flags, case
## and whitespace variants, the client-only ``--remote`` family, firmware
## paths that escape their roots through ``..`` or a symlink, paths through
## the magic ``/proc`` and ``/dev/fd`` directories (whose reason names the
## directory the host's ``/dev/stdin`` actually reaches: ``/proc`` on Linux,
## ``/dev/fd`` elsewhere), and a file spelled ``f/`` or ``f/.``, refused
## before resolution because BSD ``realpath`` would accept it.
##
## The last suite ties the policy to the WORKER's parser: for a large,
## seeded set of adversarial argvs, everything the policy admits must parse
## (``cli.parseCliOpts``) to options that name no daemon-host path. That is
## what makes this an allowlist of meanings and not of spellings.
##
## The operator-configured half (G13 residuals): golden images
## (``--source-image`` / ``--base-image``) must be a disk image of the
## backend's format, resolved through every symlink, under
## ``ExecPolicyConfig.imageRoots`` when the operator set any; Incus image
## names may not be paths or options; ``--incus-profile`` must be on the
## profile allowlist (``default`` unless configured). Also the ``gosti serve
## --allow-image-root`` / ``--allow-incus-profile`` parsing and their
## environment fallbacks.
##
## The end-to-end half (HTTP 403, no worker spawned) is
## ``tests/e2e/t_gosti_serve_exec_policy.nim``. Hermetic.

import std/[json, os, osproc, posix, random, strutils, tempfiles, unittest]
import gosti
import gosti/cli
import ../disk_image_fixtures

proc allowed(argv: seq[string],
             pc: ExecPolicyConfig = ExecPolicyConfig()): bool =
  gostiExecPolicy(argv, pc).len == 0

proc refusedWith(argv: seq[string], fragment: string,
                 pc: ExecPolicyConfig = ExecPolicyConfig()): bool =
  let r = gostiExecPolicy(argv, pc)
  if r.len == 0:
    echo "  NOT refused: ", argv
    return false
  if fragment notin r:
    echo "  refused, but reason lacks '", fragment, "': ", r
    return false
  true

proc publicFirmwareFile(): string =
  ## A real file under one of ``FirmwareRoots`` to stand in for OVMF. The dev
  ## shell's tools live in /nix/store; a distro host has /usr/share.
  for exe in ["sh", "nim", "bash"]:
    let p = findExe(exe)
    if p.len > 0:
      let real = expandFilename(p)
      for root in FirmwareRoots:
        if real.startsWith(root): return real
  for root in FirmwareRoots:
    if dirExists(root):
      for f in walkDirRec(root):
        if fileExists(f): return f
  ""

# ---------------------------------------------------------------------------
# Image fixtures (``tests/disk_image_fixtures.nim``): structurally valid
# headers and zeros. The policy sniffs the container format and parses only
# what would make a hypervisor open ANOTHER file.
# ---------------------------------------------------------------------------

proc writeImage(path, magic: string, size = 4096) =
  ## Magic bytes and nothing else: NOT a valid header.
  writeFile(path, magic & repeat('\0', size - magic.len))

let fixtures = createTempDir("gosti-policy-img-", "")
let imgRoot = fixtures / "images"        ## the operator's configured root
let outside = fixtures / "elsewhere"     ## NOT a root
let siblingRoot = fixtures / "images-other"  ## shares imgRoot's name prefix
createDir(imgRoot)
createDir(outside)
createDir(siblingRoot)
let goldenQcow2 = imgRoot / "golden-win11.qcow2"
writeQcow2(goldenQcow2)
let goldenVhdx = imgRoot / "golden.vhdx"
writeVhdx(goldenVhdx)
let goldenVhdFixed = imgRoot / "fixed.vhd"   # fixed VHD: footer only
writeVhdFixed(goldenVhdFixed)
let installerIso = imgRoot / "installer.iso"
writeIso(installerIso)
let goldenDir = imgRoot / "win-arm-runner"    # qemu-windows-arm golden
createDir(goldenDir)
writeQcow2(goldenDir / QwaBaseDiskName)
writeFile(goldenDir / QwaGoldenManifestName, "{}")
let outsideQcow2 = outside / "other-lane.qcow2"
writeQcow2(outsideQcow2)
let siblingQcow2 = siblingRoot / "g.qcow2"
writeQcow2(siblingQcow2)
let notAnImage = imgRoot / "serve-token"      # a secret in the root
writeFile(notAnImage, "serve-bearer-secret\n")
let linkEscape = imgRoot / "escape.qcow2"     # in the root, points out
createSymlink(outsideQcow2, linkEscape)
let linkToDevice = imgRoot / "dev.qcow2"
createSymlink("/dev/zero", linkToDevice)
let linkInward = outside / "inward.qcow2"     # out of the root, points in
createSymlink(goldenQcow2, linkInward)
let dotDotEscape = imgRoot & "/../elsewhere/other-lane.qcow2"
  ## Spelled with ``&``: ``os./`` would normalise the ``..`` away.
let fifo = imgRoot / "fifo.qcow2"
doAssert mkfifo(fifo.cstring, 0o600) == 0
let rootLink = fixtures / "root-link"         # a root that is a symlink
createSymlink(imgRoot, rootLink)

let hostPolicy = ExecPolicyConfig(imageRoots: @[imgRoot],
                                  incusProfiles: @["default", "ci-store"])
  ## A configured serve host: one image root, two profiles.

# The exact argv shapes ``garm-provider-gosti`` builds (nixos-modules
# packages/garm-provider-gosti/src/internal/backend/remote.go:
# noopRecipe, ephemeralRecipe, label, inventory). Every one is admitted by
# the DEFAULT config (``gosti serve`` with no allowlist flags), which is how
# nixos-modules be58b2e's ``modules/gosti-serve`` starts the daemon.
let providerArgvs = @[
  @["provision", "--backend", "noop", "--baseline", "garm-a1",
    "--log-format", "json"],
  @["ephemeral-destroy", "--backend", "noop", "--baseline", "garm-a1",
    "--log-format", "json"],
  @["run", "--ephemeral", "--backend", "incus", "--baseline", "garm-a1",
    "--keep", "--log-format", "json"],
  @["run", "--ephemeral", "--backend", "incus", "--baseline", "garm-a1",
    "--base-image", "runner-base", "--source-image", "runner-base",
    "--incus-profile", "default",
    "--incus-security-nesting", "--incus-nested-kvm",
    "--cpus", "4", "--memory-mb", "8192", "--keep", "--log-format", "json"],
  @["run", "--ephemeral", "--backend", "tart-linux-arm", "--baseline",
    "garm-a1", "--base-image", "ghcr.io/x/y:1", "--source-image",
    "ghcr.io/x/y:1", "--keep", "--log-format", "json"],
  # Remote libvirt (hms-libvirt: a qcow2 golden under /storage/iso, OVMF
  # firmware via /run/libvirt/nix-ovmf, 4 vCPU / 16 GiB). The firmware is
  # added per test where the host has a file under FirmwareRoots.
  @["run", "--ephemeral", "--backend", "libvirt", "--baseline", "garm-a1",
    "--base-image", goldenQcow2, "--source-image", goldenQcow2,
    "--cpus", "4", "--memory-mb", "16384", "--keep", "--log-format", "json"],
  @["run", "--ephemeral", "--backend", "hyperv", "--baseline", "garm-a1",
    "--base-image", goldenVhdx, "--source-image", goldenVhdx, "--keep",
    "--log-format", "json"],
  @["run", "--ephemeral", "--backend", "qemu-windows-arm", "--baseline",
    "garm-a1", "--base-image", goldenDir, "--source-image", goldenDir,
    "--keep", "--log-format", "json"],
  @["run", "--ephemeral", "--backend", "tart-macos", "--baseline", "garm-a1",
    "--base-image", "macos-runner", "--source-image", "macos-runner",
    "--keep", "--log-format", "json"],
  @["run", "--ephemeral", "--backend", "utm-windows-arm", "--baseline",
    "garm-a1", "--base-image", "win-arm-golden", "--source-image",
    "win-arm-golden", "--keep", "--log-format", "json"],
  @["ephemeral-destroy", "--backend", "incus", "--baseline", "garm-a1",
    "--log-format", "json"],
  @["ephemeral-label", "--backend", "incus", "--baseline", "garm-a1",
    "--label", "garm-pool=p1", "--label", "garm-controller=c1",
    "--log-format", "json"],
  @["ephemeral-list", "--backend", "incus", "--log-format", "json"],
  @["ephemeral-list", "--backend", "incus", "--name", "garm-a1",
    "--log-format", "json"],
  @["ephemeral-list", "--backend", "incus", "--label", "garm-pool=p1",
    "--log-format", "json"]]

# The crud façade over serve (architecture §8), as the parity gates send it.
let crudArgvs = @[
  @["crud", "list_vms", "--backend", "noop"],
  @["crud", "create_vm", "vm1", "--backend", "mock"],
  @["crud", "create_vm", "vm1", "--backend", "incus", "--source-image",
    "deb12", "--ssh-user", "dev"],
  @["crud", "get_vm", "vm1", "--backend", "mock"],
  @["crud", "exec", "vm1", "--backend", "mock", "--cwd", "/work",
    "--run-as", "dev", "--env", "A=1", "--timeout", "30", "--", "echo", "hi"],
  @["crud", "stop_vm", "vm1", "--backend", "mock"],
  @["crud", "start_vm", "vm1", "--backend", "mock"],
  @["crud", "delete_vm", "vm1", "--backend", "mock", "--force"],
  @["crud", "snapshot", "vm1", "s1", "--backend", "mock"],
  @["crud", "restore_snapshot", "vm1", "s1", "--backend", "mock"],
  @["crud", "list_snapshots", "vm1", "--backend", "mock"],
  @["crud", "ssh_endpoint", "vm1", "--backend", "mock"],
  @["crud", "list_images", "--backend", "incus"],
  @["crud", "list_vms", "--backend", "mock", "--lock-timeout-sec", "5"]]

suite "t_serve_exec_policy: legitimate clients":
  test "every garm-provider-gosti argv shape is allowed":
    for argv in providerArgvs:
      check gostiExecPolicy(argv) == ""
      # ...and on a host whose roots hold the goldens.
      check gostiExecPolicy(argv, hostPolicy) == ""

  test "every crud façade verb except the host-path copies is allowed":
    for argv in crudArgvs:
      check gostiExecPolicy(argv) == ""
    check CrudVerbsViaServe.len == 12
    check "copy_to_vm" notin CrudVerbsViaServe
    check "copy_from_vm" notin CrudVerbsViaServe

  test "host-gate shapes: guest probe after '--', timeout, prefix, guest":
    check allowed(@["run", "--ephemeral", "--backend", "incus", "--baseline",
      "j1", "--base-image", "img", "--timeout-sec", "90", "--", "sh", "-c",
      "test -c /dev/kvm"])
    check allowed(@["run", "--ephemeral", "--backend", "tart-linux-arm",
      "--guest", "linux", "--baseline", "j1", "--ephemeral-prefix",
      "gosti-serve-1a2b", "--source-image", "img", "--", "true"])
    # A guest command may say anything: it never reaches the daemon's parser.
    check allowed(@["run", "--ephemeral", "--backend", "incus", "--baseline",
      "j1", "--", "--mount", "/:/host:rw,shift", "--user-data", "/etc/shadow"])

  test "libvirt UEFI firmware under a public root is allowed":
    let fw = publicFirmwareFile()
    if fw.len == 0:
      echo "[skip] no file under ", FirmwareRoots, " on this host"
      skip()
    else:
      check allowed(@["run", "--ephemeral", "--backend", "libvirt",
        "--baseline", "j1", "--uefi-loader", fw, "--uefi-nvram-template", fw,
        "--keep", "--log-format", "json"])
      # The full hms-libvirt shape: golden + firmware + size.
      let full = @["run", "--ephemeral", "--backend", "libvirt", "--baseline",
        "garm-a1", "--base-image", goldenQcow2, "--source-image", goldenQcow2,
        "--uefi-loader", fw, "--uefi-nvram-template", fw, "--cpus", "4",
        "--memory-mb", "16384", "--keep", "--log-format", "json"]
      check allowed(full)
      check allowed(full, hostPolicy)

suite "t_serve_exec_policy: subcommand allowlist":
  test "subcommands outside the allowlist are refused":
    for sub in ["serve", "probe", "boot", "install", "shell", "instance",
                "snapshot", "baseline", "prune", "layer", "backends",
                "manifest", "help", "frobnicate"]:
      check refusedWith(@[sub, "--backend", "noop"], "not allowed via serve")
    check refusedWith(@[], "empty argv")

  test "case and whitespace variants of an allowed subcommand are refused":
    for sub in ["RUN", "Run", " run", "run ", "run\t", "Crud", "CRUD",
                "ephemeral_destroy", "Ephemeral-List", "provision\n"]:
      check refusedWith(@[sub, "--ephemeral", "--backend", "noop"],
                        "not allowed via serve")

  test "global options before the subcommand are refused":
    # The worker takes argv[0] verbatim as the subcommand.
    check refusedWith(@["--backend", "noop", "run", "--ephemeral"],
                      "subcommand '--backend'")
    check refusedWith(@["--", "run", "--ephemeral"], "subcommand '--'")
    check refusedWith(@["-h", "run"], "subcommand '-h'")
    check refusedWith(@["--state-dir", "/", "crud", "list_vms"],
                      "subcommand '--state-dir'")

  test "run without --ephemeral (writes --output-dir) is refused":
    check refusedWith(@["run", "--backend", "noop", "--baseline", "rt",
                        "--", "/bin/echo", "hi"], "requires --ephemeral")
    check refusedWith(@["run", "--backend", "noop", "--baseline", "rt",
      "--output-dir", "/tmp/x", "--", "true"], "'--output-dir' is not allowed")

  test "provision is limited to the noop test recipe":
    check refusedWith(@["provision", "--backend", "libvirt", "--baseline",
                        "x"], "limited to --backend noop")
    check refusedWith(@["provision", "--baseline", "x"], "requires --backend")
    # A repeated --backend cannot smuggle a real backend past the first.
    check refusedWith(@["provision", "--backend", "noop", "--backend",
                        "libvirt"], "limited to --backend noop")
    check refusedWith(@["provision", "--backend", "noop", "--recipe",
                        "windows-x64-base"], "'--recipe' is not allowed")

  test "duplicated subcommands do not change the subcommand":
    check refusedWith(@["provision", "crud", "--backend", "noop"],
                      "no positional")
    check refusedWith(@["crud", "crud", "create_vm", "x"],
                      "crud verb 'crud'")
    check refusedWith(@["run", "--ephemeral", "run", "--backend", "noop"],
                      "only after '--'")
    check refusedWith(@["ephemeral-list", "ephemeral-list"], "no positional")

  test "the client-only --remote family is refused anywhere, even after --":
    for flag in RemoteClientFlags:
      check refusedWith(@["ephemeral-list", "--backend", "noop", flag, "x"],
                        "client-only")
      check refusedWith(@["run", "--ephemeral", "--backend", "incus",
        "--baseline", "j", "--", "echo", flag, "/etc/shadow"], "client-only")
      # As a "value" too: runCli lifts it out before any parser sees it.
      check refusedWith(@["ephemeral-list", "--name", flag, "attacker:80"],
                        "client-only")

  test "a value option with no value is refused (the worker would crash)":
    check refusedWith(@["ephemeral-list", "--backend"], "needs a value")
    check refusedWith(@["crud", "list_vms", "--backend"], "needs a value")

suite "t_serve_exec_policy: host paths":
  test "--mount is refused in every spelling":
    check refusedWith(@["crud", "create_vm", "x", "--backend", "incus",
      "--mount", "/:/host:rw,shift"], "'--mount' is not allowed")
    check refusedWith(@["crud", "create_vm", "x", "--backend", "incus",
      "--mount=/:/host:rw,shift"], "'--mount=/:/host:rw,shift' is not allowed")
    check refusedWith(@["run", "--ephemeral", "--backend", "incus",
      "--baseline", "j", "--mount", "/:/host"], "'--mount' is not allowed")
    check refusedWith(@["crud", "create_vm", "x", "--MOUNT", "/:/h"],
                      "'--MOUNT' is not allowed")
    check refusedWith(@["crud", "create_vm", "x", "--mount ", "/:/h"],
                      "is not allowed")

  test "a caller --user-data path is refused (wire userData is the way)":
    check refusedWith(@["run", "--ephemeral", "--backend", "incus",
      "--baseline", "j", "--user-data", "/etc/shadow", "--keep"],
      "'--user-data' is not allowed")
    check refusedWith(@["crud", "create_vm", "x", "--backend", "libvirt",
      "--user-data", "/etc/shadow"], "'--user-data' is not allowed")
    check refusedWith(@["crud", "create_vm", "x", "--user-data=/etc/shadow"],
                      "is not allowed")
    check refusedWith(@["run", "--ephemeral", "--baseline", "j",
      "--meta-data", "/etc/shadow"], "'--meta-data' is not allowed")

  test "other daemon-host path options are refused":
    for (sub, flag) in [("crud", "--state-dir"), ("run", "--output-dir"),
                        ("run", "--copy-to"), ("run", "--copy-from"),
                        ("run", "--golden-image"), ("run", "--kernel"),
                        ("run", "--initrd"), ("run", "--image-pool-dir"),
                        ("run", "--ssh-private-key"), ("run", "--state-dir"),
                        ("run", "--detach-script"), ("run", "--screenshot"),
                        ("ephemeral-destroy", "--state-dir"),
                        ("ephemeral-list", "--state-dir"),
                        ("crud", "--install-shim"), ("crud", "--tart-vms-dir")]:
      var argv = @[sub, "--ephemeral"]
      if sub != "run": argv = @[sub]
      if sub == "crud": argv.add("list_vms")
      argv.add(@[flag, "/etc/shadow"])
      check refusedWith(argv, "'" & flag & "' is not allowed")

  test "crud copy verbs (host source / host destination) are refused":
    check refusedWith(@["crud", "copy_to_vm", "vm1", "/etc/shadow", "/x"],
                      "crud verb 'copy_to_vm'")
    check refusedWith(@["crud", "copy_from_vm", "vm1", "/x", "/root/.ssh/k"],
                      "crud verb 'copy_from_vm'")
    # ``--`` does not hide the verb: parseCliOpts folds the tail into cmd.
    check refusedWith(@["crud", "--backend", "mock", "--", "copy_to_vm",
                        "vm1", "/etc/shadow", "/x"], "crud verb 'copy_to_vm'")
    check refusedWith(@["crud", "frob"], "crud verb 'frob'")
    check refusedWith(@["crud", "--backend", "mock"], "requires a verb")

  test "--ephemeral-prefix must be a plain name":
    for bad in ["../x", "a/b", "..", ".hidden", "", "x y", "a\\b"]:
      check refusedWith(@["run", "--ephemeral", "--backend", "tart-macos",
        "--baseline", "j", "--ephemeral-prefix", bad], "not a plain name")

  test "UEFI paths must resolve inside the firmware roots":
    check refusedWith(@["run", "--ephemeral", "--backend", "libvirt",
      "--baseline", "j", "--uefi-nvram-template", "/etc/passwd"],
      "outside the firmware roots")
    check refusedWith(@["run", "--ephemeral", "--backend", "libvirt",
      "--baseline", "j", "--uefi-loader", "relative/OVMF.fd"],
      "must be an absolute path")
    check refusedWith(@["run", "--ephemeral", "--backend", "libvirt",
      "--baseline", "j", "--uefi-loader", "/nix/store/does-not-exist.fd"],
      "does not resolve")
    # ``..`` out of a root is refused outright, before anything resolves it.
    for root in FirmwareRoots:
      check refusedWith(@["run", "--ephemeral", "--backend", "libvirt",
        "--baseline", "j", "--uefi-loader", root & "../../etc/passwd"],
        "has a '..' component")
    # A device is not a firmware file (its kind is checked before the roots).
    check refusedWith(@["run", "--ephemeral", "--backend", "libvirt",
      "--baseline", "j", "--uefi-loader", "/dev/zero"],
      "not a regular file")

  test "a symlink is judged by its target, not its name":
    let dir = createTempDir("gosti-policy-fw-", "")
    defer: removeDir(dir)
    let escape = dir / "OVMF_VARS.fd"
    createSymlink("/etc/passwd", escape)
    check refusedWith(@["run", "--ephemeral", "--backend", "libvirt",
      "--baseline", "j", "--uefi-nvram-template", escape],
      "outside the firmware roots")
    let fw = publicFirmwareFile()
    if fw.len > 0:
      # The converse: a link OUTSIDE the roots that points INTO one is fine,
      # which is the NixOS /run/libvirt/nix-ovmf layout.
      let inward = dir / "OVMF_CODE.fd"
      createSymlink(fw, inward)
      check allowed(@["run", "--ephemeral", "--backend", "libvirt",
        "--baseline", "j", "--uefi-loader", inward])

suite "t_serve_exec_policy: names, backends and argv bytes":
  test "--baseline / --name must be plain names (backends build paths from them)":
    for bad in ["../../etc/x", "a/b", "..", "/abs", "", "x\\y", ".hidden"]:
      check refusedWith(@["ephemeral-destroy", "--backend", "libvirt",
        "--baseline", bad, "--log-format", "json"], "not a plain name")
      check refusedWith(@["run", "--ephemeral", "--backend", "libvirt",
        "--baseline", bad, "--keep"], "not a plain name")
      check refusedWith(@["ephemeral-list", "--backend", "incus", "--name",
        bad], "not a plain name")
      check refusedWith(@["crud", "create_vm", "vm1", "--backend", "libvirt",
        "--baseline", bad], "not a plain name")
    # A repeated --baseline cannot smuggle a path past a plain first one
    # (the worker keeps the last).
    check refusedWith(@["ephemeral-destroy", "--backend", "noop", "--baseline",
      "garm-a1", "--baseline", "../../x"], "not a plain name")

  test "--backend must be explicit, concrete and not wsl":
    check refusedWith(@["crud", "list_vms"], "--backend is required")
    check refusedWith(@["run", "--ephemeral", "--baseline", "j", "--keep"],
                      "--backend is required")
    for bad in ["wsl", "auto", "", "WSL", "incus "]:
      check refusedWith(@["crud", "create_vm", "vm1", "--backend", bad],
                        "is not allowed via serve")
      check refusedWith(@["run", "--ephemeral", "--backend", bad,
        "--baseline", "j"], "is not allowed via serve")
    # The worker keeps the last --backend, so every one is checked.
    check refusedWith(@["crud", "exec", "vm1", "--backend", "incus",
      "--backend", "wsl", "--", "cmd.exe"], "'wsl' is not allowed")
    # The allowlist is every backend id except wsl.
    var ids: seq[string]
    for id in BackendId:
      if id != biWsl: ids.add($id)
    check ServeBackends.len == ids.len
    for id in ids: check id in ServeBackends
    check "wsl" notin ServeBackends

  test "an option value of '--' is refused (it would hide the real '--')":
    # parseCliOpts takes this ``--`` as --source-image's value; the daemon
    # would then stage --user-data before it, i.e. as a value / positional.
    check refusedWith(@["run", "--ephemeral", "--backend", "incus",
      "--baseline", "j", "--source-image", "--", "--", "true"],
      "may not take '--'")
    check refusedWith(@["crud", "exec", "vm1", "--backend", "mock", "--cwd",
      "--", "--", "true"], "may not take '--'")

  test "a NUL byte anywhere is refused (the worker's C argv would cut it)":
    check refusedWith(@["ephemeral-list", "--backend", "incus\0x"], "NUL")
    check refusedWith(@["run", "--ephemeral", "--backend", "incus",
      "--baseline", "j", "--", "true\0--mount"], "NUL")
    check refusedWith(@["crud\0", "list_vms", "--backend", "noop"], "NUL")

proc runImg(backend, image: string): seq[string] =
  @["run", "--ephemeral", "--backend", backend, "--baseline", "garm-a1",
    "--base-image", image, "--source-image", image, "--keep",
    "--log-format", "json"]

proc crudImg(backend, image: string): seq[string] =
  @["crud", "create_vm", "vm1", "--backend", backend, "--source-image", image]

suite "t_serve_exec_policy: golden images under the operator's roots":
  test "images under a configured root are admitted, per backend format":
    check allowed(runImg("libvirt", goldenQcow2), hostPolicy)
    check allowed(runImg("hyperv", goldenVhdx), hostPolicy)
    check allowed(runImg("hyperv", goldenVhdFixed), hostPolicy)
    check allowed(runImg("qemu-windows-arm", goldenDir), hostPolicy)
    check allowed(crudImg("libvirt", goldenQcow2), hostPolicy)
    check allowed(crudImg("libvirt", installerIso), hostPolicy)
    check allowed(crudImg("mock", goldenQcow2), hostPolicy)
    check allowed(crudImg("qemu-boot", goldenVhdx), hostPolicy)
    # A link outside the roots that resolves INTO one is judged by its target.
    check allowed(runImg("libvirt", linkInward), hostPolicy)
    # A root that is itself a symlink admits what it points to.
    let viaLinkRoot = ExecPolicyConfig(imageRoots: @[rootLink])
    check allowed(runImg("libvirt", goldenQcow2), viaLinkRoot)
    # Several roots: any one of them.
    let two = ExecPolicyConfig(imageRoots: @["/nonexistent-root", imgRoot])
    check allowed(runImg("libvirt", goldenQcow2), two)

  test "an image outside every root is refused":
    check refusedWith(runImg("libvirt", outsideQcow2), "outside the image roots",
                      hostPolicy)
    check refusedWith(crudImg("libvirt", outsideQcow2),
                      "outside the image roots", hostPolicy)
    # Whole path components: /x/images does not hold /x/images-other/...
    check refusedWith(runImg("libvirt", siblingQcow2),
                      "outside the image roots", hostPolicy)
    check refusedWith(runImg("libvirt", "/etc/passwd"), "outside the image roots",
                      hostPolicy)

  test "'..' is refused, not resolved, even when it lands on an image":
    check refusedWith(runImg("libvirt", dotDotEscape), "has a '..' component",
                      hostPolicy)
    check refusedWith(runImg("libvirt", dotDotEscape), "has a '..' component")
    check refusedWith(runImg("libvirt", imgRoot &
      "/../images/golden-win11.qcow2"), "has a '..' component", hostPolicy)
    check refusedWith(runImg("qemu-windows-arm", goldenDir & "/.."),
                      "has a '..' component", hostPolicy)

  test "a symlink in a root that points out of it is refused":
    check refusedWith(runImg("libvirt", linkEscape), "outside the image roots",
                      hostPolicy)
    check refusedWith(crudImg("libvirt", linkEscape), "outside the image roots",
                      hostPolicy)

  test "a device node is refused, directly or through a link":
    for cfg in [ExecPolicyConfig(), hostPolicy]:
      check refusedWith(runImg("libvirt", "/dev/zero"), "not a regular file",
                        cfg)
      check refusedWith(runImg("libvirt", linkToDevice), "not a regular file",
                        cfg)
      check refusedWith(crudImg("libvirt", "/dev/null"), "not a regular file",
                        cfg)
      check refusedWith(runImg("hyperv", "/dev/zero"), "not a regular file",
                        cfg)
      # A FIFO too, and the check must not block opening it.
      check refusedWith(runImg("libvirt", fifo), "not a regular file", cfg)

  test "a directory is refused where a file is read, and vice versa":
    check refusedWith(runImg("libvirt", imgRoot), "not a regular file",
                      hostPolicy)
    check refusedWith(crudImg("libvirt", goldenDir), "not a regular file",
                      hostPolicy)
    check refusedWith(runImg("qemu-windows-arm", goldenQcow2),
                      "not a directory", hostPolicy)
    # A qemu-windows-arm golden directory must hold its qcow2 disk, inside it.
    let empty = imgRoot / "not-a-golden"
    createDir(empty)
    defer: removeDir(empty)
    check refusedWith(runImg("qemu-windows-arm", empty),
                      "is not a golden directory", hostPolicy)
    let leaky = imgRoot / "leaky-golden"
    createDir(leaky)
    defer: removeDir(leaky)
    createSymlink(outsideQcow2, leaky / QwaBaseDiskName)
    check refusedWith(runImg("qemu-windows-arm", leaky),
                      "outside the golden directory roots", hostPolicy)
    check refusedWith(runImg("qemu-windows-arm", leaky),
                      "outside the golden directory roots")

  test "a non-existent or relative image is refused":
    for cfg in [ExecPolicyConfig(), hostPolicy]:
      check refusedWith(runImg("libvirt", imgRoot / "missing.qcow2"),
                        "does not resolve", cfg)
      check refusedWith(runImg("qemu-windows-arm", imgRoot / "missing"),
                        "does not resolve", cfg)
      check refusedWith(runImg("libvirt", "golden.qcow2"),
                        "must be an absolute path", cfg)
      check refusedWith(runImg("hyperv", ""), "must be an absolute path", cfg)

  test "the file must be a disk image of the format the backend reads":
    # The DEFAULT config (no roots) still refuses a non-image host file:
    # this is what stops a caller reading a secret into a guest disk.
    for cfg in [ExecPolicyConfig(), hostPolicy]:
      check refusedWith(runImg("libvirt", notAnImage),
                        "is not a qcow2 disk image", cfg)
      check refusedWith(crudImg("libvirt", notAnImage),
                        "is not a qcow2/vhdx/vhd/iso9660 disk image", cfg)
      check refusedWith(runImg("hyperv", notAnImage),
                        "is not a vhdx/vhd disk image", cfg)
      # run --ephemeral clones with ``-F qcow2``: no other format.
      check refusedWith(runImg("libvirt", installerIso), "is not a qcow2", cfg)
      check refusedWith(runImg("noop", goldenVhdx), "is not a qcow2", cfg)
      check refusedWith(runImg("hyperv", goldenQcow2), "is not a vhdx/vhd",
                        cfg)
    check refusedWith(runImg("libvirt", "/etc/passwd"), "is not a qcow2")

  test "without roots, any disk image of the right format is admitted":
    # The default cannot be narrower without breaking the hms-libvirt lane,
    # whose golden lives under /storage/iso (see docs/contributors/serve.md).
    check allowed(runImg("libvirt", outsideQcow2))
    check allowed(runImg("libvirt", linkEscape))
    check allowed(runImg("libvirt", siblingQcow2))

  test "the format sniffer reads magic bytes, not names":
    check sniffDiskFormat(goldenQcow2) == {dfQcow2}
    check sniffDiskFormat(goldenVhdx) == {dfVhdx}
    check sniffDiskFormat(goldenVhdFixed) == {dfVhd}
    check sniffDiskFormat(installerIso) == {dfIso9660}
    check sniffDiskFormat(notAnImage) == {}
    check sniffDiskFormat(imgRoot / "missing") == {}
    check QwaGoldenDiskName == QwaBaseDiskName

suite "t_serve_exec_policy: files an image makes the hypervisor open":
  # The magic bytes say what a file IS, not what else opening it reads. A
  # qcow2 golden with ``backing_file=/etc/shadow, backing_fmt=raw`` passes a
  # format-only check, and QEMU then serves the secret's bytes as the
  # guest's disk (falsified with qemu-img: an overlay of such a file
  # converts to the backing file's content). Files a caller can shape exist
  # on a serve host: the daemon's own staged ``userData`` seeds, and every
  # raw guest disk a previous job wrote.
  let chain = imgRoot / "chain"
  createDir(chain)
  let secret = notAnImage

  test "a qcow2 whose backing file is not a qcow2 image is refused":
    let rawSecret = chain / "raw-secret.qcow2"
    writeQcow2(rawSecret, backing = secret, backingFmt = "raw")
    let probed = chain / "probed-secret.qcow2"
    writeQcow2(probed, backing = secret)          # no format: QEMU probes
    let v2 = chain / "v2-secret.qcow2"
    writeQcow2(v2, backing = secret, version = 2)
    let shadow = chain / "shadow.qcow2"
    writeQcow2(shadow, backing = "/etc/shadow", backingFmt = "raw")
    for cfg in [ExecPolicyConfig(), hostPolicy]:
      check refusedWith(runImg("libvirt", rawSecret),
                        "'raw' backing file", cfg)
      check refusedWith(crudImg("libvirt", rawSecret),
                        "'raw' backing file", cfg)
      check refusedWith(runImg("libvirt", probed),
                        "backing file '" & secret & "' is not a qcow2", cfg)
      check refusedWith(runImg("libvirt", v2), "is not a qcow2", cfg)
      check refusedWith(runImg("libvirt", shadow), "'raw' backing file", cfg)

  test "a qcow2 backing chain is admitted when every link passes":
    let layer = chain / "layer.qcow2"            # relative, like qemu-img -b
    writeQcow2(layer, backing = "../golden-win11.qcow2", backingFmt = "qcow2")
    let top = chain / "top.qcow2"
    writeQcow2(top, backing = "layer.qcow2", backingFmt = "qcow2")
    let absolute = chain / "abs.qcow2"
    writeQcow2(absolute, backing = goldenQcow2)
    for cfg in [ExecPolicyConfig(), hostPolicy]:
      check allowed(runImg("libvirt", layer), cfg)
      check allowed(runImg("libvirt", top), cfg)
      check allowed(runImg("libvirt", absolute), cfg)
      check allowed(crudImg("libvirt", top), cfg)
    # A relative name resolves against the directory of the path AS GIVEN
    # (what QEMU opened), so through a link elsewhere it names another file.
    let linkedTop = outside / "linked-top.qcow2"
    createSymlink(top, linkedTop)
    check refusedWith(runImg("libvirt", linkedTop),
                      "does not resolve to an existing file")

  test "a backing link out of the roots is refused like the image itself":
    let escape = chain / "escape-backing.qcow2"
    writeQcow2(escape, backing = outsideQcow2, backingFmt = "qcow2")
    let dotdot = chain / "dotdot-backing.qcow2"
    writeQcow2(dotdot, backing = "../../elsewhere/other-lane.qcow2")
    check refusedWith(runImg("libvirt", escape), "outside the image roots",
                      hostPolicy)
    check refusedWith(runImg("libvirt", dotdot), "outside the image roots",
                      hostPolicy)
    check allowed(runImg("libvirt", escape))   # no roots: any image
    # A qemu-windows-arm golden's disk may not reach out of its directory.
    let qwa = imgRoot / "qwa-backed"
    createDir(qwa)
    writeQcow2(qwa / QwaBaseDiskName, backing = outsideQcow2)
    writeFile(qwa / QwaGoldenManifestName, "{}")
    check refusedWith(runImg("qemu-windows-arm", qwa),
                      "outside the golden directory roots")

  test "protocol and JSON backing names, data files, loops are refused":
    for name in ["json:{\"file.filename\":\"/etc/shadow\"}",
                 "file:/etc/shadow", "nbd://10.0.0.1/x", "nbd:unix:/s"]:
      let p = chain / "proto.qcow2"
      writeQcow2(p, backing = name, backingFmt = "qcow2")
      check refusedWith(runImg("libvirt", p), "protocol or JSON")
      removeFile(p)
    let df = chain / "datafile.qcow2"
    writeQcow2(df, dataFile = true)
    check refusedWith(runImg("libvirt", df), "external qcow2 data file")
    let loop = chain / "loop.qcow2"
    writeQcow2(loop, backing = "loop.qcow2", backingFmt = "qcow2")
    check refusedWith(runImg("libvirt", loop), "deeper than " &
                      $MaxBackingDepth)
    let magicOnly = chain / "magic-only.qcow2"
    writeImage(magicOnly, "QFI\xfb")
    check refusedWith(runImg("libvirt", magicOnly), "qcow2 version 0")
    check refusedWith(crudImg("libvirt", magicOnly), "qcow2 version 0")

  test "the header parser reads what qemu-img reads":
    # Both directions: qemu-img's view of these fixtures, and the policy's
    # view of images qemu-img itself wrote (with the feature-name table and
    # other header extensions QEMU adds, which the parser must walk past).
    let qemuImg = findExe("qemu-img")
    if qemuImg.len == 0:
      skip()
    else:
      proc info(p: string): JsonNode =
        let (outp, code) = execCmdEx(quoteShellCommand(
          [qemuImg, "info", "-U", "--output=json", p]))
        check code == 0
        if code != 0:
          echo outp
          return newJObject()
        parseJson(outp)
      for (name, b, fmt, version) in [
          ("agree-none.qcow2", "", "", 3),
          ("agree-rel.qcow2", "../golden-win11.qcow2", "qcow2", 3),
          ("agree-v2.qcow2", "../golden-win11.qcow2", "", 2)]:
        let p = chain / name
        writeQcow2(p, backing = b, backingFmt = fmt, version = version)
        let i = info(p)
        check i{"backing-filename"}.getStr("") == b
        check i{"backing-filename-format"}.getStr("") == fmt
        let refs = qcow2Refs(p)
        check refs.malformed == ""
        check refs.backing == b
        check refs.backingFmt == fmt
      for (name, opts, b, fmt, df) in [
          ("q-plain.qcow2", @[], "", "", false),
          ("q-raw.qcow2", @["-b", secret, "-F", "raw"], secret, "raw", false),
          ("q-rel.qcow2", @["-b", "../golden-win11.qcow2", "-F", "qcow2"],
           "../golden-win11.qcow2", "qcow2", false),
          ("q-data.qcow2", @["-o", "data_file=" & chain / "q-data.raw"], "",
           "", true)]:
        let p = chain / name
        let (outp, code) = execCmdEx(quoteShellCommand(
          @[qemuImg, "create", "-q", "-u", "-f", "qcow2"] & opts & @[p, "1M"]))
        check code == 0
        if code != 0: echo outp
        let refs = qcow2Refs(p)
        check refs.malformed == ""
        check refs.backing == b
        check refs.backingFmt == fmt
        check refs.dataFile == df
        if b.len > 0 and fmt == "raw":
          check refusedWith(runImg("libvirt", p), "'raw' backing file")
        if df:
          check refusedWith(runImg("libvirt", p), "external qcow2 data file")
        if b.len == 0 and not df:
          check allowed(runImg("libvirt", p), hostPolicy)

  test "differencing VHD and VHDX (they name a parent) are refused":
    let vhdDiff = chain / "diff.vhd"
    writeVhdFixed(vhdDiff, differencing = true)
    let vhdxDiff = chain / "diff.vhdx"
    writeVhdx(vhdxDiff, differencing = true)
    let vhdxBare = chain / "bare.vhdx"             # no region table
    writeImage(vhdxBare, "vhdxfile")
    for cfg in [ExecPolicyConfig(), hostPolicy]:
      check refusedWith(runImg("hyperv", vhdDiff), "differencing VHD", cfg)
      check refusedWith(runImg("hyperv", vhdxDiff), "differencing VHDX", cfg)
      check refusedWith(crudImg("libvirt", vhdxDiff), "differencing VHDX",
                        cfg)
      check refusedWith(runImg("hyperv", vhdxBare), "no readable VHDX region",
                        cfg)
      check allowed(runImg("hyperv", goldenVhdx), cfg)
      check allowed(runImg("hyperv", goldenVhdFixed), cfg)

suite "t_serve_exec_policy: path spellings":
  test "no path through /proc: magic links name another namespace's file":
    let linkToProc = imgRoot / "via-proc.qcow2"
    createSymlink("/proc/self/root" & goldenQcow2, linkToProc)
    defer: removeFile(linkToProc)
    # ``/dev/fd`` is magic on every POSIX host: a symlink to /proc/self/fd
    # on Linux, an ``fdesc`` mount on macOS. ``/dev/stdin`` reaches it
    # through ``/proc/self/fd/0`` on Linux and through ``fd/0`` on macOS.
    let stdinVia = when defined(linux): "/proc" else: "/dev/fd"
    for cfg in [ExecPolicyConfig(), hostPolicy]:
      for p in ["/proc/self/root" & goldenQcow2, "/proc/1/root" & goldenQcow2,
                "/proc/self/cwd/x.qcow2", "/proc/self/fd/0", linkToProc]:
        check refusedWith(runImg("libvirt", p), "resolves through /proc", cfg)
      for p in ["/dev/fd/0", "/dev//fd/./0", "/dev/fd"]:
        check refusedWith(runImg("libvirt", p), "resolves through /dev/fd",
                          cfg)
      check refusedWith(runImg("libvirt", "/dev/stdin"),
                        "resolves through " & stdinVia, cfg)
      check refusedWith(runImg("qemu-windows-arm", "/proc/self/root" &
                        goldenDir), "resolves through /proc", cfg)
    let fw = publicFirmwareFile()
    if fw.len > 0:
      check refusedWith(@["run", "--ephemeral", "--backend", "libvirt",
        "--baseline", "j", "--uefi-loader", "/proc/self/root" & fw],
        "resolves through /proc")

  test "trailing slash, doubled slashes, long and non-UTF-8 names":
    for cfg in [ExecPolicyConfig(), hostPolicy]:
      for suffix in ["/", "/.", "//", "/./"]:
        check refusedWith(runImg("libvirt", goldenQcow2 & suffix),
                          "does not resolve", cfg)
      check allowed(runImg("libvirt", "/" & goldenQcow2), cfg)
      check allowed(runImg("libvirt", imgRoot & "//./golden-win11.qcow2"),
                    cfg)
      check refusedWith(runImg("libvirt", "/" & repeat("a/", 3000) & "x"),
                        "does not resolve", cfg)
    # A name that is not valid UTF-8 must still be judged by its bytes. APFS
    # refuses to create such a name at all (EILSEQ), so on macOS there is no
    # such file for the policy to be asked about, and nothing to test.
    when not defined(macosx):
      let odd = imgRoot / "g\xff\xfe.qcow2"
      writeQcow2(odd)
      check allowed(runImg("libvirt", odd), hostPolicy)

  test "a file spelled as a directory is refused before resolution":
    # BSD ``realpath`` (macOS) resolves ``f/`` to ``f``; Linux's fails with
    # ENOTDIR. The backend's ``open`` fails either way, so the policy must
    # refuse the spelling without consulting the host's ``realpath``. A
    # symlink ``f/`` cannot be built through the file system, so this
    # proves the order: a ``/``-terminated path that DOES resolve (a
    # directory with a valid image's name) is still refused as a file.
    let dirNamedImage = imgRoot / "dir-named.qcow2"
    createDir(dirNamedImage)
    defer: removeDir(dirNamedImage)
    for cfg in [ExecPolicyConfig(), hostPolicy]:
      check refusedWith(runImg("libvirt", dirNamedImage & "/"),
                        "does not resolve to an existing file", cfg)
      check refusedWith(runImg("libvirt", dirNamedImage & "/."),
                        "does not resolve to an existing file", cfg)
      # Without the trailing spelling it is the resolve step's refusal.
      check refusedWith(runImg("libvirt", dirNamedImage),
                        "which is not a regular file", cfg)
    # A golden DIRECTORY may still be spelled with a trailing '/'.
    check allowed(runImg("qemu-windows-arm", goldenDir & "/"), hostPolicy)

  test "hardlinks are judged by their bytes":
    let hardSecret = imgRoot / "hard-secret.qcow2"
    doAssert link(notAnImage.cstring, hardSecret.cstring) == 0
    let hardImage = imgRoot / "hard-image.qcow2"
    doAssert link(outsideQcow2.cstring, hardImage.cstring) == 0
    for cfg in [ExecPolicyConfig(), hostPolicy]:
      check refusedWith(runImg("libvirt", hardSecret), "is not a qcow2", cfg)
      check allowed(runImg("libvirt", hardImage), cfg)

  test "'=' spellings are unknown options, as in the worker":
    for a in ["--source-image=" & goldenQcow2, "--base-image=" & goldenQcow2,
              "--incus-profile=privileged"]:
      check refusedWith(@["run", "--ephemeral", "--backend", "libvirt",
        "--baseline", "j", a], "is not allowed for 'run'")

  test "crud on lima: its source image is a template, so none is admitted":
    check refusedWith(crudImg("lima", goldenQcow2), "names a template",
                      hostPolicy)
    check refusedWith(crudImg("lima", "template:default"), "names a template")
    check allowed(@["crud", "create_vm", "vm1", "--backend", "lima"])
    # run --ephemeral --backend lima is libvirt's qcow2 clone.
    check allowed(runImg("lima", goldenQcow2), hostPolicy)

suite "t_serve_exec_policy: image names resolved by the hypervisor":
  test "Incus, Tart and UTM take names, never paths or options":
    for backend in ["incus", "tart-macos", "tart-linux-arm", "utm-windows-arm"]:
      for good in ["runner-base", "images:debian/12", "ghcr.io/x/y:1",
                   "ghcr.io/cirruslabs/macos-sequoia-base@sha256:ab12",
                   "win-arm-golden"]:
        check allowed(runImg(backend, good), hostPolicy)
      for bad in ["/etc/shadow", goldenQcow2, "-pprivileged",
                  "--profile=privileged", "../x", "a/../b", "images:..",
                  "~/x", "C:\\x", "x y", ".hidden", "a\\b", ""]:
        check refusedWith(runImg(backend, bad), "is not an image name",
                          hostPolicy)
    check allowed(crudImg("incus", "deb12"))
    check refusedWith(crudImg("incus", "/var/lib/incus/images/x"),
                      "is not an image name")

  test "every --backend is checked, not only the one the worker keeps":
    # A name admitted for incus must not reach libvirt as a relative path...
    check refusedWith(@["run", "--ephemeral", "--backend", "incus",
      "--backend", "libvirt", "--baseline", "j", "--source-image",
      "runner-base"], "must be an absolute path", hostPolicy)
    # ...and a host path admitted for libvirt must not reach incus.
    check refusedWith(@["run", "--ephemeral", "--backend", "libvirt",
      "--backend", "incus", "--baseline", "j", "--source-image",
      goldenQcow2], "is not an image name", hostPolicy)
    # Even when the backend the worker keeps would accept it: the policy
    # does not rely on last-wins, so an earlier backend's reading counts too.
    check refusedWith(@["run", "--ephemeral", "--backend", "libvirt",
      "--backend", "incus", "--baseline", "j", "--source-image",
      "runner-base"], "must be an absolute path", hostPolicy)
    check refusedWith(@["crud", "create_vm", "vm1", "--backend", "incus",
      "--backend", "mock", "--source-image", goldenQcow2],
      "is not an image name", hostPolicy)
    # Every repeated image value is checked as well.
    check refusedWith(@["run", "--ephemeral", "--backend", "libvirt",
      "--baseline", "j", "--source-image", goldenQcow2, "--source-image",
      outsideQcow2], "outside the image roots", hostPolicy)

suite "t_serve_exec_policy: Incus profiles":
  proc withProfiles(profiles: varargs[string]): seq[string] =
    result = @["run", "--ephemeral", "--backend", "incus", "--baseline",
               "garm-a1", "--base-image", "runner-base"]
    for p in profiles: result.add(@["--incus-profile", p])
    result.add(@["--keep", "--log-format", "json"])

  test "the default allowlist is exactly 'default'":
    check DefaultIncusProfiles == ["default"]
    check allowed(withProfiles())
    check allowed(withProfiles("default"))
    for bad in ["privileged", "ci-store", "Default", "default ", " default",
                "", "default,privileged"]:
      check refusedWith(withProfiles(bad), "is not allowed via serve")
    check refusedWith(withProfiles("default", "privileged"),
                      "'privileged' is not allowed")

  test "a configured allowlist admits exactly its names":
    check allowed(withProfiles("default", "ci-store"), hostPolicy)
    check allowed(withProfiles("ci-store"), hostPolicy)
    check refusedWith(withProfiles("default", "privileged"),
                      "'privileged' is not allowed", hostPolicy)
    check refusedWith(withProfiles("CI-store"), "is not allowed", hostPolicy)
    # The configured list REPLACES the default.
    let only = ExecPolicyConfig(incusProfiles: @["ci-store"])
    check refusedWith(withProfiles("default"), "'default' is not allowed", only)
    check allowed(withProfiles("ci-store"), only)

  test "eccf8dc's provider shape with an operator profile needs the allowlist":
    let shape = @["run", "--ephemeral", "--backend", "incus", "--baseline",
      "garm-a1", "--base-image", "runner-base", "--source-image",
      "runner-base", "--incus-profile", "default", "--incus-profile",
      "runners", "--incus-security-nesting", "--incus-nested-kvm", "--cpus",
      "4", "--memory-mb", "8192", "--keep", "--log-format", "json"]
    check refusedWith(shape, "'runners' is not allowed")
    check allowed(shape, ExecPolicyConfig(
      incusProfiles: @["default", "runners"]))

  test "a profile is checked whatever the backend":
    check refusedWith(@["run", "--ephemeral", "--backend", "noop",
      "--baseline", "j", "--incus-profile", "privileged"], "not allowed")
    check refusedWith(@["run", "--ephemeral", "--backend", "incus",
      "--baseline", "j", "--incus-profile", "--", "--", "true"],
      "may not take '--'")

suite "t_serve_exec_policy: Incus shared build stores":
  proc withStores(extra: varargs[string]): seq[string] =
    result = @["run", "--ephemeral", "--backend", "incus", "--baseline",
               "garm-a1", "--base-image", "runner-base",
               "--incus-security-nesting", "--incus-nested-kvm"]
    for e in extra: result.add(e)
    result.add(@["--cpus", "6", "--memory-mb", "24576", "--keep",
                 "--log-format", "json"])

  test "the fixed Nix store share is a switch and is admitted":
    check allowed(withStores("--incus-share-host-nix-store"))

  test "the default reprobuild-store allowlist is exactly the PM3 location":
    check DefaultIncusReprobuildStores == ["/var/lib/reprobuild/shared-store"]
    check allowed(withStores("--incus-share-host-nix-store",
      "--incus-reprobuild-store", "/var/lib/reprobuild/shared-store",
      "--incus-reprobuild-store-guest-path", "/srv/repro-store"))
    # Checked verbatim: the worker gets the same text the policy saw.
    for bad in ["/", "/etc", "/var/lib/reprobuild",
                "/var/lib/reprobuild/shared-store/",
                "/var/lib/reprobuild//shared-store",
                "/var/lib/reprobuild/shared-store/../..",
                "/var/lib/reprobuild/shared-store/cas"]:
      check refusedWith(withStores("--incus-reprobuild-store", bad),
                        "is not allowed via serve")

  test "a configured reprobuild-store allowlist replaces the default":
    let only = ExecPolicyConfig(incusReprobuildStores: @["/srv/cas"])
    check allowed(withStores("--incus-reprobuild-store", "/srv/cas"), only)
    check refusedWith(withStores("--incus-reprobuild-store",
      "/var/lib/reprobuild/shared-store"), "is not allowed", only)

  test "--allow-incus-reprobuild-store parses, repeats and falls back to env":
    let o = parseCliOpts(@["serve", "--allow-incus-reprobuild-store",
      "/srv/cas/", "--allow-incus-reprobuild-store", "/var/lib/x"])
    check o.allowIncusReprobuildStores == @["/srv/cas", "/var/lib/x"]
    for bad in [@["serve", "--allow-incus-reprobuild-store", "rel"],
                @["serve", "--allow-incus-reprobuild-store", "/a/../b"],
                @["serve", "--allow-incus-reprobuild-store"]]:
      expect ValueError:
        discard parseCliOpts(bad)
    putEnv("GOSTI_SERVE_ALLOW_INCUS_REPROBUILD_STORES", "/srv/a:/srv/b")
    defer: delEnv("GOSTI_SERVE_ALLOW_INCUS_REPROBUILD_STORES")
    var fromEnv = parseCliOpts(@["serve"])
    serveAllowlistsFromEnv(fromEnv)
    check fromEnv.allowIncusReprobuildStores == @["/srv/a", "/srv/b"]
    var flagged = parseCliOpts(@["serve",
      "--allow-incus-reprobuild-store", "/srv/c"])
    serveAllowlistsFromEnv(flagged)
    check flagged.allowIncusReprobuildStores == @["/srv/c"]

suite "t_serve_exec_policy: serve allowlist configuration":
  test "--allow-image-root / --allow-incus-profile parse and repeat":
    let o = parseCliOpts(@["serve", "--listen", "127.0.0.1:0",
      "--allow-image-root", "/storage/iso", "--allow-image-root",
      "/nix/store", "--allow-incus-profile", "default",
      "--allow-incus-profile", "ci-store"])
    check o.subcommand == "serve"
    check o.allowImageRoots == @["/storage/iso", "/nix/store"]
    check o.allowIncusProfiles == @["default", "ci-store"]
    let none = parseCliOpts(@["serve", "--listen", "127.0.0.1:0"])
    check none.allowImageRoots.len == 0
    check none.allowIncusProfiles.len == 0

  test "malformed allowlist flags are refused at startup":
    for bad in [@["serve", "--allow-image-root", "relative/dir"],
                @["serve", "--allow-image-root", ""],
                @["serve", "--allow-image-root", "/storage/../etc"],
                @["serve", "--allow-image-root"],
                @["serve", "--allow-incus-profile", ""],
                @["serve", "--allow-incus-profile", "a,b"],
                @["serve", "--allow-incus-profile", "a b"],
                @["serve", "--allow-incus-profile"]]:
      expect ValueError:
        discard parseCliOpts(bad)

  test "environment fallbacks fill only what no flag set":
    putEnv("GOSTI_SERVE_ALLOW_IMAGE_ROOTS", "/storage/iso:/nix/store")
    putEnv("GOSTI_SERVE_ALLOW_INCUS_PROFILES", "default, ci-store")
    defer:
      delEnv("GOSTI_SERVE_ALLOW_IMAGE_ROOTS")
      delEnv("GOSTI_SERVE_ALLOW_INCUS_PROFILES")
    var fromEnv = parseCliOpts(@["serve"])
    serveAllowlistsFromEnv(fromEnv)
    check fromEnv.allowImageRoots == @["/storage/iso", "/nix/store"]
    check fromEnv.allowIncusProfiles == @["default", "ci-store"]
    # A flag replaces the variable; the two are never merged.
    var flagged = parseCliOpts(@["serve", "--allow-image-root", "/srv/img",
                                 "--allow-incus-profile", "runners"])
    serveAllowlistsFromEnv(flagged)
    check flagged.allowImageRoots == @["/srv/img"]
    check flagged.allowIncusProfiles == @["runners"]
    putEnv("GOSTI_SERVE_ALLOW_IMAGE_ROOTS", "relative")
    var bad = parseCliOpts(@["serve"])
    expect ValueError:
      serveAllowlistsFromEnv(bad)

  test "gosti serve hands the allowlists to the daemon's ServeConfig":
    let cfg = serveConfigFor(parseCliOpts(@["serve", "--allow-image-root",
      imgRoot, "--allow-incus-profile", "default", "--allow-incus-profile",
      "ci-store"]), "tok", "127.0.0.1", 0)
    check cfg.allowImageRoots == @[imgRoot]
    check cfg.allowIncusProfiles == @["default", "ci-store"]
    check cfg.execPolicy == nil        # the gosti policy, with these lists
    putEnv("GOSTI_SERVE_ALLOW_IMAGE_ROOTS", imgRoot)
    putEnv("GOSTI_SERVE_ALLOW_INCUS_PROFILES", "default,runners")
    defer:
      delEnv("GOSTI_SERVE_ALLOW_IMAGE_ROOTS")
      delEnv("GOSTI_SERVE_ALLOW_INCUS_PROFILES")
    let fromEnv = serveConfigFor(parseCliOpts(@["serve"]), "tok",
                                 "127.0.0.1", 0)
    check fromEnv.allowImageRoots == @[imgRoot]
    check fromEnv.allowIncusProfiles == @["default", "runners"]
    putEnv("GOSTI_SERVE_ALLOW_INCUS_PROFILES", "default,a b")
    expect ValueError:
      discard serveConfigFor(parseCliOpts(@["serve"]), "tok", "127.0.0.1", 0)

  test "the serve-only flags are themselves refused via /v1/exec":
    check refusedWith(@["run", "--ephemeral", "--backend", "incus",
      "--baseline", "j", "--allow-image-root", "/"],
      "'--allow-image-root' is not allowed")
    check refusedWith(@["crud", "list_vms", "--backend", "mock",
      "--allow-incus-profile", "privileged"],
      "'--allow-incus-profile' is not allowed")

suite "t_serve_exec_policy: the policy agrees with the worker's parser":
  proc hostPathFields(o: CliOpts): seq[string] =
    ## Every parsed option that names a file or directory on the daemon host,
    ## or makes the worker a client of another daemon.
    if o.mounts.len > 0: result.add("mounts")
    if o.userDataFile.len > 0: result.add("userDataFile")
    if o.metaDataFile.len > 0: result.add("metaDataFile")
    if o.stateDir.len > 0: result.add("stateDir")
    if o.outputDir.len > 0: result.add("outputDir")
    if o.copyTo.len > 0: result.add("copyTo")
    if o.copyFrom.len > 0: result.add("copyFrom")
    if o.goldenImage.len > 0: result.add("goldenImage")
    if o.kernel.len > 0: result.add("kernel")
    if o.initrd.len > 0: result.add("initrd")
    if o.screenshotPath.len > 0: result.add("screenshotPath")
    if o.imagePoolDir.len > 0: result.add("imagePoolDir")
    if o.provisionScripts.len > 0: result.add("provisionScripts")
    if o.recipe.len > 0: result.add("recipe")
    if o.recipeBuildDir.len > 0: result.add("recipeBuildDir")
    if o.sshPrivateKey.len > 0: result.add("sshPrivateKey")
    if o.sshKnownHosts.len > 0: result.add("sshKnownHosts")
    if o.shims.len > 0: result.add("shims")
    if o.detachScript.len > 0: result.add("detachScript")
    if o.secondaryIsoPath.len > 0: result.add("secondaryIsoPath")
    if o.targetDiskPath.len > 0: result.add("targetDiskPath")
    if o.remote.len > 0: result.add("remote")
    if o.authToken.len > 0: result.add("authToken")
    if o.authTokenFile.len > 0: result.add("authTokenFile")
    if o.workerExe.len > 0: result.add("workerExe")
    if o.portFile.len > 0: result.add("portFile")
    if o.listen.len > 0: result.add("listen")
    if o.allowImageRoots.len > 0: result.add("allowImageRoots")
    if o.allowIncusProfiles.len > 0: result.add("allowIncusProfiles")

  # The images a generated argv can reach that ARE legitimate goldens, as
  # real paths: under the root, and anywhere on the host.
  let inRootImages = @[expandFilename(goldenQcow2), expandFilename(goldenVhdx),
    expandFilename(goldenVhdFixed), expandFilename(installerIso),
    expandFilename(goldenDir)]
  let anywhereImages = inRootImages & @[expandFilename(outsideQcow2),
    expandFilename(siblingQcow2)]

  proc resourceLeak(o: CliOpts, pc: ExecPolicyConfig): string =
    ## Written independently of the policy: what the WORKER would read for
    ## the image and profile options it parsed. "" when that is a golden the
    ## host's config admits and only allowlisted profiles; else what leaked.
    let profiles = if pc.incusProfiles.len > 0: pc.incusProfiles
                   else: @["default"]
    for p in o.incusProfiles:
      if p notin profiles: return "profile '" & p & "'"
    for v in [o.sourceImage, o.baseImage]:
      if v.len == 0: continue
      if o.backend in ["incus", "tart-macos", "tart-linux-arm",
                       "utm-windows-arm"]:
        # Resolved in the hypervisor's own store: must not be a path or an
        # option to its CLI.
        if v[0] in {'/', '-', '.', '~'} or ".." in v.split({'/', ':'}):
          return "image name '" & v & "'"
        continue
      let real = try: expandFilename(v) except OSError: ""
      if real.len == 0: return "unresolvable image '" & v & "'"
      let legit = if pc.imageRoots.len > 0: inRootImages
                  else: anywhereImages
      if real notin legit: return "image '" & v & "' -> '" & real & "'"
    ""

  let seedDir = createTempDir("gosti-policy-seed-", "")
  proc checkAgreement(argv: seq[string],
                      pc: ExecPolicyConfig = ExecPolicyConfig()): bool =
    ## For an argv the policy admits: the worker's parser must not produce a
    ## host-path option, the subcommand must be an allowed one, a crud verb
    ## must be an allowed verb, and every image / profile it parses to must
    ## be one ``pc`` admits.
    if not allowed(argv, pc): return true
    for a in argv:
      if a in RemoteClientFlags:
        echo "  admitted a client-only flag: ", argv
        return false
    var o: CliOpts
    try: o = parseCliOpts(argv)
    except CatchableError: return true   # the worker refuses it itself
    let leaked = hostPathFields(o)
    if leaked.len > 0:
      echo "  admitted ", argv, " -> ", leaked
      return false
    if o.subcommand notin ["provision", "run", "ephemeral-destroy",
                           "ephemeral-label", "ephemeral-list", "crud"]:
      echo "  admitted subcommand '", o.subcommand, "': ", argv
      return false
    if o.subcommand == "run" and not o.ephemeral:
      echo "  admitted a non-ephemeral run: ", argv
      return false
    if o.subcommand == "crud" and
        (o.cmd.len == 0 or o.cmd[0] notin CrudVerbsViaServe):
      echo "  admitted crud cmd ", o.cmd, ": ", argv
      return false
    if o.backend notin ServeBackends:
      echo "  admitted backend '", o.backend, "': ", argv
      return false
    if '/' in o.baseline or ".." in o.baseline:
      echo "  admitted baseline '", o.baseline, "': ", argv
      return false
    let leak = resourceLeak(o, pc)
    if leak.len > 0:
      echo "  admitted ", leak, ": ", argv
      return false
    # What the daemon does next: stage wire user-data into this argv. The
    # worker must then parse exactly the staged path as --user-data, and the
    # guest argv must be unchanged.
    let (withSeed, staged) = applyUserData(argv, "#cloud-config\n",
                                           seedDir)
    defer: removeFile(staged)
    var o2: CliOpts
    try: o2 = parseCliOpts(withSeed)
    except CatchableError:
      echo "  staging user-data broke the parse: ", withSeed
      return false
    if o2.userDataFile != staged or o2.cmd != o.cmd:
      echo "  staged --user-data misplaced: ", withSeed, " -> ",
        o2.userDataFile, " ", o2.cmd
      return false
    true

  test "known-good shapes parse to no host path":
    for argv in providerArgvs & crudArgvs:
      check checkAgreement(argv)
      check checkAgreement(argv, hostPolicy)

  test "'crud -- create_vm x --mount …' is admitted but mounts nothing":
    # After ``--`` the worker's parser takes ``--mount`` as a positional, so
    # the policy may admit it: the property is what the worker DOES with it.
    let argv = @["crud", "--backend", "incus", "--", "create_vm", "x",
                 "--mount", "/:/host:rw,shift", "--user-data", "/etc/shadow"]
    check allowed(argv)
    let o = parseCliOpts(argv)
    check o.mounts.len == 0
    check o.userDataFile == ""
    check o.cmd[0] == "create_vm"

  test "seeded adversarial argvs: nothing admitted reaches a host path":
    let pool = @[
      "run", "crud", "provision", "ephemeral-destroy", "ephemeral-list",
      "ephemeral-label", "serve", "probe", "RUN", " crud", "--", "-h",
      "--help", "--ephemeral", "--keep", "--backend", "--baseline",
      "--base-image", "--source-image", "--golden-image", "--mount",
      "--mount=/:/host:rw,shift", "--user-data", "--user-data=/etc/shadow",
      "--meta-data", "--state-dir", "--output-dir", "--copy-to", "--copy-from",
      "--remote", "--auth-token", "--auth-token-file", "--uefi-loader",
      "--uefi-nvram-template", "--ephemeral-prefix", "--incus-profile",
      "--label", "--name", "--env", "--cwd", "--kernel", "--recipe",
      "--install-shim", "--detach-script", "--force", "--log-format",
      "noop", "incus", "mock", "json", "/:/host:rw,shift", "/etc/shadow",
      "/tmp/x:/x", "a=b", "garm-pool=p", "create_vm", "copy_to_vm",
      "copy_from_vm", "exec", "list_vms", "vm1", "..", "true", "wsl",
      "auto", "../x", "--source-image", "--cwd", "--guest", "linux",
      # Images and profiles (G13 residuals): every kind of host file a
      # caller could aim at, and names for the hypervisor-resolved backends.
      "libvirt", "hyperv", "qemu-windows-arm", "tart-macos", "incus",
      "--base-image", "--source-image", "--incus-profile", "--incus-profile",
      goldenQcow2, goldenVhdx, installerIso, goldenDir, outsideQcow2,
      siblingQcow2, linkEscape, linkInward, linkToDevice, dotDotEscape,
      notAnImage, fifo, imgRoot, "/dev/null", "/etc/passwd",
      imgRoot / "missing.qcow2", "golden.qcow2", "runner-base",
      "-pprivileged", "images:debian/12", "default", "ci-store",
      "privileged", "Default"]
    var rng = initRand(0x613)
    var admitted = [0, 0]           # [default config, configured host]
    var imageAdmitted = [0, 0]      # of those, carrying an image or profile
    var disagreements = 0
    let configs = [ExecPolicyConfig(), hostPolicy]
    proc tally(argv: seq[string]) =
      for i, pc in configs:
        if allowed(argv, pc):
          inc admitted[i]
          if "--source-image" in argv or "--base-image" in argv or
              "--incus-profile" in argv:
            inc imageAdmitted[i]
        if not checkAgreement(argv, pc): inc disagreements
    for _ in 0 ..< 20_000:
      var argv: seq[string]
      let n = rng.rand(1 .. 9)
      for _ in 0 ..< n:
        argv.add(pool[rng.rand(pool.high)])
      tally(argv)
    # Also mutate the legitimate shapes, which is where a bypass would hide.
    let seeds = providerArgvs & crudArgvs
    for _ in 0 ..< 20_000:
      var argv = seeds[rng.rand(seeds.high)]
      for _ in 0 .. rng.rand(2):
        argv.insert(pool[rng.rand(pool.high)], rng.rand(argv.len))
      tally(argv)
    check disagreements == 0
    # The generator must actually reach the admitted region, including argvs
    # that carry an image or a profile, or the property holds vacuously.
    for i in 0 .. 1:
      check admitted[i] > 100
      check imageAdmitted[i] > 100
    echo "  admitted ", admitted, " of 40000 generated argvs (default, host)",
      "; with an image/profile: ", imageAdmitted

  removeDir(seedDir)

removeDir(fixtures)
