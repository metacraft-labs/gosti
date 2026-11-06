# SPDX-FileCopyrightText: 2026 Metacraft Labs / Schelling Point Labs
# SPDX-License-Identifier: Apache-2.0
## t_layer_gc_incus_host — ``gosti layer gc`` refuses an Incus image that a
## REAL container was created from, and stops refusing once it is gone.
##
## The hermetic half lives in ``tests/unit/t_layer_gc.nim`` (fake ``incus``:
## running / stopped / split-image / daemon-down / garbage / absent). This is
## the half a fake cannot give: that the identifier the guard compares — the
## ``volatile.base_image`` fingerprint a real incusd records on a real
## instance — is the file name the same incusd stores the image under. If
## those ever diverged every hermetic case would stay green and the guard
## would protect nothing.
##
## Steps, against a real daemon:
##   1. ``incus init <source-image>`` a throwaway container and ``incus
##      publish`` it as a new local image — the LAYER. Delete the source.
##   2. With no instance using the layer, ``gosti layer gc <images>/<fp>
##      --dry-run`` exits 0 (``lgoDryRun``) — the positive control.
##   3. ``incus init <layer> user`` (STOPPED): the same command exits 3 and
##      names the container. ``incus start`` it: still exits 3.
##   4. ``incus delete --force`` it: exits 0 (``lgoDryRun``) again.
##
## EVERY call passes ``--dry-run``. The layer is a file inside incusd's own
## store and must be removed with ``incus image delete``, never by unlinking
## it, so this test never lets gosti delete it even if the guard were wrong.
## A refusal does not depend on ``--dry-run``: ``planLayerDeletion`` decides
## before the flag is consulted.
##
## ``virsh`` is a fake answering "no domains" (the native command fixture),
## because libvirt is not under test and a host without a reachable libvirtd
## would otherwise make every step exit 3 for the wrong reason. Everything
## Incus-side is real.
##
## Skips cleanly (exit 0, ``[skip]`` line) when: not Linux; incus is not
## usable via the configured command (``GOSTI_INCUS_CMD``); there is no
## local container image to build the layer from
## (``GOSTI_LAYER_GUARD_SOURCE_IMAGE`` names one, else the first local
## container image is used); or the image store is not readable by this
## user (``INCUS_DIR``, default ``/var/lib/incus``). Throwaway names embed
## the PID; nothing pre-existing is touched.
##
## Run:  nim r --hints:off --threads:on tests/e2e/t_layer_gc_incus_host.nim

import std/[json, os, osproc, streams, strtabs, strutils, unittest]
import ../native_command_fixture
import gosti/types
import gosti/backends/incus
import gosti/cli

when isMainModule:
  let cliParams = commandLineParams()
  if cliParams.len >= 1 and cliParams[0] == "__gosti_cli":
    quit(runCli(cliParams[1 .. ^1]))

when not defined(linux):
  echo "[skip] t_layer_gc_incus_host: Linux host required"
  quit(0)

let tag = "p" & $getCurrentProcessId()
let srcName = "gosti-lgc-src-" & tag
let userName = "gosti-lgc-user-" & tag
let layerAlias = "gosti-lgc-layer-" & tag
let incusDir = getEnv("INCUS_DIR", "/var/lib/incus")
let be = newIncusBackend()

proc incus(args: seq[string]; timeoutSec = 180): ExecResult =
  be.runIncus(args, timeoutSec = timeoutSec)

proc mustIncus(args: seq[string]) =
  let r = incus(args)
  doAssert r.exitCode == 0,
    "incus " & args.join(" ") & " exited " & $r.exitCode & ": " & r.stdout

proc sourceImage(): string =
  result = getEnv("GOSTI_LAYER_GUARD_SOURCE_IMAGE")
  if result.len > 0: return
  let r = incus(@["image", "list", "--format", "json"], 60)
  if r.exitCode != 0: return ""
  for img in parseJson(r.stdout):
    if img{"type"}.getStr("container") == "container":
      return img["fingerprint"].getStr()

