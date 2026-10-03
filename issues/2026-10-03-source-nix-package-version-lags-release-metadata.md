# Source Nix package version lags the release metadata

Status: open.

At Gosti `379b0de52a3dab3ba0c8d4b94b71e1216cb75dc8`, `vm_harness.nimble`
and `QwaVmHarnessVersion` declare 0.1.1, while the source-built flake derivation
still declares 0.1.0. This is separate from the correctly versioned Nix channel
that installs immutable release payloads.

Not specified: the release plan does not explicitly prescribe how the source
flake obtains its version. Proposed, within the authorized new release:
derive it from the existing canonical Nimble version file, so Nix derivation
metadata and release metadata stay aligned when that version changes. Preserve
the full build, installed files and all package checks.

Fetched current agents at `379b0de5` and searched open and deleted issues for
Nix package version drift. No existing record covers this source derivation.
The owning release plan is
[tool releases](https://github.com/metacraft-labs/metacraft-pm/blob/latest/infrastructure/gosti-io-mon-runquota-releases.md).
