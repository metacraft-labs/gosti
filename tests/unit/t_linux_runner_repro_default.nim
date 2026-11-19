# SPDX-FileCopyrightText: 2026 Metacraft Labs / Schelling Point Labs
# SPDX-License-Identifier: Apache-2.0
## The Linux runner recipe must not bake `repro` unless asked to.
##
## Every `repro-portable` up to and including reprobuild 0.2.18's is broken on
## a host without /nix: its nix-user-chroot hid /bin (every `/bin/sh` repro
## spawns failed with ENOENT, breaking the managed git hooks), started repro in
## `/`, and emptied PATH. `repro --version` and `repro hooks protocol` both
## pass regardless, so nothing at bake time notices. infra #2421 turned the bake
## off for gosti-linux-runner with GOSTI_RUNNER_REPRO=0; this gate holds the
## recipe's side, so any other consumer gets no repro rather than a broken one:
##
##   * the recipe's OWN assignment and bake guards, run under bash, skip the
##     bake when GOSTI_RUNNER_REPRO is unset, empty or 0, and bake for 1;
##   * the recipe header and the parameter reference say the bake is off and
##     name the reprobuild check a bundle must pass before it is re-enabled.

import std/[os, osproc, strutils, unittest]

const RecipePath = "guest-recipes/linux-x64-runner/build-runner-image.sh"
const ParametersPath = "docs/site/content/reference/parameters.md"
const HostRootCheck = "repro-portable-host-root"

proc assignment(text: string): string =
  ## The recipe's `REPRO="${GOSTI_RUNNER_REPRO:-...}"` line.
  for line in text.splitLines:
    if line.startsWith("REPRO=\"${GOSTI_RUNNER_REPRO"):
      return line
  doAssert false, "no REPRO= assignment from GOSTI_RUNNER_REPRO in the recipe"

proc guards(text: string): seq[string] =
  ## Every column-0 `if` that tests $REPRO: the bake step and the provenance
  ## stamp.
  for line in text.splitLines:
    if line.startsWith("if ") and "\"$REPRO\"" in line:
      result.add line

proc decisions(text, setting: string): seq[string] =
  ## Runs the recipe's assignment and each guard under bash with
  ## GOSTI_RUNNER_REPRO set as `setting` ("<unset>" leaves it unset), and
  ## returns BAKE / SKIP per guard.
  var script = "unset GOSTI_RUNNER_REPRO\n"
  if setting != "<unset>":
    script.add "export GOSTI_RUNNER_REPRO=" & quoteShell(setting) & "\n"
  script.add assignment(text) & "\n"
  for guard in guards(text):
    script.add guard & "\n  echo BAKE\nelse\n  echo SKIP\nfi\n"
  let dir = getTempDir() / "t_linux_runner_repro_default"
  createDir(dir)
  let file = dir / "probe.sh"
  writeFile(file, script)
  let (output, code) = execCmdEx(quoteShell(findExe("bash")) & " " &
    quoteShell(file.replace('\\', '/')))
  doAssert code == 0, "bash probe failed: " & output
  output.strip.splitLines

suite "linux runner recipe: repro bake default":
  let text = readFile(RecipePath)

  test "both bake guards are found":
    # The bake step and the provenance stamp. A guard the parser missed would
    # make every decision below vacuous.
    check guards(text).len == 2

  test "unset, empty and 0 skip the bake":
    for setting in ["<unset>", "", "0"]:
      let got = decisions(text, setting)
      check got == @["SKIP", "SKIP"]
      if got != @["SKIP", "SKIP"]:
        echo "GOSTI_RUNNER_REPRO=", setting, " -> ", got

  test "an explicit 1 still bakes":
    # Positive control: the guards are live, so the SKIPs above are the
    # default talking rather than a bake that can no longer be enabled.
    check decisions(text, "1") == @["BAKE", "BAKE"]

  test "the re-enable condition is documented":
    check "default: off" in text
    check HostRootCheck in text
    let params = readFile(ParametersPath)
    check "| `GOSTI_RUNNER_REPRO` | bool (`0` = off) | off |" in params
    check HostRootCheck in params
