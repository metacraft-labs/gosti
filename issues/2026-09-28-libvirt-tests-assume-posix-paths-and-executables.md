# Libvirt integration fixtures assume POSIX paths and executables on Windows

- Status: open
- Observed: Gosti `d68e662`, Windows x64 Reprobuild job `109021357416`

The repaired Reprobuild bootstrap builds Gosti and compiles all portable test
programs. Two execution actions fail:

- `t_libvirt_backend` hardcodes `/storage/...` while `domainDiskPath` returns
  the host's path separators. Its xorriso fixture is a Bash script without an
  `.exe` extension, and its PATH uses `:`. Windows cannot find that fixture,
  so the BIOS-only ISO refusal case takes the documented missing-tool path.
- `t_cli_libvirt_flags` expects a raw known-hosts path in the SSH config
  argument, although the Windows path needs the backend's existing quoting.

Expected: the five-class portable catalog declared in [AGENTS.md](../AGENTS.md)
must exercise these boundaries on Windows. [Libvirt operator contract](../docs/m4-libvirt.md)
requires the configured image pool and rejection of BIOS-only Windows ISOs
when xorriso is present. [CLI SSH flags](../docs/user-guide/cli-reference.md)
preserve the selected known-hosts file. No production defect is established
by these fixture failures.

Repair the host-path expectations and use a native executable fixture that
returns the captured xorriso reports through a real process. Keep the actual
BIOS-only refusal, successful UEFI report, missing-tool behavior and SSH path
assertions. Explain the xorriso stand-in in the test header. Validate the SSH
argument with OpenSSH's config parser where available.

Fetched `dev` (`850e9de`) and current `agents` (`9d59f2e`); searched current
issues and issue history for libvirt, Windows paths and xorriso before filing.
