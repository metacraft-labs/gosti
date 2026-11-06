# SPDX-FileCopyrightText: 2026 Metacraft Labs / Schelling Point Labs
# SPDX-License-Identifier: Apache-2.0
## Gate: the GOSTI2 Incus parity preconditions through the CRUD façade —
## ``create_vm --mount`` (incus ``disk`` devices), ``create_vm --user-data``
## (``cloud-init.user-data``, set before first start, fail-closed for an
## image with no cloud-init template), stop/start keeping the container, and
## the ``list_images`` verb (JSON shape + the §8.1 exit codes 0/4/5).
##
## *Mocking, justified.* ``incus`` is replaced by a shell script that keeps
## per-container state in a temp dir and logs every argv (and, separately,
## anything a call received on stdin). The real daemon on a shared host runs
## production containers; what is under test here is the argv gosti issues,
## its ORDER (config before first start), what it withholds from argv (the
## user-data body), and how it maps each daemon answer to the frozen
## envelope. The live path is gated by the host-tier
## ``tests/e2e/t_crud_incus_real.nim`` against a real Incus daemon.
##
## The shell script runs only where ``/bin/sh`` can be exec'd, and the create
## suites that use it are Linux-only anyway (IncusBackend create is). The
## ``list_images`` suite runs on every host, so its ``incus`` is the native
## command fixture (``tests/native_command_fixture.nim``): a copy of this test
## executable that answers from a JSON sidecar. Windows ``CreateProcess``
## cannot start a ``#!/bin/sh`` file at all, and a fake that cannot be
## started reads as "client not runnable" (backend-unavailable, 4) — which
## would make every exit-code case below either fail or pass for the wrong
## reason. Same justification as above: what is pinned is how gosti maps each
## answer to the envelope, not the daemon.

import std/[json, options, os, strutils, tables, tempfiles, unittest]
import ../native_command_fixture
import gosti
import gosti/cli
import gosti/crud_store

const FakeIncus = """#!/bin/sh
state="$FAKE_INCUS_STATE"
echo "$*" >> "$state/argv.log"
cmd="$1"; shift
case "$cmd" in
  info)
    if [ $# -eq 0 ]; then exit 0; fi
    [ -d "$state/c/$1" ] && exit 0 || exit 1 ;;
  image)
    case "$*" in
      *"--format json"*) cat "$state/images.json"; exit 0 ;;
      *) echo "$2"; exit 0 ;;
    esac ;;
  launch|init)
    img="$1"; name="$2"; shift 2
    mkdir -p "$state/c/$name"
    if [ "$cmd" = launch ]; then echo RUNNING > "$state/c/$name/.state"
    else echo STOPPED > "$state/c/$name/.state"; fi
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
      set) if [ "$3" = "-" ]; then cat > "$state/c/$1/$2"; cp "$state/c/$1/$2" "$state/stdin-$2"
           else printf '%s' "$3" > "$state/c/$1/$2"; fi; exit 0 ;;
      metadata)
        echo "templates:"
        if [ -z "$FAKE_NO_TEMPLATE" ]; then
          echo "  /var/lib/cloud/seed/nocloud-net/user-data:"
          echo "    template: cloud-init-user-data.tpl"
        fi
        echo "  /etc/hostname:"
        echo "    template: hostname.tpl"
        exit 0 ;;
      device) exit "${FAKE_DEVICE_RC:-0}" ;;
    esac ;;
  start) echo RUNNING > "$state/c/$1/.state"; exit 0 ;;
  stop) [ "$1" = "--force" ] && shift; echo STOPPED > "$state/c/$1/.state"; exit 0 ;;
  list)
    name="$1"
    [ -f "$state/c/$name/.state" ] || exit 0
    case "$*" in
      *"-c ns"*) echo "$name,$(cat "$state/c/$name/.state")" ;;
      *) cat "$state/c/$name/.state" ;;
    esac
    exit 0 ;;
  delete) [ "$1" = "--force" ] && shift; rm -rf "$state/c/$1"; exit 0 ;;
  exec) exit 0 ;;
esac
exit 0
"""

const ImagesJson = """[
 {"fingerprint": "abc123", "aliases": [{"name": "deb12-cloud", "description": ""}],
  "properties": {"description": "Debian bookworm (cloud)"}, "type": "container",
  "architecture": "x86_64", "size": 123456789, "created_at": "2026-11-04T00:00:00Z"},
 {"fingerprint": "def456", "aliases": [], "properties": {}, "type": "virtual-machine",
  "architecture": "aarch64", "size": 7, "created_at": "2026-11-03T00:00:00Z"}
]"""