proc fingerprintOf(alias: string): string =
  let r = incus(@["image", "list", alias, "--format", "json"], 60)
  doAssert r.exitCode == 0, r.stdout
  for img in parseJson(r.stdout):
    for a in img{"aliases"}.getElems():
      if a{"name"}.getStr() == alias:
        return img["fingerprint"].getStr()
  doAssert false, "published alias " & alias & " not found"

proc cleanup() =
  for c in [userName, srcName]:
    try:
      if be.containerExists(c): discard be.deleteContainer(c)
    except CatchableError: discard
  try: discard incus(@["image", "delete", layerAlias], 60)
  except CatchableError: discard

type CliRun = object
  code: int
  output: string
  event: JsonNode

proc layerGc(binDir, pool, layer: string): CliRun =
  var env = newStringTable(modeCaseSensitive)
  for k, v in envPairs(): env[k] = v
  env["PATH"] = binDir & $PathSep & getEnv("PATH")
  let p = startProcess(getAppFilename(), args = @["__gosti_cli", "layer",
      "gc", layer, "--dry-run", "--image-pool-dir", pool,
      "--log-format", "json"], env = env, options = {poStdErrToStdOut})
  p.inputStream.close()
  result.output = p.outputStream.readAll()
  result.code = p.waitForExit()
  p.close()
  result.event = newJNull()
  for line in result.output.splitLines():
    if line.startsWith("{") and "\"layer-gc\"" in line:
      result.event = parseJson(line)
  echo "    gosti layer gc --dry-run -> exit ", result.code, ": ",
    result.output.strip()

proc namesContainer(r: CliRun; name: string): bool =
  if r.event.kind != JObject: return false
  for referent in r.event["referents"].getElems():
    if referent["kind"].getStr() == "lrkContainer" and referent["name"].getStr() == name:
      return true

suite "t_layer_gc_incus_host":
  test "a real container protects the Incus image it was created from":
    if not be.probeAvailability():
      echo "[skip] incus is not usable via the configured command " &
        "(set GOSTI_INCUS_CMD=\"sudo -n incus\" if needed)"
      skip()
    elif sourceImage().len == 0:
      echo "[skip] no local container image to build the layer from " &
        "(set GOSTI_LAYER_GUARD_SOURCE_IMAGE, or `incus image copy " &
        "images:alpine/3.21 local:`)"
      skip()
    else:
      let work = getTempDir() / ("gosti-lgc-host-" & tag)
      createDir(work)
      let bin = work / "bin"
      let pool = work / "pool"
      createDir(bin); createDir(pool)
      discard commandFixture(bin / "virsh", %*{"output": ""})
      cleanup()
      try:
        # 1. Build the layer: a fresh image with its own fingerprint.
        mustIncus(@["init", sourceImage(), srcName])
        mustIncus(@["publish", srcName, "--alias", layerAlias])
        discard be.deleteContainer(srcName)
        let fp = fingerprintOf(layerAlias)
        let layer = incusDir / "images" / fp
        echo "    layer image ", layerAlias, " = ", layer
        var readable = false
        try:
          readable = fileExists(layer) and getFileSize(layer) > 0
        except OSError: discard
        if not readable:
          echo "[skip] image store not readable by this user: " & layer
          skip()
        else:
          # 2. Positive control: nothing uses it yet.
          let free0 = layerGc(bin, pool, layer)
          check free0.code == 0
          check free0.event{"outcome"}.getStr() == "lgoDryRun"

          # 3. A STOPPED container created from it protects it ...
          mustIncus(@["init", layerAlias, userName])
          let stopped = layerGc(bin, pool, layer)
          check stopped.code == 3
          check stopped.event{"outcome"}.getStr() == "lgoRefused"
          check stopped.namesContainer(userName)

          # ... and so does the same container RUNNING.
          mustIncus(@["start", userName])
          let running = layerGc(bin, pool, layer)
          check running.code == 3
          check running.namesContainer(userName)

          # 4. Gone: deletable again, and the file was never touched.
          check be.deleteContainer(userName).exitCode == 0
          let free1 = layerGc(bin, pool, layer)
          check free1.code == 0
          check free1.event{"outcome"}.getStr() == "lgoDryRun"
          check fileExists(layer)
      finally:
        cleanup()
        removeDir(work)
      check not be.containerExists(userName)
      check not be.containerExists(srcName)
