# SPDX-FileCopyrightText: 2026 Metacraft Labs / Schelling Point Labs
# SPDX-License-Identifier: Apache-2.0
## The libvirt Linux path through the CLI a script uses (campaign M4):
##
##   gosti run --ephemeral --backend libvirt --guest linux \
##     --golden-image <qcow2> --user-data <cloud-config> \
##     --ssh-forward-port auto --ssh-user U --ssh-private-key K -- <cmd>
##
## builds a NoCloud seed from --user-data, boots the clone with a loopback SSH
## forward, runs <cmd> over SSH, prints its output, and destroys the clone.
## Asserts the command's output (the seed's hostname, so the seed was
## consumed), the exit status, and that no domain or pool file survives.
##
## Skips without GOSTI_LINUX_CLOUD_GOLDEN (guest-recipes/linux-x64-cloud/
## fetch-image.sh), /dev/kvm, or a built `build/bin/gosti`.

import std/[os, osproc, strutils, unittest]
import std/posix

when not defined(linux):
  echo "[skip] t_gosti_libvirt_cli_linux_ephemeral: Linux host required"
  quit(0)

let golden = getEnv("GOSTI_LINUX_CLOUD_GOLDEN")
let cli = currentSourcePath().parentDir.parentDir.parentDir / "build/bin/gosti"
var st: Stat
if golden.len == 0 or not fileExists(golden):
  echo "[skip] t_gosti_libvirt_cli_linux_ephemeral: GOSTI_LINUX_CLOUD_GOLDEN not set"
  quit(0)
if stat("/dev/kvm", st) != 0 or not S_ISCHR(st.st_mode):
  echo "[skip] t_gosti_libvirt_cli_linux_ephemeral: /dev/kvm not available"
  quit(0)
if not fileExists(cli):
  echo "[skip] t_gosti_libvirt_cli_linux_ephemeral: run `just build` first (" &
       cli & ")"
  quit(0)

suite "gosti run --ephemeral --guest linux (libvirt CLI)":
  test "NoCloud seed, SSH probe over the forward, no residue":
    let scratch = getTempDir() / ("gosti-cli-linux-" & $getpid())
    removeDir(scratch)
    createDir(scratch)
    let key = scratch / "key"
    check execCmd("ssh-keygen -q -t ed25519 -N '' -f " & quoteShell(key)) == 0
    writeFile(scratch / "user-data",
      "#cloud-config\nusers:\n  - name: gosti\n    ssh_authorized_keys:\n      - " &
      readFile(key & ".pub").strip() & "\n")
    let name = "repro-vm-cli-linux-" & $getpid()
    let pool = scratch / "pool"
    let argv = @[cli, "run", "--ephemeral", "--backend", "libvirt",
      "--guest", "linux", "--baseline", name, "--golden-image", golden,
      "--user-data", scratch / "user-data", "--ssh-forward-port", "auto",
      "--ssh-user", "gosti", "--ssh-private-key", key, "--memory-mb", "2048",
      "--", "hostname"]
    putEnv("LIBVIRT_DEFAULT_URI", "qemu:///session")
    putEnv("GOSTI_LIBVIRT_IMAGE_POOL_DIR", pool)
    let (output, code) = execCmdEx(quoteShellCommand(argv))
    checkpoint output
    check code == 0
    # The default meta-data names the host after the domain.
    check name in output
    let listing = execCmdEx("virsh -c qemu:///session list --all --name")
    check name notin listing.output
    var leftovers: seq[string] = @[]
    if dirExists(pool):
      for f in walkDir(pool): leftovers.add(f.path)
    check leftovers.len == 0
    removeDir(scratch)
