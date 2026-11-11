# SPDX-FileCopyrightText: 2026 Metacraft Labs / Schelling Point Labs
# SPDX-License-Identifier: Apache-2.0
## t_serve_exec_policy — what a ``gosti serve`` bearer token may run
## (SEC-1 G13; ``src/gosti/serve/exec_policy.nim``).
##
## Pure checks of ``gostiExecPolicy``: the provider's and the crud façade's
## real argv shapes are admitted, and every way found to reach a host path or
## another subcommand is refused — global options before the subcommand,
## ``--`` tricks, ``=``-joined options, repeated subcommands and flags, case
## and whitespace variants, the client-only ``--remote`` family, and firmware
## paths that escape their roots through ``..`` or a symlink.
##
## The last suite ties the policy to the WORKER's parser: for a large,
## seeded set of adversarial argvs, everything the policy admits must parse
## (``cli.parseCliOpts``) to options that name no daemon-host path. That is
## what makes this an allowlist of meanings and not of spellings.
##
## The end-to-end half (HTTP 403, no worker spawned) is
## ``tests/e2e/t_gosti_serve_exec_policy.nim``. Hermetic.

import std/[os, random, strutils, tempfiles, unittest]
import gosti
import gosti/cli

proc allowed(argv: seq[string]): bool = gostiExecPolicy(argv).len == 0

proc refusedWith(argv: seq[string], fragment: string): bool =
  let r = gostiExecPolicy(argv)
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

# The exact argv shapes ``garm-provider-gosti`` builds (nixos-modules
# packages/garm-provider-gosti/src/internal/backend/remote.go:
# noopRecipe, ephemeralRecipe, label, inventory).
let providerArgvs = @[
  @["provision", "--backend", "noop", "--baseline", "garm-a1",
    "--log-format", "json"],
  @["ephemeral-destroy", "--backend", "noop", "--baseline", "garm-a1",
    "--log-format", "json"],
  @["run", "--ephemeral", "--backend", "incus", "--baseline", "garm-a1",
    "--keep", "--log-format", "json"],
  @["run", "--ephemeral", "--backend", "incus", "--baseline", "garm-a1",
    "--base-image", "runner-base", "--source-image", "runner-base",
    "--incus-profile", "default", "--incus-profile", "runners",
    "--incus-security-nesting", "--incus-nested-kvm",
    "--cpus", "4", "--memory-mb", "8192", "--keep", "--log-format", "json"],
  @["run", "--ephemeral", "--backend", "tart-linux-arm", "--baseline",
    "garm-a1", "--base-image", "ghcr.io/x/y:1", "--source-image",
    "ghcr.io/x/y:1", "--keep", "--log-format", "json"],
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
    # ``..`` out of a root is resolved before the root check.
    for root in FirmwareRoots:
      check refusedWith(@["run", "--ephemeral", "--backend", "libvirt",
        "--baseline", "j", "--uefi-loader", root & "../../etc/passwd"],
        "outside the firmware roots")

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

  let seedDir = createTempDir("gosti-policy-seed-", "")
  proc checkAgreement(argv: seq[string]): bool =
    ## For an argv the policy admits: the worker's parser must not produce a
    ## host-path option, the subcommand must be an allowed one, and a crud
    ## verb must be an allowed verb.
    if not allowed(argv): return true
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
    const pool = [
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
      "auto", "../x", "--source-image", "--cwd", "--guest", "linux"]
    var rng = initRand(0x613)
    var admitted = 0
    var disagreements = 0
    for _ in 0 ..< 20_000:
      var argv: seq[string]
      let n = rng.rand(1 .. 9)
      for _ in 0 ..< n:
        argv.add(pool[rng.rand(pool.high)])
      if allowed(argv): inc admitted
      if not checkAgreement(argv): inc disagreements
    # Also mutate the legitimate shapes, which is where a bypass would hide.
    let seeds = providerArgvs & crudArgvs
    for _ in 0 ..< 20_000:
      var argv = seeds[rng.rand(seeds.high)]
      for _ in 0 .. rng.rand(2):
        argv.insert(pool[rng.rand(pool.high)], rng.rand(argv.len))
      if allowed(argv): inc admitted
      if not checkAgreement(argv): inc disagreements
    check disagreements == 0
    # The generator must actually reach the admitted region, or the property
    # above holds vacuously.
    check admitted > 100
    echo "  admitted ", admitted, " of 40000 generated argvs"
