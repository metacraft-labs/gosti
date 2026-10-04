# Committed hook configuration lacks its required license header

| | |
| --- | --- |
| Status | open |
| Recorded | 2026-10-04 |
| Observed in | Gosti `246fdfdc832c49e7b7f243dc0a541c7428563399` |
| Area | `.pre-commit-config.yaml` |

## Observed

The newly committed hook configuration has no SPDX copyright or license
header. `just lint` reports it as the sole file missing both and fails the
existing `reuse lint` gate. The observed run was at `d977668` with only
uncommitted release-guide edits and removal of that guide's resolved issue;
the hook configuration was byte-identical to `246fdfdc`.

## Expected

The README's **License** section requires every source file to carry an SPDX
header. `REUSE.toml` reserves annotations for files that cannot carry one.
YAML supports comments, as the other repository configuration files show.
The normal lint target must pass without excluding the new file.

## Evidence

The unchanged lint command reports:

```text
The following files have no copyright and licensing information:
* .pre-commit-config.yaml
```

## Search

Refreshed `agents` and the current promotion branch at `d977668`; searched
open issues and issue history for `.pre-commit-config.yaml`, SPDX and license
headers. No existing issue records this new configuration file.
