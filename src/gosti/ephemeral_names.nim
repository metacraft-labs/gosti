# SPDX-FileCopyrightText: 2026 Metacraft Labs / Schelling Point Labs
# SPDX-License-Identifier: Apache-2.0
## Names of the per-job clones the gosti-run backends (tart, utm,
## qemu-windows-arm) mint, and the rule that decides which existing clones a
## backend may treat as its OWN stale leftovers.
##
## Every one of those backends names a clone ``<prefix>-<epoch-ms>-<pid>``
## (tart additionally clones snapshots as ``<clone>-snap-<name>``), and the
## tart and utm backends "reap stale ephemerals" at provision time: they stop
## and delete every VM whose name belongs to their prefix, to reclaim a
## previous attempt that died before its cleanup ran.
##
## WHY THE SCOPE MATTERS. That reap is only safe when the prefix names ONE
## owner. On the Apple-silicon CI host m3 (measured 2026-11-12) two GARM
## controllers create tart-linux-arm guests side by side: the per-host GARM
## passes ``--ephemeral-prefix repro-vm-tart-linux-<garm-instance>``, while
## the central GARM's remote provider calls ``run --ephemeral … --baseline
## garm-<id>`` with no prefix at all. The backend default
## ``repro-vm-tart-linux`` is a prefix of every per-host guest's name, so each
## central-pool create stopped and deleted every running per-host CI guest
## mid-job. Two rules close that, and each is needed on its own:
##
## * ``instanceEphemeralPrefix`` gives a ``run --ephemeral`` with no explicit
##   prefix a per-INSTANCE prefix derived from ``--baseline``. Without it the
##   central GARM's own concurrent instances would all share the default
##   prefix and reap each other.
## * ``ownsEphemeralName`` matches only names of the exact shape the backend
##   mints for that prefix. A bare ``startsWith`` would still let
##   ``…-garm-ab`` claim ``…-garm-abc-<ms>-<pid>``, or the default prefix
##   claim every per-instance one.

import std/strutils

proc instanceKey*(baseline: string): string =
  ## ``baseline`` reduced to characters that are safe in a VM name and a
  ## directory name. GARM instance names (``garm-<id>``) pass unchanged.
  result = newStringOfCap(baseline.len)
  for c in baseline:
    if c in {'a'..'z', 'A'..'Z', '0'..'9', '-', '_'}:
      result.add(c)
    else:
      result.add('_')
  if result.len == 0:
    result = "_"

proc instanceEphemeralPrefix*(backendPrefix, baseline: string): string =
  ## The clone-name prefix for one ephemeral instance:
  ## ``<backend prefix>-<instanceKey(baseline)>``. For tart-linux-arm and
  ## ``garm-abc`` that is ``repro-vm-tart-linux-garm-abc`` — the same prefix
  ## the per-host GARM provider passes explicitly — so every clone on the host
  ## carries its owner in its name whichever controller created it.
  backendPrefix & "-" & instanceKey(baseline)

proc ephemeralName*(prefix: string, epochMs: int64, pid: int): string =
  ## The name a gosti-run backend gives a new per-job clone.
  prefix & "-" & $epochMs & "-" & $pid

proc skipDigits(s: string, start: int): int =
  result = start
  while result < s.len and s[result] in Digits:
    inc result

proc ownsEphemeralName*(prefix, name: string): bool =
  ## Whether ``name`` is a clone this ``prefix`` minted:
  ## ``<prefix>-<digits>-<digits>``, optionally followed by a tart snapshot
  ## suffix ``-snap-<anything>``. Anything else that merely starts with the
  ## prefix belongs to someone else and must never be reaped.
  if prefix.len == 0 or not name.startsWith(prefix & "-"):
    return false
  var i = prefix.len + 1
  let msEnd = skipDigits(name, i)
  if msEnd == i or msEnd >= name.len or name[msEnd] != '-':
    return false
  i = msEnd + 1
  let pidEnd = skipDigits(name, i)
  if pidEnd == i:
    return false
  pidEnd == name.len or name.continuesWith("-snap-", pidEnd)
