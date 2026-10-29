# SPDX-FileCopyrightText: 2026 Metacraft Labs / Schelling Point Labs
# SPDX-License-Identifier: Apache-2.0

## Default state directories (``parent/gosti``).
##
## MIGRATION CODE. Before the product was named gosti its state lived in
## ``parent/vm-harness``. ``gostiStateDir`` moves such a directory to
## ``parent/gosti`` the first time it is resolved, so a host keeps its
## ephemeral handles, labels and CRUD records across the upgrade. The old
## directory is never read in place. Hosts whose service modules migrate the
## directory on activation never reach the move.

import std/os

const
  StateDirName* = "gosti"
  RetiredStateDirName = "vm-harness" ## Migration source only.

proc gostiStateDir*(parent: string): string =
  ## ``parent/gosti``. When only the retired ``parent/vm-harness`` exists, it
  ## is renamed to ``parent/gosti`` first. Raises ``OSError`` when that rename
  ## fails and no other process completed it, rather than silently starting
  ## from an empty directory.
  result = parent / StateDirName
  let retired = parent / RetiredStateDirName
  if dirExists(result) or not dirExists(retired):
    return
  try:
    moveDir(retired, result)
  except OSError as e:
    # A concurrent resolver may have moved it first.
    if not dirExists(result):
      raise newException(OSError, "cannot move the retired state directory " &
        retired & " to " & result & ": " & e.msg & ". Move it by hand.")
