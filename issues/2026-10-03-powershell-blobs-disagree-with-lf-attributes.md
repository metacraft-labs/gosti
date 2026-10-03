# Three PowerShell blobs disagree with their LF attributes

Status: open. Observed at Gosti `581f225` in a fresh macOS worktree.

The committed `.gitattributes` requires LF for `*.ps1`, but these index blobs
still contain CRLF:

- `guest-recipes/windows-x64-base/build-golden-hyperv.ps1` — 400 lines
- `tools/hyperv-pool.ps1` — 431 lines
- `tools/hyperv-scale-set.ps1` — 336 lines

`git ls-files --eol` reports `i/crlf w/crlf attr/text eol=lf`. Working bytes
are identical to HEAD, yet Git's clean filter reports all three as modified.
`git diff --ignore-space-at-eol` is empty. This leaves a fresh checkout dirty.

Normalize those three stored blobs to the declared LF format, retaining every
other byte. Verify the exact CRLF-to-LF transform and PowerShell parsing. Do
not hide the files with index flags or override the shared attributes. Refreshed
`agents` and searched open/deleted CRLF records: the existing shared-catalog
issue explains the LF contract, but does not record these leftover blobs.
