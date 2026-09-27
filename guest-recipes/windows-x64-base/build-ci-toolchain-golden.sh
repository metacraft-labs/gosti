#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Metacraft Labs / Schelling Point Labs
# SPDX-License-Identifier: Apache-2.0
# build-ci-toolchain-golden.sh — layer the CI toolchain onto the Windows golden.
#
# Produces a SIDE artifact from the cloudbase-init golden that additionally
# carries everything a Windows CI job expects the MACHINE to provide (the parts
# that cannot come from a content-addressed store at job time):
#
#   * Visual Studio 2022 Build Tools (MSVC x64 + Windows SDK), WinFsp,
#     LongPathsEnabled=1, the pinned actions runner      provision-ci-toolchain.ps1
#   * the guest clock contract (RealTimeIsUniversal=1 + UTC) (same, -ClockMode)
#   * antivirus real-time scanning off, offline            ../lib/harden-defender-offline.sh
#
# Every version and digest comes from ci-toolchain.pins. The rationale is in
# ci-toolchain-golden.md. The procedure is the same boot-a-copy / modify /
# capture-cold shape as build-sysprep-golden.sh and the README's retrofits, with
# the gates run TWICE: in the work guest before capture, and on a fresh CoW
# clone of the captured image (the property the fleet depends on is what a
# CLONE sees, not what the work VM saw).
#
# SAFETY: the source golden is never opened for write, and this script never
# writes the live golden path. Promotion (swap) is a separate, explicit step —
# see ci-toolchain-golden.md §Promote.
#
# Usage (on the KVM host, as a user with sudo):
#   ./build-ci-toolchain-golden.sh
#   VMH_CI_DRY_RUN=1 ./build-ci-toolchain-golden.sh      # print the plan only
#
# Env:
#   VMH_SRC_GOLDEN   source golden (default /storage/iso/golden-win11-cloudbase.qcow2)
#   VMH_OUT_GOLDEN   output side artifact
#                      (default /storage/iso/golden-win11-cloudbase-ci-<UTC date>.qcow2)
#   VMH_WORK_QCOW2   throwaway full copy (default /storage/scratch/ci-toolchain-work.qcow2)
#   VMH_CACHE_DIR    host download cache (default /storage/scratch/ci-golden-cache)
#   VMH_CLOCK_MODE   utc (default) | keep — see provision-ci-toolchain.ps1.
#                    `utc` is only correct for domains rendered with
#                    <clock offset='utc'>; see ci-toolchain-golden.md §Clock.
#   VMH_DISABLE_DEFENDER  1 (default) = offline-disable real-time scanning; 0 = keep
#   VMH_GROW_DISK_GB extra virtual disk GiB added to the image (default 80; 0 = none)
#   VMH_VCPUS / VMH_MEMORY_MB  work + verify VM size (default 4 / 8192)
#   VMH_GUEST_PASSWORD  guest admin password (default repro-windows-x64)
#   VMH_OVMF_CODE / VMH_OVMF_VARS  (default /run/libvirt/nix-ovmf/edk2-x86_64-code.fd / edk2-i386-vars.fd)
#   VMH_PROVISION_TIMEOUT seconds for the in-guest provision (default 7200)
#   VMH_KEEP_ON_FAIL  non-empty = on failure, keep the work/verify domains + disks
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
LIB_DIR="$SCRIPT_DIR/../lib"
PINS="$SCRIPT_DIR/ci-toolchain.pins"

SRC_GOLDEN="${VMH_SRC_GOLDEN:-/storage/iso/golden-win11-cloudbase.qcow2}"
OUT_GOLDEN="${VMH_OUT_GOLDEN:-/storage/iso/golden-win11-cloudbase-ci-$(date -u +%Y%m%d).qcow2}"
WORK="${VMH_WORK_QCOW2:-/storage/scratch/ci-toolchain-work.qcow2}"
CACHE="${VMH_CACHE_DIR:-/storage/scratch/ci-golden-cache}"
CLOCK_MODE="${VMH_CLOCK_MODE:-utc}"
DISABLE_DEFENDER="${VMH_DISABLE_DEFENDER:-1}"
GROW_GB="${VMH_GROW_DISK_GB:-80}"
VCPUS="${VMH_VCPUS:-4}"
MEMORY_MB="${VMH_MEMORY_MB:-8192}"
GUEST_PASSWORD="${VMH_GUEST_PASSWORD:-repro-windows-x64}"
OVMF_CODE="${VMH_OVMF_CODE:-/run/libvirt/nix-ovmf/edk2-x86_64-code.fd}"
OVMF_VARS="${VMH_OVMF_VARS:-/run/libvirt/nix-ovmf/edk2-i386-vars.fd}"
PROVISION_TIMEOUT="${VMH_PROVISION_TIMEOUT:-7200}"
URI="${LIBVIRT_DEFAULT_URI:-qemu:///system}"
WORK_DOMAIN="ci-toolchain-work"
VERIFY_DOMAIN="ci-toolchain-verify"
GUEST_STAGE='C:\Windows\Temp\ci-toolchain'
GUEST_STAGE_SCP='C:/Windows/Temp/ci-toolchain'

