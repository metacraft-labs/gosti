#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Metacraft Labs / Schelling Point Labs
# SPDX-License-Identifier: Apache-2.0
#
# install-binaries.sh <built-cli> <bin-dir>
#
# The ONE definition of the installed command names, shared by the flake's
# installPhase and `just build` so the two can never disagree.
#
#   <bin-dir>/gosti        the CLI/daemon (primary name since the rename)
#   <bin-dir>/vm-harness   -> gosti   (compatibility name, same binary)
#
# The compatibility name is a RELATIVE symlink, so it survives the store path
# and any copy of the bin dir. It is not a wrapper: argv, exit codes and the
# serve daemon's worker re-exec (which uses the resolved executable) are
# identical under either name. Consumers that still invoke `vm-harness` —
# `vm-harness serve` units, garm-provider-vmharness's default binary path,
# scripts — keep working unchanged. See docs/design.md "Command names".
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: $0 <built-cli> <bin-dir>" >&2
  exit 2
fi
built=$1
bindir=$2

mkdir -p "$bindir"
install -m755 "$built" "$bindir/gosti"
ln -sfn gosti "$bindir/vm-harness"
