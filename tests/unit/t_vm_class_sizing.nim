# SPDX-FileCopyrightText: 2026 Metacraft Labs / Schelling Point Labs
# SPDX-License-Identifier: Apache-2.0
## t_vm_class_sizing — the VM-class sizing helper (``gosti vm-class-size``):
## from a ``runquota profile --json`` answer (and optionally a ``runquota
## sizing --json`` answer), the vCPUs, memory, memory per vCPU, write
## bandwidth and disk of a VM class, each with its source, and caveats for
## what the measurements could not supply.
##
## The answers below are literal JSON in the shape runquota prints (its
## ``profileAnswerJson`` / sizing answer): the helper's input is that text,
## so a fixture of it is the input itself, not a stand-in. The end to end
## path (gosti running ``runquota profile`` against a daemon) is exercised by
## the CLI case with a recording ``runquota`` script, justified there.
##
## Each case names the change that makes it fail.

import std/[json, os, osproc, strutils, tempfiles, unittest]
import gosti

const
  MiB = 1024'u64 * 1024'u64
  GiB = 1024'u64 * MiB

proc profileAnswer(widthQ = 4000; peakQ = 3'u64 * GiB; writeQ = 1_000_000;
                   runWriteQ = 10'u64 * GiB; entries = 1): JsonNode =
  var profiles = newJArray()
  for i in 0 ..< entries:
    profiles.add(%*{
      "project": "proj",
      "entry_point": (if i == 0: "test" else: "build"),
      "host_profile": "hp1",
      "runs": 5, "executions": 40, "executions_incomplete": 0,
      "peak_memory_bytes": {"count": 40, "quantile": peakQ, "max": peakQ * 2},
      "duration_millis": {"count": 40, "quantile": 60000, "max": 90000},
      "mean_cpu_milli": {"count": 40, "quantile": 3500, "max": 4000},
      "granted_width_milli": {"count": 40, "quantile": widthQ, "max": widthQ},
      "write_bytes_per_sec": {"count": 40, "quantile": writeQ, "max": writeQ},
      "run_write_bytes": {"count": 5, "quantile": runWriteQ,
        "max": runWriteQ}})
  %*{"status": "ok", "quantile": 0.99, "caveats": [], "profiles": profiles}

proc sizingAnswer(cpus: int; total: uint64; write: int64): JsonNode =
  %*{"status": "ok", "caveats": [], "sizes": [{"cpus": cpus,
    "memory_quantile_bytes": total - GiB, "memory_max_bytes": total,
    "write_quantile_bytes_per_sec": write, "write_max_bytes_per_sec": write,
    "total_bytes": total, "makespan_quantile_millis": 1000,
    "makespan_max_millis": 1000}]}

suite "vm-class sizing":
  test "from the profile alone":
    # Mutation: dividing the peak by vCPUs instead of by the width it ran
    # at sizes a 4-wide job's 3 GiB as 0.75 GiB per 4 vCPUs.
    var inputs = defaultInputs("proj")
    let size = sizeVmClass(profileAnswer(), nil, inputs)
    check size.vcpus.value == 4
    check "granted_width_milli" in size.vcpus.source
    # 3 GiB x 4 / 4 CPUs of width, plus 512 MiB, rounded to 256 MiB.
    check size.memoryBytes.value == 3'u64 * GiB + 512'u64 * MiB
    check size.memoryPerVcpuBytes == size.memoryBytes.value div 4
    # Every CPU writing at the per-execution rate.
    check size.writeBytesPerSec.value == 4_000_000'u64
    # 10 GiB x 1.5, rounded up to whole GiB.
    check size.diskBytes.value == 15'u64 * GiB
    check size.caveats.len >= 1
    check "no `runquota sizing` answer" in size.caveats.join("\n")
    # More vCPUs than the jobs' width: memory scales by vCPUs per CPU of
    # width (3 GiB per 4-wide job, so 6 GiB for 8 vCPUs).
    inputs.vcpus = 8
    let wide = sizeVmClass(profileAnswer(), nil, inputs)
    check wide.memoryBytes.value == 6'u64 * GiB + 512'u64 * MiB
    check wide.writeBytesPerSec.value == 8_000_000'u64

  test "the sizing replay wins where it has the figures":
    # Mutation: ignoring the sizing answer uses the per-execution estimate.
    var inputs = defaultInputs("proj")
    inputs.vcpus = 8
    let size = sizeVmClass(profileAnswer(), sizingAnswer(8, 9'u64 * GiB,
      7_000_000), inputs)
    check size.vcpus.value == 8
    check size.vcpus.source == "given"
    check size.memoryBytes.value == 9'u64 * GiB + 512'u64 * MiB
    check "sizing total_bytes at 8 CPUs" == size.memoryBytes.source
    check size.writeBytesPerSec.value == 7_000_000'u64
    # A sizing answer at another N is not used, and says so.
    let other = sizeVmClass(profileAnswer(), sizingAnswer(2, 9'u64 * GiB,
      7_000_000), inputs)
    check "no figures at 8 CPUs" in other.caveats.join("\n")
    check "profile peak_memory_bytes" in other.memoryBytes.source

  test "rounding, base disk, headroom and overhead":
    var inputs = defaultInputs("proj")
    inputs.guestOverheadBytes = 100'u64 * MiB
    inputs.baseDiskBytes = 20'u64 * GiB
    inputs.diskHeadroom = 1.0
    let size = sizeVmClass(profileAnswer(widthQ = 1500, peakQ = 1'u64 * GiB,
      runWriteQ = 3'u64 * GiB + 1), nil, inputs)
    # 1.5 CPUs of width rounds up to 2 vCPUs; 1 GiB x 2 / 2 + 100 MiB,
    # rounded up to 256 MiB.
    check size.vcpus.value == 2
    check size.memoryBytes.value == 1'u64 * GiB + 256'u64 * MiB
    check size.diskBytes.value == 24'u64 * GiB

  test "missing figures are caveats, not zeros passed off as sizes":
    var answer = profileAnswer()
    let entry = answer["profiles"][0]
    entry["write_bytes_per_sec"] = %*{"count": 0, "quantile": nil, "max": nil}
    entry["run_write_bytes"] = %*{"count": 0, "quantile": nil, "max": nil}
    entry["granted_width_milli"] = %*{"count": 0, "quantile": nil, "max": nil}
    let size = sizeVmClass(answer, nil, defaultInputs("proj"))
    let notes = size.caveats.join("\n")
    check "write bandwidth unknown" in notes
    check "disk is the base image alone" in notes
    check "pass --vcpus" in notes
    check size.writeBytesPerSec.source == "no write figures recorded"

  test "refusals":
    expect VmClassSizeError:
      discard sizeVmClass(%*{"status": "ok"}, nil, defaultInputs("proj"))
    expect VmClassSizeError:
      discard sizeVmClass(profileAnswer(), nil, defaultInputs("other"))
    # Two entry points and none chosen: blending them would size for
    # neither.
    try:
      discard sizeVmClass(profileAnswer(entries = 2), nil,
        defaultInputs("proj"))
      check false
    except VmClassSizeError as e:
      check "choose one with --entry-point" in e.msg
    var inputs = defaultInputs("proj")
    inputs.entryPoint = "build"
    check sizeVmClass(profileAnswer(entries = 2), nil, inputs).entryPoint ==
      "build"

  test "the JSON form":
    let node = sizeVmClass(profileAnswer(), nil, defaultInputs("proj")).toJson()
    check node["vcpus"]["value"].getInt() == 4
    check node["memory_bytes"]["source"].getStr().len > 0
    check node.hasKey("memory_per_vcpu_bytes")
    check node.hasKey("disk_bytes") and node.hasKey("write_bytes_per_sec")
    check node["caveats"].kind == JArray

  when defined(posix):
    test "the CLI asks runquota for the profile and the replay at its N":
      # A RECORDING `runquota` (a shell script) stands in for the client
      # here: what is under test is which questions gosti asks and how it
      # reads the answers; the answers' shape is runquota's, pinned above.
      let dir = createTempDir("gosti-vmsize-", "")
      defer: removeDir(dir)
      writeFile(dir / "profile.json", $profileAnswer())
      writeFile(dir / "sizing.json", $sizingAnswer(4, 6'u64 * GiB, 9))
      let script = dir / "runquota"
      writeFile(script, "#!/bin/sh\necho \"$@\" >> " & quoteShell(dir / "argv") &
        "\ncase \"$1\" in\n  profile) cat " & quoteShell(dir / "profile.json") &
        " ;;\n  sizing) cat " & quoteShell(dir / "sizing.json") & " ;;\n" &
        "esac\n")
      setFilePermissions(script, {fpUserRead, fpUserWrite, fpUserExec})
      putEnv("GOSTI_RUNQUOTA_CMD", script)
      defer: delEnv("GOSTI_RUNQUOTA_CMD")
      let code = runVmClassSize(@["--project", "proj", "--json"])
      check code == 0
      let argv = readFile(dir / "argv")
      check "profile --json --project proj" in argv
      check "sizing --json --project proj --cpus 4" in argv
      check runVmClassSize(@["--project"]) == 2
      check runVmClassSize(@["--vcpus", "0", "--project", "p"]) == 2
