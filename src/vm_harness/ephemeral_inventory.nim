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
##   {"vmhEphemeralList":1,"backend":"libvirt","instances":[{"name":"garm-x","state":"running"}]}
##
## ``state`` is normalized to GARM's own vocabulary (``running`` / ``stopped``
## / ``error`` / ``unknown``) so the provider forwards it verbatim.

import std/[json, strutils]

const
  InventoryMarker* = "vmhEphemeralList"
    ## Key that identifies the result line in a merged log stream.
  InventoryVersion* = 1

type
  EphemeralEntry* = object
    name*: string
    state*: string   ## running | stopped | error | unknown

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

proc filterEntries*(entries: seq[EphemeralEntry];
                    name = ""; prefix = ""): seq[EphemeralEntry] =
  ## ``--name`` selects exactly one instance (the provider's GetInstance);
  ## ``--ephemeral-prefix`` narrows to one naming convention (``garm-``).
  for e in entries:
    if name.len > 0 and e.name != name: continue
    if prefix.len > 0 and not e.name.startsWith(prefix): continue
    result.add(e)

proc inventoryLine*(backend: string; entries: seq[EphemeralEntry]): string =
  ## The single result line (no trailing newline).
  var arr = newJArray()
  for e in entries:
    arr.add(%*{"name": e.name, "state": e.state})
  $(%*{InventoryMarker: InventoryVersion, "backend": backend,
       "instances": arr})

proc parseInventoryLine*(line: string): InventoryResult =
  ## Inverse of ``inventoryLine`` — used by tests and by the Nim serve client.
  let node = parseJson(line)
  if node.kind != JObject or not node.hasKey(InventoryMarker):
    raise newException(ValueError, "not an ephemeral-list result line")
  var entries: seq[EphemeralEntry]
  for it in node{"instances"}.getElems():
    entries.add(EphemeralEntry(name: it{"name"}.getStr(""),
                               state: it{"state"}.getStr("unknown")))
  inventorySuccess(entries)

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
