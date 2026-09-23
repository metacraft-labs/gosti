## Enumerate the per-job ephemeral instances a backend is holding — the
## ``vm-harness ephemeral-list`` verb's value logic.
##
## WHY THIS EXISTS. ``run --ephemeral --keep`` creates a per-job guest and
## returns; ``ephemeral-destroy`` reclaims it later. Nothing could ASK which of
## those guests exist. The remote GARM provider (``garm-provider-vmharness``
## driving ``vm-harness serve``) therefore answered GARM's ``ListInstances``
## with an empty list, and GARM reads "not in the list" as "the provider
## already lost it": its orphaned-runner sweep deletes the database row and
## never calls DeleteInstance. On high-mem-server that leaked ~210 Windows
## libvirt domains (55 GiB) in a day — every one of them a guest whose runner
## took longer than five minutes to come online in GitHub.
##
## THE SAFETY PROPERTY. The answer is consumed by something that FORGETS
## instances on the strength of it, so "I could not enumerate" must never look
## like "there are none". Every enumerator here returns ``ok = false`` (and the
## verb exits non-zero) when the backend cannot answer; an empty ``instances``
## array is only ever emitted after a successful enumeration.
##
## WIRE FORMAT. The verb runs as a ``vm-harness serve`` worker, whose stdout
## and stderr are MERGED into one ``log`` stream, so the result cannot simply
## be "stdout". It is one line carrying a marker key the provider scans for:
##
##   {"vmhEphemeralList":1,"backend":"libvirt","instances":[{"name":"garm-x","state":"running","labels":{"garm-pool":"…"}}]}
##
## ``state`` is normalized to GARM's own vocabulary (``running`` / ``stopped``
## / ``error`` / ``unknown``) so the provider forwards it verbatim.

import std/[json, os, strutils, tables]
import ./ephemeral_handle

const
  InventoryMarker* = "vmhEphemeralList"
    ## Key that identifies the result line in a merged log stream.
  InventoryVersion* = 1

type
  EphemeralEntry* = object
    name*: string
    state*: string   ## running | stopped | error | unknown
    labels*: Table[string, string]
      ## Attribution recorded by ``ephemeral-label`` (empty when none).

  InventoryResult* = object
    ok*: bool
    entries*: seq[EphemeralEntry]
    message*: string ## why enumeration failed (ok = false)

proc inventoryFailure*(msg: string): InventoryResult =
  InventoryResult(ok: false, message: msg)

proc inventorySuccess*(entries: seq[EphemeralEntry]): InventoryResult =
  InventoryResult(ok: true, entries: entries)

proc normalizeIncusState*(raw: string): string =
  ## ``incus list -c s`` → GARM state. FROZEN is a live, paused container: it
  ## still exists and still holds its runner, so it is ``running`` for GARM's
  ## purposes (GARM would otherwise try to Start it).
  case raw.strip().toUpperAscii()
  of "RUNNING", "FROZEN": "running"
  of "STOPPED": "stopped"
  of "ERROR": "error"
  else: "unknown"

proc parseIncusListCsv*(output: string): seq[EphemeralEntry] =
  ## Parse ``incus list --format csv -c ns`` (``<name>,<STATE>`` per line).
  ## Incus instance names cannot contain a comma, so the first comma splits.
  for line in output.splitLines():
    let s = line.strip()
    if s.len == 0: continue
    let comma = s.find(',')
    if comma <= 0:
      raise newException(ValueError,
        "unexpected `incus list` csv row (no name,state pair): " & s)
    result.add(EphemeralEntry(name: s[0 ..< comma],
                              state: normalizeIncusState(s[comma + 1 .. ^1])))

proc splitNames*(output: string): seq[string] =
  ## One non-empty name per line (``virsh list --name`` output).
  for line in output.splitLines():
    let s = line.strip()
    if s.len > 0: result.add(s)

