# SPDX-FileCopyrightText: 2026 Metacraft Labs / Schelling Point Labs
# SPDX-License-Identifier: Apache-2.0
## Sizing a VM class from what RunQuota measured: ``gosti vm-class-size``.
##
## A VM class (the shape a pool's VMs are created with) should fit the work
## that runs in it. RunQuota records, per project and entry point, the
## memory, CPU, duration and write bandwidth of every leased command, and
## answers two questions about them: ``runquota profile`` (per-execution
## figures, quantile and maximum) and ``runquota sizing`` (the job mix
## replayed at N CPUs: the memory N CPUs need). This module turns those
## answers into a shape: vCPUs, memory (and memory per vCPU), disk and write
## bandwidth.
##
## THE SIZES ARE ADVICE. Which shape a pool uses is the fleet's and the
## provider's configuration; this only says what the measurements support,
## and every figure names where it came from and what it could not know.
##
## The rules (each figure's ``source`` names which one applied):
##
## * vCPUs: given (``--vcpus``), else the profile's granted-width quantile
##   rounded up to whole CPUs, at least 1.
## * memory: the sizing answer's ``total_bytes`` at that N (the replayed
##   memory quantile plus the baseline), else its ``memory_quantile_bytes``;
##   else the profile's per-execution peak-memory quantile x N / (the width
##   quantile in CPUs, at least 1) -- one execution's memory per CPU it ran
##   on, times the CPUs. Plus the guest's own overhead, rounded up to
##   256 MiB.
## * write bandwidth: the sizing answer's ``write_quantile_bytes_per_sec``,
##   else the profile's per-execution write rate quantile x N (every CPU
##   writing at once: an upper bound).
## * disk: the base image plus the profile's ``run_write_bytes`` quantile
##   (what one run wrote in all) x the headroom, rounded up to 1 GiB.

import std/[json, math, options, os, osproc, strutils]
import ./runquota_vm

type
  VmClassInputs* = object
    project*: string
    entryPoint*: string
      ## The profile entry to size from; empty for "the one entry of the
      ## project" (refused when the profile has several).
    vcpus*: int
      ## 0: derive from the profile.
    guestOverheadBytes*: uint64
    baseDiskBytes*: uint64
    diskHeadroom*: float64

  SizedFigure* = object
    value*: uint64
    source*: string

  VmClassSize* = object
    project*: string
    entryPoint*: string
    vcpus*: SizedFigure
    memoryBytes*: SizedFigure
    memoryPerVcpuBytes*: uint64
    writeBytesPerSec*: SizedFigure
    diskBytes*: SizedFigure
    executions*: int
    caveats*: seq[string]

  VmClassSizeError* = object of CatchableError

const
  MiB = 1024'u64 * 1024'u64
  GiB = 1024'u64 * MiB
  DefaultGuestOverheadBytes* = 512'u64 * MiB
  DefaultDiskHeadroom* = 1.5
  MemoryGranularity* = 256'u64 * MiB
  DiskGranularity* = GiB

proc defaultInputs*(project: string): VmClassInputs =
  VmClassInputs(project: project, guestOverheadBytes: DefaultGuestOverheadBytes,
    diskHeadroom: DefaultDiskHeadroom)

proc roundUp(value, step: uint64): uint64 =
  if step == 0'u64 or value mod step == 0'u64: value
  else: value + (step - value mod step)

