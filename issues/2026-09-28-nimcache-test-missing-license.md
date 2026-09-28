# The nimcache regression test lacks its required license header

Found while preparing releases at `5661fc1` on 2026-09-28.

`just lint` fails REUSE validation because
`tests/unit/t_nimcache_is_worktree_local.nim` has no SPDX header.
`REUSE.toml` deliberately requires source files to carry their own headers;
the repository's Apache-2.0 licensing policy therefore applies to this test.

Add the same copyright and license header as the surrounding unit tests,
then run `just lint`. Open and deleted issue history had no earlier record.
