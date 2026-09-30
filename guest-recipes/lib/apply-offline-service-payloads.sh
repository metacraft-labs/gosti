#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Metacraft Labs / Schelling Point Labs
# SPDX-License-Identifier: Apache-2.0
#
# apply-offline-service-payloads.sh — disable Windows services in a qcow2 that
# is NOT running, by editing its registry hives offline via qemu-nbd + ntfs-3g
# + hivexregedit.
#
# Offline editing is used because some of the services we disable refuse
# an ONLINE change, even from an elevated administrator. These include
# Defender's (Tamper Protection) and Windows Update's UsoSvc and WaaSMedicSvc
# (service ACLs). The hives on a cold disk carry no such protection.
# harden-defender.README.md is the rationale for the Defender payload.
# ../windows-x64-base/ci-toolchain-golden.md covers `ci-background-off`.
#
# Usage:  sudo apply-offline-service-payloads.sh <image.qcow2> <payload>...
#
# A payload <name> is a set of files in this directory:
#   <name>-system.reg    SYSTEM-hive values ({{CS}} = the current control set),
#                        rooted at HKEY_LOCAL_MACHINE\HARDEN_SYS      (required)
#   <name>-software.reg  SOFTWARE-hive values, rooted at
#                        HKEY_LOCAL_MACHINE\HARDEN_SOFT               (optional)
#   <name>.targets       the services that must read back Start=4    (required)
# hivexregedit --merge does NOT create missing parent keys: a .reg file must
# list every key that may be absent, parent first (an empty section suffices).
# Payloads today: defender-off, ci-background-off.
#
# Needs root (nbd + mount), and on PATH: qemu-nbd, ntfs-3g, hivexregedit,
# hivexget. e.g.
#   nix shell nixpkgs#qemu nixpkgs#ntfs3g nixpkgs#hivex -c sudo -E ./apply-offline-service-payloads.sh img.qcow2 defender-off
#
# The image must have been shut down cleanly with hibernation/fast startup
# off (the Windows recipes guarantee both): ntfs-3g refuses a hibernated
# volume, and this script does not force it.
set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
USAGE="usage: apply-offline-service-payloads.sh <image.qcow2> <payload>..."
IMG="${1:?$USAGE}"
shift
[[ $# -gt 0 ]] || { echo "$USAGE" >&2; exit 2; }
PAYLOADS=("$@")

log()  { echo "[offline-service-payloads] $*"; }
fail() { echo "[offline-service-payloads][FAIL] $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || fail "must run as root (nbd + mount)"
[[ -f "$IMG" ]] || fail "image not found: $IMG"
# Validate every payload before the image is touched.
for p in "${PAYLOADS[@]}"; do
  [[ "$p" =~ ^[a-z0-9-]+$ ]] || fail "bad payload name: $p"
  for f in "$HERE/$p-system.reg" "$HERE/$p.targets"; do [[ -f "$f" ]] || fail "payload file missing: $f"; done
done
for t in qemu-nbd ntfs-3g hivexregedit hivexget; do command -v "$t" >/dev/null || fail "missing tool: $t"; done

# hivexget is a shell script with a #!/bin/bash shebang, which NixOS does not
# have; run it through the bash on PATH.
hget() { bash "$(command -v hivexget)" "$@"; }

modprobe nbd max_part=16
NBD=""
for d in /sys/block/nbd*; do
  n="$(basename "$d")"
  if [[ "$(cat "$d/size")" == 0 ]] && [[ ! -e "$d/pid" ]]; then NBD="/dev/$n"; break; fi
done
[[ -n "$NBD" ]] || fail "no free /dev/nbd device"

MNT="$(mktemp -d /tmp/offline-payloads-XXXXXX)"
WORK="$(mktemp -d /tmp/offline-payloads-reg-XXXXXX)"
MOUNTED=0
cleanup() {
  [[ "$MOUNTED" == 1 ]] && umount "$MNT" 2>/dev/null || true
  qemu-nbd --disconnect "$NBD" >/dev/null 2>&1 || true
  rmdir "$MNT" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

log "attaching $IMG at $NBD"
qemu-nbd --connect="$NBD" --format=qcow2 "$IMG"
for _ in $(seq 1 30); do ls "${NBD}p"* >/dev/null 2>&1 && break; sleep 1; done

# Find the Windows volume: the NTFS partition that carries the SYSTEM hive.
for part in "${NBD}p"*; do
  if ntfs-3g -o ro "$part" "$MNT" 2>/dev/null; then
    if [[ -f "$MNT/Windows/System32/config/SYSTEM" ]]; then
      umount "$MNT"
      ntfs-3g "$part" "$MNT" || fail "rw mount of $part failed (hibernated / unclean volume?)"
      MOUNTED=1
      log "Windows volume: $part"
      break
    fi
    umount "$MNT"
  fi
done
[[ "$MOUNTED" == 1 ]] || fail "no NTFS partition with Windows/System32/config/SYSTEM"

SYSHIVE="$MNT/Windows/System32/config/SYSTEM"
SOFTHIVE="$MNT/Windows/System32/config/SOFTWARE"
cur="$(hget "$SYSHIVE" '\Select' Current)"
[[ "$cur" =~ ^[0-9]+$ ]] || fail "could not read \\Select\\Current from SYSTEM (got '$cur')"
CS="$(printf 'ControlSet%03d' "$cur")"
log "current control set: $CS"

# Verify by reading back, and assert every target was found and set.
bad=0; n=0
for p in "${PAYLOADS[@]}"; do
  log "payload $p"
  sed "s/{{CS}}/$CS/g" "$HERE/$p-system.reg" > "$WORK/$p-system.reg"
  hivexregedit --merge --prefix 'HKEY_LOCAL_MACHINE\HARDEN_SYS' "$SYSHIVE" "$WORK/$p-system.reg"
  if [[ -f "$HERE/$p-software.reg" ]]; then
    hivexregedit --merge --prefix 'HKEY_LOCAL_MACHINE\HARDEN_SOFT' "$SOFTHIVE" "$HERE/$p-software.reg"
  fi
  m=0
  while read -r svc; do
    [[ -z "$svc" || "$svc" == \#* ]] && continue
    m=$((m + 1))
    v="$(hget "$SYSHIVE" "\\$CS\\Services\\$svc" Start 2>/dev/null || echo missing)"
    if [[ "$v" == 4 ]]; then log "  $svc Start=4"; else log "  $svc Start=$v (EXPECTED 4)"; bad=1; fi
  done < "$HERE/$p.targets"
  [[ "$m" -gt 0 ]] || fail "$p.targets listed nothing"
  n=$((n + m))
done
[[ "$bad" == 0 ]] || fail "one or more services did not take Start=4"
sync
log "done: $n services disabled offline in $IMG (${PAYLOADS[*]})"
