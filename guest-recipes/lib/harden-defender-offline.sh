#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Metacraft Labs / Schelling Point Labs
# SPDX-License-Identifier: Apache-2.0
#
# harden-defender-offline.sh — the Linux/qcow2 sibling of harden-defender.ps1.
#
# Applies the SAME offline registry payload (defender-off-system.reg,
# defender-off-software.reg, verified against defender-off.targets) to a
# Windows qcow2 that is NOT running, via qemu-nbd + ntfs-3g + hivexregedit.
# harden-defender.README.md is the rationale (why offline, why the service
# Start=4 values are the lever, why TamperProtection is deliberately not
# touched); nothing here changes that design, only the host it runs on.
#
# Usage:  sudo harden-defender-offline.sh <image.qcow2>
#
# Needs root (nbd + mount), and on PATH: qemu-nbd, ntfs-3g, hivexregedit,
# hivexget. e.g.
#   nix shell nixpkgs#qemu nixpkgs#ntfs3g nixpkgs#hivex -c sudo -E ./harden-defender-offline.sh img.qcow2
#
# The image must have been shut down cleanly with hibernation/fast startup
# off (the Windows recipes guarantee both): ntfs-3g refuses a hibernated
# volume, and this script does not force it.
set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
IMG="${1:?usage: harden-defender-offline.sh <image.qcow2>}"
SYS_REG="$HERE/defender-off-system.reg"
SOFT_REG="$HERE/defender-off-software.reg"
TARGETS="$HERE/defender-off.targets"

log()  { echo "[harden-defender-offline] $*"; }
fail() { echo "[harden-defender-offline][FAIL] $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || fail "must run as root (nbd + mount)"
[[ -f "$IMG" ]] || fail "image not found: $IMG"
for f in "$SYS_REG" "$SOFT_REG" "$TARGETS"; do [[ -f "$f" ]] || fail "payload file missing: $f"; done
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

MNT="$(mktemp -d /tmp/harden-defender-XXXXXX)"
WORK="$(mktemp -d /tmp/harden-defender-reg-XXXXXX)"
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

sed "s/{{CS}}/$CS/g" "$SYS_REG" > "$WORK/system.reg"
hivexregedit --merge --prefix 'HKEY_LOCAL_MACHINE\HARDEN_SYS' "$SYSHIVE" "$WORK/system.reg"
hivexregedit --merge --prefix 'HKEY_LOCAL_MACHINE\HARDEN_SOFT' "$SOFTHIVE" "$SOFT_REG"

# Verify by reading back, and assert every target was found and set.
bad=0; n=0
while read -r svc; do
  [[ -z "$svc" || "$svc" == \#* ]] && continue
  n=$((n + 1))
  v="$(hget "$SYSHIVE" "\\$CS\\Services\\$svc" Start 2>/dev/null || echo missing)"
  if [[ "$v" == 4 ]]; then log "  $svc Start=4"; else log "  $svc Start=$v (EXPECTED 4)"; bad=1; fi
done < "$TARGETS"
[[ "$n" -gt 0 ]] || fail "targets file listed nothing"
[[ "$bad" == 0 ]] || fail "one or more services did not take Start=4"
sync
log "done: $n services disabled offline in $IMG"
