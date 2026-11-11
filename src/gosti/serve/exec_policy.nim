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
## Options whose value names a HOST RESOURCE are then checked against what the
## operator allows (``ExecPolicyConfig``, from ``gosti serve
## --allow-image-root`` / ``--allow-incus-profile``):
##
##   * ``--uefi-loader`` / ``--uefi-nvram-template`` resolve under
##     ``FirmwareRoots``;
##   * ``--source-image`` / ``--base-image`` are read the way each named
##     backend reads them (``imageKindFor``): a host disk-image file or
##     golden directory must resolve, through every symlink and with no
##     ``..``, to a regular file (directory) of the backend's disk format,
##     under the configured image roots; a name the hypervisor resolves in
##     its own store (Incus, Tart, UTM) may not be a path or an option;
##   * ``--incus-profile`` must be on the profile allowlist
##     (``DefaultIncusProfiles`` unless configured).
##
## All host paths go through one check, ``hostPathReason``.
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
when defined(posix):
  import std/posix

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

proc hasDotDot(path: string): bool =
  for part in path.split({'/', '\\'}):
    if part == "..": return true
  false

proc trimRoot(root: string): string =
  ## A root without its trailing separators (``/`` stays ``/``).
  result = root
  while result.len > 1 and result[^1] in {'/', '\\'} and
      not (result.len == 3 and result[1] == ':'):   # keep ``C:\``
    result.setLen(result.len - 1)

proc resolvedRoot(root: string): string =
  ## A root as the policy compares against it: its own real path when it
  ## exists (so a root that is itself a symlink still admits what it points
  ## to), else the root as written.
  try: trimRoot(expandFilename(root))
  except OSError: trimRoot(root)

proc isUnder(real, root: string): bool =
  ## Whole-component containment: ``/srv/img`` holds ``/srv/img/a.qcow2`` but
  ## not ``/srv/img-other/a.qcow2``.
  when defined(windows):
    let (a, r) = (real.toLowerAscii, root.toLowerAscii)
  else:
    let (a, r) = (real, root)
  if r.len > 0 and r[^1] in {'/', '\\'}: return a.startsWith(r)
  a == r or a.startsWith(r & DirSep)

proc rootsReason(flag, path, real: string, roots: openArray[string],
                 label: string): string =
  ## "" when ``real`` lies under one of ``roots``; else the refusal reason.
  var shown: seq[string]
  for root in roots:
    let r = resolvedRoot(root)
    shown.add(r)
    if real.isUnder(r): return ""
  flag & " '" & path & "' resolves to '" & real & "', outside the " & label &
    " roots " & $shown

type
  DiskFormat* = enum
    ## The disk-image containers a serve-admitted image file may be. Sniffed
    ## from the file's own bytes, never from its name.
    dfQcow2 = "qcow2"        ## ``QFI\xfb`` at offset 0
    dfVhdx = "vhdx"          ## ``vhdxfile`` at offset 0
    dfVhd = "vhd"            ## ``conectix`` footer (last 512 bytes) or header
    dfIso9660 = "iso9660"    ## ``CD001`` at offset 0x8001

proc sniffDiskFormat*(path: string): set[DiskFormat] =
  ## The container format(s) ``path``'s bytes carry; {} when none (or the
  ## file cannot be read). Only ever called on a path already known to be a
  ## REGULAR file, so the open cannot block on a FIFO or touch a device.
  var f: File
  if not open(f, path, fmRead): return
  defer: f.close()
  var head: array[512, char]
  let n = f.readBuffer(head[0].addr, head.len)
  proc at(buf: openArray[char], off: int, magic: string, len: int): bool =
    if off + magic.len > len: return false
    for i, c in magic:
      if buf[off + i] != c: return false
    true
  if head.at(0, "QFI\xfb", n): result.incl dfQcow2
  if head.at(0, "vhdxfile", n): result.incl dfVhdx
  if head.at(0, "conectix", n): result.incl dfVhd
  let size = f.getFileSize()
  if size >= 512:
    var foot: array[512, char]
    f.setFilePos(size - 512)
    if f.readBuffer(foot[0].addr, foot.len) == foot.len and
        foot.at(0, "conectix", foot.len):
      result.incl dfVhd
  if size >= 0x8001 + 5:
    var cd: array[5, char]
    f.setFilePos(0x8001)
    if f.readBuffer(cd[0].addr, cd.len) == cd.len and
        cd.at(0, "CD001", cd.len):
      result.incl dfIso9660