proc fakeIncus(): tuple[dir, exe: string] =
  let dir = createTempDir("gosti-crud-incus-", "")
  createDir(dir / "c")
  let exe = dir / "incus"
  writeFile(exe, FakeIncus)
  setFilePermissions(exe, {fpUserRead, fpUserWrite, fpUserExec})
  writeFile(dir / "images.json", ImagesJson)
  putEnv("FAKE_INCUS_STATE", dir)
  for k in ["FAKE_NO_TEMPLATE", "FAKE_DEVICE_RC"]:
    delEnv(k)
  (dir, exe)

proc nativeIncus(config: JsonNode): tuple[dir, exe: string] =
  ## A native ``incus`` stand-in (see the header): every call appends its argv
  ## to ``<dir>/argv.log`` and then answers as ``config`` says.
  let dir = createTempDir("gosti-crud-incus-native-", "")
  var cfg = copy(config)
  cfg["log"] = %(dir / "argv.log")
  (dir, commandFixture(dir / "incus", cfg))

proc argvLog(dir: string): seq[string] =
  if fileExists(dir / "argv.log"): readFile(dir / "argv.log").splitLines()
  else: @[]

proc indexOf(lines: seq[string], prefix: string): int =
  for i, l in lines:
    if l.startsWith(prefix): return i
  -1

proc params(name = ""): CrudParams =
  CrudParams(name: name, guestOs: goLinux, guestArch: gaX86_64,
             env: initTable[string, string]())

proc session(exe: string, storeDir = ""): CrudSession =
  let b = newIncusBackend(incusCmd = @[exe], baseImage = "gosti-base")
  newCrudSession(b, (if storeDir.len > 0: newCrudStore(storeDir) else: nil))

