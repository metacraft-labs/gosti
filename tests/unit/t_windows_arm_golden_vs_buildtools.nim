# SPDX-FileCopyrightText: 2026 Metacraft Labs / Schelling Point Labs
# SPDX-License-Identifier: Apache-2.0
## The Windows-ARM golden carries Visual Studio Build Tools, and cannot be
## captured without them.
##
## FIELD FAILURE. The promoted ``win-arm-runner-20260915T154742Z`` golden had
## no VS Build Tools. Every MSVC cargo link on the ``eph-win-arm64`` runners
## failed with "error: linker `link.exe` not found" and reprobuild printed
## "MSVC dev-env activation skipped: vswhere.exe not found". Nothing in the
## recipe installed them and nothing in the headless build checked.
##
## What this pins, all by reading the real recipe files (no mocks):
##   * the shared pin file names a fixed-version, digest-pinned bootstrapper
##     whose digest is the one in its URL, and both MSVC toolsets;
##   * the ARM answer file stages the installer, its pins and EVERY capture
##     gate the headless build runs, and installs before the sentinel;
##   * the ARM ISO builder copies those files onto the ISO;
##   * the x64 golden delegates to the same installer instead of a copy;
##   * the capture-gate command the backend sends is ``$``-free (sshd's
##     DefaultShell is powershell.exe, which would expand it) and cannot be
##     passed by an ssh wrapper that echoes its argument.
## The capture gates' ENFORCEMENT -- a refusal stops the build before sysprep
## -- is driven end to end in t_qemu_windows_arm_golden_build.nim.

import std/[os, strutils, unittest, xmlparser, xmltree]
import gosti
import qwa_fixture_paths

proc libPath(name: string): string =
  repoRoot() / "guest-recipes" / "lib" / name

proc readPins(path: string): seq[(string, string)] =
  for raw in lines(path):
    let line = raw.strip()
    if line.len == 0 or line.startsWith("#"):
      continue
    let eq = line.find('=')
    if eq > 0:
      result.add((line[0 ..< eq].strip(), line[eq + 1 .. ^1].strip()))

proc pin(pins: seq[(string, string)], key: string): string =
  for (k, v) in pins:
    if k == key:
      return v
  ""

proc collect(node: XmlNode, tag: string, acc: var seq[XmlNode]) =
  if node.kind != xnElement:
    return
  if node.tag == tag:
    acc.add node
  for child in node:
    collect(child, tag, acc)

proc text(node: XmlNode, tag: string): string =
  for child in node:
    if child.kind == xnElement and child.tag == tag:
      for t in child:
        if t.kind in {xnText, xnCData}:
          result.add t.text
  result = result.strip()

proc armAnswerFile(): XmlNode =
  loadXml(recipeDir() / "autounattend.xml")

proc firstLogonCommandLines(xml: XmlNode): seq[string] =
  var cmds: seq[XmlNode]
  collect(xml, "SynchronousCommand", cmds)
  for c in cmds:
    result.add c.text("CommandLine")

proc specializePaths(xml: XmlNode): seq[string] =
  var cmds: seq[XmlNode]
  collect(xml, "RunSynchronousCommand", cmds)
  for c in cmds:
    result.add c.text("Path")

suite "Windows-ARM golden: VS Build Tools pins":

  test "the bootstrapper is the fixed-version one, digest-pinned to its URL":
    let pins = readPins(libPath("vs-buildtools.pins"))
    let url = pins.pin("VS_BUILDTOOLS_URL")
    let sha = pins.pin("VS_BUILDTOOLS_SHA256")
    checkpoint "url=" & url & " sha=" & sha
    check sha.len == 64
    for c in sha:
      check c in {'0' .. '9', 'a' .. 'f'}
    # The evergreen aka.ms link changes bytes with every servicing release,
    # so it cannot be digest-pinned; the fixed-version link carries its own
    # digest as a path segment. The two must agree.
    check url.startsWith("https://download.visualstudio.microsoft.com/")
    check ("/" & sha & "/") in url
    check "aka.ms" notin url
    check pins.pin("VS_BUILDTOOLS_VERSION").len > 0
    check pins.pin("VS_INSTALL_PATH") ==
      "C:\\Program Files (x86)\\Microsoft Visual Studio\\2022\\BuildTools"

  test "both MSVC toolsets, the workload and the SDK are installed and gated":
    let pins = readPins(libPath("vs-buildtools.pins"))
    let components = pins.pin("VS_COMPONENTS").splitWhitespace()
    for want in ["Microsoft.VisualStudio.Workload.VCTools",
                 "Microsoft.VisualStudio.Component.VC.Tools.x86.x64",
                 "Microsoft.VisualStudio.Component.VC.Tools.ARM64",
                 "Microsoft.VisualStudio.Component.Windows11SDK.26100"]:
      checkpoint want
      check want in components
    let targets = pins.pin("VS_REQUIRED_TARGETS").splitWhitespace()
    check "x64" in targets
    check "arm64" in targets
    check pins.pin("WINDOWS_SDK_VERSION") == "10.0.26100.0"

  test "the installer verifies digest and signature before it runs anything":
    let script = readFile(libPath("provision-vs-buildtools.ps1"))
    let digest = script.find("Get-FileHash -Algorithm SHA256")
    let signature = script.find("Get-AuthenticodeSignature")
    let install = script.find("Start-Process -FilePath $boot")
    let recheck = script.rfind("Find-VsInstall $want")
    checkpoint "digest=" & $digest & " sig=" & $signature & " install=" &
      $install & " recheck=" & $recheck
    check digest > 0
    check signature > digest
    check install > signature
    # Success is vswhere seeing every component, not the installer's exit.
    check recheck > install
    check "O=Microsoft Corporation" in script
    check "--includeRecommended" in script

  test "the gate requires vswhere, every component and a linker per target":
    let gate = readFile(libPath("assert-vs-buildtools.ps1"))
    check "vswhere.exe" in gate
    check "-requires" in gate
    check "VS_REQUIRED_TARGETS" in gate
    check "link.exe" in gate
    check "cl.exe" in gate
    check "exit 1" in gate
    # The success line is the marker the headless build requires.
    check QwaCaptureGatePassedMarker in gate

