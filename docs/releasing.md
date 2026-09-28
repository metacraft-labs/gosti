# Releasing gosti

The [tool release specification](https://github.com/metacraft-labs/metacraft-specs/blob/latest/infrastructure/gosti-io-mon-runquota-releases.md)
sets the release scope. `.github/release.json` defines the exact asset matrix;
`.github/workflows/release.yml` calls an immutable shared workflow revision.
Update both `uses` and `tooling-ref` together when changing shared tooling.

## Targets and checks

Linux x86_64/aarch64, macOS ARM64, and Windows x86_64/ARM64 are built and
executed on matching runners. Linux archives and deb/rpm packages are exercised
in Debian 11, Ubuntu 24.04 and AlmaLinux 9 containers without the Nix store.
Every archive is extracted away from the source tree and checked for native
architecture, runtime dependencies and functional behavior.

The archive includes `gosti`, its `vm-harness` compatibility command, guest scripts and recipes. Windows bundles matching-architecture PCRE. The smoke check uses the existing no-op lifecycle backend; it does not assert hypervisor availability.

Each target emits JSON evidence naming the source commit, pinned dependency
revisions, smoke result, signing state and artifact hashes. The assembly step
checks the exact asset set and hashes after upload, then signs `SHA256SUMS`
with Sigstore. Verification checks the pinned shared workflow identity and
the producing repository, ref and commit.

## Release sequence

1. Agree the version, update its declared source(s), and land the reviewed
   implementation through `agents` into `dev`. Keep tags and published bytes
   immutable.
2. Run the **Release** workflow with `workflow_dispatch` at the exact candidate
   commit. Wait for the complete matrix, packaging checks and signed manifest.
   Download the `verified-release` workflow artifact for review. A dispatch
   never publishes, including one dispatched at an existing tag.
3. Confirm the OS signing scope. The current workflow refuses publication when
   Developer ID/notarization or Authenticode evidence is missing. An explicit
   exception must be recorded in the release policy before changing this gate.
   Ad-hoc macOS signing is not Developer ID signing.
4. Create the matching `v<version>` tag at that tested commit, reachable from
   `dev`. The tag workflow checks the successful dispatch at the same SHA,
   repeats the builds and tests, and verifies every draft asset's uploaded bytes
   before publication. A retry refuses any differing existing asset.
5. Track the dispatched `publish-release` run in
   [metacraft-desktop-packages](https://github.com/metacraft-labs/metacraft-desktop-packages/actions/workflows/publish-release.yaml).
   Verify both architectures in the live apt and RPM indices and install from
   those repositories in clean environments. The producer carries no package
   repository keys or bucket credentials.
6. Download the published archives, verify `SHA256SUMS` and its Sigstore bundle,
   and record the tag SHA, dry-run/tag/publisher URLs and installation evidence.
   Only then fast-forward `stable` to the published tag.

Do not reuse a published version to repair an artifact. Do not treat a queued
ARM runner as an outage; consult the fleet runbook before diagnosis.

The broader org distribution draft also covers Homebrew, installers, additional
package formats and nixpkgs publication. Those channels are outside this staged
release scope and must not be claimed as shipped by this workflow.