suite "incus crud create: spec conversion (pure)":
  test "mounts: :ro / :rw / no suffix, exact disk-device argv":
    let host = createTempDir("gosti-mnt-", "")
    defer: removeDir(host)
    let spec = BaselineSpec(name: "vm1", sourceImage: "images:debian/12/cloud",
      mounts: @[(host: host, guest: "/mnt/a:ro"), (host: host, guest: "/mnt/b"),
                (host: host, guest: "/mnt/c:rw")])
    let c = crudCloneSpec("vm1", spec, "gosti-base")
    check c.name == "vm1"
    check c.baseImage == "images:debian/12/cloud"
    check not c.ephemeral
    check c.mounts.len == 3
    check c.mounts[0] == IncusDiskMount(hostPath: host, guestPath: "/mnt/a",
                                        readOnly: true)
    check not c.mounts[1].readOnly and c.mounts[1].guestPath == "/mnt/b"
    check not c.mounts[2].readOnly and c.mounts[2].guestPath == "/mnt/c"
    check diskMountArgs("vm1", 0, c.mounts[0]) == @["config", "device", "add",
      "vm1", "gosti-mount-0", "disk", "source=" & host, "path=/mnt/a",
      "readonly=true"]
    check diskMountArgs("vm1", 1, c.mounts[1]) == @["config", "device", "add",
      "vm1", "gosti-mount-1", "disk", "source=" & host, "path=/mnt/b"]

  test "invalid mounts and names are InvalidSpecError (nothing created)":
    let host = createTempDir("gosti-mnt-", "")
    defer: removeDir(host)
    for m in [(host: "relative", guest: "/x"),
              (host: host / "missing", guest: "/x"),
              (host: host, guest: "relative"),
              (host: host, guest: "/x:bogus"),
              (host: host, guest: "/x:ro,rw"),
              (host: host, guest: "/x:ro,bogus"),
              (host: host, guest: ":ro")]:
      expect InvalidSpecError:
        discard crudCloneSpec("vm1", BaselineSpec(mounts: @[m]), "img")
    for n in ["bad_name", "1abc", "a.b", "trailing-", "", 'a'.repeat(64)]:
      expect InvalidSpecError:
        discard crudCloneSpec(n, BaselineSpec(), "img")
    check crudCloneSpec('a'.repeat(63), BaselineSpec(), "img").name.len == 63

  test "mount options: parseMountGuest grammar, shift=true argv":
    check parseMountGuest("/m") == (path: "/m", readOnly: false, shift: false)
    check parseMountGuest("/m:ro") == (path: "/m", readOnly: true, shift: false)
    check parseMountGuest("/m:rw") == (path: "/m", readOnly: false, shift: false)
    check parseMountGuest("/m:shift") == (path: "/m", readOnly: false, shift: true)
    check parseMountGuest("/m:ro,shift") == (path: "/m", readOnly: true, shift: true)
    check parseMountGuest("/m:shift,rw") == (path: "/m", readOnly: false, shift: true)
    # Not an option list: left on the path (then rejected as colon-bearing).
    check parseMountGuest("/m:bogus") == (path: "/m:bogus", readOnly: false, shift: false)
    expect ValueError:
      discard parseMountGuest("/m:ro,rw")
    let host = createTempDir("gosti-mnt-", "")
    defer: removeDir(host)
    let c = crudCloneSpec("vm1", BaselineSpec(mounts: @[
      (host: host, guest: "/mnt/s:shift"), (host: host, guest: "/mnt/p")]), "img")
    check c.mounts[0].shift and not c.mounts[0].readOnly
    check not c.mounts[1].shift
    check diskMountArgs("vm1", 0, c.mounts[0]) == @["config", "device", "add",
      "vm1", "gosti-mount-0", "disk", "source=" & host, "path=/mnt/s",
      "shift=true"]
    # Default (no :shift) never asks for shifting.
    check "shift=true" notin diskMountArgs("vm1", 1, c.mounts[1])
    # A ',' / '=' / ' ' in a host path stays inside ONE key=value argv element.
    let odd = host / "a,b=c d"
    createDir(odd)
    let o = crudCloneSpec("vm1", BaselineSpec(mounts: @[
      (host: odd, guest: "/mnt/o:ro")]), "img")
    check diskMountArgs("vm1", 0, o.mounts[0]) == @["config", "device", "add",
      "vm1", "gosti-mount-0", "disk", "source=" & odd, "path=/mnt/o",
      "readonly=true"]

  test "image refs: fingerprint detection + incus's resolution order":
    check looksLikeFingerprintRef("abc123")
    check looksLikeFingerprintRef("images:4185591de931")
    check looksLikeFingerprintRef('a'.repeat(64))
    for r in ["gosti-base", "images:debian/12/cloud", "", "ABC123",
              'a'.repeat(65), "local:"]:
      check not looksLikeFingerprintRef(r)
    let imgs = @[ImageInfo(id: "abc123ff", aliases: @["beef"]),
                 ImageInfo(id: "abd45600", aliases: @[]),
                 ImageInfo(id: "beef0001", aliases: @[])]
    check resolveIncusImageRef(imgs, "abc123ff") == irFound   # full
    check resolveIncusImageRef(imgs, "abc") == irFound        # unique prefix
    check resolveIncusImageRef(imgs, "local:abd4") == irFound # remote-qualified
    check resolveIncusImageRef(imgs, "ab") == irAmbiguous
    check resolveIncusImageRef(imgs, "beef") == irFound       # alias wins over prefix
    check resolveIncusImageRef(imgs, "c0ffee") == irMissing
    check resolveIncusImageRef(imgs, "123ff") == irMissing    # infix, not prefix

  test "user-data and sizes reach the clone spec; image defaults":
    let c = crudCloneSpec("vm1", BaselineSpec(userData: "#cloud-config\n",
                                              cpus: 2, memoryMB: 512), "gosti-base")
    check c.baseImage == "gosti-base"
    check c.cloudInitUserData == "#cloud-config\n"
    check c.config[IncusLimitsCpuKey] == "2"
    check c.config[IncusLimitsMemoryKey] == "512MiB"

  test "imageRendersUserData reads the metadata templates":
    check imageRendersUserData("templates:\n  /var/lib/cloud/seed/nocloud-net/user-data:\n    template: cloud-init-user-data.tpl\n")
    check imageRendersUserData("templates:\n  /var/lib/cloud/seed/nocloud/user-data:\n    template: custom.tpl\n")
    check not imageRendersUserData("templates:\n  /etc/hostname:\n    template: hostname.tpl\n")
    check not imageRendersUserData("")

