# SPDX-FileCopyrightText: 2026 Metacraft Labs / Schelling Point Labs
# SPDX-License-Identifier: Apache-2.0
## t_gosti_env_names — GOSTI1b step 3: every setting is read as ``GOSTI_<X>``
## first and the legacy ``VMH_<X>`` / ``VM_HARNESS_<X>`` second, and state
## directories prefer ``gosti/`` while keeping an existing ``vm-harness/``.
##
## For each variable gosti reads: new-only, old-only and both-set (new wins),
## asserted through the REAL readers where one is exported (store roots,
## serve token/enroll secret, incus timeouts, mock failure injection), and
## through ``gostiEnv`` for the rest. The list below is checked against the
## sources, so a newly added ``gostiEnv("VMH_…")`` without a case here fails.
##
## Mock policy: none. Real process environment and real temp directories.

import std/[os, sets, strutils, tempfiles, unittest]
import vm_harness/[env_names, crud_store, ephemeral_handle, ephemeral_inventory]
import vm_harness/serve/enrollment
import vm_harness/backends/[incus, mock]

const LegacyNames = [
  "VMH_BOOT_SMOKE_ARTIFACT_DIR", "VMH_CRUD_STATE_DIR", "VMH_ENROLL_SECRET",
  "VMH_EPHEMERAL_LABEL_DIR", "VMH_EPHEMERAL_STATE_DIR",
  "VMH_HYPERV_CONFIG_DRIVE", "VMH_HYPERV_CRED_CACHE", "VMH_HYPERV_EPH_PREFIX",
  "VMH_HYPERV_FULL_COPY", "VMH_HYPERV_METADATA_PROXY", "VMH_HYPERV_SWITCH",
  "VMH_INCUS_CMD", "VMH_INCUS_CONFIG_TIMEOUT_SEC",
  "VMH_INCUS_CREATE_CONCURRENCY", "VMH_INCUS_CREATE_LOCK_DIR",
  "VMH_INCUS_INIT_TIMEOUT_SEC", "VMH_INCUS_START_TIMEOUT_SEC",
  "VMH_LIBVIRT_IMAGE_POOL_DIR", "VMH_MOCK_FAIL", "VMH_MOCK_UNAVAILABLE",
  "VMH_OVMF_CODE", "VMH_OVMF_VARS", "VMH_QEMU_BOOT_NAME_PREFIX",
  "VMH_QEMU_BOOT_QEMU_CMD", "VMH_QEMU_BOOT_QEMU_IMG_CMD",
  "VMH_QEMU_BOOT_SWTPM_CMD", "VMH_QEMU_EFI_CODE", "VMH_QEMU_EFI_CODE_TEMPLATE",
  "VMH_QEMU_EFI_VARS", "VMH_QEMU_EFI_VARS_TEMPLATE", "VMH_QEMU_FIRMWARE_DIR",
  "VMH_QEMU_WINDOWS_ARM_BOOT_TIMEOUT", "VMH_QEMU_WINDOWS_ARM_DISK_MODE",
  "VMH_QEMU_WINDOWS_ARM_EPHEMERAL_PREFIX", "VMH_QEMU_WINDOWS_ARM_MIN_FREE_GB",
  "VMH_QEMU_WINDOWS_ARM_PROBE_TIMEOUT", "VMH_QEMU_WINDOWS_ARM_QEMU_CMD",
  "VMH_QEMU_WINDOWS_ARM_QEMU_IMG_CMD", "VMH_QEMU_WINDOWS_ARM_SCP_CMD",
  "VMH_QEMU_WINDOWS_ARM_SSHPASS_CMD", "VMH_QEMU_WINDOWS_ARM_SSH_CMD",
  "VMH_QEMU_WINDOWS_ARM_SSH_PASSWORD", "VMH_QEMU_WINDOWS_ARM_SSH_PORT",
  "VMH_QEMU_WINDOWS_ARM_SSH_TIMEOUT", "VMH_QEMU_WINDOWS_ARM_SSH_USER",
  "VMH_QEMU_WINDOWS_ARM_SWTPM_CMD", "VMH_RECIPES_DIR", "VMH_SERVE_TOKEN",
  "VMH_TART_CMD", "VM_HARNESS_QEMU_BOOT_STATE_DIR",
  "VM_HARNESS_QEMU_WINDOWS_ARM_STATE_DIR", "VM_HARNESS_TART_STATE_DIR",
  "VM_HARNESS_UTM_DOCUMENTS_DIR"]

proc withEnv(pairs: openArray[(string, string)], body: proc()) =
  ## "" deletes the variable; "<empty>" sets it to the empty string.
  var saved: seq[(string, string, bool)]
  for (k, v) in pairs:
    saved.add((k, getEnv(k), existsEnv(k)))
    if v == "<empty>": putEnv(k, "")
    elif v.len > 0: putEnv(k, v)
    else: delEnv(k)
  try:
    body()
  finally:
    for (k, v, had) in saved:
      if had: putEnv(k, v) else: delEnv(k)

proc reader(legacy: string): proc(): string =
  result = proc(): string = gostiEnv(legacy)

proc cases(legacy: string, read: proc(): string) =
  ## new-only / old-only / both-set (new wins) / neither.
  let canonical = canonicalEnvName(legacy)
  withEnv([(canonical, "new-value"), (legacy, "")]) do:
    check read() == "new-value"
  withEnv([(canonical, ""), (legacy, "old-value")]) do:
    check read() == "old-value"
  withEnv([(canonical, "new-value"), (legacy, "old-value")]) do:
    check read() == "new-value"

