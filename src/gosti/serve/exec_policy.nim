# SPDX-FileCopyrightText: 2026 Metacraft Labs / Schelling Point Labs
# SPDX-License-Identifier: Apache-2.0
## gosti serve — the ``/v1/exec`` ARGV POLICY.
##
## The bearer token proves WHO is calling (``server.authorized``). This module
## bounds WHAT that caller may run. Without it the token ran any gosti argv on
## the daemon host, which made it root-equivalent there: ``crud create_vm
## --mount /:/host:rw,shift`` gave a guest root over the host's root
## filesystem, and a caller ``--user-data <path>`` (or ``copy_to_vm``) put any
## file the daemon user can read into a guest (reprobuild-pm issue
## ``2026-11-05-gosti-serve-token-and-garm-incus-admin-membership-are-root-on-every-runner-host``,
## SEC-1 G13).
##
## The policy is an ALLOWLIST derived from the argv the daemon's real clients
## send, not a denylist of known-bad flags:
##
##   * ``garm-provider-gosti`` (nixos-modules
##     ``packages/garm-provider-gosti/src/internal/backend/remote.go``):
##     ``provision`` (noop test recipe only), ``run --ephemeral … --keep``,
##     ``ephemeral-destroy``, ``ephemeral-label``, ``ephemeral-list``;
##   * the generic-CRUD façade over serve (``crud <verb>``, architecture §8),
##     minus the verbs and options that name a path on the daemon host.
##
## Anything else — another subcommand, an unlisted option, a host path the
## caller chooses — is REFUSED before a worker is spawned
## (``server.handleExec`` answers ``403``). Every admitted argv must also
## name a concrete ``--backend`` from ``ServeBackends`` (never ``wsl``, whose
## distro shares its Windows host's drives and runs host executables, nor
## ``auto``, which can pick ``wsl``), plain ``--baseline`` / ``--name`` values
## (backends build host paths from them), no ``--`` as an option value (the
## daemon stages ``--user-data`` before the first ``--``) and no NUL byte (the
## worker's C argv would truncate the token that was checked).
##
## The check mirrors the worker's own parser rather than matching strings:
##
##   * ``runCli`` lifts ``--remote`` / ``--auth-token`` / ``--auth-token-file``
##     out of ANY position (even after ``--``) before parsing, so those tokens
##     are refused anywhere in the argv — otherwise a worker could be told to
##     read a host file as a "token file" and send it to a caller-chosen host;
##   * ``parseCliOpts`` takes ``argv[0]`` verbatim as the subcommand (no
##     global options before it, case-sensitive), consumes the token after a
##     value option as that option's value whatever it looks like, treats
##     every other ``-``-prefixed token before ``--`` as a flag (``--x=y`` is
##     an unknown flag, never ``--x y``), and collects positionals and
##     everything after ``--`` into one ``cmd`` list. ``crud``'s verb is that
##     list's first element, so it is checked there, ``--`` or not.
##
## Direct local use of the CLI is the operator's own authority and is NOT
## routed through this module: ``crud create_vm --mount`` stays unrestricted
## on the command line.

import std/[os, strutils]

type
  ExecArgvPolicy* = proc(argv: seq[string]): string {.nimcall, gcsafe.}
    ## Returns "" when ``argv`` may run, else a one-line refusal reason.
    ## ``ServeConfig.execPolicy`` holds one; nil selects ``gostiExecPolicy``.

  FlagKind = enum
    fkSwitch      ## takes no value
    fkValue       ## consumes the next token as its value

  Flag = tuple[name: string, kind: FlagKind]

