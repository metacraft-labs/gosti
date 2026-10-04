# SPDX-FileCopyrightText: 2026 Metacraft Labs / Schelling Point Labs
# SPDX-License-Identifier: Apache-2.0
## No mocks. Eight real children overlap the launcher's error-pipe lifetime.
## A test-only constructor hook holds every parent before fork, after all
## pipes exist. Children inspect the actual inherited descriptors and stay
## alive until the parent assesses startup. Removing O_CLOEXEC must fail;
## cleanup releases the children even after a failed assertion.
{.define: gostiProcessPipeTest.}
import std/[atomics, monotimes, os, osproc, posix, streams, strutils,
            tempfiles, times, unittest]

when not declared(processPipeCreatedHook):
  {.error: "The Linux process-pipe compatibility module was not selected".}

const Children = 8

when isMainModule:
  let args = commandLineParams()
  if args.len == 3 and args[0] == "__hold":
    let work = args[1]
    var inherited: seq[string]
    # readFile closes its own descriptor before the inspection begins.
    let descriptors = readFile(work / "descriptors").splitWhitespace()
    for raw in descriptors:
      let fd = cint(parseInt(raw))
      if fcntl(fd, F_GETFD) >= 0 or errno != EBADF:
        inherited.add(raw)
    writeFile(work / ("child-" & args[2]), inherited.join(","))
    let deadline = getMonoTime() + initDuration(seconds = 30)
    while not fileExists(work / "release") and getMonoTime() < deadline:
      sleep(10)
    quit(if inherited.len == 0: 17 else: 29)
  elif args.len == 1 and args[0] == "__echo":
    let line = stdin.readLine()
    stdout.writeLine("stdout:" & line)
    stderr.writeLine("stderr:" & line)
    quit(23)
  elif args.len == 1 and args[0] == "__closed_stdin":
    discard posix.close(0)
    let child = startProcess(getAppFilename(), args = @["__echo"], options = {})
    child.inputStream.writeLine("closed stdin")
    child.inputStream.close()
    let output = child.outputStream.readAll()
    let errors = child.errorStream.readAll()
    let code = child.waitForExit(timeout = 10000)
    child.close()
    quit(if code == 23 and output == "stdout:closed stdin\n" and
        errors == "stderr:closed stdin\n": 0 else: 67)

var pipeCount, pipesReady, startsReturned: Atomic[int]
var releaseForks, barrierExpired: Atomic[bool]
var pipeDescriptors: array[Children, array[0..1, cint]]
var exitCodes: array[Children, int]
var launchFailed: array[Children, bool]

proc holdBeforeFork(fds: array[0..1, cint]) {.nimcall, gcsafe, raises: [].} =
  let index = pipeCount.fetchAdd(1)
  if index < Children:
    pipeDescriptors[index] = fds
  discard pipesReady.fetchAdd(1)
  let deadline = getMonoTime() + initDuration(seconds = 10)
  while not releaseForks.load() and getMonoTime() < deadline:
    sleep(1)
  if not releaseForks.load():
    barrierExpired.store(true)

type LaunchArg = object
  index: int
  work: string

proc launch(arg: LaunchArg) {.thread.} =
  try:
    # Parent streams leave exactly one new pipe: osproc's error-report pipe.
    let child = startProcess(getAppFilename(),
      args = @["__hold", arg.work, $arg.index], options = {poParentStreams})
    discard startsReturned.fetchAdd(1)
    exitCodes[arg.index] = child.waitForExit(timeout = 35000)
    child.close()
  except CatchableError:
    launchFailed[arg.index] = true

suite "Linux process pipe ownership":
  test "overlapping launches finish while every other child remains alive":
    let work = createTempDir("gosti-pipes-", "")
    defer: removeDir(work)
    var threads: array[Children, Thread[LaunchArg]]
    processPipeCreatedHook = holdBeforeFork
    for i in 0 ..< Children:
      createThread(threads[i], launch, LaunchArg(index: i, work: work))
    try:
      let readyDeadline = getMonoTime() + initDuration(seconds = 10)
      while pipesReady.load() < Children and getMonoTime() < readyDeadline:
        sleep(1)
      check pipesReady.load() == Children
      check pipeCount.load() == Children
      var descriptorText = ""
      for pair in pipeDescriptors:
        for fd in pair:
          check fd > 2
          let flags = fcntl(fd, F_GETFD)
          check flags >= 0
          check (flags and FD_CLOEXEC) != 0
          descriptorText.add($fd & "\n")
      writeFile(work / "descriptors", descriptorText)
      releaseForks.store(true)
      let startedDeadline = getMonoTime() + initDuration(seconds = 10)
      while startsReturned.load() < Children and getMonoTime() < startedDeadline:
        sleep(1)
      check startsReturned.load() == Children
      check not barrierExpired.load()
    finally:
      releaseForks.store(true)
      writeFile(work / "release", "release")
      joinThreads(threads)
      processPipeCreatedHook = nil
    for i in 0 ..< Children:
      check not launchFailed[i]
      check exitCodes[i] == 17
      let evidence = work / ("child-" & $i)
      check fileExists(evidence)
      if fileExists(evidence):
        check readFile(evidence) == ""

  test "child stdin stdout stderr and exit status retain their ordinary behavior":
    let child = startProcess(getAppFilename(), args = @["__echo"], options = {})
    defer: child.close()
    child.inputStream.writeLine("actual pipe input")
    child.inputStream.close()
    check child.outputStream.readAll() == "stdout:actual pipe input\n"
    check child.errorStream.readAll() == "stderr:actual pipe input\n"
    check child.waitForExit(timeout = 10000) == 23

  test "a caller with closed stdin still supplies working child stdin":
    let child = startProcess(getAppFilename(), args = @["__closed_stdin"],
      options = {poParentStreams})
    defer: child.close()
    check child.waitForExit(timeout = 15000) == 0

  test "an executable launch failure still reports the OS error":
    let work = createTempDir("gosti-no-exe-", "")
    defer: removeDir(work)
    expect OSError:
      discard startProcess(work / "absent-executable", options = {poParentStreams})