# The tests below that create, start or stop a container drive
# IncusBackend's lifecycle methods, which are Linux-only: on any other host
# each one refuses before it runs incus (backend-unavailable, 4), so the
# argv and ordering they check never exist there. They skip off Linux, as
# tests/unit/t_cli_incus.nim does; the pure spec conversion above, the CLI
# guard and list_images still run on every platform.
suite "incus crud create: argv through the façade (fake incus)":
  test "--user-data + --mount: init, user-data on stdin, devices, THEN start":
    when defined(linux):
      let (dir, exe) = fakeIncus()
      let host = createTempDir("gosti-mnt-", "")
      defer:
        removeDir(dir)
        removeDir(host)
      let s = session(exe)
      var p = params("vm1")
      p.sourceImage = "images:debian/12/cloud"
      p.userData = "#cloud-config\nruncmd: [[touch, /SECRET-MARKER]]\n"
      p.mounts = @[(host: host, guest: "/mnt/ro:ro"), (host: host, guest: "/mnt/rw")]
      let r = runCrud(s, "create_vm", p)
      check r.exitCode == 0
      check r.json["data"]["vm"]["state"].getStr == "running"
      let log = argvLog(dir)
      let iInit = log.indexOf("init images:debian/12/cloud vm1 --config user.gosti.owner=crud-")
      let iMeta = log.indexOf("config metadata show vm1")
      let iUd = log.indexOf("config set vm1 cloud-init.user-data -")
      let iDev0 = log.indexOf("config device add vm1 gosti-mount-0 disk source=" &
                              host & " path=/mnt/ro readonly=true")
      let iDev1 = log.indexOf("config device add vm1 gosti-mount-1 disk source=" &
                              host & " path=/mnt/rw")
      let iStart = log.indexOf("start vm1")
      check iInit >= 0 and iMeta > iInit and iUd > iMeta
      check iDev0 > iUd and iDev1 > iDev0 and iStart > iDev1
      check log[iDev1] == "config device add vm1 gosti-mount-1 disk source=" &
                          host & " path=/mnt/rw"   # rw ⇒ no readonly key
      check log.indexOf("launch ") < 0             # never the launch-then-config path
      # The body went on stdin, never into an argv.
      check readFile(dir / "stdin-cloud-init.user-data") == p.userData
      check "SECRET-MARKER" notin readFile(dir / "argv.log")
      # create_vm returns at exec-ready; it never blocks on cloud-init (§8.2).
      check "cloud-init" notin readFile(dir / "argv.log").replace(
        "cloud-init.user-data", "")
    else:
      skip()

  test "user-data for an image with no cloud-init template: bad-args, container removed":
    when defined(linux):
      let (dir, exe) = fakeIncus()
      defer: removeDir(dir)
      putEnv("FAKE_NO_TEMPLATE", "1")
      defer: delEnv("FAKE_NO_TEMPLATE")
      var p = params("vm2")
      p.sourceImage = "images:alpine/3.21"
      p.userData = "#cloud-config\n"
      let r = runCrud(session(exe), "create_vm", p)
      check r.exitCode == 2
      check r.json["error"]["kind"].getStr == "bad-args"
      check "cloud-init" in r.json["error"]["message"].getStr
      let log = argvLog(dir)
      check log.indexOf("delete --force vm2") > log.indexOf("config metadata show vm2")
      check log.indexOf("config set vm2 cloud-init.user-data") < 0
      check log.indexOf("start vm2") < 0
      check not dirExists(dir / "c" / "vm2")
    else:
      skip()

  test "a failing device add tears the container down (backend-error 5)":
    when defined(linux):
      let (dir, exe) = fakeIncus()
      defer: removeDir(dir)
      let host = createTempDir("gosti-mnt-", "")
      defer: removeDir(host)
      putEnv("FAKE_DEVICE_RC", "1")
      defer: delEnv("FAKE_DEVICE_RC")
      var p = params("vm3")
      p.mounts = @[(host: host, guest: "/mnt/x")]
      let r = runCrud(session(exe), "create_vm", p)
      check r.exitCode == 5
      check not dirExists(dir / "c" / "vm3")
      check argvLog(dir).indexOf("start vm3") < 0
    else:
      skip()

  test "invalid incus name: bad-args before anything is created":
    when defined(linux):
      let (dir, exe) = fakeIncus()
      defer: removeDir(dir)
      let r = runCrud(session(exe), "create_vm", params("bad_name"))
      check r.exitCode == 2
      let log = argvLog(dir)
      check log.indexOf("init ") < 0 and log.indexOf("launch ") < 0
    else:
      skip()

  test "no options: the original launch shape, no pre-start config":
    when defined(linux):
      let (dir, exe) = fakeIncus()
      defer: removeDir(dir)
      let r = runCrud(session(exe), "create_vm", params("vm4"))
      check r.exitCode == 0
      let log = argvLog(dir)
      check log.indexOf("launch gosti-base vm4 --config user.gosti.owner=crud-") >= 0
      check log.indexOf("config metadata") < 0
      check log.indexOf("config device") < 0
    else:
      skip()

  test "stop_vm keeps the container; start_vm restarts it; delete_vm removes it":
    when defined(linux):
      let (dir, exe) = fakeIncus()
      let store = createTempDir("gosti-crud-store-", "")
      defer:
        removeDir(dir)
        removeDir(store)
      check runCrud(session(exe, store), "create_vm", params("vm5")).exitCode == 0
      let st = runCrud(session(exe, store), "stop_vm", params("vm5"))
      check st.exitCode == 0
      check st.json["data"]["vm"]["state"].getStr == "stopped"
      check dirExists(dir / "c" / "vm5")                # kept, not deleted
      check argvLog(dir).indexOf("stop --force vm5") >= 0
      let g = runCrud(session(exe, store), "get_vm", params("vm5"))
      check g.json["data"]["vm"]["state"].getStr == "stopped"
      let sv = runCrud(session(exe, store), "start_vm", params("vm5"))
      check sv.exitCode == 0
      check sv.json["data"]["vm"]["state"].getStr == "running"
      let log = argvLog(dir)
      check log.indexOf("start vm5") > log.indexOf("stop --force vm5")
      discard runCrud(session(exe, store), "stop_vm", params("vm5"))
      check runCrud(session(exe, store), "delete_vm", params("vm5")).exitCode == 0
      check not dirExists(dir / "c" / "vm5")            # no residue after stop+delete
      check runCrud(session(exe, store), "get_vm", params("vm5")).exitCode == 3
    else:
      skip()

  test "the CLI guard lets --user-data / --mount through for incus":
    let b: VmBackend = newIncusBackend()
    check b.honorsUserData() and b.honorsMounts() and b.keepsInstanceOnStop()
    let opts = parseCliOpts(@["crud", "create_vm", "vm1", "--backend", "incus",
                              "--user-data", "/x", "--mount", "/a:/b:ro"])
    check opts.mounts == @[(host: "/a", guest: "/b:ro")]
    check crudCreateGuard("create_vm", opts, b).isNone