proc libvirtEntries*(allNames, activeNames: seq[string]): seq[EphemeralEntry] =
  ## Combine ``virsh list --all --name`` with ``virsh list --name`` (active
  ## domains only). A domain that is defined but not active is ``stopped``;
  ## an active one (running, paused, in shutdown…) is ``running``. Two plain
  ## name lists rather than one parsed table because a table needs column
  ## parsing that breaks on the multi-word ``shut off`` state.
  for n in allNames:
    result.add(EphemeralEntry(name: n,
      state: (if n in activeNames: "running" else: "stopped")))

proc matchesLabels*(e: EphemeralEntry; want: seq[string]): bool

proc filterEntries*(entries: seq[EphemeralEntry];
                    name = ""; prefix = "";
                    labels: seq[string] = @[]): seq[EphemeralEntry] =
  ## ``--name`` selects exactly one instance (the provider's GetInstance);
  ## ``--ephemeral-prefix`` narrows to one naming convention (``garm-``);
  ## ``--label`` keeps only instances attributed with every given label.
  for e in entries:
    if name.len > 0 and e.name != name: continue
    if prefix.len > 0 and not e.name.startsWith(prefix): continue
    if not e.matchesLabels(labels): continue
    result.add(e)

proc inventoryLine*(backend: string; entries: seq[EphemeralEntry]): string =
  ## The single result line (no trailing newline).
  var arr = newJArray()
  for e in entries:
    var labels = newJObject()
    for k, v in e.labels: labels[k] = %v
    arr.add(%*{"name": e.name, "state": e.state, "labels": labels})
  $(%*{InventoryMarker: InventoryVersion, "backend": backend,
       "instances": arr})

proc parseInventoryLine*(line: string): InventoryResult =
  ## Inverse of ``inventoryLine`` — used by tests and by the Nim serve client.
  let node = parseJson(line)
  if node.kind != JObject or not node.hasKey(InventoryMarker):
    raise newException(ValueError, "not an ephemeral-list result line")
  var entries: seq[EphemeralEntry]
  for it in node{"instances"}.getElems():
    var e = EphemeralEntry(name: it{"name"}.getStr(""),
                           state: it{"state"}.getStr("unknown"))
    if it{"labels"} != nil and it{"labels"}.kind == JObject:
      for k, v in it{"labels"}: e.labels[k] = v.getStr("")
    entries.add(e)
  inventorySuccess(entries)

# ---------------------------------------------------------------------------
# Attribution labels.
#
# WHY. GARM consumes a pool's ListInstances in two ways, and one of them is
# destructive: the scale-set worker DELETES every provider instance whose name
# is not in its own database set. A host-wide list would therefore let one
# pool (or scale set) destroy another's runners — three GARM pools share
# high-mem-server's libvirt alone, next to durable non-GARM domains. So the
# list a pool gets must contain exactly that pool's instances, and nothing a
# backend natively tracks says which pool an instance belongs to.
#
# HOW. A small per-instance record on the daemon host, keyed by backend and
# instance name, written by ``ephemeral-label`` right after a successful
# ``run --ephemeral --keep`` and removed by a successful ``ephemeral-destroy``.
# ``ephemeral-list --label k=v`` is then the JOIN of the backend's own
# enumeration (the truth about what exists) with these records (the truth
# about whose it is): a stale record with no instance is never listed, and an
# instance with no record never matches a label filter. It is a separate verb
# rather than a ``run`` flag so a provider can use it against any daemon
# version: an old daemon rejects the unknown verb, the create still stands.

const LabelStateDirEnv* = "VMH_EPHEMERAL_LABEL_DIR"

proc labelStateRoot*(): string =
  ## ``$VMH_EPHEMERAL_LABEL_DIR``, else ``$VMH_EPHEMERAL_STATE_DIR/labels``,
  ## else systemd's ``$STATE_DIRECTORY/ephemeral-labels`` — the serve unit
  ## runs under ``ProtectSystem=strict`` where only its StateDirectory is
  ## writable — else ``<ephemeralStateRoot()>/labels``.
  let explicit = getEnv(LabelStateDirEnv)
  if explicit.len > 0: return explicit
  if getEnv(EphemeralStateDirEnv).len > 0:
    return getEnv(EphemeralStateDirEnv) / "labels"
  let sd = getEnv("STATE_DIRECTORY").split(':')[0]
  if sd.len > 0: return sd / "ephemeral-labels"
  ephemeralStateRoot() / "labels"