# ---------------------------------------------------------------------------
# References an image carries to OTHER host files. The magic bytes say what a
# file is; they do not say what else opening it reads. A qcow2 may name a
# backing file (any host path, in any format: ``backing_fmt=raw`` makes the
# guest read it verbatim) or an external data file, and a VHD/VHDX may be a
# differencing disk naming a parent. Each would put a file the policy never
# looked at under the guest's disk, so they are checked too.
# ---------------------------------------------------------------------------

const
  MaxBackingDepth* = 16
    ## Longest qcow2 backing chain admitted (each link is checked).
  Qcow2ExtEnd = 0'u32
  Qcow2ExtBackingFormat = 0xE2792ACA'u32
  Qcow2ExtDataFile = 0x44415441'u32
  Qcow2IncompatDataFile = 4'u64        ## incompatible_features bit 2
  VhdxMetadataRegion = "\x06\xA2\x7C\x8B\x90\x47\x9A\x4B\xB8\xFE\x57\x5F\x05\x0F\x88\x6E"
    ## GUID 8B7CA206-4790-4B9A-B8FE-575F050F886E, on-disk byte order.
  VhdxParentLocator = "\x2D\x5F\xD3\xA8\x0B\xB3\x4D\x45\xAB\xF7\xD3\xD8\x48\x34\xAB\x0C"
    ## GUID A8D35F2D-B30B-454D-ABF7-D3D84834AB0C: only a differencing VHDX
    ## carries this metadata item.
  VhdDiskTypeDifferencing = 4'u32

type
  Qcow2Refs* = object
    ## What a qcow2 header says opening the file also opens.
    malformed*: string        ## non-empty ⇒ the header cannot be trusted
    backing*: string          ## backing file name as stored ("" ⇒ none)
    backingFmt*: string       ## backing format extension ("" ⇒ absent)
    dataFile*: bool           ## an external data file is in use

proc be32(s: string, off: int): uint32 =
  for i in 0 ..< 4: result = (result shl 8) or uint32(s[off + i].uint8)

proc be64(s: string, off: int): uint64 =
  for i in 0 ..< 8: result = (result shl 8) or uint64(s[off + i].uint8)

proc le16(s: string, off: int): uint64 =
  for i in countdown(1, 0): result = (result shl 8) or uint64(s[off + i].uint8)

proc le32(s: string, off: int): uint64 =
  for i in countdown(3, 0): result = (result shl 8) or uint64(s[off + i].uint8)

proc le64(s: string, off: int): uint64 =
  for i in countdown(7, 0): result = (result shl 8) or uint64(s[off + i].uint8)

proc readAt(f: File, off: int64, n: int): string =
  ## Up to ``n`` bytes at ``off`` (fewer at end of file).
  result = newString(n)
  f.setFilePos(off)
  let got = if n > 0: f.readBuffer(result[0].addr, n) else: 0
  result.setLen(got)

