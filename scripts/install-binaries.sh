#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Metacraft Labs / Schelling Point Labs
# SPDX-License-Identifier: Apache-2.0
#
# install-binaries.sh <built-cli> <bin-dir>
#
# The ONE definition of the installed command name, shared by the flake's
# installPhase and `just build` so the two can never disagree: the CLI and
# serve daemon are installed as <bin-dir>/gosti. See
# docs/contributors/architecture.md "Command names".
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: $0 <built-cli> <bin-dir>" >&2
  exit 2
fi
built=$1
bindir=$2

mkdir -p "$bindir"
install -m755 "$built" "$bindir/gosti"