suite "canonical names":
  test "VMH_ and VM_HARNESS_ both map onto GOSTI_":
    check canonicalEnvName("VMH_SERVE_TOKEN") == "GOSTI_SERVE_TOKEN"
    check canonicalEnvName("VM_HARNESS_TART_STATE_DIR") == "GOSTI_TART_STATE_DIR"
    check canonicalEnvName("GOSTI_X") == "GOSTI_X"
    check canonicalEnvName("HOME") == "HOME"

  test "every legacy variable the sources read is covered here":
    var read = initHashSet[string]()
    for f in walkDirRec(currentSourcePath().parentDir / ".." / ".." / "src"):
      if not f.endsWith(".nim"): continue
      for line in lines(f):
        var i = line.find("gostiEnv(\"")
        while i >= 0:
          let start = i + "gostiEnv(\"".len
          let stop = line.find('"', start)
          read.incl(line[start ..< stop])
          i = line.find("gostiEnv(\"", stop)
    for constName in [CrudStateDirEnv, EphemeralStateDirEnv, LabelStateDirEnv,
                      MockFailEnv, MockUnavailableEnv]:
      read.incl(constName)
    for n in read:
      check n in LegacyNames

suite "every variable: new-only / old-only / both (new wins)":
  test "gostiEnv over the full list":
    for legacy in LegacyNames:
      cases(legacy, reader(legacy))

  test "a set-but-empty GOSTI_ value is a deliberate override":
    withEnv([("GOSTI_HYPERV_FULL_COPY", "<empty>"),
             ("VMH_HYPERV_FULL_COPY", "1")]) do:
      check gostiEnv("VMH_HYPERV_FULL_COPY", "dflt") == ""
    withEnv([("GOSTI_HYPERV_FULL_COPY", ""), ("VMH_HYPERV_FULL_COPY", "")]) do:
      check gostiEnv("VMH_HYPERV_FULL_COPY", "dflt") == "dflt"
      check not gostiEnvExists("VMH_HYPERV_FULL_COPY")

  test "real readers: store roots":
    cases("VMH_CRUD_STATE_DIR", proc(): string = crudStateRoot())
    cases("VMH_EPHEMERAL_LABEL_DIR", proc(): string = labelStateRoot())
    cases("VMH_EPHEMERAL_STATE_DIR", proc(): string = ephemeralStateRoot())

  test "real readers: serve enrollment secret":
    for (canonical, legacy, want) in [("s-new", "", "s-new"),
                                      ("", "s-old", "s-old"),
                                      ("s-new", "s-old", "s-new")]:
      withEnv([("GOSTI_ENROLL_SECRET", canonical),
               ("VMH_ENROLL_SECRET", legacy)]) do:
        check resolveEnrollmentSecret("", "", "") == want

  test "real readers: incus tuning":
    for (canonical, legacy, want) in [("11", "", 11), ("", "22", 22),
                                      ("11", "22", 11)]:
      withEnv([("GOSTI_INCUS_INIT_TIMEOUT_SEC", canonical),
               ("VMH_INCUS_INIT_TIMEOUT_SEC", legacy)]) do:
        check incusInitTimeoutSec() == want

  test "real readers: mock failure injection":
    withEnv([("GOSTI_MOCK_UNAVAILABLE", "1"), ("VMH_MOCK_UNAVAILABLE", "")]) do:
      check mockUnavailable()
    withEnv([("GOSTI_MOCK_UNAVAILABLE", ""), ("VMH_MOCK_UNAVAILABLE", "1")]) do:
      check mockUnavailable()
    withEnv([("GOSTI_MOCK_UNAVAILABLE", "0"), ("VMH_MOCK_UNAVAILABLE", "1")]) do:
      check not mockUnavailable()

suite "state directories: prefer gosti/, keep an existing vm-harness/":
  test "neither, legacy only, both":
    let parent = createTempDir("gosti-dirs", "")
    defer: removeDir(parent)
    check preferGostiDir(parent) == parent / "gosti"
    createDir(parent / "vm-harness")
    check preferGostiDir(parent) == parent / "vm-harness"
    createDir(parent / "gosti")
    check preferGostiDir(parent) == parent / "gosti"
    # Nothing was created, moved or removed by the resolver itself.
    check dirExists(parent / "vm-harness")

  when not defined(windows):
    test "crud and label roots follow the same rule under XDG_STATE_HOME":
      let xdg = createTempDir("gosti-xdg", "")
      defer: removeDir(xdg)
      withEnv([("VMH_CRUD_STATE_DIR", ""), ("GOSTI_CRUD_STATE_DIR", ""),
               ("VMH_EPHEMERAL_LABEL_DIR", ""), ("GOSTI_EPHEMERAL_LABEL_DIR", ""),
               ("VMH_EPHEMERAL_STATE_DIR", ""), ("GOSTI_EPHEMERAL_STATE_DIR", ""),
               ("STATE_DIRECTORY", ""), ("XDG_STATE_HOME", xdg)]) do:
        check crudStateRoot() == xdg / "gosti" / "crud"
        createDir(xdg / "vm-harness")
        check crudStateRoot() == xdg / "vm-harness" / "crud"
        check labelStateRoot() == xdg / "vm-harness" / "ephemeral-labels"
        createDir(xdg / "gosti")
        check crudStateRoot() == xdg / "gosti" / "crud"
        check labelStateRoot() == xdg / "gosti" / "ephemeral-labels"
