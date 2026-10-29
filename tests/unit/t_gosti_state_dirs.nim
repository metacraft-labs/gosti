# SPDX-FileCopyrightText: 2026 Metacraft Labs / Schelling Point Labs
# SPDX-License-Identifier: Apache-2.0
## t_gosti_state_dirs — settings are read only as ``GOSTI_<X>``, and a state
## directory left under the product's retired name is migrated, not read in
## place.
##
##   1. No source file reads an environment variable under a retired prefix
##      (``VMH_``, ``VM_HARNESS_``), and the real readers ignore one that is
##      set: retired names fail as unknown instead of being honoured.
##   2. ``gostiStateDir`` returns ``parent/gosti``; when only the retired
##      ``parent/vm-harness`` exists, it is moved there with its contents.
##   3. The CRUD and label store roots resolve through the same migration.
##
## Mock policy: none. Real process environment and real temp directories.

import std/[os, strutils, tempfiles, unittest]
import gosti/[state_dirs, crud_store, ephemeral_inventory]
import gosti/serve/enrollment
import gosti/backends/[incus, mock]

const RetiredEnvPrefixes = ["VMH_", "VM_HARNESS_"]
const RetiredDirName = "vm-harness"

proc withEnv(pairs: openArray[(string, string)], body: proc()) =
  ## "" deletes the variable.
  var saved: seq[(string, string, bool)]
  for (k, v) in pairs:
    saved.add((k, getEnv(k), existsEnv(k)))
    if v.len > 0: putEnv(k, v) else: delEnv(k)
  try:
    body()
  finally:
    for (k, v, had) in saved:
      if had: putEnv(k, v) else: delEnv(k)

suite "environment variables: GOSTI_ only":
  test "no source reads a retired prefix":
    var offenders: seq[string]
    for f in walkDirRec(currentSourcePath().parentDir / ".." / ".." / "src"):
      if not f.endsWith(".nim"): continue
      for n, line in pairs(readFile(f).splitLines):
        for p in RetiredEnvPrefixes:
          if ("\"" & p) in line:
            offenders.add(f & ":" & $(n + 1))
    check offenders.len == 0
    if offenders.len > 0: echo offenders.join("\n")

  test "real readers ignore a retired variable":
    withEnv([("GOSTI_ENROLL_SECRET", ""), ("VMH_ENROLL_SECRET", "s-old")]) do:
      check resolveEnrollmentSecret("", "", "") == ""
    withEnv([("GOSTI_ENROLL_SECRET", "s-new"), ("VMH_ENROLL_SECRET", "s-old")]) do:
      check resolveEnrollmentSecret("", "", "") == "s-new"
    withEnv([("GOSTI_INCUS_INIT_TIMEOUT_SEC", ""),
             ("VMH_INCUS_INIT_TIMEOUT_SEC", "22")]) do:
      check incusInitTimeoutSec() != 22
    withEnv([("GOSTI_INCUS_INIT_TIMEOUT_SEC", "11")]) do:
      check incusInitTimeoutSec() == 11
    withEnv([("GOSTI_MOCK_UNAVAILABLE", ""), ("VMH_MOCK_UNAVAILABLE", "1")]) do:
      check not mockUnavailable()
    withEnv([("GOSTI_MOCK_UNAVAILABLE", "1")]) do:
      check mockUnavailable()
    withEnv([("GOSTI_CRUD_STATE_DIR", ""), ("VMH_CRUD_STATE_DIR", "/old"),
             ("VM_HARNESS_CRUD_STATE_DIR", "/old")]) do:
      check crudStateRoot() != "/old"

suite "state directories: migrate the retired directory":
  test "neither exists: parent/gosti, nothing created":
    let parent = createTempDir("gosti-dirs", "")
    defer: removeDir(parent)
    check gostiStateDir(parent) == parent / "gosti"
    check not dirExists(parent / "gosti")

  test "only the retired directory exists: it is moved, contents intact":
    let parent = createTempDir("gosti-dirs", "")
    defer: removeDir(parent)
    createDir(parent / RetiredDirName / "crud")
    writeFile(parent / RetiredDirName / "crud" / "record.json", "{}")
    check gostiStateDir(parent) == parent / "gosti"
    check not dirExists(parent / RetiredDirName)
    check readFile(parent / "gosti" / "crud" / "record.json") == "{}"

  test "both exist: parent/gosti, the retired one is left alone":
    let parent = createTempDir("gosti-dirs", "")
    defer: removeDir(parent)
    createDir(parent / "gosti")
    createDir(parent / RetiredDirName)
    check gostiStateDir(parent) == parent / "gosti"
    check dirExists(parent / RetiredDirName)

  when not defined(windows):
    test "a move that cannot happen fails loudly":
      let parent = createTempDir("gosti-dirs", "")
      defer:
        setFilePermissions(parent, {fpUserRead, fpUserWrite, fpUserExec})
        removeDir(parent)
      createDir(parent / RetiredDirName)
      setFilePermissions(parent, {fpUserRead, fpUserExec})
      if getEnv("USER") != "root" and not dirExists(parent / "gosti"):
        expect OSError:
          discard gostiStateDir(parent)

    test "crud and label roots migrate under XDG_STATE_HOME":
      let xdg = createTempDir("gosti-xdg", "")
      defer: removeDir(xdg)
      createDir(xdg / RetiredDirName / "crud")
      writeFile(xdg / RetiredDirName / "crud" / "marker", "x")
      withEnv([("GOSTI_CRUD_STATE_DIR", ""), ("GOSTI_EPHEMERAL_LABEL_DIR", ""),
               ("GOSTI_EPHEMERAL_STATE_DIR", ""), ("STATE_DIRECTORY", ""),
               ("XDG_STATE_HOME", xdg)]) do:
        check crudStateRoot() == xdg / "gosti" / "crud"
        check fileExists(xdg / "gosti" / "crud" / "marker")
        check not dirExists(xdg / RetiredDirName)
        check labelStateRoot() == xdg / "gosti" / "ephemeral-labels"
