# SPDX-FileCopyrightText: 2026 Metacraft Labs / Schelling Point Labs
# SPDX-License-Identifier: Apache-2.0
## t_crud_incus_real — the GOSTI2 Incus parity preconditions against a REAL
## Incus daemon, driven exclusively through the ``gosti crud`` CLI (each verb
## a separate process, sharing one crud store — exactly what the agent-harbor
## ``GostiOrchestrator`` binding does).
##
## One container, end to end:
##
##   (a) ``create_vm --mount <ro>:/mnt/ro:ro --mount <rw>:/mnt/rw
##       --user-data <cloud-config>`` from a cloud-init image variant;
##   (b) cloud-init ran the user-data (a ``write_files`` marker and a
##       ``runcmd`` marker exist in the guest);
##   (c) the RO mount shows a host-written file and refuses writes; the RW
##       mount carries a guest write back to the host, owned by the
##       container's MAPPED root (not host root), and an unshifted RW mount
##       of a root-owned 0755 host dir refuses guest-root writes;
##   (d) ``list_images`` lists the image the container was created from;
##   (e) ``stop_vm`` / ``start_vm`` keep the SAME container (marker survives);
##   (f) ``delete_vm`` leaves no container, no storage volume, no crud record.
##
## Plus the fail-closed case: ``--user-data`` with an image that has no
## cloud-init template is ``bad-args`` (2) and leaves no container; and
## ``--source-image`` given as a bare full / unique-prefix fingerprint of a
## local image creates (an ambiguous prefix is ``bad-args``); and a
## ``:shift`` mount, which on a host with idmapped-mount support lets guest
## root write a root-owned host dir as host uid 0, and on a host without it
## fails as ``backend-error`` (5) with the container removed.
##
## The image is ``GOSTI_CRUD_INCUS_IMAGE`` (default
## ``images:alpine/3.21/cloud``); the non-cloud image for the fail-closed case
## is ``GOSTI_CRUD_INCUS_PLAIN_IMAGE`` (default ``images:alpine/3.21``). Both
## are pulled on first use, so the host needs the image server (or the images
## cached). Socket access: as the other incus gates, export
## ``GOSTI_INCUS_CMD="sudo -n incus"`` when the incus-admin group is not
## active. The gate self-skips when Incus is not reachable or the image
## cannot be resolved; it never touches a container it did not create (unique
## ``gosti-crud-e2e-<pid>-<rand>`` names, owner-token checked by gosti).
##
## Run: nim r --hints:off --threads:on tests/e2e/t_crud_incus_real.nim

import std/[json, os, osproc, posix, random, streams, strutils, tempfiles,
            unittest]
import gosti
import gosti/cli

when isMainModule:
  let params = commandLineParams()
  if params.len >= 1 and params[0] == "__gosti_cli":
    quit(runCli(params[1 .. ^1]))

when not defined(linux):
  echo "[skip] t_crud_incus_real: Linux host required"
  quit(0)

let image = block:
  let e = getEnv("GOSTI_CRUD_INCUS_IMAGE")
  if e.len > 0: e else: "images:alpine/3.21/cloud"
let plainImage = block:
  let e = getEnv("GOSTI_CRUD_INCUS_PLAIN_IMAGE")
  if e.len > 0: e else: "images:alpine/3.21"

let incus = newIncusBackend()

proc incusOut(args: varargs[string]): tuple[code: int, output: string] =
  let r = incus.runIncus(@args, timeoutSec = 120)
  (r.exitCode, r.stdout)

proc crud(stateDir: string, args: varargs[string]): tuple[code: int, env: JsonNode] =
  ## ``gosti crud <args> --backend incus --state-dir <dir>`` as its own
  ## process; stdout must be exactly one JSON envelope line.
  var argv = @["__gosti_cli", "crud"]
  var guest: seq[string]
  var seenDash = false
  for a in args:
    if a == "--": seenDash = true
    if seenDash: guest.add(a) else: argv.add(a)
  argv.add(@["--backend", "incus", "--state-dir", stateDir])
  argv.add(guest)
  let p = startProcess(getAppFilename(), args = argv, options = {})
  p.inputStream.close()
  let output = p.outputStream.readAll()
  let code = p.waitForExit()
  p.close()
  let lines = output.strip().splitLines()
  doAssert lines.len == 1, "crud " & args.join(" ") & ": expected one " &
    "envelope line, got: " & output
  (code, parseJson(lines[0]))

