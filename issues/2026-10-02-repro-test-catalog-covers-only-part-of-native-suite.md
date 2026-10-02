# Reprobuild test catalog covers only part of the native suite

## Observed in

Gosti `5c31e6f352844647acfbc1a70314e6d0b7cb7c4c`, macOS ARM64,
2026-10-02. The complete native `just test` runs 66 programs and reports
764 passing assertions. `REPRO_DAEMON=off repro build .#test` completes
66 actions, comprising 33 builds and 33 executions, with 449 passing
assertions. Reprobuild is the local build at `c14b1e618d7c4b64476d89792e80b8e8f10b8a52`.

The manually maintained `portableTestSpecs` and `posixTestSpecs` in
`repro.nim` omit 34 native program paths; one Reprobuild program is absent
from the native list. This predates the v0.1.1 version changes. Both lanes
must be reported separately; 66 successful actions are not 66 executed tests.

## Expected

The header of `repro.nim` says its test collection builds and executes the
deterministic, host-independent suite, with live hypervisor tests kept in
an explicit host catalog. The omissions include deterministic CRUD, protocol
and lifecycle cases. Reconcile the two catalogs, preserving platform and
live-host boundaries, and make catalog drift fail a check. Until then,
release qualification must retain both the full native suite and the existing
Reprobuild graph; the latter alone does not establish full native coverage.

## Reproduction and evidence

Run both commands above on the named revision. Compare each
`==> nim r ... tests/...` entry in `scripts/run-tests.sh` output with
`vm_harness.test_execute.*` in the Reprobuild JSON report. The observed
omissions are:

```text
tests/unit/t_nimcache_is_worktree_local.nim
tests/unit/t_crud_facade.nim
tests/unit/t_crud_facade_mock.nim
tests/unit/t_crud_surface_growth.nim
tests/unit/t_crud_store.nim
tests/e2e/t_crud_store_roundtrip.nim
tests/unit/t_libvirt_nocloud_seed.nim
tests/unit/t_libvirt_baseline_off.nim
tests/unit/t_ephemeral_inventory.nim
tests/unit/t_hyperv_ephemeral_clone.nim
tests/unit/t_pool_algorithms.nim
tests/unit/t_libvirt_snapshot_args.nim
tests/unit/t_qemu_windows_arm_overlay.nim
tests/unit/t_qemu_boot_backend.nim
tests/unit/t_tpm_device_args.nim
tests/unit/t_windows_golden_recipe_hardening.nim
tests/unit/t_linux_runner_recipe_pin.nim
tests/unit/t_lima_backend.nim
tests/unit/t_prune.nim
tests/unit/t_layer_gc.nim
tests/unit/t_design_reprobuild_adapter_section.nim
tests/unit/t_uefi_iso_validator.nim
tests/unit/t_serve_enrollment.nim
tests/e2e/t_vmharness_serve_roundtrip.nim
tests/e2e/t_gosti_command_names.nim
tests/e2e/t_crud_serve_parity.nim
tests/e2e/t_vmharness_serve_concurrency.nim
tests/e2e/t_vmharness_serve_teardown_survives_disconnect.nim
tests/e2e/t_vmharness_serve_client_disconnect_no_spin.nim
tests/e2e/t_vmharness_serve_survives_a_hung_request.nim
tests/e2e/t_vmharness_serve_enrollment.nim
tests/integration/t_boot_smoke_harness_fails_on_missing_line.nim
tests/integration/t_boot_smoke_harness_tears_down_on_failure.nim
tests/integration/t_guest_sees_tpm_device.nim
```

Local evidence: `/tmp/gosti-011-local-gates-fixed.log` and
`/tmp/gosti-011-repro.json`. Some host-specific cases in the native list have
existing platform skips; catalog presence does not establish host coverage.

## Archive search

Fetched `origin/agents` and confirmed it still names `5c31e6f`. Searched
open issues, historical issue paths and the `catalog` pickaxe. The archived
Incus registration and disk-tool records concern individual fixtures; they
do not record this broader catalog mismatch.
