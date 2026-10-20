#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Metacraft Labs / Schelling Point Labs
# SPDX-License-Identifier: Apache-2.0
# fetch-image.sh — fetch the Ubuntu 24.04 cloud image the libvirt Linux
# smoke gates boot (campaign M4, ``e2e_vm_harness_libvirt_linux_smoke``).
#
# The image is pinned to one dated release directory and its SHA-256, so
# the same golden is booted until this file is changed on purpose. The
# hash was taken from that directory's SHA256SUMS on 2026-10-20.
#
# The image ships cloud-init and reads a NoCloud ``cidata`` seed, which is
# how the gate injects its throwaway SSH key. It boots under SeaBIOS and
# OVMF alike.
#
# Output:
#   ./build/ubuntu-24.04-server-cloudimg-amd64.qcow2
#
# Override the directory with VMH_BUILD_DIR (or GOSTI_BUILD_DIR). Required
# tools: curl, sha256sum.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
BUILD_DIR="${GOSTI_BUILD_DIR:-${VMH_BUILD_DIR:-${SCRIPT_DIR}/build}}"
RELEASE="release-20260926"
URL="https://cloud-images.ubuntu.com/releases/noble/${RELEASE}/ubuntu-24.04-server-cloudimg-amd64.img"
SHA256="6a81c37564db9b1ee84e141922625e1d7c5b389b99bb3c572e0243607d5bb4d2"
OUT="${BUILD_DIR}/ubuntu-24.04-server-cloudimg-amd64.qcow2"

mkdir -p "${BUILD_DIR}"

verify() {
  echo "${SHA256}  $1" | sha256sum --check --status
}

if [[ -f "${OUT}" ]] && verify "${OUT}"; then
  echo "fetch-image: ${OUT} already present and verified"
  echo "${OUT}"
  exit 0
fi

partial="${OUT}.partial"
echo "fetch-image: downloading ${URL}" >&2
curl -L --fail --progress-bar -o "${partial}" "${URL}"
if ! verify "${partial}"; then
  actual="$(sha256sum "${partial}" | cut -d' ' -f1)"
  rm -f "${partial}"
  echo "fetch-image: SHA-256 mismatch for ${URL}: expected ${SHA256}, got ${actual}" >&2
  exit 1
fi
mv "${partial}" "${OUT}"
echo "${OUT}"
