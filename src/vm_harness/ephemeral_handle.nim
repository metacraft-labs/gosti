# SPDX-FileCopyrightText: 2026 Metacraft Labs / Schelling Point Labs
# SPDX-License-Identifier: Apache-2.0
## Persist the VmHandle of a kept ephemeral instance, so a LATER process can
## tear it down.
##
## WHY THIS EXISTS. `run --ephemeral --keep` returns while the guest keeps
## running, and `ephemeral-destroy` reclaims it from a different process
## minutes or hours later. For libvirt and incus that works without any state:
## their per-job artifacts are a deterministic function of `--baseline`
## (`<baseline>` is the domain/container name, the overlay is
## `overlayPathFor(baseline)`, and so on), so `cmdEphemeralDestroy`
## RECONSTRUCTS the handle from the name alone.
##
## The vm-harness-run backends are not like that, and the difference is why
## remote driving never worked for them. `revertToBaseline` mints the per-job
## name itself — `ephemeralName(prefix, epochMs, pid)`, e.g.
## `repro-vm-qemu-windows-arm-1789745025315-96801` — and the only way to stop
## the guest is the live handle's `extra`: `qemuPid`, `swtpmPid`, `vmDir`.
## None of that is derivable from `--baseline`. The local-exec path never
## noticed because it keeps ONE supervising process alive for the instance's
## whole life and hands that in-memory handle straight to `stopAndCleanup`.
##
## So the handle is written to disk at create and read back at destroy. That
## is the whole module. It is deliberately backend-agnostic: it stores what
## `VmHandle` carries and nothing a particular backend knows, so adding a
## backend to the ephemeral path needs no change here.
##
## NOT a general instance registry. `instances.nim` already is one, and it is
## libvirt-specific by construction (`beginDurableBoot` takes a
## `LibvirtBackend`). This is the small, flat thing the ephemeral lifecycle
## needs: write once, read once, delete.

import std/[json, options, os, strutils, tables]
import ./types

const
  EphemeralStateDirEnv* = "VMH_EPHEMERAL_STATE_DIR"
  DefaultEphemeralStateDir* = "/var/lib/vm-harness/ephemeral"

proc ephemeralStateRoot*(): string =
  ## Where kept-instance handles live. One root for every backend, keyed by
  ## backend id below, because the per-backend state dirs are configured
  ## independently (`VM_HARNESS_TART_STATE_DIR`,
  ## `VM_HARNESS_QEMU_WINDOWS_ARM_STATE_DIR`, …) and a teardown must be able to
  ## find the record without first constructing the backend that wrote it.
  let configured = getEnv(EphemeralStateDirEnv)
  if configured.len > 0: configured else: DefaultEphemeralStateDir

proc sanitizeKey*(s: string): string =
  ## `--baseline` is a GARM instance name (`garm-xxxxxxxxxxxx`), but nothing
  ## enforces that, and this value becomes a FILENAME. Keep it to a safe set
  ## rather than trusting the caller: a `--baseline` of `../../etc/x` must not
  ## escape the state root.
  result = newStringOfCap(s.len)
  for c in s:
    if c in {'a'..'z', 'A'..'Z', '0'..'9', '-', '_', '.'}:
      result.add(c)
    else:
      result.add('_')
  # Collapse any run of dots. Replacing separators alone already defeats
  # traversal — `../../etc/x` becomes `.._.._etc_x`, which names one file in
  # one directory — but leaving `..` inside a filename is needlessly ambiguous
  # to anyone reading the state directory, and ambiguity in a path is how
  # traversal bugs get reintroduced later.
  var collapsed = newStringOfCap(result.len)
  var dots = 0
  for c in result:
    if c == '.':
      inc dots
      if dots == 1: collapsed.add('.') else: collapsed.add('_')
    else:
      dots = 0
      collapsed.add(c)
  result = collapsed
  if result.len == 0 or result == "." or result.allCharsInSet({'.', '_'}):
    result = "_"

proc handlePath*(backendId, baseline: string): string =
  ephemeralStateRoot() / sanitizeKey(backendId) / (sanitizeKey(baseline) & ".json")

proc handleToJson*(vm: VmHandle): JsonNode =
  ## The backend-agnostic serialization of a ``VmHandle``: everything
  ## ``stopAndCleanup`` and the guest verbs need, and nothing a particular
  ## backend knows. Shared by the ephemeral handle store (below) and the crud
  ## store (``crud_store.nim``). ``backend`` is deliberately NOT stored — it is
  ## a live ref, and the reader constructs a fresh one.
  var extra = newJObject()
  for k, v in vm.extra:
    extra[k] = %v
  var auth = newJObject()
  case vm.sshAuth.kind
  of saNone:
    auth["kind"] = %"none"
  of saPassword:
    auth["kind"] = %"password"
    auth["password"] = %vm.sshAuth.password
  of saKeyFile:
    auth["kind"] = %"keyFile"
    auth["keyPath"] = %vm.sshAuth.keyPath
  %*{
    "name": vm.name,
    "clonedFrom": vm.baseline,
    "ipAddress": (if vm.ipAddress.isSome: %vm.ipAddress.get else: newJNull()),
    "sshPort": vm.sshPort,
    "sshUser": vm.sshUser,
    "sshAuth": auth,
    "extra": extra,
  }