proc quantileOf(figure: JsonNode): Option[uint64] =
  ## A profile figure's quantile (``{"count", "quantile", "max"}``), or none
  ## when it was computed from nothing.
  if figure.isNil or figure.kind != JObject:
    return none(uint64)
  let q = figure{"quantile"}
  if q.isNil or q.kind != JInt or figure{"count"}.getInt() <= 0:
    return none(uint64)
  some(uint64(max(0'i64, q.getBiggestInt())))

proc pickProfile(profile: JsonNode; inputs: VmClassInputs): JsonNode =
  ## The ``profiles`` entry of the project (and entry point). A project with
  ## several entry points and none chosen is refused: their figures differ,
  ## and blending them silently would size for neither.
  if profile.isNil or profile.kind != JObject or
      profile{"profiles"}.isNil or profile{"profiles"}.kind != JArray:
    raise newException(VmClassSizeError,
      "not a `runquota profile --json` answer (no `profiles` list)")
  var matches: seq[JsonNode]
  for entry in profile["profiles"]:
    let project = entry{"project"}
    if project.isNil or project.kind != JString or
        project.getStr() != inputs.project:
      continue
    if inputs.entryPoint.len > 0:
      let entry2 = entry{"entry_point"}
      if entry2.isNil or entry2.kind != JString or
          entry2.getStr() != inputs.entryPoint:
        continue
    matches.add(entry)
  if matches.len == 0:
    raise newException(VmClassSizeError, "the profile has no figures for " &
      "project " & inputs.project &
      (if inputs.entryPoint.len > 0: " entry point " & inputs.entryPoint
       else: ""))
  if matches.len > 1:
    var names: seq[string]
    for m in matches:
      let e = m{"entry_point"}
      names.add((if e.isNil or e.kind != JString: "(none)" else: e.getStr()) &
        " on " & m{"host_profile"}.getStr())
    raise newException(VmClassSizeError, "project " & inputs.project &
      " has " & $matches.len & " profile entries (" & names.join(", ") &
      "); choose one with --entry-point (and keep one host profile)")
  matches[0]

proc sizeAt(sizing: JsonNode; vcpus: int): JsonNode =
  ## The sizing answer's figures at ``vcpus`` CPUs, or nil.
  if sizing.isNil or sizing.kind != JObject or sizing{"sizes"}.isNil:
    return nil
  for size in sizing["sizes"]:
    if size{"cpus"}.getInt() == vcpus:
      return size
  nil

proc sizeVmClass*(profile: JsonNode; sizing: JsonNode;
                  inputs: VmClassInputs): VmClassSize =
  ## The VM class shape the measurements support. ``sizing`` may be nil.
  ## Raises ``VmClassSizeError`` when the profile cannot size the project.
  if inputs.project.len == 0:
    raise newException(VmClassSizeError, "no project to size")
  let entry = pickProfile(profile, inputs)
  result.project = inputs.project
  let e = entry{"entry_point"}
  result.entryPoint = if e.isNil or e.kind != JString: "" else: e.getStr()
  result.executions = entry{"executions"}.getInt()
  if not profile{"caveats"}.isNil:
    for caveat in profile["caveats"]:
      result.caveats.add(caveat.getStr())
  if result.executions == 0:
    raise newException(VmClassSizeError, "project " & inputs.project &
      " has no complete executions in the profile")
  let width = quantileOf(entry{"granted_width_milli"})
  let widthCpus =
    if width.isSome: max(1'u64, (width.get + 999'u64) div 1000'u64)
    else: 1'u64
  # vCPUs.
  if inputs.vcpus > 0:
    result.vcpus = SizedFigure(value: uint64(inputs.vcpus), source: "given")
  elif width.isSome:
    result.vcpus = SizedFigure(value: widthCpus,
      source: "profile granted_width_milli quantile, rounded up")
  else:
    result.vcpus = SizedFigure(value: 1, source: "no width recorded: 1")
    result.caveats.add("no execution recorded its granted width; 1 vCPU " &
      "assumed: pass --vcpus")
  let n = result.vcpus.value
  let size = sizing.sizeAt(int(n))
  if sizing.isNil:
    result.caveats.add("no `runquota sizing` answer: memory and write " &
      "bandwidth are estimated from per-execution figures, without the " &
      "replay or the baseline")
  elif size.isNil:
    result.caveats.add("the `runquota sizing` answer has no figures at " &
      $n & " CPUs (ask it with --cpus " & $n & "); per-execution figures used")
  # Memory.
  var memory = 0'u64
  if not size.isNil and size{"total_bytes"}.kind == JInt:
    memory = uint64(size["total_bytes"].getBiggestInt())
    result.memoryBytes.source = "sizing total_bytes at " & $n & " CPUs"
  elif not size.isNil and size{"memory_quantile_bytes"}.kind == JInt:
    memory = uint64(size["memory_quantile_bytes"].getBiggestInt())
    result.memoryBytes.source = "sizing memory_quantile_bytes at " & $n &
      " CPUs (baseline unknown)"
    result.caveats.add("the sizing answer's baseline is unknown: memory " &
      "outside leases is not counted")
  else:
    let peak = quantileOf(entry{"peak_memory_bytes"})
    if peak.isNone:
      raise newException(VmClassSizeError, "project " & inputs.project &
        " has no peak memory recorded")
    memory = peak.get * n div widthCpus
    result.memoryBytes.source = "profile peak_memory_bytes quantile x " &
      $n & " / " & $widthCpus & " CPUs of width"
  memory += inputs.guestOverheadBytes
  result.memoryBytes.value = roundUp(memory, MemoryGranularity)
  result.memoryPerVcpuBytes = result.memoryBytes.value div max(1'u64, n)
  # Write bandwidth.
  if not size.isNil and size{"write_quantile_bytes_per_sec"}.kind == JInt:
    result.writeBytesPerSec = SizedFigure(
      value: uint64(size["write_quantile_bytes_per_sec"].getBiggestInt()),
      source: "sizing write_quantile_bytes_per_sec at " & $n & " CPUs")
  else:
    let rate = quantileOf(entry{"write_bytes_per_sec"})
    if rate.isSome:
      result.writeBytesPerSec = SizedFigure(value: rate.get * n,
        source: "profile write_bytes_per_sec quantile x " & $n &
          " (every CPU writing at once)")
    else:
      result.writeBytesPerSec = SizedFigure(value: 0,
        source: "no write figures recorded")
      result.caveats.add("no execution recorded its writes (sizing-data " &
        "off, or a platform that does not measure them): write bandwidth " &
        "unknown")
  # Disk.
  let written = quantileOf(entry{"run_write_bytes"})
  var disk = inputs.baseDiskBytes
  if written.isSome:
    disk += uint64(ceil(float64(written.get) * max(1.0, inputs.diskHeadroom)))
    result.diskBytes.source = "base " & $inputs.baseDiskBytes &
      " + profile run_write_bytes quantile x " & $inputs.diskHeadroom
  else:
    result.diskBytes.source = "base only: no run_write_bytes recorded"
    result.caveats.add("no run recorded what it wrote: the disk is the " &
      "base image alone")
  result.diskBytes.value = roundUp(disk, DiskGranularity)

proc toJson*(size: VmClassSize): JsonNode =
  proc figure(f: SizedFigure): JsonNode = %*{"value": f.value, "source": f.source}
  %*{
    "project": size.project,
    "entry_point": (if size.entryPoint.len > 0: %size.entryPoint else: newJNull()),
    "executions": size.executions,
    "vcpus": figure(size.vcpus),
    "memory_bytes": figure(size.memoryBytes),
    "memory_per_vcpu_bytes": size.memoryPerVcpuBytes,
    "write_bytes_per_sec": figure(size.writeBytesPerSec),
    "disk_bytes": figure(size.diskBytes),
    "caveats": size.caveats,
  }

proc humanBytes(value: uint64): string =
  if value >= GiB: formatFloat(float64(value) / float64(GiB), ffDecimal, 2) & " GiB"
  else: formatFloat(float64(value) / float64(MiB), ffDecimal, 1) & " MiB"

proc renderText*(size: VmClassSize): string =
  result = "project " & size.project &
    (if size.entryPoint.len > 0: " / " & size.entryPoint else: "") &
    " (" & $size.executions & " executions)\n"
  result.add("vcpus: " & $size.vcpus.value & "  (" & size.vcpus.source & ")\n")
  result.add("memory: " & humanBytes(size.memoryBytes.value) & ", " &
    humanBytes(size.memoryPerVcpuBytes) & " per vCPU  (" &
    size.memoryBytes.source & ")\n")
  result.add("write bandwidth: " & $size.writeBytesPerSec.value & " B/s  (" &
    size.writeBytesPerSec.source & ")\n")
  result.add("disk: " & humanBytes(size.diskBytes.value) & "  (" &
    size.diskBytes.source & ")")
  for caveat in size.caveats:
    result.add("\nnote: " & caveat)

proc runRunquotaJson(command: seq[string]; args: seq[string]): JsonNode =
  ## One ``runquota ... --json`` answer.
  let (output, code) =
    try:
      execCmdEx(quoteShellCommand(command & args))
    except OSError as e:
      raise newException(VmClassSizeError, "cannot run " & command[0] &
        ": " & e.msg)
  if code != 0:
    raise newException(VmClassSizeError, "`" & (command & args).join(" ") &
      "` exited " & $code & ": " & output.strip())
  try:
    parseJson(output)
  except JsonParsingError as e:
    raise newException(VmClassSizeError, "`" & (command & args).join(" ") &
      "` did not answer JSON: " & e.msg)

const VmClassSizeUsage* = """usage: gosti vm-class-size --project P [--entry-point E] [--vcpus N]
                              [--profile-json FILE] [--sizing-json FILE]
                              [--guest-overhead SIZE] [--base-disk SIZE]
                              [--disk-headroom X] [--json]

Size a VM class from RunQuota's measurements of project P. Without
--profile-json, runs `runquota profile --json --project P` (the client is
GOSTI_RUNQUOTA_CMD or `runquota`); without --sizing-json, runs `runquota
sizing --json --project P --cpus N` once N is known. A file of `-` is stdin.
Sizes accept MiB/GiB/MB/GB units. The result is advice: every figure names
its source, and notes say what the measurements could not supply."""

proc runVmClassSize*(args: seq[string]): int =
  ## ``gosti vm-class-size``. Exit 0 sized, 1 the measurements could not
  ## size it, 2 bad arguments.
  var inputs = defaultInputs("")
  var profilePath, sizingPath = ""
  var json = false
  var i = 0
  proc value(i: var int): string =
    if i + 1 >= args.len:
      raise newException(ValueError, args[i] & " needs a value")
    inc i
    result = args[i]
    inc i
  try:
    while i < args.len:
      case args[i]
      of "--project": inputs.project = value(i)
      of "--entry-point": inputs.entryPoint = value(i)
      of "--vcpus":
        inputs.vcpus = parseInt(value(i))
        if inputs.vcpus <= 0:
          raise newException(ValueError, "--vcpus must be positive")
      of "--profile-json": profilePath = value(i)
      of "--sizing-json": sizingPath = value(i)
      of "--guest-overhead": inputs.guestOverheadBytes = parseMemoryBytes(value(i))
      of "--base-disk": inputs.baseDiskBytes = parseMemoryBytes(value(i))
      of "--disk-headroom":
        inputs.diskHeadroom = parseFloat(value(i))
        if inputs.diskHeadroom < 1.0:
          raise newException(ValueError, "--disk-headroom must be at least 1")
      of "--json":
        json = true
        inc i
      of "-h", "--help":
        echo VmClassSizeUsage
        return 0
      else:
        raise newException(ValueError, "unknown argument '" & args[i] & "'")
    if inputs.project.len == 0:
      raise newException(ValueError, "--project is required")
  except ValueError as e:
    stderr.writeLine("gosti vm-class-size: " & e.msg)
    stderr.writeLine(VmClassSizeUsage)
    return 2
  let command = runquotaVmCommand(@[])
  proc readJson(path: string): JsonNode =
    let text = if path == "-": stdin.readAll() else: readFile(path)
    parseJson(text)
  try:
    let profile =
      if profilePath.len > 0: readJson(profilePath)
      else:
        var a = @["profile", "--json", "--project", inputs.project]
        if inputs.entryPoint.len > 0: a.add(@["--entry-point", inputs.entryPoint])
        runRunquotaJson(command, a)
    var sizing: JsonNode = nil
    if sizingPath.len > 0:
      sizing = readJson(sizingPath)
    elif profilePath.len == 0:
      # The vCPU count decides which N to replay: size once without the
      # replay to learn it, then ask for that N.
      let first = sizeVmClass(profile, nil, inputs)
      var a = @["sizing", "--json", "--project", inputs.project, "--cpus",
        $first.vcpus.value]
      if inputs.entryPoint.len > 0: a.add(@["--entry-point", inputs.entryPoint])
      try:
        sizing = runRunquotaJson(command, a)
      except VmClassSizeError as e:
        stderr.writeLine("gosti vm-class-size: no sizing replay (" & e.msg &
          "); sizing from the profile alone")
    let size = sizeVmClass(profile, sizing, inputs)
    if json: echo size.toJson().pretty()
    else: echo size.renderText()
    0
  except VmClassSizeError, JsonParsingError, IOError:
    stderr.writeLine("gosti vm-class-size: " & getCurrentExceptionMsg())
    1
