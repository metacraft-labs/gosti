#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Metacraft Labs / Schelling Point Labs
# SPDX-License-Identifier: Apache-2.0
#
# gosti-fixture — the gosti CRUD contract (docs/contributors/architecture.md §8.1) with no
# hypervisor, for hermetic consumer tests (e.g. an ah-vm GostiOrchestrator
# test suite).
#
# It is NOT a reimplementation: it runs the real `gosti crud` against the
# deterministic, file-backed `mock` backend (§8.6), so the envelopes, exit
# codes and cross-invocation behaviour are exactly what a real host returns.
#
#   usage: gosti-fixture <verb> [<name>] [args…] [-- <guest argv>]
#
#   GOSTI_FIXTURE_STATE_DIR  per-test state directory (REQUIRED; use a fresh
#                          temp dir per test so tests cannot see each other)
#   GOSTI_FIXTURE_CLI        the gosti command to run (default: the
#                          `gosti` next to this script, else PATH);
#                          word-split, so a prefix like "bin __gosti_cli" works
#   GOSTI_MOCK_FAIL          inject failures: comma list of provision, revert,
#                          start, exec, copy, snapshot, restore (→ exit 5)
#   GOSTI_MOCK_UNAVAILABLE=1 make the backend unavailable (→ exit 4)
#
# Example:
#   export GOSTI_FIXTURE_STATE_DIR=$(mktemp -d)
#   gosti-fixture create_vm vm1
#   gosti-fixture exec vm1 -- echo hi
#   gosti-fixture delete_vm vm1
set -euo pipefail

: "${GOSTI_FIXTURE_STATE_DIR:?set GOSTI_FIXTURE_STATE_DIR to a per-test temp dir}"

if [[ -n "${GOSTI_FIXTURE_CLI:-}" ]]; then
  read -r -a cli <<<"$GOSTI_FIXTURE_CLI"
elif [[ -x "$(dirname "$0")/gosti" ]]; then
  cli=("$(dirname "$0")/gosti")
else
  cli=(gosti)
fi

if [[ $# -lt 1 ]]; then
  echo "usage: gosti-fixture <verb> [<name>] [args…] [-- <guest argv>]" >&2
  exit 2
fi

# The fixture's flags must precede `--` (everything after it is guest argv).
args=()
while [[ $# -gt 0 && "$1" != "--" ]]; do
  args+=("$1")
  shift
done
exec "${cli[@]}" crud "${args[@]}" \
  --backend mock --state-dir "$GOSTI_FIXTURE_STATE_DIR" "$@"