proc parseLabel*(arg: string): (string, string) =
  ## ``key=value``. Keys are restricted so they stay readable in the record
  ## and unambiguous on the command line; values are free-form but non-empty.
  let eq = arg.find('=')
  if eq <= 0 or eq == arg.len - 1:
    raise newException(ValueError, "--label expects key=value, got '" & arg & "'")
  let k = arg[0 ..< eq]
  for c in k:
    if c notin {'a'..'z', 'A'..'Z', '0'..'9', '-', '_', '.'}:
      raise newException(ValueError, "--label key has invalid characters: " & k)
  (k, arg[eq + 1 .. ^1])

proc labelRecordPath*(backend, name: string): string =
  labelStateRoot() / sanitizeKey(backend) / (sanitizeKey(name) & ".json")

proc saveLabels*(backend, name: string; labels: seq[string]) =
  ## Write-then-rename, like the handle store. Raises on failure: a caller
  ## that asked for attribution must learn it did not get it.
  let path = labelRecordPath(backend, name)
  createDir(path.parentDir)
  var obj = newJObject()
  for l in labels:
    let (k, v) = parseLabel(l)
    obj[k] = %v
  let doc = %*{"schema": "vm-harness/ephemeral-labels/1", "backend": backend,
               "name": name, "labels": obj}
  let tmp = path & ".tmp"
  writeFile(tmp, $doc & "\n")
  moveFile(tmp, path)

proc loadLabels*(backend, name: string): Table[string, string] =
  let path = labelRecordPath(backend, name)
  if not fileExists(path): return
  try:
    let doc = parseFile(path)
    if doc{"name"}.getStr("") != name: return   # sanitized-key collision
    for k, v in doc{"labels"}:
      result[k] = v.getStr("")
  except CatchableError:
    discard

proc forgetLabels*(backend, name: string) =
  try:
    let path = labelRecordPath(backend, name)
    if fileExists(path): removeFile(path)
  except CatchableError:
    discard

proc attachLabels*(backend: string; entries: var seq[EphemeralEntry]) =
  for e in entries.mitems:
    e.labels = loadLabels(backend, e.name)

proc matchesLabels*(e: EphemeralEntry; want: seq[string]): bool =
  ## Every wanted ``key=value`` must be present. No filter matches everything.
  for w in want:
    let (k, v) = parseLabel(w)
    if e.labels.getOrDefault(k, "\0") != v: return false
  true

# ---------------------------------------------------------------------------
# Teardown classification (``ephemeral-destroy`` on incus).

proc isTransientIncusDeleteError*(output: string): bool =
  ## Whether a failed ``incus delete`` is worth retrying in-process.
  ##
  ## MEASURED on gpu-server-001 (2026-09-23): ``incus delete`` of a STOPPED
  ## GARM container failed with
  ##   ``zfs destroy -r …/containers/garm-<x>: dataset is busy``
  ## while nothing held the dataset (not mounted, absent from every
  ## ``/proc/*/mountinfo``), and the SAME delete succeeded ~30 minutes later
  ## with no intervention. That is a transient condition of ZFS under load,
  ## not a verdict, and the old teardown — which discarded the delete's result
  ## and reported success — turned each occurrence into a permanent STOPPED
  ## orphan. The patterns below are the busy/in-progress family; anything
  ## else is still retried within the budget but is logged as unexpected.
  let o = output.toLowerAscii()
  for needle in ["dataset is busy", "device or resource busy",
                 "resource busy", "timed out", "operation already in progress",
                 "is currently being", "try again"]:
    if needle in o: return true
  false
