# SPDX-FileCopyrightText: 2026 Metacraft Labs / Schelling Point Labs
# SPDX-License-Identifier: Apache-2.0
## No mocks. Include the capability module to exercise its private runOk path
## with a real self-executed child. Its cleanup callback opens /dev/null at the
## just-freed descriptor numbers, deterministically modeling another request's
## actual allocation. The old merged-stderr cleanup closes those live files.
import std/[os, posix, strutils, unittest]
include ../../src/vm_harness/serve/capability

when isMainModule:
  let args = commandLineParams()
  if args.len == 2 and args[0] == "__probe":
    stdout.writeLine("real stdout")
    stderr.writeLine("real stderr")
    quit(parseInt(args[1]))

var planted: seq[cint]
var closedOutput: cint

proc occupyFreedDescriptors(closedFd: int) {.nimcall, gcsafe.} =
  {.cast(gcsafe).}:
    closedOutput = cint(closedFd)
    # POSIX allocates the lowest free number. Keep opening until the actual
    # stdout number has been reoccupied, independent of the runner's other fds.
    while true:
      let fd = posix.open("/dev/null", O_RDONLY)
      doAssert fd >= 0
      if fd > closedOutput:
        discard posix.close(fd)
        break
      planted.add(fd)

proc isDevNull(fd: cint): bool =
  var actual, expected: Stat
  fstat(fd, actual) == 0 and stat("/dev/null", expected) == 0 and
    actual.st_ino == expected.st_ino and actual.st_rdev == expected.st_rdev

suite "capability probe descriptor ownership":
  teardown:
    for fd in planted:
      discard posix.close(fd)
    planted.setLen(0)

  test "successful probes preserve descriptors opened during cleanup":
    check runOk(getAppFilename(), ["__probe", "0"], occupyFreedDescriptors)
    check closedOutput in planted
    for fd in planted:
      check isDevNull(fd)

  test "failed probes retain their exit result and preserve other descriptors":
    check not runOk(getAppFilename(), ["__probe", "7"], occupyFreedDescriptors)
    check closedOutput in planted
    for fd in planted:
      check isDevNull(fd)