# Linux-only for the same reason as the façade suite above.
suite "incus crud create: --source-image by fingerprint (fake incus)":
  const FpImages = """[
   {"fingerprint": "abc123ff", "aliases": [], "type": "container"},
   {"fingerprint": "abd45600", "aliases": [], "type": "container"},
   {"fingerprint": "beef0001", "aliases": [], "type": "container"}]"""

  test "full and unique-prefix fingerprints create; JSON lookup, no csv probe":
    when defined(linux):
      for fp in ["abc123ff", "abc", "beef0001"]:
        let (dir, exe) = fakeIncus()
        defer: removeDir(dir)
        writeFile(dir / "images.json", FpImages)
        var p = params("vm-fp")
        p.sourceImage = fp
        let r = runCrud(session(exe), "create_vm", p)
        check r.exitCode == 0
        let log = argvLog(dir)
        check log.indexOf("image list " & fp & " --format json") >= 0
        check log.indexOf("image list " & fp & " --format csv") < 0
        check log.indexOf("launch " & fp & " vm-fp ") >= 0
    else:
      skip()

  test "ambiguous prefix => bad-args (2); unknown => backend-error (5)":
    when defined(linux):
      for (fp, code) in [("ab", 2), ("c0ffee", 5)]:
        let (dir, exe) = fakeIncus()
        defer: removeDir(dir)
        writeFile(dir / "images.json", FpImages)
        var p = params("vm-fp")
        p.sourceImage = fp
        let r = runCrud(session(exe), "create_vm", p)
        check r.exitCode == code
        if code == 2: check "ambiguous" in r.json["error"]["message"].getStr
        let log = argvLog(dir)
        check log.indexOf("launch ") < 0 and log.indexOf("init ") < 0
    else:
      skip()

  test "an alias keeps the original csv presence probe (byte-identical)":
    when defined(linux):
      let (dir, exe) = fakeIncus()
      defer: removeDir(dir)
      let r = runCrud(session(exe), "create_vm", params("vm-al"))
      check r.exitCode == 0
      let log = argvLog(dir)
      check log.indexOf("image list gosti-base --format csv -c l") >= 0
      check log.indexOf("image list gosti-base --format json") < 0
    else:
      skip()