proc handleFromJson*(doc: JsonNode, backend: VmBackend): VmHandle =
  ## Inverse of ``handleToJson``. Tolerant of missing keys (a record written by
  ## an older gosti still rebuilds).
  var extra = initTable[string, string]()
  if doc.hasKey("extra") and doc["extra"].kind == JObject:
    for k, v in doc["extra"]:
      if v.kind == JString: extra[k] = v.getStr
  var auth = SshAuth(kind: saNone)
  if doc.hasKey("sshAuth") and doc["sshAuth"].kind == JObject:
    let a = doc["sshAuth"]
    case a{"kind"}.getStr("none")
    of "password": auth = SshAuth(kind: saPassword,
                                  password: a{"password"}.getStr(""))
    of "keyFile": auth = SshAuth(kind: saKeyFile,
                                 keyPath: a{"keyPath"}.getStr(""))
    else: auth = SshAuth(kind: saNone)
  let ipNode = doc{"ipAddress"}
  let ip =
    if ipNode != nil and ipNode.kind == JString and ipNode.getStr.len > 0:
      some(ipNode.getStr)
    else:
      none(string)
  VmHandle(
    backend: backend,
    name: doc{"name"}.getStr(""),
    baseline: doc{"clonedFrom"}.getStr(""),
    ipAddress: ip,
    sshPort: doc{"sshPort"}.getInt(0),
    sshUser: doc{"sshUser"}.getStr(""),
    sshAuth: auth,
    extra: extra)

proc saveEphemeralHandle*(backendId, baseline: string, vm: VmHandle) =
  ## Record everything `stopAndCleanup` will need.
  ##
  ## Mode 0600: `sshAuth` may carry the guest provisioning password, and while
  ## that is a well-known credential for a throwaway guest rather than a real
  ## secret, a world-readable file containing a password is not worth the
  ## convenience.
  let path = handlePath(backendId, baseline)
  createDir(path.parentDir)
  let doc = %*{
    "schema": "vm-harness/ephemeral-handle/1",
    "backend": backendId,
    "baseline": baseline,
  }
  for k, v in handleToJson(vm):
    doc[k] = v
  # Write-then-rename so a crashed writer cannot leave a half-parsed record
  # that makes a live guest look unreclaimable.
  let tmp = path & ".tmp"
  writeFile(tmp, doc.pretty & "\n")
  try:
    setFilePermissions(tmp, {fpUserRead, fpUserWrite})
  except CatchableError:
    discard
  moveFile(tmp, path)

proc loadEphemeralHandle*(backendId, baseline: string,
                          backend: VmBackend): Option[VmHandle] =
  ## Rebuild the handle, or `none` when there is no record — an
  ## already-destroyed or never-kept instance must be a NO-OP for the caller,
  ## not an error, because GARM retries deletes.
  let path = handlePath(backendId, baseline)
  if not fileExists(path):
    return none(VmHandle)
  var doc: JsonNode
  try:
    doc = parseFile(path)
  except CatchableError:
    return none(VmHandle)
  some(handleFromJson(doc, backend))

proc forgetEphemeralHandle*(backendId, baseline: string) =
  ## Drop the record. Called AFTER a successful teardown, so a failed teardown
  ## leaves the record in place and the instance remains reclaimable rather
  ## than becoming an orphan nothing knows how to stop.
  let path = handlePath(backendId, baseline)
  try:
    if fileExists(path): removeFile(path)
  except CatchableError:
    discard

proc listEphemeralHandles*(backendId: string): seq[string] =
  ## The ``--baseline`` of every kept instance recorded for ``backendId`` —
  ## the vm-harness-run half of ``ephemeral-list``. A record exists from a
  ## successful ``run --ephemeral --keep`` until a successful
  ## ``ephemeral-destroy``, which is exactly the lifetime GARM must see.
  ##
  ## A MISSING directory is a legitimate "none kept yet". An UNREADABLE one
  ## raises (``walkDir`` on a permission-denied directory would otherwise
  ## silently yield nothing), because the caller forgets instances that are
  ## absent from this answer. A record that no longer parses is still listed,
  ## under its file stem: it is a kept instance nothing can describe, which is
  ## the last thing that should disappear from view.
  let dir = ephemeralStateRoot() / sanitizeKey(backendId)
  if not dirExists(dir):
    return @[]
  when defined(posix):
    if not (fpUserRead in getFilePermissions(dir) or
            fpGroupRead in getFilePermissions(dir) or
            fpOthersRead in getFilePermissions(dir)):
      raise newException(IOError, "ephemeral state dir is not readable: " & dir)
  for kind, path in walkDir(dir):
    if kind != pcFile or not path.endsWith(".json"): continue
    var name = path.extractFilename()
    name.setLen(name.len - ".json".len)
    try:
      let b = parseFile(path){"baseline"}.getStr("")
      if b.len > 0: name = b
    except CatchableError:
      discard
    result.add(name)