proc qcow2Refs*(path: string): Qcow2Refs =
  ## Parse the qcow2 header the way QEMU does, far enough to find every other
  ## file it would open: ``backing_file_offset``/``_size`` (QEMU caps the name
  ## at 1023 bytes inside the first cluster), the backing-format and
  ## data-file header extensions, and ``incompatible_features`` bit 2.
  var f: File
  if not open(f, path, fmRead):
    return Qcow2Refs(malformed: "cannot be read")
  defer: f.close()
  let hdr = f.readAt(0, 104)
  if hdr.len < 72 or hdr[0 ..< 4] != "QFI\xfb":
    return Qcow2Refs(malformed: "has a truncated qcow2 header")
  let version = be32(hdr, 4)
  if version notin [2'u32, 3'u32]:
    return Qcow2Refs(malformed: "is qcow2 version " & $version)
  let clusterBits = be32(hdr, 20)
  if clusterBits < 9 or clusterBits > 21:
    return Qcow2Refs(malformed: "has an invalid qcow2 cluster size")
  let cluster = f.readAt(0, 1 shl clusterBits)
  var extStart = 72
  if version == 3:
    if hdr.len < 104:
      return Qcow2Refs(malformed: "has a truncated qcow2 v3 header")
    if (be64(hdr, 72) and Qcow2IncompatDataFile) != 0:
      result.dataFile = true
    let hl = be32(hdr, 100)
    if hl < 104 or hl.int > cluster.len:
      return Qcow2Refs(malformed: "has an invalid qcow2 header length")
    extStart = hl.int
  var pos = extStart
  while pos + 8 <= cluster.len:
    let t = be32(cluster, pos)
    let l = be32(cluster, pos + 4).int
    if t == Qcow2ExtEnd: break
    if l > cluster.len - pos - 8:
      return Qcow2Refs(malformed: "has a qcow2 header extension past its " &
        "first cluster")
    case t
    of Qcow2ExtBackingFormat: result.backingFmt = cluster[pos + 8 ..< pos + 8 + l]
    of Qcow2ExtDataFile: result.dataFile = true
    else: discard
    pos += 8 + ((l + 7) and not 7)
  let bOff = be64(hdr, 8)
  let bLen = be32(hdr, 16).int
  if bOff != 0 and bLen > 0:
    if bLen > 1023 or bOff > uint64(cluster.len) or
        bOff.int + bLen > cluster.len:
      return Qcow2Refs(malformed: "has an invalid qcow2 backing file name")
    result.backing = cluster[bOff.int ..< bOff.int + bLen]