suite "crud list_images":
  test "incus: ok envelope, stable entry shape":
    let (dir, exe) = nativeIncus(%*{"output": ImagesJson})
    defer: removeDir(dir)
    let r = runCrud(session(exe), "list_images", params())
    check r.exitCode == 0
    check r.json["ok"].getBool and r.json["verb"].getStr == "list_images"
    let d = r.json["data"]
    check d["backend"].getStr == "incus"
    check d["images"].len == 2
    let a = d["images"][0]
    check a == %*{"id": "abc123", "aliases": ["deb12-cloud"],
                  "description": "Debian bookworm (cloud)", "type": "container",
                  "architecture": "x86_64", "size_bytes": 123456789,
                  "created_at": "2026-11-04T00:00:00Z"}
    check d["images"][1]["aliases"].len == 0
    check d["images"][1]["type"].getStr == "virtual-machine"
    check argvLog(dir).indexOf("image list --format json") >= 0

  test "incus: empty store is an empty list, not an error":
    let (dir, exe) = nativeIncus(%*{"output": "[]"})
    defer: removeDir(dir)
    let r = runCrud(session(exe), "list_images", params())
    check r.exitCode == 0
    check r.json["data"]["images"].len == 0

  test "incus: listing fails but the daemon answers => backend-error (5)":
    # `image ...` exits 1; every other call (`incus info`) exits 0.
    let (dir, exe) = nativeIncus(%*{"failFirstArg": "image", "failureCode": 1})
    defer: removeDir(dir)
    let r = runCrud(session(exe), "list_images", params())
    check r.exitCode == 5
    check r.json["error"]["kind"].getStr == "backend-error"
    # The daemon probe really ran: 5 is the answer to "info succeeded".
    check argvLog(dir).indexOf("info") >= 0

  test "incus: listing AND incus info fail => backend-unavailable (4)":
    let (dir, exe) = nativeIncus(%*{"errorOutput": "Error: boom\n",
                                     "exitCode": 1})
    defer: removeDir(dir)
    let r = runCrud(session(exe), "list_images", params())
    check r.exitCode == 4
    check r.json["error"]["kind"].getStr == "backend-unavailable"
    # A refusal from the probe, not a client that could not be started.
    check argvLog(dir).indexOf("info") >= 0
    check "exited 1" in r.json["error"]["message"].getStr

  test "incus: unparseable listing => backend-error (5), never an empty list":
    let (dir, exe) = nativeIncus(%*{"output": "not json\n"})
    defer: removeDir(dir)
    let r = runCrud(session(exe), "list_images", params())
    check r.exitCode == 5
    expect ValueError:
      discard parseIncusImageList("""[{"aliases": []}]""")
    expect ValueError:
      discard parseIncusImageList("""{"not": "an array"}""")

  test "incus: client not installed => backend-unavailable (4)":
    let r = runCrud(session("/nonexistent/gosti-test/incus"), "list_images",
                    params())
    check r.exitCode == 4

  test "mock: one image per baseline, fault injection => 5":
    let m = newMockBackend(biMock)
    let s = newCrudSession(m)
    check runCrud(s, "list_images", params()).json["data"]["images"].len == 0
    check runCrud(s, "create_vm", params("b1")).exitCode == 0
    let r = runCrud(s, "list_images", params())
    check r.exitCode == 0
    check r.json["data"]["images"][0]["aliases"] == %*["b1"]
    putEnv("GOSTI_MOCK_FAIL", "list_images")
    defer: delEnv("GOSTI_MOCK_FAIL")
    check runCrud(s, "list_images", params()).exitCode == 5

  test "a backend without image enumeration (noop) => backend-unavailable (4)":
    let r = runCrud(newCrudSession(newNoopBackend()), "list_images", params())
    check r.exitCode == 4
    check r.json["error"]["kind"].getStr == "backend-unavailable"

  test "list_images is part of the verb vocabulary":
    check "list_images" in CrudVerbs