const
  RemoteClientFlags* = ["--remote", "--auth-token", "--auth-token-file"]
    ## Lifted out of any argv position by ``cli.scanRemoteFlags``.

  FirmwareRoots* = ["/nix/store/", "/usr/share/"]
    ## Where a forwarded ``--uefi-loader`` / ``--uefi-nvram-template`` must
    ## resolve (after symlinks). Both are public, package-managed trees (NixOS's
    ## ``/run/libvirt/nix-ovmf/*`` links into ``/nix/store``; other
    ## distributions ship OVMF under ``/usr/share``), so a firmware path cannot
    ## be pointed at a private host file whose bytes the guest would then read
    ## as its firmware or NVRAM.

  ProvisionFlags: seq[Flag] = @[
    ("--backend", fkValue), ("--baseline", fkValue), ("--log-format", fkValue)]

  RunFlags: seq[Flag] = @[
    ("--ephemeral", fkSwitch), ("--keep", fkSwitch),
    ("--backend", fkValue), ("--baseline", fkValue), ("--guest", fkValue),
    ("--base-image", fkValue), ("--source-image", fkValue),
    ("--incus-profile", fkValue), ("--incus-security-nesting", fkSwitch),
    ("--incus-nested-kvm", fkSwitch), ("--cpus", fkValue),
    ("--memory-mb", fkValue), ("--uefi-loader", fkValue),
    ("--uefi-nvram-template", fkValue), ("--ephemeral-prefix", fkValue),
    ("--timeout-sec", fkValue), ("--log-format", fkValue)]

  EphemeralDestroyFlags: seq[Flag] = @[
    ("--backend", fkValue), ("--baseline", fkValue), ("--log-format", fkValue)]

  EphemeralLabelFlags: seq[Flag] = @[
    ("--backend", fkValue), ("--baseline", fkValue), ("--label", fkValue),
    ("--log-format", fkValue)]

  EphemeralListFlags: seq[Flag] = @[
    ("--backend", fkValue), ("--name", fkValue), ("--label", fkValue),
    ("--log-format", fkValue)]

  CrudFlags: seq[Flag] = @[
    ("--backend", fkValue), ("--baseline", fkValue),
    ("--source-image", fkValue), ("--guest", fkValue), ("--cpus", fkValue),
    ("--memory-mb", fkValue), ("--disk-gb", fkValue), ("--env", fkValue),
    ("--ssh-user", fkValue), ("--cwd", fkValue), ("--run-as", fkValue),
    ("--timeout", fkValue), ("--lock-timeout-sec", fkValue),
    ("--force", fkSwitch), ("--log-format", fkValue)]

  ServeBackends* = ["noop", "mock", "incus", "libvirt", "hyperv",
                    "tart-macos", "tart-linux-arm", "utm-windows-arm",
                    "qemu-windows-arm", "qemu-boot", "lima"]
    ## Every backend id except ``wsl`` (not an isolation boundary from its
    ## Windows host) and ``auto`` (which can resolve to ``wsl``).

  CrudVerbsViaServe* = ["create_vm", "start_vm", "stop_vm", "delete_vm",
                        "get_vm", "list_vms", "exec", "ssh_endpoint",
                        "snapshot", "restore_snapshot", "list_snapshots",
                        "list_images"]
    ## Every crud verb except ``copy_to_vm`` / ``copy_from_vm``, whose
    ## positionals are a path on the DAEMON host (read into, or written from,
    ## the guest).

type
  ParsedArgv = object
    values: seq[tuple[flag, value: string]]   ## every option occurrence
    switches: seq[string]
    positionals: seq[string]                  ## before ``--``
    afterDash: seq[string]                    ## after ``--``
    sawDoubleDash: bool

proc kindOf(flags: seq[Flag], name: string, kind: var FlagKind): bool =
  for f in flags:
    if f.name == name:
      kind = f.kind
      return true
  false

proc parseAgainst(sub: string, argv: seq[string], flags: seq[Flag],
                  parsed: var ParsedArgv): string =
  ## Walk ``argv[1..]`` exactly as ``parseCliOpts`` does, refusing any option
  ## that is not in ``flags``. Returns "" or a refusal reason.
  var i = 1
  while i < argv.len:
    let a = argv[i]
    if parsed.sawDoubleDash:
      parsed.afterDash.add(a)
      inc i
      continue
    if a == "--":
      parsed.sawDoubleDash = true
      inc i
      continue
    if a.startsWith("-"):
      var kind: FlagKind
      if not flags.kindOf(a, kind):
        return "option '" & a & "' is not allowed for '" & sub & "' via serve"
      case kind
      of fkSwitch:
        parsed.switches.add(a)
        inc i
      of fkValue:
        if i + 1 >= argv.len:
          return "option '" & a & "' needs a value"
        # The worker would take a ``--`` here as the VALUE, so it would not
        # end the options. Refuse it: the daemon stages ``--user-data`` before
        # the first ``--`` it finds, which must be the parser's real one.
        if argv[i + 1] == "--":
          return "option '" & a & "' may not take '--' as its value"
        parsed.values.add((a, argv[i + 1]))
        inc i, 2
      continue
    parsed.positionals.add(a)
    inc i
  ""

proc valuesOf(parsed: ParsedArgv, flag: string): seq[string] =
  for (f, v) in parsed.values:
    if f == flag: result.add(v)

proc isSafeName(s: string): bool =
  ## A bare instance-name component: no path separator, no ``..``.
  if s.len == 0 or s.len > 128 or s[0] notin Letters + Digits: return false
  for c in s:
    if c notin Letters + Digits + {'.', '_', '-'}: return false
  ".." notin s

proc firmwarePathReason*(flag, path: string): string =
  ## "" when ``path`` resolves (after symlinks and ``..``) to an existing
  ## regular file under one of ``FirmwareRoots``; else the refusal reason.
  when defined(posix):
    if not path.isAbsolute:
      return flag & " must be an absolute path"
    let real =
      try: expandFilename(path)
      except OSError: ""
    if real.len == 0 or not fileExists(real):
      return flag & " '" & path & "' does not resolve to an existing file"
    for root in FirmwareRoots:
      if real.startsWith(root):
        return ""
    flag & " '" & path & "' resolves to '" & real &
      "', outside the firmware roots " & $FirmwareRoots
  else:
    flag & " is not accepted via serve on this platform"

