# Sentinel deadline test assumes the first probe finishes within one second

Status: open. Observed at Gosti `6a2ed63` plus the test-tool declarations,
local full Reprobuild graph (`/tmp/gosti-complete-runtime-tools.json`).
The golden-build fixture fails only `probes.len >= 2`: an instrumented shell
probe can consume its entire one-second budget. `waitForInstallSentinel`
correctly returns after that unsuccessful probe when its deadline has passed.

The golden-build contract requires bounded waiting and repeated polling while
budget remains. Check those separately: retain the one-second deadline with
an oversized poll interval and all elapsed-time bounds; require at least one
probe there. Add a controlled two-probe fixture that reports readiness only on
the second call, keeping a bounded deadline and proving both calls happened.
This preserves both behaviors without requiring a process-startup speed.

Refreshed dev `850e9de` and searched open/deleted issue history; no matching
record exists. The fake SSH transport is already justified in the fixture's
header; disk-image operations continue using real qemu-img.
