# SPDX-FileCopyrightText: 2026 Metacraft Labs / Schelling Point Labs
# SPDX-License-Identifier: Apache-2.0
## The Linux runner golden must ship a working system C compiler.
##
## The golden is a Debian image without Nix. On such a host reprobuild treats
## the system C compiler as a precondition: it compiles each project's recipe
## with it, and needs curl (and xz) to fetch and unpack the Nim source archive
## it bootstraps from. Without them `repro exec` fails with "could not
## provision the C compiler that compiles the recipe", which is how CI jobs
## failed on the ephemeral `garm-*` runners while passing on bare-metal ones.
##
## This gate holds the recipe text: the baseline apt install names every
## package, and the build compiles, links and runs a probe program, so an image
## with `gcc` but no `libc6-dev` fails the BUILD rather than a CI job later.
## Building the image itself needs an Incus host; that is infra's
## checks/t_runner_image_bake.sh, not this hermetic unit test.

import std/[strutils, unittest]

const RecipePath = "guest-recipes/linux-x64-runner/build-runner-image.sh"
const InstallPrefix = "apt-get install -y -qq --no-install-recommends git "
const Required = ["gcc", "libc6-dev", "curl", "xz-utils"]

proc baselineInstall(text: string): seq[string] =
  ## The package list of the baseline `apt-get install` line, or @[].
  let start = text.find(InstallPrefix)
  if start < 0: return @[]
  let lineEnd = text.find('\n', start)
  let line = text[start + "apt-get install -y -qq --no-install-recommends ".len ..<
                  (if lineEnd < 0: text.len else: lineEnd)]
  line.splitWhitespace

proc problems(text: string): seq[string] =
  let pkgs = baselineInstall(text)
  if pkgs.len == 0:
    result.add "the recipe has no baseline apt-get install line"
    return
  for p in Required:
    if p notin pkgs:
      result.add "the baseline install does not name " & p
  if "cc -o /tmp/cc-probe /tmp/cc-probe.c" notin text or
      "\n  /tmp/cc-probe\n" notin text:
    result.add "the build does not compile and run a C probe program"

suite "linux runner C toolchain":
  test "the baseline installs gcc, libc6-dev, curl and xz-utils and probes cc":
    let found = problems(readFile(RecipePath))
    check found.len == 0
    if found.len > 0: echo found

  test "negative controls are caught":
    let text = readFile(RecipePath)
    # libc headers dropped: gcc alone cannot compile against libc.
    check problems(text.replace(" curl gcc libc6-dev ", " curl gcc ")).len > 0
    # The compiler dropped.
    check problems(text.replace(" curl gcc libc6-dev ", " curl libc6-dev ")).len > 0
    # curl dropped (the Nim source download).
    check problems(text.replace(" ca-certificates curl gcc ", " ca-certificates gcc ")).len > 0
    # The probe reduced to a PATH lookup.
    check problems(text.replace("cc -o /tmp/cc-probe /tmp/cc-probe.c", "true")).len > 0