proc commonReason(parsed: ParsedArgv): string =
  ## Checks every admitted subcommand shares (run after ``parseAgainst``).
  ##
  ## * ``--backend`` must name a concrete backend, and not ``wsl``: a WSL
  ##   distro is not an isolation boundary from its Windows host (the host's
  ##   drives are mounted under ``/mnt`` and Windows executables run from
  ##   inside it), so a "guest" there is the daemon user on the host. ``auto``
  ##   (or no ``--backend``) is refused because it resolves to ``wsl`` for a
  ##   Linux guest on a Windows host.
  ## * ``--baseline`` / ``--name`` are instance names, and several backends
  ##   build daemon-host paths from them (libvirt's
  ##   ``<pool>/<name>.overlay.qcow2``, noop's ``baselines/<name>``), so they
  ##   must be plain names: no separator, no ``..``.
  let backends = parsed.valuesOf("--backend")
  if backends.len == 0:
    return "--backend is required via serve (auto is not accepted)"
  for b in backends:
    if b notin ServeBackends:
      return "--backend '" & b & "' is not allowed via serve (allowed: " &
        ServeBackends.join(", ") & ")"
  for flag in ["--baseline", "--name"]:
    for v in parsed.valuesOf(flag):
      if not v.isSafeName:
        return flag & " '" & v & "' is not a plain name"
  ""

proc subcommandReason(argv: seq[string], parsed: var ParsedArgv): string =
  ## The per-subcommand half of ``gostiExecPolicy``: the option allowlist and
  ## each subcommand's own constraints. "" only for an admitted subcommand.
  let sub = argv[0]
  case sub
  of "provision":
    let r = parseAgainst(sub, argv, ProvisionFlags, parsed)
    if r.len > 0: return r
    if parsed.positionals.len > 0 or parsed.sawDoubleDash:
      return "'provision' takes no positional arguments via serve"
    let backends = parsed.valuesOf("--backend")
    if backends.len == 0:
      return "'provision' via serve requires --backend noop"
    for b in backends:
      if b != "noop":
        return "'provision' via serve is limited to --backend noop " &
          "(the provider's test recipe)"
  of "run":
    let r = parseAgainst(sub, argv, RunFlags, parsed)
    if r.len > 0: return r
    if "--ephemeral" notin parsed.switches:
      return "'run' via serve requires --ephemeral (a non-ephemeral run " &
        "writes to a caller-chosen --output-dir on the daemon host)"
    if parsed.positionals.len > 0:
      return "'run' via serve takes the guest command only after '--'"
    for p in parsed.valuesOf("--ephemeral-prefix"):
      if not p.isSafeName:
        return "--ephemeral-prefix '" & p & "' is not a plain name"
    for flag in ["--uefi-loader", "--uefi-nvram-template"]:
      for p in parsed.valuesOf(flag):
        let reason = firmwarePathReason(flag, p)
        if reason.len > 0: return reason
  of "ephemeral-destroy":
    let r = parseAgainst(sub, argv, EphemeralDestroyFlags, parsed)
    if r.len > 0: return r
    if parsed.positionals.len > 0 or parsed.sawDoubleDash:
      return "'ephemeral-destroy' takes no positional arguments via serve"
  of "ephemeral-label":
    let r = parseAgainst(sub, argv, EphemeralLabelFlags, parsed)
    if r.len > 0: return r
    if parsed.positionals.len > 0 or parsed.sawDoubleDash:
      return "'ephemeral-label' takes no positional arguments via serve"
  of "ephemeral-list":
    let r = parseAgainst(sub, argv, EphemeralListFlags, parsed)
    if r.len > 0: return r
    if parsed.positionals.len > 0 or parsed.sawDoubleDash:
      return "'ephemeral-list' takes no positional arguments via serve"
  of "crud":
    let r = parseAgainst(sub, argv, CrudFlags, parsed)
    if r.len > 0: return r
    # parseCliOpts folds positionals and the post-``--`` tail into one list
    # and cmdCrud takes its first element as the verb, so ``crud -- <verb>``
    # names a verb too.
    let cmd = parsed.positionals & parsed.afterDash
    if cmd.len == 0:
      return "'crud' via serve requires a verb"
    if cmd[0] notin CrudVerbsViaServe:
      return "crud verb '" & cmd[0] & "' is not allowed via serve " &
        "(allowed: " & CrudVerbsViaServe.join(", ") & ")"
  else:
    return "subcommand '" & sub & "' is not allowed via serve (allowed: " &
      "provision, run --ephemeral, ephemeral-destroy, ephemeral-label, " &
      "ephemeral-list, crud)"
  ""

proc gostiExecPolicy*(argv: seq[string]): string {.gcsafe.} =
  ## The production ``/v1/exec`` policy. See the module header.
  if argv.len == 0:
    return "empty argv"
  for a in argv:
    if a in RemoteClientFlags:
      return "'" & a & "' is a client-only option and is refused via serve"
    # The worker gets its argv as C strings, so a NUL would silently cut the
    # token the policy checked into a different, shorter one.
    if '\0' in a:
      return "an argv element contains a NUL byte"
  var parsed: ParsedArgv
  let r = subcommandReason(argv, parsed)
  if r.len > 0: return r
  commonReason(parsed)