VIRSH=(sudo -n virsh -c "$URI")

log()  { echo "[ci-toolchain-golden] $(date -u +%H:%M:%SZ) $*"; }
fail() { echo "[ci-toolchain-golden][FAIL] $*" >&2; exit 1; }

pin() { sed -n "s/^$1=//p" "$PINS" | head -1; }

SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=15
          -o LogLevel=ERROR -o PreferredAuthentications=password
          -o ServerAliveInterval=30 -o ServerAliveCountMax=20)
ssh_guest() { sshpass -p "$GUEST_PASSWORD" ssh "${SSH_OPTS[@]}" "admin@$1" "$2"; }
scp_guest() { sshpass -p "$GUEST_PASSWORD" scp "${SSH_OPTS[@]}" "${@:2}" "admin@$1:$GUEST_STAGE_SCP/"; }
ps_guest()  { ssh_guest "$1" "powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass $2"; }

guest_ip() {
  local ip
  ip=$("${VIRSH[@]}" domifaddr "$1" --source agent 2>/dev/null | grep -oE '192\.168\.122\.[0-9]+' | head -1)
  [[ -z "$ip" ]] && ip=$("${VIRSH[@]}" domifaddr "$1" 2>/dev/null | grep -oE '192\.168\.122\.[0-9]+' | head -1)
  echo "$ip"
}

wait_ssh() { # domain -> prints ip
  local ip="" _
  for _ in $(seq 1 90); do
    ip="$(guest_ip "$1")"
    if [[ -n "$ip" ]] && ssh_guest "$ip" hostname >/dev/null 2>&1; then echo "$ip"; return 0; fi
    sleep 10
  done
  return 1
}

wait_off() { # domain timeout
  local deadline=$(( $(date +%s) + $2 ))
  while [[ $(date +%s) -lt $deadline ]]; do
    [[ "$("${VIRSH[@]}" domstate "$1" 2>/dev/null | tr -d '[:space:]')" == shutoff ]] && return 0
    sleep 10
  done
  return 1
}

# The domain shape the recipe boots. Mirrors gosti's ephemeral libvirt XML
# (backends/libvirt.nim buildEphemeralDomainXml): 1 socket x N cores, because
# Windows 11 Pro uses at most 2 sockets and libvirt's default is one socket
# per vCPU; clock per VMH_CLOCK_MODE.
domain_xml() { # name disk nvram
  local offset=utc
  [[ "$CLOCK_MODE" == keep ]] && offset=localtime
  cat <<XML
<domain type='kvm'>
  <name>$1</name>
  <memory unit='MiB'>${MEMORY_MB}</memory>
  <vcpu>${VCPUS}</vcpu>
  <os>
    <type arch='x86_64' machine='q35'>hvm</type>
    <loader readonly='yes' type='pflash' format='raw'>${OVMF_CODE}</loader>
    <nvram template='${OVMF_VARS}' templateFormat='raw' format='raw'>$3</nvram>
    <boot dev='hd'/>
  </os>
  <features>
    <acpi/><apic/>
    <hyperv mode='custom'>
      <relaxed state='on'/><vapic state='on'/>
      <spinlocks state='on' retries='8191'/>
    </hyperv>
    <smm state='on'/>
  </features>
  <cpu mode='host-passthrough'>
    <topology sockets='1' dies='1' cores='${VCPUS}' threads='1'/>
  </cpu>
  <clock offset='${offset}'>
    <timer name='rtc' tickpolicy='catchup'/>
    <timer name='hpet' present='no'/>
    <timer name='hypervclock' present='yes'/>
  </clock>
  <devices>
    <disk type='file' device='disk'>
      <driver name='qemu' type='qcow2'/>
      <source file='$2'/>
      <target dev='vda' bus='virtio'/>
    </disk>
    <interface type='network'>
      <source network='default'/>
      <model type='virtio'/>
    </interface>
    <channel type='unix'>
      <target type='virtio' name='org.qemu.guest_agent.0'/>
    </channel>
    <graphics type='vnc' port='-1' listen='127.0.0.1'/>
    <video><model type='qxl'/></video>
  </devices>
</domain>
XML
}

