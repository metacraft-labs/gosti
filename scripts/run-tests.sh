#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Metacraft Labs / Schelling Point Labs
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail

run_nim() {
  echo
  echo "==> nim $*"
  nim "$@"
}

# Host-independent unit tests.
run_nim r --hints:off tests/unit/t_output_envelope.nim
run_nim r --hints:off tests/unit/t_auto_selection.nim
# GOSTI2 PR-1: the generic-CRUD façade contract (JSON schema + exit codes),
# every verb driven through the noop backend in-process. Hermetic.
run_nim r --hints:off tests/unit/t_crud_facade.nim
# GOSTI2 PR-2: the same façade driven through the FULL deterministic mock
# backend (backends/mock.nim) — round-trips every verb and asserts the
# lifecycle state machine, snapshot persistence + guest-fs restore, and the
# canned/deterministic VmInfo/SshEndpoint/ExecResult. Hermetic (in-memory).
run_nim r --hints:off tests/unit/t_crud_facade_mock.nim
# GOSTI2 PR-3 + honor-userdata follow-up: the CRUD create surface growth
# (--user-data/--mount/--ssh-user, exec --cwd/--run-as/--timeout) and the
# BACKEND-AWARE fail-closed guard (--user-data allowed only for a backend whose
# honorsUserData() is true; libvirt honors it, the mock does not). Hermetic.
run_nim r --hints:off tests/unit/t_crud_surface_growth.nim
# Cross-invocation crud state (design doc §8.6): the store's location chain,
# name validation, record round-trip, locks (busy + stale-owner break), and
# each real backend's instancePresence decision ("gone" only on a successful
# answer). Hermetic (temp dir + pure functions).
run_nim r --hints:off tests/unit/t_crud_store.nim
# ... and end to end: every verb as a SEPARATE CLI process against the
# file-backed mock — lifecycle, vanished-instance reconciliation, fault
# injection, lock-busy, store isolation, noop persistence, and the
# consumer fixture script. Hermetic.
run_nim r --hints:off tests/e2e/t_crud_store_roundtrip.nim
# GOSTI2 honor-userdata: libvirt BUILDS a NoCloud "cidata" seed from the
# caller's cloud-init user-data and ATTACHES it to the domain XML as a
# read-only CD-ROM. Pure-function gate (seed round-trip + domain-XML render +
# capability signal) — no libvirtd, no VM. Live cloud-init boot is a follow-up.
run_nim r --hints:off tests/unit/t_libvirt_nocloud_seed.nim
run_nim r --hints:off tests/unit/t_libvirt_baseline_off.nim
run_nim r --hints:off tests/unit/t_guest_scripts.nim
run_nim r --hints:off tests/unit/t_cli_probe.nim
run_nim r --hints:off tests/unit/t_cli_boot.nim
run_nim r --hints:off tests/unit/t_cli_incus.nim
# GARM instance-lifecycle gate: `ephemeral-list` makes kept ephemeral
# instances visible and fails CLOSED (an unenumerable backend is an error,
# never an empty list), and incus `ephemeral-destroy` retries a transiently
# busy ZFS delete and exits non-zero while the container still exists.
run_nim r --hints:off tests/unit/t_ephemeral_inventory.nim
run_nim r --hints:off tests/unit/t_ssh_serialization.nim
run_nim r --hints:off tests/unit/t_hyperv_parsers.nim
run_nim r --hints:off tests/unit/t_hyperv_boot_media.nim
run_nim r --hints:off tests/unit/t_hyperv_ephemeral_clone.nim
run_nim r --hints:off tests/unit/t_pool_algorithms.nim
run_nim r --hints:off tests/unit/t_libvirt_snapshot_args.nim
run_nim r --hints:off tests/unit/t_wsl_parsers.nim
run_nim r --hints:off tests/unit/t_utm_parsers.nim
run_nim r --hints:off tests/unit/t_tart_shared_dirs.nim
run_nim r --hints:off tests/unit/t_qemu_windows_arm_backend.nim
run_nim r --hints:off tests/unit/t_qemu_windows_arm_overlay.nim
# Runner-Fleet-M3-ARM-Wave MA3 gate: t_qemu_windows_arm_golden_build, UNIT
# TIER — the install argv, the rebuild-safety guards, the free-space
# precondition, and the install -> sysprep -> power-off -> finalize ->
# manifest orchestration driven end to end against a fake QEMU that binds the
# real forwarded port and serves a real monitor socket. The HOST tier (a real
# Windows install, and two clones with distinct machine SIDs) is
# tests/e2e/t_qemu_windows_arm_golden_build_host.nim, run by
# scripts/run-host-tests.sh; it skips with an explicit message naming every
# precondition it lacks.
run_nim r --hints:off tests/unit/t_qemu_windows_arm_golden_build.nim
# Runner-Fleet-M3-ARM-Wave MA8 gate: t_qemu_windows_arm_dead_guest_is_named,
# UNIT TIER — a per-job boot whose QEMU exits before SSH is reached fails in
# SECONDS naming the exited process and its exit status, instead of being
# polled to the 300s SSH deadline and then blamed on sshd. Shares MA3/MA4's
# fake QEMU (tests/unit/qwa_fake_qemu.nim). The HOST tier restores -no-reboot
# on a real golden -- the known reproducer, measured at 5m38s before this --
# and is tests/e2e/t_qemu_windows_arm_dead_guest_is_named_host.nim, run by
# scripts/run-host-tests.sh.
run_nim r --hints:off tests/unit/t_qemu_windows_arm_dead_guest_is_named.nim
run_nim r --hints:off tests/unit/t_qemu_boot_backend.nim
run_nim r --hints:off tests/unit/t_tpm_device_args.nim
run_nim r --hints:off tests/unit/t_windows_golden_recipe_hardening.nim
run_nim r --hints:off tests/unit/t_tart_backend.nim
# Runner-Fleet-M3-ARM-Wave MA0 gate: t_vmharness_image_is_honoured, assertion
# (c) — a registry-constructed tart backend with no image configured RAISES
# rather than substituting a default. Assertions (a) and (b) are provider-side
# and are run by the nix check of the same name in metacraft-labs/nixos-modules.
run_nim r --hints:off tests/unit/t_vmharness_image_is_honoured.nim
run_nim r --hints:off tests/unit/t_lima_backend.nim
run_nim r --hints:off tests/unit/t_prune.nim
# Runner-Fleet-M3-ARM-Wave MA7 (hygiene half) gate:
# t_m3_tart_orphan_dirs_reclaimed — `tart list` omits a VM with no disk.img,
# so `tart delete` cannot address one and every CLI-driven reaper is blind to
# it; m3 had leaked 600 such directories / 14.6 GiB. This gates the
# filesystem sweep that reclaims them AND, mostly, that each of its four
# guards independently spares a VM that is alive.
run_nim r --hints:off tests/unit/t_m3_tart_orphan_dirs_reclaimed.nim
run_nim r --hints:off tests/unit/t_layer_gc.nim
run_nim r --hints:off tests/unit/t_design_reprobuild_adapter_section.nim
run_nim r --hints:off tests/unit/t_uefi_iso_validator.nim
run_nim r --hints:off tests/unit/t_serve_protocol.nim
# RA6 enrollment/identity + capability manifest: pure crypto vectors, the
# capability deciders against fixtures, and the sign/verify state machine.
run_nim r --hints:off tests/unit/t_serve_enrollment.nim

