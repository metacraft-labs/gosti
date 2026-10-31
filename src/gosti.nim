# SPDX-FileCopyrightText: 2026 Metacraft Labs / Schelling Point Labs
# SPDX-License-Identifier: Apache-2.0
## gosti — cross-platform VM lifecycle orchestration for test
## harnesses and dev workflows.
##
## Public surface re-exported from this top-level module:
##
## - Types: ``VmBackend``, ``VmHandle``, ``BaselineSpec``, ``ExecResult``,
##   ``ArgvTraceShim``, the exception hierarchy.
## - Auto-selection: ``autoSelectBackendId``, ``newBackend``,
##   ``newBackendForGuest``, ``registerBackend``.
## - Output envelope: ``OutputEnvelope``, ``Verdict``, ``StepStatus``.
## - Orchestrator: ``GateSpec``, ``GateResult``, ``runGate``.
## - Guest scripts (embedded): ``PosixRunner``, ``WindowsRunner``,
##   ``writeGuestRunner``, ``renderShimScript``.
## - Boot smoke: ``BootSmokeSpec``, ``BootSmokeStep``, ``runBootSmoke``,
##   ``writeSyntheticBootDisk``.
## - NoopBackend (test fixture): re-exported from ``backends/noop``.
## - MockBackend (deterministic in-memory fixture): re-exported from
##   ``backends/mock`` (GOSTI2 PR-2).
##
## See ``docs/contributors/architecture.md`` for the canonical design reference and the
## per-backend implementation notes.

import ./gosti/types
import ./gosti/pool
import ./gosti/output
import ./gosti/auto
import ./gosti/crud
import ./gosti/orchestrator
import ./gosti/guest_scripts
import ./gosti/serial
import ./gosti/firmware
import ./gosti/cloud_init_seed
import ./gosti/disk_growth
import ./gosti/backends/noop
import ./gosti/backends/mock
import ./gosti/backends/process_helpers
import ./gosti/backends/hyperv
import ./gosti/backends/wsl
import ./gosti/backends/tart
import ./gosti/backends/utm
import ./gosti/backends/qemu_windows_arm
import ./gosti/backends/qemu_boot
import ./gosti/boot_smoke
import ./gosti/backends/lima
import ./gosti/backends/libvirt
import ./gosti/backends/incus
import ./gosti/serve/protocol
import ./gosti/serve/http
import ./gosti/serve/server
import ./gosti/serve/client
import ./gosti/serve/hmac
import ./gosti/serve/capability
import ./gosti/serve/enrollment

export types
export pool
export output
export auto
export crud
export orchestrator
export guest_scripts
export serial
export disk_growth
export firmware
export cloud_init_seed
export noop
export mock
export process_helpers
export hyperv
export wsl
export tart
export utm
export qemu_windows_arm
export qemu_boot
export boot_smoke
export lima
export libvirt except cleanupAcquiredDomain
export incus
export protocol
export http
export server
export client
export hmac
export capability
export enrollment