boot_domain() { # name disk nvram
  local xml; xml="$(mktemp /tmp/ci-toolchain-XXXXXX.xml)"
  domain_xml "$1" "$2" "$3" > "$xml"
  sudo -n cp "$OVMF_VARS" "$3"
  "${VIRSH[@]}" define "$xml" >/dev/null || fail "virsh define $1 failed"
  rm -f "$xml"
  "${VIRSH[@]}" start "$1" >/dev/null || fail "virsh start $1 failed"
}

drop_domain() {
  "${VIRSH[@]}" destroy "$1" >/dev/null 2>&1 || true
  "${VIRSH[@]}" undefine "$1" --nvram >/dev/null 2>&1 || true
}

run_gates() { # ip extra-assert-args label
  local ip="$1" extra="$2" label="$3" g
  for g in assert-git-provisioned.ps1 assert-pwsh-provisioned.ps1 assert-defender-exclusions-sane.ps1; do
    if [[ "$g" == assert-defender-exclusions-sane.ps1 && "$DISABLE_DEFENDER" == 1 && "$label" == clone ]]; then
      continue  # with the AV services disabled there are no preferences to read
    fi
    ps_guest "$ip" "-File $GUEST_STAGE\\$g" 2>&1 | sed "s/^/  [$label:$g] /"
    [[ ${PIPESTATUS[0]} == 0 ]] || fail "$label gate $g FAILED"
  done
  ps_guest "$ip" "-File $GUEST_STAGE\\assert-ci-toolchain.ps1 -StageDir $GUEST_STAGE -ClockMode $CLOCK_MODE -ExpectLogicalProcessors $VCPUS $extra" \
    2>&1 | sed "s/^/  [$label:ci-toolchain] /"
  [[ ${PIPESTATUS[0]} == 0 ]] || fail "$label gate assert-ci-toolchain.ps1 FAILED"
}

stage_into_guest() { # ip [files...]
  local ip="$1"; shift
  ps_guest "$ip" "-Command \"New-Item -Force -ItemType Directory -Path $GUEST_STAGE | Out-Null\"" >/dev/null
  scp_guest "$ip" "$PINS" "$SCRIPT_DIR/provision-ci-toolchain.ps1" "$SCRIPT_DIR/assert-ci-toolchain.ps1" \
    "$LIB_DIR/assert-git-provisioned.ps1" "$LIB_DIR/assert-pwsh-provisioned.ps1" \
    "$LIB_DIR/assert-defender-exclusions-sane.ps1" "$@" || fail "scp into guest failed"
}

check_clock() { # ip
  local g h d
  g="$(ps_guest "$1" "-Command \"[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()\"" | tr -dc 0-9)"
  h="$(date +%s)"; d=$(( g > h ? g - h : h - g ))
  log "clock: guest UTC vs host UTC differ by ${d}s"
  [[ "$d" -le 120 ]] || fail "guest clock is ${d}s off host UTC under clock mode '$CLOCK_MODE'"
}

# ── preflight ────────────────────────────────────────────────────────────────
[[ -f "$PINS" ]] || fail "pins not found: $PINS"
[[ -f "$SRC_GOLDEN" ]] || fail "source golden not found: $SRC_GOLDEN"
[[ "$OUT_GOLDEN" != "$SRC_GOLDEN" ]] || fail "refusing: OUT == SRC"
[[ "$OUT_GOLDEN" != /storage/iso/golden-win11-cloudbase.qcow2 ]] || fail "refusing to write the live golden path; promote separately"
[[ "$CLOCK_MODE" == utc || "$CLOCK_MODE" == keep ]] || fail "VMH_CLOCK_MODE must be utc or keep"

RUNNER_VER="$(pin ACTIONS_RUNNER_VERSION)"
RUNNER_ZIP="actions-runner-win-x64-$RUNNER_VER.zip"
WINFSP_MSI="winfsp-$(pin WINFSP_VERSION).msi"