# Backend-independent lifecycle and CLI coverage.
run_nim r --hints:off tests/integration/t_noop_lifecycle.nim
run_nim r --hints:off tests/e2e/t_vm_harness_smoke.nim
run_nim r --hints:off tests/e2e/t_vm_harness_finally_cleanup_on_panic.nim
run_nim r --hints:off tests/e2e/t_vm_harness_auto_backend_selection.nim
# RA1 remoting: a remote client drives provision->run->destroy against a
# `vm-harness serve` daemon over the authenticated endpoint (noop backend).
run_nim r --hints:off tests/e2e/t_vmharness_serve_roundtrip.nim
# GOSTI2 PR-1 follow-up: the generic-CRUD `--json` envelope and exit code are
# byte-identical over the local CLI (child process, stdout only) and over
# serve's POST /v1/exec (one `log` line + matching `exit`). Hermetic (noop).
run_nim r --hints:off tests/e2e/t_crud_serve_parity.nim
# Concurrency gate: a slow /v1/exec must NOT serialize other connections
# (the central-GARM driver fires many simultaneous calls). Fails against the
# old serial accept loop, passes against the thread-pool loop. Hermetic (the
# worker is a trivial self-exec sleep/quick role — no backend).
run_nim r --hints:off tests/e2e/t_vmharness_serve_concurrency.nim
# A teardown whose client vanishes (GARM SIGKILLs/cancels its provider) must
# still run to completion on the daemon host. Hermetic (self-exec worker).
run_nim r --hints:off tests/e2e/t_vmharness_serve_teardown_survives_disconnect.nim
# Runner-Fleet-M3-ARM-Wave MA12 gate:
# t_vmharness_serve_survives_a_hung_request — the daemon must survive a HUNG
# request, not merely a slow one. Three layers: one hung /v1/exec does not
# stop a concurrent request (the thread pool); a FULLY SATURATED pool answers
# 503 immediately instead of letting connections rot in the listen backlog
# (the production wedge — `Recv-Q 4097` on a LISTEN socket, twice, once for 19
# hours); and the daemon recovers once the hangs drain. Falsifiable in both
# directions: VMH_HUNG_TEST_THREADS=1 makes layer 1 fail (serial-equivalent),
# and the pre-MA12 thread-pool-only daemon passes layer 1 but fails layer 2.
# Hermetic — the worker is a trivial self-exec hang/quick role, no backend.
run_nim r --hints:off tests/e2e/t_vmharness_serve_survives_a_hung_request.nim
# RA6 enrollment gate: a remote client reads the daemon's SIGNED identity +
# capability manifest over /v1/manifest and verifies it against a trust store;
# unenrolled/expired/revoked/tampered identities are rejected. Hermetic (noop).
run_nim r --hints:off tests/e2e/t_vmharness_serve_enrollment.nim

# Backend contracts that do not require a live hypervisor.
run_nim r --hints:off tests/integration/t_libvirt_backend.nim
run_nim r --hints:off tests/integration/t_cli_libvirt_flags.nim
run_nim r --hints:off tests/integration/t_incus_ephemeral_capabilities.nim
run_nim r --hints:off tests/integration/t_durable_media.nim

# Live boot-smoke falsifiability gates. These really boot QEMU, but under
# TCG against a 512-byte synthetic guest that halts in under a second, so
# they need no hypervisor and no prebuilt artifact. They exit early with a
# printed reason on non-Linux hosts; on Linux they never skip.
run_nim r --hints:off tests/integration/t_boot_smoke_harness_fails_on_missing_line.nim
run_nim r --hints:off tests/integration/t_boot_smoke_harness_tears_down_on_failure.nim

# Live vTPM gate. Boots a real Linux guest (stock nixpkgs kernel + busybox
# initramfs, `nix/guest-linux-tpm.nix`) with and without a swtpm-backed TPM
# and asserts what the guest itself reports about /dev/tpm0. Needs
# $VMH_TPM_GUEST_DIR, which the dev shell exports; on Linux it never skips.
run_nim r --hints:off tests/integration/t_guest_sees_tpm_device.nim
