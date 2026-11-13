# SPDX-FileCopyrightText: 2026 Metacraft Labs / Schelling Point Labs
# SPDX-License-Identifier: Apache-2.0
## The Linux runner golden must ship the cloud image's own /etc/resolv.conf,
## not the build container's single static resolver.
##
## The recipe points the build container at one public resolver
## (GOSTI_BUILD_EGRESS_DNS, default 1.1.1.1) for its apt steps. Until this gate
## existed it never put the original back, so every golden shipped
## `nameserver 1.1.1.1` as a plain file in place of systemd-resolved's stub
## symlink, and every per-job guest ignored the resolver its DHCP lease names
## (measured on gpu-server-002 and high-mem-server guests, 2026-11-12).
##
## The recipe keeps the save and restore steps in two shell snippets that take
## the root to act on as $1. This gate extracts them from the recipe text and
## RUNS them with /bin/sh against scratch trees, so the behaviour checked is the
## behaviour the build executes. No mocks: real files, real symlinks, real sh.

import std/[os, osproc, strutils, tempfiles, unittest]

const RecipePath = "guest-recipes/linux-x64-runner/build-runner-image.sh"

proc snippet(text, name: string): string =
  ## The single-quoted value of `NAME='…'` in the recipe.
  let open = name & "='"
  let start = text.find(open)
  doAssert start >= 0, name & " not found in " & RecipePath
  let bodyStart = start + open.len
  let finish = text.find("'\n", bodyStart)
  doAssert finish > bodyStart, name & " is not terminated"
  text[bodyStart ..< finish]

let recipe = readFile(RecipePath)
let saveSh = snippet(recipe, "RESOLV_SAVE_SH")
let restoreSh = snippet(recipe, "RESOLV_RESTORE_SH")

proc run(script, root: string) =
  let p = startProcess("/bin/sh", args = ["-c", script, "t", root],
                       options = {poStdErrToStdOut})
  let rc = p.waitForExit()
  p.close()
  doAssert rc == 0, "snippet failed with exit " & $rc

proc build(root: string) =
  ## What ensure_build_egress does in the container: save, then replace.
  run(saveSh, root)
  removeFile(root / "etc/resolv.conf")
  writeFile(root / "etc/resolv.conf", "nameserver 1.1.1.1\n")

suite "linux runner golden keeps its own resolv.conf":
  test "systemd-resolved's stub symlink survives the build":
    let root = createTempDir("gosti-resolv-stub", "")
    defer: removeDir(root)
    createDir(root / "etc")
    # Dangling here, as it is in a stopped image: -e alone would miss it.
    createSymlink("../run/systemd/resolve/stub-resolv.conf",
                  root / "etc/resolv.conf")
    build(root)
    build(root)   # ensure_build_egress may be reached twice; first save wins
    run(restoreSh, root)
    check symlinkExists(root / "etc/resolv.conf")
    check expandSymlink(root / "etc/resolv.conf") ==
      "../run/systemd/resolve/stub-resolv.conf"
    check not symlinkExists(root / "etc/.gosti-build-resolv.conf")
    check not fileExists(root / "etc/.gosti-build-resolv.conf")

  test "a plain resolv.conf is restored byte for byte":
    let root = createTempDir("gosti-resolv-file", "")
    defer: removeDir(root)
    createDir(root / "etc")
    writeFile(root / "etc/resolv.conf", "nameserver 10.0.0.1\nsearch lan\n")
    build(root)
    run(restoreSh, root)
    check readFile(root / "etc/resolv.conf") ==
      "nameserver 10.0.0.1\nsearch lan\n"

  test "an image with no resolv.conf ships none":
    let root = createTempDir("gosti-resolv-absent", "")
    defer: removeDir(root)
    createDir(root / "etc")
    build(root)
    run(restoreSh, root)
    check not fileExists(root / "etc/resolv.conf")
    check not fileExists(root / "etc/.gosti-build-resolv.conf.absent")

  test "the build saves before it overwrites and restores in teardown":
    let ensure = recipe.find("ensure_build_egress() {")
    let saveCall = recipe.find("sh -c \"$RESOLV_SAVE_SH\"", ensure)
    let overwrite = recipe.find("rm -f /etc/resolv.conf", ensure)
    check ensure >= 0
    check saveCall > ensure
    check saveCall < overwrite
    let teardown = recipe.find("teardown_build_egress() {")
    check recipe.find("sh -c \"$RESOLV_RESTORE_SH\"", teardown) > teardown