log "SRC  $SRC_GOLDEN (read-only)"
log "OUT  $OUT_GOLDEN (side artifact)"
log "WORK $WORK   clock=$CLOCK_MODE defender-off=$DISABLE_DEFENDER grow=${GROW_GB}G vm=${VCPUS}c/${MEMORY_MB}M"
if [[ -n "${VMH_CI_DRY_RUN:-}" ]]; then
  log "plan: fetch -> copy+grow -> boot work VM -> provision -> reboot -> gates -> shutdown"
  log "      -> offline AV disable -> capture -> boot CoW clone -> gates again -> record"
  exit 0
fi
for t in sshpass qemu-img curl sha256sum; do command -v "$t" >/dev/null || fail "missing tool: $t"; done
sudo -n true || fail "needs passwordless sudo (virsh / nbd)"

# ── step 1: host-side fetch, digest-checked ──────────────────────────────────
log "step 1: fetching pinned artifacts into $CACHE"
mkdir -p "$CACHE"
fetch() { # url file sha|-
  if [[ ! -f "$CACHE/$2" ]]; then curl -fsSL --retry 3 -o "$CACHE/$2.part" "$1" && mv "$CACHE/$2.part" "$CACHE/$2" || fail "download $1"; fi
  if [[ "$3" != - ]]; then echo "$3  $CACHE/$2" | sha256sum -c --quiet || fail "digest mismatch for $2"; fi
}
fetch "https://github.com/actions/runner/releases/download/v$RUNNER_VER/$RUNNER_ZIP" "$RUNNER_ZIP" "$(pin ACTIONS_RUNNER_SHA256_WIN_X64)"
fetch "$(pin WINFSP_MSI_URL)" "$WINFSP_MSI" "$(pin WINFSP_MSI_SHA256)"
rm -f "$CACHE/vs_buildtools.exe"   # evergreen: always the current bootstrapper, signature-checked in the guest
fetch "$(pin VS_BUILDTOOLS_URL)" vs_buildtools.exe -
log "vs_buildtools.exe sha256 $(sha256sum "$CACHE/vs_buildtools.exe" | cut -d' ' -f1) (recorded, not pinned)"

WORK_NVRAM="${WORK%.qcow2}_VARS.fd"
VERIFY_OVERLAY="${WORK%.qcow2}-verify.qcow2"
VERIFY_NVRAM="${WORK%.qcow2}-verify_VARS.fd"
DONE_OK=0
cleanup() {
  if [[ "$DONE_OK" != 1 && -n "${VMH_KEEP_ON_FAIL:-}" ]]; then
    log "VMH_KEEP_ON_FAIL set: leaving $WORK_DOMAIN / $VERIFY_DOMAIN and their disks for inspection"
    return
  fi
  drop_domain "$WORK_DOMAIN"; drop_domain "$VERIFY_DOMAIN"
  sudo -n rm -f "$WORK" "$WORK_NVRAM" "$VERIFY_OVERLAY" "$VERIFY_NVRAM" "${OUT_GOLDEN}.partial" 2>/dev/null || true
}
trap cleanup EXIT
drop_domain "$WORK_DOMAIN"; drop_domain "$VERIFY_DOMAIN"

# ── step 2: full standalone copy (+ grow) ────────────────────────────────────
log "step 2: copying the golden to $WORK"
sudo -n mkdir -p "$(dirname "$WORK")"
sudo -n rm -f "$WORK"
sudo -n qemu-img convert -O qcow2 "$SRC_GOLDEN" "$WORK" || fail "qemu-img convert (copy) failed"
if [[ "$GROW_GB" -gt 0 ]]; then
  sudo -n qemu-img resize "$WORK" "+${GROW_GB}G" >/dev/null || fail "qemu-img resize failed"
fi

# ── step 3: boot, provision, reboot, gate ────────────────────────────────────
log "step 3: booting $WORK_DOMAIN"
boot_domain "$WORK_DOMAIN" "$WORK" "$WORK_NVRAM"
IP="$(wait_ssh "$WORK_DOMAIN")" || fail "work guest SSH never came up"
log "work guest at $IP ($(ssh_guest "$IP" hostname | tr -d '\r'))"
stage_into_guest "$IP" "$CACHE/$RUNNER_ZIP" "$CACHE/$WINFSP_MSI" "$CACHE/vs_buildtools.exe"
grow=""; [[ "$GROW_GB" -gt 0 ]] && grow="-GrowSystemVolume"
log "provisioning (VS Build Tools is the long leg; budget ${PROVISION_TIMEOUT}s)"
timeout "$PROVISION_TIMEOUT" sshpass -p "$GUEST_PASSWORD" ssh "${SSH_OPTS[@]}" "admin@$IP" \
  "powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $GUEST_STAGE\\provision-ci-toolchain.ps1 -StageDir $GUEST_STAGE -ClockMode $CLOCK_MODE $grow" \
  2>&1 | sed 's/^/  [provision] /'