proc vhdIsDifferencing(path: string): bool =
  ## A VHD whose footer (or its header copy) says disk type 4.
  var f: File
  if not open(f, path, fmRead): return false
  defer: f.close()
  let size = f.getFileSize()
  for off in [size - 512, 0'i64]:
    if off < 0: continue
    let foot = f.readAt(off, 512)
    if foot.len == 512 and foot[0 ..< 8] == "conectix" and
        be32(foot, 60) == VhdDiskTypeDifferencing:
      return true
  false

proc vhdxParentReason(path: string): string =
  ## "" for a VHDX with no parent locator; else why it is refused. Reads the
  ## region table (64 KiB-aligned at 192 KiB, backup at 256 KiB) for the
  ## metadata region, then that region's table for a parent-locator item. A
  ## VHDX whose tables cannot be read is refused: Hyper-V would not open it.
  var f: File
  if not open(f, path, fmRead): return "cannot be read"
  defer: f.close()
  let size = f.getFileSize()
  for rtOff in [0x30000'i64, 0x40000'i64]:
    let rt = f.readAt(rtOff, 0x10000)
    if rt.len < 16 or rt[0 ..< 4] != "regi": continue
    let count = le32(rt, 8).int
    if count > 2047: continue
    for i in 0 ..< count:
      let e = 16 + 32 * i
      if e + 32 > rt.len: break
      if rt[e ..< e + 16] != VhdxMetadataRegion: continue
      let mOff = le64(rt, e + 16)
      if mOff.int64 < 0 or mOff.int64 + 32 > size: return "has an invalid VHDX metadata region"
      let mt = f.readAt(mOff.int64, 0x10000)
      if mt.len < 32 or mt[0 ..< 8] != "metadata":
        return "has an invalid VHDX metadata table"
      let items = le16(mt, 10).int
      for j in 0 ..< items:
        let it = 32 + 32 * j
        if it + 32 > mt.len: return "has an invalid VHDX metadata table"
        if mt[it ..< it + 16] == VhdxParentLocator:
          return "is a differencing VHDX (it names a parent disk)"
      return ""
    return "has no VHDX metadata region"
  "has no readable VHDX region table"

type
  HostPathWant = object
    ## What a host-path option must resolve to.
    dir: bool                  ## a directory (else a regular file)
    formats: set[DiskFormat]   ## for a file: {} ⇒ any regular file

proc throughProc(path: string): bool =
  ## Whether resolving ``path`` would pass through ``/proc`` (directly or via
  ## any symlink on the way). ``/proc/<pid>/root``, ``/proc/<pid>/cwd`` and
  ## ``/proc/self/fd/<n>`` (``/dev/fd`` links there) are MAGIC links:
  ## ``realpath`` reports a string that names a different file in the
  ## daemon's mount namespace than the one the worker later opens (a
  ## container's rootfs, another process's fd), so the policy would judge
  ## one file and the backend read another. Walks the components itself,
  ## with ``lstat``/``readlink``, so the check sees every hop.
  when defined(posix):
    var pending = path.split('/')
    var cur = ""
    var hops = 0
    while pending.len > 0:
      let c = pending[0]
      pending.delete(0)
      if c.len == 0 or c == ".": continue
      if c == "..":
        let i = cur.rfind('/')
        cur = if i <= 0: "" else: cur[0 ..< i]
        continue
      let next = cur & "/" & c
      if next == "/proc" or next.startsWith("/proc/"): return true
      var st: Stat
      if lstat(next.cstring, st) != 0:
        return false        # does not exist: the resolve step refuses it
      if S_ISLNK(st.st_mode):
        inc hops
        if hops > 40: return true
        let target = try: expandSymlink(next) except OSError: return true
        if target.startsWith("/"): cur = ""
        pending = target.split('/') & pending
      else:
        cur = next
    false
  else:
    false

proc hostPathReason(flag, path: string, roots: openArray[string],
                    rootsLabel: string, want: HostPathWant,
                    real: var string, depth = 0): string =
  ## THE one check for every option that names a path on the daemon host
  ## (UEFI firmware, golden images). "" when ``path``:
  ##
  ##   * is absolute and has no ``..`` component (refused rather than
  ##     normalised, so the policy and the backend can never disagree about
  ##     which file it names);
  ##   * resolves, after every symlink, to an existing REGULAR file (or, for
  ##     ``want.dir``, a directory) — never a device, FIFO or socket;
  ##   * lies under one of ``roots`` (whole path components), unless
  ##     ``roots`` is empty;
  ##   * for a file with ``want.formats``, carries one of those disk-image
  ##     formats in its own bytes;
  ##   * names no other file a hypervisor would open with it (``refsReason``:
  ##     a qcow2 backing chain is followed, each link through this same
  ##     check; external data files and differencing VHD/VHDX are refused);
  ##   * does not pass through ``/proc`` (``throughProc``).
  ##
  ## ``depth`` > 0 is a qcow2 backing link: its name was written by whoever
  ## built the image and QEMU resolves it with the kernel, ``..`` included,
  ## so ``..`` is resolved (by ``realpath``, as the kernel does) rather than
  ## refused.
  ##
  ## ``real`` receives the resolved path. Otherwise the refusal reason.
  real = ""
  if path.len == 0 or not path.isAbsolute:
    return flag & " must be an absolute path"
  if depth == 0 and path.hasDotDot:
    return flag & " '" & path & "' has a '..' component"
  if path.throughProc:
    return flag & " '" & path & "' resolves through /proc"
  let what = if want.dir: "directory" else: "file"
  when defined(windows):
    # GetFullPathName does not follow links, so refuse any reparse point on
    # the way instead of resolving it; and no ``\\?\`` / ``\\.\`` device or
    # UNC names.
    if path.startsWith("\\\\") or path.startsWith("//"):
      return flag & " '" & path & "' is a device or network path"
    let full =
      try: expandFilename(path)
      except OSError: ""
    if full.len == 0:
      return flag & " '" & path & "' does not resolve to an existing " & what
    var prefix = ""
    for part in full.split({'\\', '/'}):
      prefix = if prefix.len == 0: part & "\\" else: prefix / part
      if part.len > 0 and symlinkExists(prefix):
        return flag & " '" & path & "' passes through a link ('" & prefix &
          "')"
    if want.dir:
      if not dirExists(full):
        return flag & " '" & path & "' does not resolve to an existing " & what
    else:
      if dirExists(full):
        return flag & " '" & path & "' resolves to '" & full &
          "', which is not a regular file"
      if not fileExists(full):
        return flag & " '" & path & "' does not resolve to an existing " & what
    real = full
  else:
    let resolved =
      try: expandFilename(path)
      except OSError: ""
    var st: Stat
    if resolved.len == 0 or stat(resolved.cstring, st) != 0:
      return flag & " '" & path & "' does not resolve to an existing " & what
    if want.dir:
      if not S_ISDIR(st.st_mode):
        return flag & " '" & path & "' resolves to '" & resolved &
          "', which is not a directory"
    elif not S_ISREG(st.st_mode):
      return flag & " '" & path & "' resolves to '" & resolved &
        "', which is not a regular file"
    real = resolved
  if roots.len > 0:
    let r = rootsReason(flag, path, real, roots, rootsLabel)
    if r.len > 0: return r
  if not want.dir and want.formats.card > 0:
    let sniffed = sniffDiskFormat(real)
    if (sniffed * want.formats).card == 0:
      var names: seq[string]
      for f in want.formats: names.add($f)
      return flag & " '" & path & "' is not a " & names.join("/") &
        " disk image"
    # Whatever the backend opens it as, a file that LOOKS like one of these
    # may be opened as one (QEMU probes), so check every container it parses
    # as, not only the one the backend asks for.
    if dfQcow2 in sniffed:
      let refs = qcow2Refs(real)
      if refs.malformed.len > 0:
        return flag & " '" & path & "' " & refs.malformed
      if refs.dataFile:
        return flag & " '" & path & "' uses an external qcow2 data file"
      if refs.backing.len > 0:
        if depth >= MaxBackingDepth:
          return flag & " '" & path & "' has a backing chain deeper than " &
            $MaxBackingDepth
        if refs.backingFmt.len > 0 and refs.backingFmt != "qcow2":
          return flag & " '" & path & "' has a '" & refs.backingFmt &
            "' backing file (only a qcow2 backing chain is admitted)"
        if ':' in refs.backing or '\0' in refs.backing:
          return flag & " '" & path & "' has a backing file name QEMU may " &
            "read as a protocol or JSON spec ('" & refs.backing & "')"
        # QEMU resolves a relative name against the directory of the path
        # it opened (as given, not as resolved).
        let link =
          if refs.backing.startsWith("/"): refs.backing
          else: path.splitPath.head & "/" & refs.backing
        var linkReal: string
        let r = hostPathReason(flag & " backing file", link, roots,
                               rootsLabel,
                               HostPathWant(dir: false, formats: {dfQcow2}),
                               linkReal, depth + 1)
        if r.len > 0:
          return flag & " '" & path & "': " & r
    if dfVhd in sniffed and vhdIsDifferencing(real):
      return flag & " '" & path & "' is a differencing VHD (it names a " &
        "parent disk)"
    if dfVhdx in sniffed:
      let r = vhdxParentReason(real)
      if r.len > 0:
        return flag & " '" & path & "' " & r
  ""

proc firmwarePathReason*(flag, path: string): string =
  ## "" when ``path`` resolves (after symlinks) to an existing regular file
  ## under one of ``FirmwareRoots``; else the refusal reason.
  var real: string
  hostPathReason(flag, path, FirmwareRoots, "firmware",
                 HostPathWant(dir: false), real)

# ---------------------------------------------------------------------------
# Golden images and Incus profiles: the operator-configured half (G13
# residuals). ``ExecPolicyConfig`` comes from ``gosti serve
# --allow-image-root`` / ``--allow-incus-profile`` (or their environment
# variables), via ``ServeConfig``.
# ---------------------------------------------------------------------------

type
  ExecPolicyConfig* = object
    ## The operator's allowlists for the parts of an argv that name host
    ## resources the caller would otherwise choose freely.
    imageRoots*: seq[string]
      ## Directories a host-path golden image (``--source-image`` /
      ## ``--base-image`` for libvirt, Hyper-V, qemu-windows-arm and the
      ## crud disk backends) must resolve under. EMPTY ⇒ no location bound:
      ## the image must still resolve to a regular file (a directory for
      ## qemu-windows-arm) that IS a disk image of the backend's format.
      ## docs/contributors/serve.md ("Image roots and Incus profiles") says
      ## why the default cannot be narrower without breaking a deployment.
    incusProfiles*: seq[string]
      ## Exact names ``--incus-profile`` may take. EMPTY ⇒
      ## ``DefaultIncusProfiles``.

  ImageKind* = enum
    ## How a backend reads ``--source-image`` / ``--base-image``.
    ikReference     ## a name the hypervisor resolves in its OWN store (an
                    ## Incus image alias, a Tart VM name or OCI reference, a
                    ## UTM bundle name): never a host path
    ikDiskFile      ## a disk-image file on the daemon host
    ikGoldenDir     ## a qemu-windows-arm golden directory on the daemon host
    ikNotViaServe   ## read as something that is not a disk image at all
                    ## (``crud --backend lima``: a Lima YAML template, whose
                    ## ``mounts:`` can share any host directory with the
                    ## guest): refused

const
  DefaultIncusProfiles* = ["default"]
    ## What ``--incus-profile`` may name when the operator configured
    ## nothing. ``default`` is the profile Incus attaches anyway when none is
    ## named, so admitting it grants nothing new; it is also the only name
    ## garm-provider-gosti sends unless its operator sets
    ## ``remote.incusProfiles`` (nixos-modules ``modules/garm``, default
    ## ``[ ]``, i.e. no flag at all).

  ImageFlags* = ["--base-image", "--source-image"]

  QwaGoldenDiskName* = "windows.qcow2"
    ## The disk inside a qemu-windows-arm golden directory
    ## (``qemu_windows_arm.QwaBaseDiskName``; the unit test pins the two
    ## together).

  RunDiskFormats = {dfQcow2}
    ## ``run --ephemeral`` on the libvirt path (libvirt and every backend
    ## that falls through to it) clones ``qemu-img create -b <golden> -F
    ## qcow2``, so the golden is a qcow2 or nothing.
  HyperVDiskFormats = {dfVhdx, dfVhd}
  CrudDiskFormats = {dfQcow2, dfVhdx, dfVhd, dfIso9660}
    ## crud ``create_vm``'s provisionBaseline takes a qcow2 golden, a VHD(X)
    ## or an installer ISO, depending on the backend.

proc imageKindFor*(sub, backend: string): tuple[kind: ImageKind,
                                                formats: set[DiskFormat]] =
  ## How ``backend`` reads an image option under subcommand ``sub``. Mirrors
  ## the worker: ``cli.ephemeralPathFor`` routes ``run --ephemeral`` (incus,
  ## hyperv, the gosti-run set, everything else to libvirt's qcow2 clone),
  ## and each backend's ``provisionBaseline`` reads ``BaselineSpec.sourceImage``
  ## for crud.
  case backend
  of "incus", "tart-macos", "tart-linux-arm", "utm-windows-arm":
    (ikReference, {})
  of "qemu-windows-arm":
    (ikGoldenDir, {})
  of "hyperv":
    (ikDiskFile, HyperVDiskFormats)
  of "lima":
    # ``run --ephemeral --backend lima`` falls through to libvirt's qcow2
    # clone; crud hands the value to ``limactl create`` as a TEMPLATE.
    if sub == "run": (ikDiskFile, RunDiskFormats)
    else: (ikNotViaServe, {})
  else:
    if sub == "run": (ikDiskFile, RunDiskFormats)
    else: (ikDiskFile, CrudDiskFormats)

proc isImageReference(s: string): bool =
  ## A name for the hypervisor's own image store: not a path (no leading
  ## ``/``, ``\`` or ``~``, no drive letter, no ``..`` component), not an
  ## option (no leading ``-``: Incus and Tart get it as a CLI argument), and
  ## printable ASCII without spaces.
  if s.len == 0 or s.len > 255: return false
  if s[0] in {'-', '/', '\\', '~', '.'}: return false
  if s.len >= 2 and s[1] == ':' and s[0] in Letters: return false
  for c in s:
    if c notin Letters + Digits + {'.', '_', '-', '/', ':', '@', '+'}:
      return false
  for part in s.split({'/', ':'}):
    if part == "..": return false
  true

proc imageReason*(sub, backend, flag, value: string,
                  pc: ExecPolicyConfig): string =
  ## "" when ``value`` is an image ``backend`` may be given via serve; else
  ## the refusal reason.
  let (kind, formats) = imageKindFor(sub, backend)
  case kind
  of ikNotViaServe:
    return flag & " is not accepted for backend '" & backend & "' via " &
      "serve (it names a template, not a disk image)"
  of ikReference:
    if not value.isImageReference:
      return flag & " '" & value & "' is not an image name for backend '" &
        backend & "' (it resolves in the hypervisor's own store, so it may " &
        "not be a path, an option or contain '..')"
  of ikDiskFile:
    var real: string
    return hostPathReason(flag, value, pc.imageRoots, "image",
                          HostPathWant(dir: false, formats: formats), real)
  of ikGoldenDir:
    var real: string
    let r = hostPathReason(flag, value, pc.imageRoots, "image",
                           HostPathWant(dir: true), real)
    if r.len > 0: return r
    # The disk inside must itself be a qcow2 that stays in the directory.
    var disk: string
    let d = hostPathReason(flag, real / QwaGoldenDiskName, [real],
                           "golden directory",
                           HostPathWant(dir: false, formats: {dfQcow2}), disk)
    if d.len > 0:
      return flag & " '" & value & "' is not a golden directory: " & d
  ""

proc profileReason*(profile: string, pc: ExecPolicyConfig): string =
  ## "" when ``--incus-profile profile`` is on the operator's allowlist.
  let allowed =
    if pc.incusProfiles.len > 0: pc.incusProfiles
    else: @DefaultIncusProfiles
  if profile in allowed: return ""
  "--incus-profile '" & profile & "' is not allowed via serve (allowed " &
    "on this host: " & allowed.join(", ") & "; see serve " &
    "--allow-incus-profile)"

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

proc hostResourceReason(sub: string, parsed: ParsedArgv,
                        pc: ExecPolicyConfig): string =
  ## Every admitted option whose value names a host resource, checked with
  ## the same walk ``parseAgainst`` produced (run after ``commonReason``, so
  ## every ``--backend`` is already a ``ServeBackends`` id):
  ##
  ## * UEFI firmware (``run``): under ``FirmwareRoots``;
  ## * golden images (``--source-image`` / ``--base-image``): by how each
  ##   named backend reads them (``imageKindFor``). EVERY ``--backend``
  ##   value is checked, not only the last one the worker keeps, so a
  ##   repeated ``--backend`` cannot turn a name admitted for incus into a
  ##   path read by libvirt;
  ## * ``--incus-profile``: on the operator's allowlist, whatever the backend.
  for flag in ["--uefi-loader", "--uefi-nvram-template"]:
    for p in parsed.valuesOf(flag):
      let reason = firmwarePathReason(flag, p)
      if reason.len > 0: return reason
  let backends = parsed.valuesOf("--backend")
  for flag in ImageFlags:
    for v in parsed.valuesOf(flag):
      for b in backends:
        let reason = imageReason(sub, b, flag, v, pc)
        if reason.len > 0: return reason
  for p in parsed.valuesOf("--incus-profile"):
    let reason = profileReason(p, pc)
    if reason.len > 0: return reason
  ""

proc gostiExecPolicy*(argv: seq[string],
                      pc: ExecPolicyConfig = ExecPolicyConfig()): string
                     {.gcsafe.} =
  ## The production ``/v1/exec`` policy. See the module header. ``pc`` is
  ## the operator's image-root and Incus-profile allowlists
  ## (``ServeConfig.allowImageRoots`` / ``allowIncusProfiles``); the default
  ## is what ``gosti serve`` enforces when none is configured.
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
  let c = commonReason(parsed)
  if c.len > 0: return c
  hostResourceReason(argv[0], parsed, pc)
