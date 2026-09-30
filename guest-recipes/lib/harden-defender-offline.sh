#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Metacraft Labs / Schelling Point Labs
# SPDX-License-Identifier: Apache-2.0
#
# harden-defender-offline.sh — the Linux/qcow2 sibling of harden-defender.ps1.
#
# Applies the SAME offline registry payload (defender-off-system.reg,
# defender-off-software.reg, verified against defender-off.targets) to a
# Windows qcow2 that is NOT running. harden-defender.README.md is the
# rationale. The mechanics live in apply-offline-service-payloads.sh, which
# also applies other payloads (e.g. ci-background-off) in the same pass.
#
# Usage:  sudo harden-defender-offline.sh <image.qcow2>
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
exec bash "$HERE/apply-offline-service-payloads.sh" "${1:?usage: harden-defender-offline.sh <image.qcow2>}" defender-off