[[ ${PIPESTATUS[0]} == 0 ]] || fail "provision-ci-toolchain.ps1 failed"

log "rebooting the work guest (installer reboot + clock settings take effect)"
ssh_guest "$IP" 'shutdown /r /t 3 /f' >/dev/null 2>&1 || true
sleep 60
IP="$(wait_ssh "$WORK_DOMAIN")" || fail "work guest did not come back after reboot"
run_gates "$IP" "" work
check_clock "$IP"

log "removing the guest staging dir and shutting down"
ps_guest "$IP" "-Command \"Remove-Item -Recurse -Force -Path $GUEST_STAGE\"" >/dev/null 2>&1 || true
ssh_guest "$IP" 'shutdown /s /t 3 /f' >/dev/null 2>&1 || true
wait_off "$WORK_DOMAIN" 900 || fail "work guest did not power off"
drop_domain "$WORK_DOMAIN"

# ── step 4: offline antivirus disable ────────────────────────────────────────
if [[ "$DISABLE_DEFENDER" == 1 ]]; then
  log "step 4: disabling real-time scanning offline"
  sudo -n env PATH="$PATH" bash "$LIB_DIR/harden-defender-offline.sh" "$WORK" 2>&1 | sed 's/^/  /'
  [[ ${PIPESTATUS[0]} == 0 ]] || fail "offline AV hardening failed"
fi

# ── step 5: capture ──────────────────────────────────────────────────────────
log "step 5: capturing -> $OUT_GOLDEN"
sudo -n qemu-img convert -O qcow2 "$WORK" "${OUT_GOLDEN}.partial" || fail "capture failed"
sudo -n mv -f "${OUT_GOLDEN}.partial" "$OUT_GOLDEN"
sudo -n rm -f "$WORK" "$WORK_NVRAM"

# ── step 6: prove it on a fresh CoW clone of the captured image ──────────────
log "step 6: verifying on a CoW clone of the captured image"
sudo -n qemu-img create -q -f qcow2 -b "$OUT_GOLDEN" -F qcow2 "$VERIFY_OVERLAY" || fail "overlay create failed"
boot_domain "$VERIFY_DOMAIN" "$VERIFY_OVERLAY" "$VERIFY_NVRAM"
IP="$(wait_ssh "$VERIFY_DOMAIN")" || fail "clone SSH never came up (did the offline edit break boot? check VNC)"
stage_into_guest "$IP"
defx=""; [[ "$DISABLE_DEFENDER" == 1 ]] && defx="-ExpectDefenderOff"
run_gates "$IP" "$defx" clone
check_clock "$IP"
drop_domain "$VERIFY_DOMAIN"
sudo -n rm -f "$VERIFY_OVERLAY" "$VERIFY_NVRAM"

# ── step 7: record ───────────────────────────────────────────────────────────
log "step 7: recording"
SUM="$(sudo -n sha256sum "$OUT_GOLDEN" | cut -d' ' -f1)"
{
  echo "golden:        $OUT_GOLDEN"
  echo "sha256:        $SUM"
  echo "built (UTC):   $(date -u +%Y-%m-%dT%H:%M:%SZ) on $(hostname)"
  echo "source:        $SRC_GOLDEN ($(stat -c '%s bytes, mtime %y' "$SRC_GOLDEN"))"
  echo "recipe:        gosti guest-recipes/windows-x64-base/build-ci-toolchain-golden.sh @ $(git -C "$SCRIPT_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)"
  echo "clock mode:    $CLOCK_MODE    defender off: $DISABLE_DEFENDER    grown: +${GROW_GB}G"
  echo "vs bootstrap:  sha256 $(sha256sum "$CACHE/vs_buildtools.exe" | cut -d' ' -f1)"
  grep -v '^#' "$PINS" | grep . | sed 's/^/pin:           /'
} | sudo -n tee "${OUT_GOLDEN%.qcow2}.record.txt"
DONE_OK=1
log "DONE. Promote with the procedure in ci-toolchain-golden.md §Promote."
