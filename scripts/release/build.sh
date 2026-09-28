#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Metacraft Labs
# SPDX-License-Identifier: Apache-2.0
# Variables below are initialized by the pinned shared common.sh.
# shellcheck disable=SC2154,SC1091
set -euo pipefail
source "${RELEASE_TOOLS:?}/common.sh" "$@"
nim c "${release_nim_flags[@]}" --nimcache:"build/nimcache/release-$release_target" \
  --out:build/gosti-release src/vm_harness/cli.nim
bash scripts/install-binaries.sh build/gosti-release "$release_stage/bin"
mkdir -p "$release_stage/share/vm-harness"
cp -R guest-scripts guest-recipes "$release_stage/share/vm-harness/"
cp LICENSE NOTICE "$release_stage/"
if [ "$release_os" = linux ]; then
  mkdir -p "$release_stage/share/licenses/pcre"
  tar -xOf "${RELEASE_PCRE_SRC:?}" pcre-8.45/LICENCE > "$release_stage/share/licenses/pcre/LICENCE"
fi
release_finish
