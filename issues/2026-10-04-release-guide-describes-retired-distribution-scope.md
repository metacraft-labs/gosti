# Release guide describes the retired distribution scope

| | |
| --- | --- |
| Status | open |
| Recorded | 2026-10-04 |
| Observed in | Gosti `246fdfdc832c49e7b7f243dc0a541c7428563399` |
| Area | `docs/releasing.md` |

## Observed

The guide scopes unsigned payloads to 0.1.0 and calls Homebrew and nixpkgs
publication future work outside the staged release. The actual inventory
prepares 0.1.2, and the shared publisher already supports Homebrew, Scoop and
the maintained Nix channels. The source's publication steps omit their required
live installation checks.

## Expected

The [tool release specification](https://github.com/metacraft-labs/metacraft-pm/blob/latest/infrastructure/gosti-io-mon-runquota-releases.md)
requires the current version-scoped signing exception, immutable exact-source
rehearsals and publication to the declared channels before stable promotion.
The guide must agree with `.github/release.json` and those requirements, while
retaining the separate proposed status of the shared installer service.

## Evidence

At the observed commit, `docs/releasing.md` names 0.1.0 in its signing steps;
`.github/release.json` sets `unsignedReleaseVersion` to `0.1.2`. The guide's
final paragraph excludes the channels documented as implemented in the shared
release specification. The 0.1.2 rehearsal at `d79caaf4` passes; it is not yet
a published release.

## Search

Refreshed Gosti `agents` at `246fdfdc` and the shared specification at
`3ca5293`. Searched open and historical Gosti issues for `docs/releasing.md`,
release guides and signing scope. The shared distribution-conformance issue
already records the cross-product gap; this file records the owning guide fix.