suite "Windows-ARM golden: the answer file installs VS Build Tools":

  test "the installer, its pins and every capture gate are staged in specialize":
    let paths = armAnswerFile().specializePaths()
    for file in @["provision-vs-buildtools.ps1", "vs-buildtools.pins"] &
                @QwaCaptureGates:
      var staged = false
      for p in paths:
        if (file & " C:\\Windows\\Temp\\" & file) in p:
          staged = true
      checkpoint file
      check staged

  test "the install runs from FirstLogon, cannot wedge it, and precedes the sentinel":
    let cmds = armAnswerFile().firstLogonCommandLines()
    var install = -1
    var sentinel = -1
    for i, c in cmds:
      if "provision-vs-buildtools.ps1" in c:
        install = i
      if "repro-install-done" in c:
        sentinel = i
    checkpoint "install=" & $install & " sentinel=" & $sentinel
    check install >= 0
    check sentinel > install
    if install >= 0:
      check "-FailureMarker" in cmds[install]
      check "gosti-vs-buildtools-provision-failed" in cmds[install]
      check cmds[install].endsWith("exit 0\"")

  test "the ISO builder copies the installer, pins and gate onto the ISO":
    let iso = readFile(recipeDir() / "build-autounattend-iso.sh")
    for file in ["provision-vs-buildtools.ps1", "vs-buildtools.pins",
                 "assert-vs-buildtools.ps1"]:
      checkpoint file
      check ("cp \"${LIB_DIR}/" & file & "\" \"${STAGE_DIR}/" & file & "\"") in iso
    # Every capture gate the backend runs must reach the guest.
    for gate in QwaCaptureGates:
      checkpoint gate
      check ("\"${STAGE_DIR}/" & gate & "\"") in iso

suite "The x64 golden shares the installer":

  test "provision-ci-toolchain.ps1 delegates instead of carrying a copy":
    let x64 = repoRoot() / "guest-recipes" / "windows-x64-base"
    let provision = readFile(x64 / "provision-ci-toolchain.ps1")
    check "provision-vs-buildtools.ps1" in provision
    check "-SignatureOnly" in provision
    # The install loop lives in one place only.
    check "--includeRecommended" notin provision
    check "Get-AuthenticodeSignature -LiteralPath $boot" notin provision
    let driver = readFile(x64 / "build-ci-toolchain-golden.sh")
    check "\"$LIB_DIR/provision-vs-buildtools.ps1\"" in driver

suite "The capture-gate command":

  test "it is dollar-free, runs the staged file, and cannot be echoed into a pass":
    for gate in QwaCaptureGates:
      let cmd = buildCaptureGateCommand(gate)
      checkpoint cmd
      check '$' notin cmd
      check "-File" in cmd
      check "-Command" notin cmd
      check cmd.endsWith(QwaCaptureGateDir & "\\" & gate)
      check QwaCaptureGatePassedMarker notin cmd

  test "every capture gate exists in the recipe library":
    for gate in QwaCaptureGates:
      checkpoint gate
      check fileExists(libPath(gate))
      check QwaCaptureGatePassedMarker in readFile(libPath(gate))

  test "the golden deadline leaves room for the Build Tools install":
    # The measured install was 35 min with one freeze recovery; VS adds
    # 20-40 min. Two hours is the floor that keeps a freeze recoverable.
    check QwaDefaultGoldenDeadlineSec >= 120 * 60
