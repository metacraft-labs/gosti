# SPDX-FileCopyrightText: 2026 Metacraft Labs / Schelling Point Labs
# SPDX-License-Identifier: Apache-2.0

## Environment-variable and state-directory names across the
## ``vm-harness`` → ``gosti`` rename (GOSTI1b step 3).
##
## Every setting gosti reads from the environment has a canonical
## ``GOSTI_<X>`` name and a legacy name: ``VMH_<X>`` for most settings,
## ``VM_HARNESS_<X>`` for the per-backend state dirs. ``gostiEnv`` reads the
## canonical name first and falls back to the legacy one, so a host whose
## modules still export only ``VMH_*`` keeps working, and a host that exports
## both gets the new value. A canonical variable that is SET wins even when it
## is empty, exactly as ``getEnv(name, default)`` treats a set-but-empty
## variable: setting ``GOSTI_X=`` is a deliberate override.
##
## Call sites keep naming the LEGACY variable (``gostiEnv("VMH_SERVE_TOKEN")``)
## so the existing constants, docs and grep paths stay valid; the canonical
## name is derived.
##
## State directories follow the same rule without ever moving data: the
## ``gosti`` directory is used when it exists, an existing ``vm-harness``
## directory otherwise (a running daemon may hold it), and the ``gosti``
## directory when neither exists yet. Independent processes resolve the same
## way, so they agree without coordination.

import std/[os, strutils]

const
  CanonicalEnvPrefix* = "GOSTI_"
  LegacyEnvPrefixes* = ["VMH_", "VM_HARNESS_"]
  CanonicalDirName* = "gosti"
  LegacyDirName* = "vm-harness"

proc canonicalEnvName*(legacy: string): string =
  ## ``VMH_SERVE_TOKEN`` → ``GOSTI_SERVE_TOKEN``,
  ## ``VM_HARNESS_TART_STATE_DIR`` → ``GOSTI_TART_STATE_DIR``. A name that
  ## already is canonical, or carries no known prefix, is returned unchanged.
  for p in LegacyEnvPrefixes:
    if legacy.startsWith(p):
      return CanonicalEnvPrefix & legacy[p.len .. ^1]
  legacy

proc gostiEnvName*(legacy: string): string =
  ## The name that ``gostiEnv`` would read for ``legacy`` right now: the
  ## canonical one when set, else the legacy one. For error messages.
  let canonical = canonicalEnvName(legacy)
  if existsEnv(canonical) or not existsEnv(legacy): canonical else: legacy

proc gostiEnvExists*(legacy: string): bool =
  existsEnv(canonicalEnvName(legacy)) or existsEnv(legacy)

proc gostiEnv*(legacy: string, default = ""): string =
  ## ``GOSTI_<X>`` if set, else the legacy variable if set, else ``default``.
  let canonical = canonicalEnvName(legacy)
  if existsEnv(canonical): return getEnv(canonical)
  if canonical != legacy and existsEnv(legacy): return getEnv(legacy)
  default

proc preferGostiDir*(parent: string): string =
  ## ``parent/gosti`` if it exists, else an existing ``parent/vm-harness``,
  ## else ``parent/gosti``. Never creates or moves anything.
  let canonical = parent / CanonicalDirName
  let legacy = parent / LegacyDirName
  if dirExists(canonical): canonical
  elif dirExists(legacy): legacy
  else: canonical
