# Releasing gosti

The [tool release specification](https://github.com/metacraft-labs/metacraft-specs/blob/latest/infrastructure/gosti-io-mon-runquota-releases.md)
sets the release scope. `.github/release.json` defines the exact asset matrix;
`.github/workflows/release.yml` calls an immutable shared workflow revision.
Update both `uses` and `tooling-ref` together when changing shared tooling.

## Targets and checks

Linux x86_64, macOS ARM64, and Windows x86_64/ARM64 are built and
executed on matching runners. Linux archives and deb/rpm packages are exercised
in Debian 11, Ubuntu 24.04 and AlmaLinux 9 containers without the Nix store.
Every archive is extracted away from the source tree and checked for native
architecture, runtime dependencies and functional behavior.

The archive includes `gosti`, its `vm-harness` compatibility command, guest scripts and recipes. Windows bundles matching-architecture PCRE. The smoke check uses the existing no-op lifecycle backend; it does not assert hypervisor availability.

Each target emits JSON evidence naming the source commit, pinned dependency
revisions, smoke result, signing state and artifact hashes. The assembly step
checks the exact asset set and hashes after upload and generates `SHA256SUMS`.
The user approved unsigned version 0.1.0 releases on 2026-09-28;
`unsignedReleaseVersion` scopes this exception to that version. Signing evidence
remains false. Later versions must update the policy explicitly or use OS
signatures and a verified Sigstore checksum-manifest signature. The shared Linux
package publisher retains its existing package and repository signatures.

Linux ARM64 is deferred from version 0.1.0 by the release scope decision of
2026-09-29. Add its native artifacts and repository verification in a later
release. Existing Linux ARM64 development tests remain enabled.

## Release sequence

1. Agree the version, update its declared source(s), and land the reviewed
   implementation through `agents` into `dev`. Keep tags and published bytes
   immutable.
2. Run the **Release** workflow with `workflow_dispatch` at the exact candidate
   commit. Wait for the complete matrix, packaging checks and checksum manifest.
   Download the `verified-release` workflow artifact for review. A dispatch
   never publishes, including one dispatched at an existing tag.
3. Check the signing scope. Version 0.1.0 has an explicit unsigned-release
   exception. A version change rejects that exception until the policy is
   updated; it cannot silently waive signing for future releases. Required
   ad-hoc Mach-O execution signatures do not imply Developer ID signing.
4. Create the matching `v<version>` tag at that tested commit, reachable from
   `dev`. The tag workflow checks the successful dispatch at the same SHA,
   repeats the builds and tests, and verifies every draft asset's uploaded bytes
   before publication. A retry refuses any differing existing asset.
5. Track the dispatched `publish-release` run in
   [metacraft-desktop-packages](https://github.com/metacraft-labs/metacraft-desktop-packages/actions/workflows/publish-release.yaml).
   Verify Linux x86_64 in the live apt and RPM indices and install from
   those repositories in clean environments. The producer carries no package
   repository keys or bucket credentials.
6. Download the published archives, verify `SHA256SUMS` (and its Sigstore bundle for signed releases),
   and record the tag SHA, dry-run/tag/publisher URLs and installation evidence.
   Only then fast-forward `stable` to the published tag.

Do not reuse a published version to repair an artifact. Do not treat a queued
ARM runner as an outage; consult the fleet runbook before diagnosis.

The broader org distribution draft also covers Homebrew, installers, additional
package formats and nixpkgs publication. Those channels are outside this staged
release scope and must not be claimed as shipped by this workflow.