proc guestSh(stateDir, name, script: string): tuple[exit: int, stdout: string] =
  let (code, env) = crud(stateDir, "exec", name, "--", "sh", "-c", script)
  doAssert code == 0, "exec envelope failed: " & $env
  (env["data"]["exit_code"].getInt, env["data"]["stdout"].getStr)

proc containerGone(name: string): bool =
  let (code, output) = incusOut("list", "--format", "csv", "-c", "n")
  doAssert code == 0, "incus list failed: " & output
  for line in output.splitLines():
    if line.strip() == name: return false
  true

proc volumeGone(name: string): bool =
  let (code, output) = incusOut("storage", "volume", "list", incus.storagePool,
                                "--format", "csv", "-c", "tn")
  doAssert code == 0, "incus storage volume list failed: " & output
  for line in output.splitLines():
    if line.strip() == "container," & name: return false
  true

proc ownerUid(path: string): int =
  var st: Stat
  doAssert stat(path.cstring, st) == 0, "stat " & path
  st.st_uid.int

proc uniqueName(tag: string): string =

  "gosti-crud-e2e-" & tag & "-" & $getCurrentProcessId() & "-" &
    toHex(rand(0xFFFFFF), 6).toLowerAscii()

randomize()

suite "t_crud_incus_real":
  var usable = incus.probeAvailability()
  if not usable:
    echo "[skip] incus daemon not reachable via the configured command " &
         "(set GOSTI_INCUS_CMD=\"sudo -n incus\" if needed)"
  else:
    let (code, output) = incusOut("image", "list", image, "--format", "csv",
                                  "-c", "f")
    if code != 0 or output.strip().len == 0:
      echo "[skip] image '" & image & "' cannot be resolved: " & output
      usable = false

  test "create with mounts + user-data, verify, list_images, stop/start, delete":
    if not usable: skip()
    else:
      let work = createTempDir("gosti-crud-incus-real-", "")
      let stateDir = work / "state"
      let roDir = work / "ro"
      let rwDir = work / "rw"
      let plainDir = work / "plain"   # root-owned 0755, unshifted rw
      createDir(roDir)
      createDir(rwDir)
      createDir(plainDir)
      discard execCmd("chmod 0755 " & quoteShell(plainDir))
      # World-readable / world-writable so the unprivileged container's
      # shifted root can read (and, on the rw share, write) them.
      setFilePermissions(work, {fpUserRead, fpUserWrite, fpUserExec,
        fpGroupRead, fpGroupExec, fpOthersRead, fpOthersExec})
      let token = "host-token-" & toHex(rand(0x7FFFFFFF), 8)
      writeFile(roDir / "hello.txt", token)
      setFilePermissions(roDir / "hello.txt", {fpUserRead, fpUserWrite,
        fpGroupRead, fpOthersRead})
      setFilePermissions(roDir, {fpUserRead, fpUserWrite, fpUserExec,
        fpGroupRead, fpGroupExec, fpOthersRead, fpOthersExec})
      discard execCmd("chmod 0777 " & quoteShell(rwDir))
      let marker = "cloud-init-marker-" & toHex(rand(0x7FFFFFFF), 8)
      let userData = work / "user-data.yaml"
      writeFile(userData, "#cloud-config\n" &
        "write_files:\n" &
        "- path: /var/tmp/gosti-crud-marker\n" &
        "  content: \"" & marker & "\"\n" &
        "runcmd:\n" &
        "- [sh, -c, \"echo runcmd-ran > /var/tmp/gosti-crud-runcmd\"]\n")
      let name = uniqueName("a")
      try:
        # (a) create
        let (cc, created) = crud(stateDir, "create_vm", name,
          "--source-image", image, "--user-data", userData,
          "--mount", roDir & ":/mnt/ro:ro", "--mount", rwDir & ":/mnt/rw",
          "--mount", plainDir & ":/mnt/plain")
        echo "create_vm: ", $created
        check cc == 0
        check created["data"]["vm"]["state"].getStr == "running"
        check not containerGone(name)

        # (b) cloud-init ran the user-data. `status --wait` exits 2 for
        # "done with recoverable errors" (e.g. no sshd in a minimal image).
        let (ws, wout) = guestSh(stateDir, name,
          "cloud-init status --wait >/dev/null 2>&1; echo rc=$?; " &
          "cloud-init status --long 2>&1 | grep -i -e '^status' -e detail")
        echo "cloud-init: ", wout.strip().replace("\n", " | ")
        check ws == 0
        check "rc=0" in wout or "rc=2" in wout
        check "status: done" in wout
        let (ms, mout) = guestSh(stateDir, name,
          "cat /var/tmp/gosti-crud-marker; echo; cat /var/tmp/gosti-crud-runcmd")
        check ms == 0
        check mout.splitLines()[0] == marker
        check "runcmd-ran" in mout

        # (c) mounts: RO shows the host file and refuses writes ...
        let (rs, rout) = guestSh(stateDir, name, "cat /mnt/ro/hello.txt")
        check rs == 0
        check rout == token
        let (ws2, wout2) = guestSh(stateDir, name,
          "echo nope > /mnt/ro/guest-wrote 2>&1; echo rc=$?")
        echo "ro write: ", wout2.strip()
        check ws2 == 0
        check "rc=0" notin wout2
        check not fileExists(roDir / "guest-wrote")
        # ... RW carries a guest write back to the host.
        let (ws3, _) = guestSh(stateDir, name,
          "echo guest-wrote-this > /mnt/rw/from-guest")
        check ws3 == 0
        check fileExists(rwDir / "from-guest")
        if fileExists(rwDir / "from-guest"):
          check readFile(rwDir / "from-guest").strip() == "guest-wrote-this"
          # Unshifted: guest root is the container's mapped uid on the host.
          let uid = ownerUid(rwDir / "from-guest")
          echo "unshifted rw: guest-root file is host uid ", uid
          check uid != 0
        # Unshifted, so guest root may NOT write a root-owned 0755 host dir.
        let (ps, pout) = guestSh(stateDir, name,
          "echo x > /mnt/plain/guest-wrote 2>&1; echo rc=$?")
        echo "unshifted root-owned write: ", pout.strip()
        check ps == 0
        check "rc=0" notin pout
        check not fileExists(plainDir / "guest-wrote")

        # (d) list_images lists the image the container was created from.
        let (fc, fp) = incusOut("config", "get", name, "volatile.base_image")
        check fc == 0
        let (lc, imgs) = crud(stateDir, "list_images")
        check lc == 0
        var found = false
        for img in imgs["data"]["images"]:
          if img["id"].getStr == fp.strip(): found = true
        echo "list_images: ", imgs["data"]["images"].len, " image(s); base ",
             fp.strip()[0 ..< min(12, fp.strip().len)], " listed=", found
        check found

        # (e) stop/start keeps the same container.
        let (sc, stopped) = crud(stateDir, "stop_vm", name)
        check sc == 0
        check stopped["data"]["vm"]["state"].getStr == "stopped"
        let (_, st) = incusOut("list", name, "--format", "csv", "-c", "s")
        check st.strip() == "STOPPED"
        let (gc, got) = crud(stateDir, "get_vm", name)
        check gc == 0 and got["data"]["vm"]["state"].getStr == "stopped"
        let (rc2, started) = crud(stateDir, "start_vm", name)
        check rc2 == 0
        check started["data"]["vm"]["state"].getStr == "running"
        let (_, again) = guestSh(stateDir, name, "cat /var/tmp/gosti-crud-marker")
        check again == marker

        # (f) delete leaves nothing behind.
        let (dc, deleted) = crud(stateDir, "delete_vm", name)
        check dc == 0
        check deleted["data"]["deleted"].getBool
        check containerGone(name)
        check volumeGone(name)
        check crud(stateDir, "get_vm", name).code == 3
        check crud(stateDir, "list_vms").env["data"]["vms"].len == 0
      finally:
        if not containerGone(name):
          discard incusOut("delete", "--force", name)
        removeDir(work)

  test "user-data with a non-cloud-init image: bad-args (2), no container":
    if not usable: skip()
    else:
      let work = createTempDir("gosti-crud-incus-real-", "")
      let name = uniqueName("b")
      try:
        writeFile(work / "ud.yaml", "#cloud-config\n")
        let (code, env) = crud(work / "state", "create_vm", name,
          "--source-image", plainImage, "--user-data", work / "ud.yaml")
        echo "non-cloud create_vm: ", $env
        check code == 2
        check env["error"]["kind"].getStr == "bad-args"
        check containerGone(name)
        check volumeGone(name)
      finally:
        if not containerGone(name):
          discard incusOut("delete", "--force", name)
        removeDir(work)

  test "--source-image as a full / unique-prefix fingerprint; ambiguous => 2":
    if not usable: skip()
    else:
      # The local store holds at least the image the first case pulled.
      let (lc, listing) = incusOut("image", "list", "--format", "json")
      doAssert lc == 0, listing
      var fps: seq[string]
      for img in parseJson(listing): fps.add(img["fingerprint"].getStr)
      check fps.len >= 1
      # A prefix that is unique in the local store (incus needs no more).
      var fp = fps[0]
      var prefix = ""
      for n in 1 .. fp.len:
        var hits = 0
        for f in fps:
          if f.startsWith(fp[0 ..< n]): inc hits
        if hits == 1:
          prefix = fp[0 ..< max(n, 4)]
          break
      for (tag, reference) in [("f", fp), ("p", prefix)]:
        let work = createTempDir("gosti-crud-incus-real-", "")
        let name = uniqueName(tag)
        try:
          let (code, env) = crud(work / "state", "create_vm", name,
                                 "--source-image", reference)
          echo "create_vm --source-image ", reference, ": ", code
          check code == 0
          if code == 0:
            let (bc, base) = incusOut("config", "get", name,
                                      "volatile.base_image")
            check bc == 0 and base.strip() == fp
            check crud(work / "state", "delete_vm", name).code == 0
          else:
            echo $env
          check containerGone(name)
        finally:
          if not containerGone(name):
            discard incusOut("delete", "--force", name)
          removeDir(work)
      # An ambiguous prefix: the longest prefix two local images share.
      var shared = ""
      for i in 0 ..< fps.len:
        for j in i + 1 ..< fps.len:
          var k = 0
          while k < min(fps[i].len, fps[j].len) and fps[i][k] == fps[j][k]: inc k
          if k > shared.len: shared = fps[i][0 ..< k]
      if shared.len == 0:
        echo "[note] no two local images share a fingerprint prefix; the " &
             "ambiguity case is pinned by t_crud_incus_parity only"
      else:
        let work = createTempDir("gosti-crud-incus-real-", "")
        let name = uniqueName("m")
        try:
          let (code, env) = crud(work / "state", "create_vm", name,
                                 "--source-image", shared)
          echo "ambiguous --source-image ", shared, ": ", $env
          check code == 2
          check "ambiguous" in env["error"]["message"].getStr
          check containerGone(name)
        finally:
          if not containerGone(name):
            discard incusOut("delete", "--force", name)
          removeDir(work)

  test ":shift mount: host-root write where supported, else 5 + no residue":
    if not usable: skip()
    else:
      let work = createTempDir("gosti-crud-incus-real-", "")
      let shiftDir = work / "shift"   # root-owned 0755
      createDir(shiftDir)
      discard execCmd("chmod 0755 " & quoteShell(work) & " " &
                      quoteShell(shiftDir))
      let name = uniqueName("s")
      try:
        let (code, env) = crud(work / "state", "create_vm", name,
          "--source-image", plainImage, "--mount", shiftDir & ":/mnt/shift:shift")
        echo ":shift create_vm: ", $env
        if code == 0:
          let (ss, sout) = guestSh(work / "state", name,
            "echo shifted > /mnt/shift/guest-wrote 2>&1; echo rc=$?")
          echo "shifted write: ", sout.strip()
          check ss == 0 and "rc=0" in sout
          check fileExists(shiftDir / "guest-wrote")
          if fileExists(shiftDir / "guest-wrote"):
            check ownerUid(shiftDir / "guest-wrote") == 0
          check crud(work / "state", "delete_vm", name).code == 0
        else:
          # This host's kernel/daemon cannot idmap the source: the create
          # fails as a backend-error carrying incus's reason, nothing left.
          echo "[note] host has no idmapped-mount support for ", shiftDir,
               "; asserting the fail-closed path"
          check code == 5
          check env["error"]["kind"].getStr == "backend-error"
          check "idmap" in env["error"]["message"].getStr
        check containerGone(name)
        check volumeGone(name)
      finally:
        if not containerGone(name):
          discard incusOut("delete", "--force", name)
        removeDir(work)
