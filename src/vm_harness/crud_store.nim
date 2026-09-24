# SPDX-FileCopyrightText: 2026 Metacraft Labs / Schelling Point Labs
# SPDX-License-Identifier: Apache-2.0
## The crud store: the generic-CRUD façade's instance registry, persisted so
## that one ``vm-harness crud`` process per verb sees the VMs earlier
## processes created (design doc §8.6).
##
## A consumer driving gosti as a subprocess (the ah-vm ``GostiOrchestrator``),
## or through ``vm-harness serve``'s ``/v1/exec``, runs a fresh process for
## every verb. Without this module the façade's registry died with each
## process, so ``create_vm`` followed by ``exec`` in the next call answered
## ``not-found``.
##
## What is stored is deliberately small: the logical name, the template it
## derives from, the last state the façade set, and the backend's
## ``VmHandle`` serialized exactly as the ephemeral handle store already does
## it (``ephemeral_handle.handleToJson``). So no backend needs crud-specific
## persistence. The *live* state is not trusted from disk: ``crud.nim``
## reconciles every loaded handle against the hypervisor through
## ``VmBackend.instancePresence``.
##
## The module knows nothing about any particular backend and nothing about
## any consumer; it is a flat, atomically-written record directory plus a
## portable per-name lock.

import std/[algorithm, json, options, os, strutils, times]
import ./ephemeral_handle
when defined(posix):
  import std/posix

const
  CrudStateDirEnv* = "VMH_CRUD_STATE_DIR"
  CrudRecordSchema* = "vm-harness/crud-vm/1"
  MaxCrudNameLen* = 64

type
  CrudStore* = ref object
    root*: string            ## resolved store root (already ends in ``crud``)

  CrudStoredVm* = object
    name*: string
    backend*: string
    baseline*: string
    state*: string           ## "running" | "stopped" — last façade-set state
    handle*: Option[JsonNode] ## ``handleToJson`` record, none once stopped

  CrudLock* = object
    path*: string            ## the lock directory; "" when not held

  CrudBusyError* = object of CatchableError
    ## The per-name lock stayed held past the timeout.

  CrudNameError* = object of ValueError
    ## The logical name cannot be a crud-store key.

proc crudStateRoot*(stateDirFlag = ""): string =
  ## Resolve the store root. The first CONFIGURED location wins — never "the
  ## first writable one": independent processes must agree without probing.
  ## Mirrors ``ephemeral_inventory.labelStateRoot`` so a serve daemon keeps its
  ## crud records next to its label records.
  if stateDirFlag.len > 0:
    return absolutePath(stateDirFlag) / "crud"
  let explicit = getEnv(CrudStateDirEnv)
  if explicit.len > 0: return explicit
  if getEnv(EphemeralStateDirEnv).len > 0:
    return getEnv(EphemeralStateDirEnv) / "crud"
  let sd = getEnv("STATE_DIRECTORY").split(':')[0]
  if sd.len > 0: return sd / "crud"
  when defined(windows):
    let local = getEnv("LOCALAPPDATA")
    if local.len > 0: return local / "vm-harness" / "crud"
  else:
    let xdg = getEnv("XDG_STATE_HOME")
    if xdg.len > 0: return xdg / "vm-harness" / "crud"
    let home = getEnv("HOME")
    if home.len > 0 and home != "/homeless-shelter":
      return home / ".local" / "state" / "vm-harness" / "crud"
  DefaultEphemeralStateDir / "crud"

proc newCrudStore*(root: string): CrudStore =
  CrudStore(root: root)

proc validateCrudName*(name: string) =
  ## ``[A-Za-z0-9][A-Za-z0-9._-]{0,63}``. Rejected rather than sanitized: two
  ## distinct logical names must never share one record.
  if name.len == 0 or name.len > MaxCrudNameLen or
     name[0] notin {'a'..'z', 'A'..'Z', '0'..'9'}:
    raise newException(CrudNameError,
      "vm name '" & name & "' is invalid: it must start with a letter or " &
      "digit and be at most " & $MaxCrudNameLen & " characters")
  for c in name:
    if c notin {'a'..'z', 'A'..'Z', '0'..'9', '-', '_', '.'}:
      raise newException(CrudNameError,
        "vm name '" & name & "' is invalid: only letters, digits, '.', '_' " &
        "and '-' are allowed")

proc backendDir*(store: CrudStore, backendId: string): string =
  store.root / sanitizeKey(backendId)

proc recordPath*(store: CrudStore, backendId, name: string): string =
  store.backendDir(backendId) / (name & ".json")

proc toJson(rec: CrudStoredVm): JsonNode =
  %*{"schema": CrudRecordSchema, "name": rec.name, "backend": rec.backend,
     "baseline": rec.baseline, "state": rec.state,
     "handle": (if rec.handle.isSome: rec.handle.get() else: newJNull())}

