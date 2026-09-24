#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Metacraft Labs / Schelling Point Labs
# SPDX-License-Identifier: Apache-2.0
#
# vm-harness-fixture — the gosti CRUD contract (docs/design.md §8.1) with no
# hypervisor, for hermetic consumer tests (e.g. an ah-vm GostiOrchestrator
# test suite).
#
# It is NOT a reimplementation: it runs the real `vm-harness crud` against the
# deterministic, file-backed `mock` backend (§8.6), so the envelopes, exit
# codes and cross-invocation behaviour are exactly what a real host returns.
#
#   usage: vm-harness-fixture <verb> [<name>] [args…] [-- <guest argv>]
#
#   VMH_FIXTURE_STATE_DIR  per-test state directory (REQUIRED; use a fresh
#                          temp dir per test so tests cannot see each other)
#   VMH_FIXTURE_CLI        the vm-harness command to run (default: the
#                          `vm-harness` next to this script, else PATH);
#                          word-split, so a prefix like "bin __vmh_cli" works
#   VMH_MOCK_FAIL          inject failures: comma list of provision, revert,
#                          start, exec, copy, snapshot, restore (→ exit 5)
#   VMH_MOCK_UNAVAILABLE=1 make the backend unavailable (→ exit 4)
#
# Example:
#   export VMH_FIXTURE_STATE_DIR=$(mktemp -d)
#   vm-harness-fixture create_vm vm1
#   vm-harness-fixture exec vm1 -- echo hi
#   vm-harness-fixture delete_vm vm1
set -euo pipefail

: "${VMH_FIXTURE_STATE_DIR:?set VMH_FIXTURE_STATE_DIR to a per-test temp dir}"

if [[ -n "${VMH_FIXTURE_CLI:-}" ]]; then
  read -r -a cli <<<"$VMH_FIXTURE_CLI"
elif [[ -x "$(dirname "$0")/vm-harness" ]]; then
  cli=("$(dirname "$0")/vm-harness")
else
  cli=(vm-harness)
fi

if [[ $# -lt 1 ]]; then
  echo "usage: vm-harness-fixture <verb> [<name>] [args…] [-- <guest argv>]" >&2
  exit 2
fi

# The fixture's flags must precede `--` (everything after it is guest argv).
args=()
while [[ $# -gt 0 && "$1" != "--" ]]; do
  args+=("$1")
  shift
done
exec "${cli[@]}" crud "${args[@]}" \
  --backend mock --state-dir "$VMH_FIXTURE_STATE_DIR" "$@"
