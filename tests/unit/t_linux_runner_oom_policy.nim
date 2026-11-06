# SPDX-FileCopyrightText: 2026 Metacraft Labs / Schelling Point Labs
# SPDX-License-Identifier: Apache-2.0
## The Linux runner golden must not let an OOM kill inside a job stop the
## runner service.
##
## Each per-job container has a memory cap. When a job exceeds it, the kernel
## kills a job process. Under systemd's default OOMPolicy=stop the manager then
## stops the runner unit the process belonged to, and the job fails with "The
## runner has received a shutdown signal" instead of an out-of-memory error in
## the failing step (nixos-ci-bare-004, 2026-11-06). The recipe installs a
## manager drop-in setting DefaultOOMPolicy=continue.
##
## This gate holds the recipe text: the drop-in is written to the manager's
## configuration directory with that setting, and the build asserts the merged
## configuration carries it. The behaviour itself (stop vs continue on a real
## kernel OOM kill) is exercised by infra's checks/runner-oom-policy.nix, which
## boots a VM with the bytes this recipe writes.

import std/[strutils, unittest]

const RecipePath = "guest-recipes/linux-x64-runner/build-runner-image.sh"
const DropIn = "/etc/systemd/system.conf.d/50-gosti-oom-policy.conf"
const Delim = "OOMPOLICY"

proc dropInBody(text: string): string =
  ## The heredoc the recipe writes to `DropIn`, or "" when there is none.
  let open = "cat > " & DropIn & " <<'" & Delim & "'\n"
  let start = text.find(open)
  if start < 0: return ""
  let bodyStart = start + open.len
  let finish = text.find("\n" & Delim & "\n", bodyStart)
  if finish < 0: return ""
  text[bodyStart .. finish]

proc problems(text: string): seq[string] =
  let body = dropInBody(text)
  if body.len == 0:
    result.add "the recipe does not write " & DropIn
    return
  var section = ""
  var policy = ""
  for raw in body.splitLines:
    let line = raw.strip
    if line.len == 0 or line.startsWith("#"): continue
    if line.startsWith("["):
      section = line
    elif line.startsWith("DefaultOOMPolicy="):
      if section != "[Manager]":
        result.add "DefaultOOMPolicy is outside the [Manager] section"
      policy = line.split('=', 1)[1]
  if policy != "continue":
    result.add "DefaultOOMPolicy is '" & policy & "', not 'continue'"
  if "grep -qx 'DefaultOOMPolicy=continue'" notin text:
    result.add "the build does not assert the merged manager configuration"

suite "linux runner OOM policy":
  test "the recipe installs DefaultOOMPolicy=continue and asserts it":
    check problems(readFile(RecipePath)).len == 0
    if problems(readFile(RecipePath)).len > 0:
      echo problems(readFile(RecipePath))

  test "negative controls are caught":
    let text = readFile(RecipePath)
    # The drop-in missing entirely.
    check problems(text.replace(DropIn, "/etc/systemd/elsewhere.conf")).len > 0
    # The systemd default restored.
    check problems(text.replace("DefaultOOMPolicy=continue\n" & Delim,
                                "DefaultOOMPolicy=stop\n" & Delim)).len > 0
    # The setting moved out of [Manager], where systemd would ignore it.
    check problems(text.replace("[Manager]\nDefaultOOMPolicy",
                                "[Service]\nDefaultOOMPolicy")).len > 0