proc parseRecord(doc: JsonNode): CrudStoredVm =
  let h = doc{"handle"}
  CrudStoredVm(
    name: doc{"name"}.getStr(""),
    backend: doc{"backend"}.getStr(""),
    baseline: doc{"baseline"}.getStr(""),
    state: doc{"state"}.getStr("stopped"),
    handle: (if h != nil and h.kind == JObject: some(h) else: none(JsonNode)))

proc atomicWrite(path, content: string) =
  ## Write-then-rename, mode 0600 (a handle may carry a guest password).
  createDir(path.parentDir)
  let tmp = path & ".tmp." & $getCurrentProcessId()
  writeFile(tmp, content)
  try:
    setFilePermissions(tmp, {fpUserRead, fpUserWrite})
  except CatchableError:
    discard
  moveFile(tmp, path)

proc save*(store: CrudStore, rec: CrudStoredVm) =
  validateCrudName(rec.name)
  atomicWrite(store.recordPath(rec.backend, rec.name), rec.toJson.pretty & "\n")

proc load*(store: CrudStore, backendId, name: string): Option[CrudStoredVm] =
  ## ``none`` when there is no record. A record that exists but no longer
  ## parses RAISES: it describes an instance nothing can describe, which must
  ## not silently read as "no such VM".
  validateCrudName(name)
  let path = store.recordPath(backendId, name)
  if not fileExists(path):
    return none(CrudStoredVm)
  some(parseRecord(parseFile(path)))

proc remove*(store: CrudStore, backendId, name: string) =
  let path = store.recordPath(backendId, name)
  if fileExists(path):
    removeFile(path)

proc list*(store: CrudStore, backendId: string): seq[CrudStoredVm] =
  ## Every record for ``backendId``, sorted by name. A missing directory is
  ## "none yet"; an unreadable one or an unparsable record RAISES — the caller
  ## must never mistake "could not read" for "there are none".
  let dir = store.backendDir(backendId)
  if not dirExists(dir):
    return @[]
  when defined(posix):
    # ``walkDir`` on an unreadable directory yields nothing, silently.
    if access(dir.cstring, R_OK or X_OK) != 0:
      raise newException(IOError, "crud store is not readable: " & dir)
  var names: seq[string]
  for kind, path in walkDir(dir):
    let fname = path.extractFilename()
    # Dot-files are store internals (the mock's ``.fleet.json``); a valid
    # vm name can never start with '.'.
    if kind == pcFile and fname.endsWith(".json") and not fname.startsWith("."):
      names.add(fname[0 ..< fname.len - ".json".len])
  names.sort()
  for n in names:
    result.add(parseRecord(parseFile(dir / (n & ".json"))))

# ---------------------------------------------------------------------------
# Locking. ``mkdir`` is atomic on every supported OS, so the lock is a
# directory; its ``owner`` file names the holder's pid so a lock left by a
# killed process can be broken (POSIX, where liveness is cheap to test).

proc ownerAlive(lockDir: string): bool =
  ## True unless the recorded owner is provably dead. Unknown ⇒ alive.
  when defined(posix):
    try:
      let pid = parseInt(readFile(lockDir / "owner").strip().split(' ')[0])
      if pid <= 0: return true
      if posix.kill(Pid(pid), 0) == 0: return true
      return errno != ESRCH
    except CatchableError:
      # No/garbled owner file: either a holder mid-acquire (it writes the file
      # right after mkdir) or debris. Treat as alive; the timeout bounds it.
      return true
  else:
    true

proc acquire*(lockDir: string, timeoutSec: int): CrudLock =
  createDir(lockDir.parentDir)
  let deadline = epochTime() + float(max(timeoutSec, 0))
  while true:
    if not existsOrCreateDir(lockDir):
      writeFile(lockDir / "owner", $getCurrentProcessId() & " " &
                $getTime().toUnix())
      return CrudLock(path: lockDir)
    if not ownerAlive(lockDir):
      # Stale: the holder died without releasing. Break it and retry at once.
      try: removeDir(lockDir) except CatchableError: discard
      continue
    if epochTime() >= deadline:
      raise newException(CrudBusyError,
        "busy: another crud invocation holds " & lockDir)
    sleep(50)

proc release*(lock: var CrudLock) =
  if lock.path.len > 0:
    try: removeDir(lock.path) except CatchableError: discard
    lock.path = ""

proc lockVm*(store: CrudStore, backendId, name: string,
             timeoutSec: int): CrudLock =
  validateCrudName(name)
  acquire(store.backendDir(backendId) / (name & ".lock"), timeoutSec)

proc lockBackend*(store: CrudStore, backendId: string,
                  timeoutSec: int): CrudLock =
  ## Backend-wide lock, for a backend whose state is one shared file (the
  ## file-backed mock). Names cannot start with '.', so this never collides.
  acquire(store.backendDir(backendId) / ".backend.lock", timeoutSec)

proc mockFleetPath*(store: CrudStore): string =
  ## Where the file-backed mock keeps its whole fleet (design doc §8.6).
  store.backendDir("mock") / ".fleet.json"
