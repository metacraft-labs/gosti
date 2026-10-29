#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Metacraft Labs / Schelling Point Labs
# SPDX-License-Identifier: Apache-2.0
# Smoke-test a prebuilt Windows ARM qcow2 directory through gosti's
# direct QEMU/HVF backend. This intentionally does not build Windows; it only
# consumes a VM directory containing windows.qcow2.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." >/dev/null 2>&1 && pwd)"

VM_DIR="${1:-}"
OUT_DIR="${OUT_DIR:-${REPO_ROOT}/build/qemu-windows-arm-cached-boot-smoke}"
TIMEOUT_SEC="${TIMEOUT_SEC:-600}"

usage() {
  cat <<'EOF'
Usage: scripts/qemu-windows-arm-cached-boot-smoke.sh <vm-directory>

The VM directory must contain windows.qcow2 and a Windows ARM guest with
OpenSSH enabled. Optional firmware files such as QEMU_EFI.fd/AAVMF_CODE.fd
and matching VARS files are copied into the ephemeral boot directory.

Environment:
  GOSTI_BIN                         gosti binary to run
  GOSTI_QEMU_WINDOWS_ARM_SSH_USER          SSH user (default: admin)
  GOSTI_QEMU_WINDOWS_ARM_SSH_PASSWORD      SSH password (default: repro-windows-arm)
  GOSTI_QEMU_WINDOWS_ARM_SSH_PORT          preferred host SSH port (default: 2223)
  GOSTI_QEMU_WINDOWS_ARM_SSH_TIMEOUT       SSH-ready timeout seconds (default: 300)
  GOSTI_QEMU_WINDOWS_ARM_STATE_DIR  writable state dir for ephemeral copies
  OUT_DIR                                output envelope directory
  TIMEOUT_SEC                            in-guest command timeout
EOF
}

if [[ -z "${VM_DIR}" || "${VM_DIR}" == "-h" || "${VM_DIR}" == "--help" ]]; then
  usage
  exit 2
fi

if [[ ! -d "${VM_DIR}" ]]; then
  echo "qemu-windows-arm-smoke: VM directory not found: ${VM_DIR}" >&2
  exit 1
fi

if [[ ! -f "${VM_DIR}/windows.qcow2" ]]; then
  echo "qemu-windows-arm-smoke: missing ${VM_DIR}/windows.qcow2" >&2
  exit 1
fi

for cmd in qemu-system-aarch64 ssh sshpass scp; do
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "qemu-windows-arm-smoke: required command not found: ${cmd}" >&2
    exit 1
  fi
done

if [[ -n "${GOSTI_BIN:-}" ]]; then
  GOSTI_CLI="${GOSTI_BIN}"
elif [[ -x "${REPO_ROOT}/build/bin/gosti" ]]; then
  GOSTI_CLI="${REPO_ROOT}/build/bin/gosti"
else
  echo "qemu-windows-arm-smoke: gosti binary not found." >&2
  echo "qemu-windows-arm-smoke: run 'nimble buildCli' or set GOSTI_BIN." >&2
  exit 1
fi

rm -rf "${OUT_DIR}"
mkdir -p "${OUT_DIR}"

echo "qemu-windows-arm-smoke: booting ${VM_DIR}"
echo "qemu-windows-arm-smoke: output ${OUT_DIR}"

"${GOSTI_CLI}" run \
  --backend qemu-windows-arm \
  --guest windows \
  --baseline "${VM_DIR}" \
  --output-dir "${OUT_DIR}" \
  --timeout-sec "${TIMEOUT_SEC}" \
  -- \
  powershell -NoLogo -NoProfile -Command \
  "[System.Environment]::OSVersion.VersionString; [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture"

echo "qemu-windows-arm-smoke: PASS"
