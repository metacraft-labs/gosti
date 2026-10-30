# SPDX-FileCopyrightText: 2026 Metacraft Labs / Schelling Point Labs
# SPDX-License-Identifier: Apache-2.0
## Gate: the Incus backend's per-run ownership rule. A container or a
## managed network created with an owner token is recorded with it at
## creation, and the backend refuses to exec in, copy to/from, delete or
## stop a container -- or delete a network -- that does not carry that
## token.
##
## *Mocking, justified.* ``incus`` is replaced by a small shell script
## that keeps container and network config in a temporary directory and
## logs every argv. The real daemon on a shared host runs production CI
## containers; a unit gate that creates and deletes real instances to
## prove it will NOT delete someone else's would be testing the refusal
## by risking the very thing it refuses. What is under test is gosti's
## decision (which argv it issues, and which it withholds), and the fake
## answers the three questions that decision reads (``config get``,
## ``network info``, ``network get``) exactly as incus does: value on
## stdout and exit 0, or exit 1 for a missing object. The live path is
## exercised end to end by reprobuild's add-on Incus test bed.

import std/[os, strutils, tables, unittest]
import gosti

const FakeIncus = """#!/bin/sh
state="$FAKE_INCUS_STATE"
echo "$*" >> "$state/argv.log"
cmd="$1"; shift
case "$cmd" in
  info) [ -d "$state/c/$1" ] && exit 0 || exit 1 ;;
  list) for d in "$state"/c/*; do [ -d "$d" ] && echo "$(basename "$d"),RUNNING"; done; exit 0 ;;
  launch|init)
    img="$1"; name="$2"; shift 2
    mkdir -p "$state/c/$name"
    while [ $# -gt 0 ]; do
      case "$1" in
        --config) k="${2%%=*}"; v="${2#*=}"; printf '%s' "$v" > "$state/c/$name/$k"; shift 2 ;;
        *) shift ;;
      esac
    done
    exit 0 ;;
  config)
    sub="$1"; shift
    case "$sub" in
      get) [ -f "$state/c/$1/$2" ] && cat "$state/c/$1/$2" && echo && exit 0
           [ -d "$state/c/$1" ] && echo && exit 0
           exit 1 ;;
      set) printf '%s' "$3" > "$state/c/$1/$2"; exit 0 ;;
    esac ;;
  delete) [ "$1" = "--force" ] && shift; rm -rf "$state/c/$1"; exit 0 ;;
  stop) exit 0 ;;
  exec) exit 0 ;;
  file) exit 0 ;;
  network)
    sub="$1"; shift
    case "$sub" in
      info) [ -d "$state/n/$1" ] && exit 0 || exit 1 ;;
      create) name="$1"; shift; mkdir -p "$state/n/$name"
              for kv in "$@"; do printf '%s' "${kv#*=}" > "$state/n/$name/${kv%%=*}"; done
              exit 0 ;;
      get) [ -f "$state/n/$1/$2" ] && cat "$state/n/$1/$2" && echo && exit 0; exit 1 ;;
      delete) rm -rf "$state/n/$1"; exit 0 ;;
    esac ;;
esac
exit 0
"""

proc setup(): tuple[dir: string, b: IncusBackend] =
  let dir = getTempDir() / ("gosti-fake-incus-" & $getCurrentProcessId())
  removeDir(dir)
  createDir(dir / "c")
  createDir(dir / "n")
  let exe = dir / "incus"
  writeFile(exe, FakeIncus)
  setFilePermissions(exe, {fpUserRead, fpUserWrite, fpUserExec})
  putEnv("FAKE_INCUS_STATE", dir)
  (dir, newIncusBackend(incusCmd = @[exe], baseImage = "images:debian/13"))

proc log(dir: string): string = readFile(dir / "argv.log")

suite "incus owner tokens":
  test "the token is set in the creating call, and checked on exec":
    let (dir, b) = setup()
    defer: removeDir(dir)
    let vm = b.provisionEphemeralClone(EphemeralIncusSpec(
      name: "addon-a2-1", ownerToken: "tok-1", network: "addon-net-1"))
    check "launch images:debian/13 addon-a2-1 --config user.gosti.owner=tok-1 --network addon-net-1" in log(dir)
    discard b.execInGuest(vm, initTable[string, string](), @["true"])
    check "exec addon-a2-1 -- true" in log(dir)

  test "a container whose token changed is not touched":
    let (dir, b) = setup()
    defer: removeDir(dir)
    let vm = b.provisionEphemeralClone(EphemeralIncusSpec(
      name: "addon-a2-2", ownerToken: "tok-2"))
    # Someone else's container now carries the name.
    writeFile(dir / "c/addon-a2-2/user.gosti.owner", "production")
    expect GostiError:
      discard b.execInGuest(vm, initTable[string, string](), @["true"])
    expect GostiError:
      b.copyToGuest(vm, dir / "incus", "/root/x")
    b.stopAndCleanup(vm)                 # must not raise ...
    check dirExists(dir / "c/addon-a2-2") # ... and must not delete
    check "delete" notin log(dir)

  test "an owned container is deleted":
    let (dir, b) = setup()
    defer: removeDir(dir)
    let vm = b.provisionEphemeralClone(EphemeralIncusSpec(
      name: "addon-a2-3", ownerToken: "tok-3"))
    b.stopAndCleanup(vm)
    check not dirExists(dir / "c/addon-a2-3")

  test "networks: created with the token, deleted only with it":
    let (dir, b) = setup()
    defer: removeDir(dir)
    discard b.createOwnedNetwork("addon-net-4", "10.250.4.1/24", "tok-4")
    check readFile(dir / "n/addon-net-4/user.gosti.owner") == "tok-4"
    expect GostiError:
      discard b.createOwnedNetwork("addon-net-4", "10.250.4.1/24", "tok-4")
    expect GostiError:
      discard b.deleteOwnedNetwork("addon-net-4", "another-run")
    check dirExists(dir / "n/addon-net-4")
    discard b.deleteOwnedNetwork("addon-net-4", "tok-4")
    check not dirExists(dir / "n/addon-net-4")
    # Already gone is a clean no-op.
    check b.deleteOwnedNetwork("addon-net-4", "tok-4").exitCode == 0

  test "a foreign network is never deleted":
    let (dir, b) = setup()
    defer: removeDir(dir)
    createDir(dir / "n/incusbr0")
    expect GostiError:
      discard b.deleteOwnedNetwork("incusbr0", "tok-5")
    check dirExists(dir / "n/incusbr0")
