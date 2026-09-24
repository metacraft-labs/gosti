# SPDX-FileCopyrightText: 2026 Metacraft Labs / Schelling Point Labs
# SPDX-License-Identifier: Apache-2.0
## t_crud_store_roundtrip — VM state persists across ``vm-harness crud``
## invocations (design doc §8.6).
##
## Every step below is a SEPARATE CLI process, exactly as a subprocess
## consumer (the ah-vm ``GostiOrchestrator``) or a serve worker runs them. The
## gate drives every verb through the file-backed ``mock`` backend and then
## checks the store's rules:
##
##   * a full lifecycle — create, get, list, copy to/from, snapshot,
##     list/restore snapshots, exec, ssh_endpoint, stop, start, delete — where
##     each call sees what earlier calls did;
##   * reconciliation: an instance that vanishes behind the store's back
##     reports ``error`` (not ``not-found``, not ``running``); guest verbs fail
##     with ``backend-error``; ``start_vm`` re-materialises it and
##     ``delete_vm`` clears the record;
##   * names are validated (``bad-args``) and nothing is written for them;
##   * fault injection for consumers (``VMH_MOCK_FAIL`` → 5,
##     ``VMH_MOCK_UNAVAILABLE`` → 4);
##   * a held per-VM lock makes a call fail ``busy`` (5) instead of racing;
##   * stores are isolated by location, and ``VMH_CRUD_STATE_DIR`` is honoured;
##   * a record-trusting backend (``noop``: no hypervisor to ask) also keeps
##     its VMs across calls.
##
## Mock policy (design doc §9.1): the ``mock`` backend IS the fixture under
## test here — it is the deterministic file-backed stand-in for a hypervisor
## that §8.6 ships for hermetic consumers — and ``noop`` is the sanctioned
## fixture. The CLI, the crud store, process boundaries, locks, and the
## filesystem are all real. The test binary re-execs itself as the CLI
## (``__vmh_cli``) so no external binary is needed.

import std/[json, os, osproc, streams, strtabs, strutils, tempfiles, unittest]
import vm_harness/cli

when isMainModule:
  let params = commandLineParams()
  if params.len >= 1 and params[0] == "__vmh_cli":
    quit(runCli(params[1 .. ^1]))

type Run = object
  code: int
  env: JsonNode     ## the parsed stdout envelope
  stdout, stderr: string

proc runCrud(stateDir: string, args: seq[string],
             extraEnv: openArray[(string, string)] = [],
             backend = "mock"): Run =
  ## One ``vm-harness crud`` process. Flags go BEFORE ``--`` (everything
  ## after it is the guest argv), so ``--backend``/``--state-dir`` are
  ## spliced in right after the verb and name.
  var argv = @["__vmh_cli", "crud"]
  let dd = args.find("--")
  let head = if dd >= 0: args[0 ..< dd] else: args
  argv.add(head)
  argv.add(@["--backend", backend])
  if stateDir.len > 0: argv.add(@["--state-dir", stateDir])
  if dd >= 0: argv.add(args[dd .. ^1])
  var env = newStringTable(modeCaseSensitive)
  for k, v in envPairs(): env[k] = v
  for (k, v) in extraEnv: env[k] = v
  let p = startProcess(getAppFilename(), args = argv, env = env, options = {})
  p.inputStream.close()
  result.stdout = p.outputStream.readAll()
  result.stderr = p.errorStream.readAll()
  result.code = p.waitForExit()
  p.close()
  let lines = result.stdout.strip().splitLines()
  doAssert lines.len == 1, "expected exactly one envelope line, got: " &
    result.stdout & " / stderr: " & result.stderr
  result.env = parseJson(lines[0])

proc vmState(r: Run): string = r.env["data"]["vm"]["state"].getStr

proc vanish(stateDir, instance: string) =
  ## Delete the instance from the mock's fleet file — the equivalent of an
  ## operator removing a domain/container behind gosti's back.
  let fleet = stateDir / "crud" / "mock" / ".fleet.json"
  let doc = parseFile(fleet)
  var kept = newJArray()
  for vm in doc["vms"]:
    if vm["name"].getStr != instance: kept.add(vm)
  doc["vms"] = kept
  writeFile(fleet, doc.pretty)

suite "t_crud_store_roundtrip":
  let work = createTempDir("vmh-crud-store-rt-", "")

  test "every verb, one process per verb, sees the previous calls":
    let sd = work / "lifecycle"
    let host1 = work / "h1.txt"
    let host2 = work / "h2.txt"
    let back = work / "back.txt"
    writeFile(host1, "first")
    writeFile(host2, "second")

    var r = runCrud(sd, @["create_vm", "vm1"])
    check r.code == 0
    check r.vmState == "running"
    check r.env["data"]["vm"]["backend"].getStr == "mock"

    r = runCrud(sd, @["get_vm", "vm1"])
    check r.code == 0
    check r.vmState == "running"
    check r.env["data"]["vm"]["ssh"]["host"].getStr == "10.0.2.15"

    r = runCrud(sd, @["list_vms"])
    check r.code == 0
    check r.env["data"]["vms"].len == 1
    check r.env["data"]["vms"][0]["name"].getStr == "vm1"

    check runCrud(sd, @["copy_to_vm", "vm1", host1, "/g/f"]).code == 0
    r = runCrud(sd, @["snapshot", "vm1", "s1"])
    check r.code == 0
    check r.env["data"]["snapshot"]["id"].getStr == "mock-vm-vm1@s1"
    check runCrud(sd, @["copy_to_vm", "vm1", host2, "/g/f"]).code == 0
    r = runCrud(sd, @["list_snapshots", "vm1"])
    check r.env["data"]["snapshots"] == %["s1"]
    check runCrud(sd, @["restore_snapshot", "vm1", "s1"]).code == 0
    check runCrud(sd, @["copy_from_vm", "vm1", "/g/f", back]).code == 0
    check readFile(back) == "first"   # the restore crossed process boundaries

    r = runCrud(sd, @["exec", "vm1", "--env", "K=V", "--", "echo", "hi"])
    check r.code == 0
    check r.env["data"]["exit_code"].getInt == 0
    check r.env["data"]["stdout"].getStr == "mock-exec: [K=V] echo hi\n"
    check r.env["data"]["elapsed_ms"].getInt == 5

    r = runCrud(sd, @["ssh_endpoint", "vm1"])
    check r.env["data"]["ssh"] ==
      %*{"host": "10.0.2.15", "port": 22, "user": "mock", "auth": "keyfile"}

    r = runCrud(sd, @["stop_vm", "vm1"])
    check r.code == 0
    check r.vmState == "stopped"
    check r.env["data"]["vm"]["ssh"].kind == JNull
    r = runCrud(sd, @["get_vm", "vm1"])
    check r.vmState == "stopped"
    r = runCrud(sd, @["exec", "vm1", "--", "true"])
    check r.code == 5
    check "not running" in r.env["error"]["message"].getStr

    r = runCrud(sd, @["start_vm", "vm1"])
    check r.code == 0
    check r.vmState == "running"

    r = runCrud(sd, @["delete_vm", "vm1"])
    check r.code == 0
    check r.env["data"]["deleted"].getBool
    check runCrud(sd, @["get_vm", "vm1"]).code == 3
    check runCrud(sd, @["list_vms"]).env["data"]["vms"].len == 0
    check not fileExists(sd / "crud" / "mock" / "vm1.json")

  test "create of an existing name is bad-args":
    let sd = work / "dup"
    check runCrud(sd, @["create_vm", "vm1"]).code == 0
    let r = runCrud(sd, @["create_vm", "vm1"])
    check r.code == 2
    check "already exists" in r.env["error"]["message"].getStr

  test "a vanished instance reports error; start_vm and delete_vm recover":
    let sd = work / "vanish"
    check runCrud(sd, @["create_vm", "vm1"]).code == 0
    vanish(sd, "mock-vm-vm1")
    var r = runCrud(sd, @["get_vm", "vm1"])
    check r.code == 0
    check r.vmState == "error"
    check r.env["data"]["vm"]["ssh"].kind == JNull
    r = runCrud(sd, @["list_vms"])
    check r.env["data"]["vms"][0]["state"].getStr == "error"
    r = runCrud(sd, @["exec", "vm1", "--", "true"])
    check r.code == 5
    check "no longer exists" in r.env["error"]["message"].getStr
    r = runCrud(sd, @["start_vm", "vm1"])
    check r.code == 0
    check r.vmState == "running"
    vanish(sd, "mock-vm-vm1")
    check runCrud(sd, @["delete_vm", "vm1"]).code == 0
    check runCrud(sd, @["get_vm", "vm1"]).code == 3

  test "invalid names are bad-args and write nothing":
    let sd = work / "names"
    for bad in ["../escape", ".hidden", "a/b"]:
      let r = runCrud(sd, @["create_vm", bad])
      check r.code == 2
      check r.env["error"]["kind"].getStr == "bad-args"
    check not fileExists(sd / "crud" / "escape.json")
    check not fileExists(sd / "escape.json")
    check runCrud(sd, @["list_vms"]).env["data"]["vms"].len == 0

  test "fault injection: VMH_MOCK_FAIL and VMH_MOCK_UNAVAILABLE":
    let sd = work / "faults"
    check runCrud(sd, @["create_vm", "vm1"]).code == 0
    var r = runCrud(sd, @["exec", "vm1", "--", "true"],
                    [("VMH_MOCK_FAIL", "exec")])
    check r.code == 5
    check r.env["error"]["kind"].getStr == "backend-error"
    check "injected failure" in r.env["error"]["message"].getStr
    # The failed exec changed nothing: the VM is still there and running.
    check runCrud(sd, @["get_vm", "vm1"]).vmState == "running"
    r = runCrud(sd, @["create_vm", "vm2"], [("VMH_MOCK_FAIL", "revert,exec")])
    check r.code == 5
    check runCrud(sd, @["get_vm", "vm2"]).code == 3   # no half-created record
    r = runCrud(sd, @["list_vms"], [("VMH_MOCK_UNAVAILABLE", "1")])
    check r.code == 4
    check r.env["error"]["kind"].getStr == "backend-unavailable"

  test "a held per-VM lock fails busy instead of racing":
    let sd = work / "lock"
    check runCrud(sd, @["create_vm", "vm1"]).code == 0
    let lockDir = sd / "crud" / "mock" / "vm1.lock"
    createDir(lockDir)
    writeFile(lockDir / "owner", $getCurrentProcessId() & " 0")  # alive
    let r = runCrud(sd, @["get_vm", "vm1", "--lock-timeout-sec", "0"])
    check r.code == 5
    check "busy" in r.env["error"]["message"].getStr
    removeDir(lockDir)
    check runCrud(sd, @["get_vm", "vm1"]).code == 0

  test "stores are isolated by location; VMH_CRUD_STATE_DIR is honoured":
    let a = work / "iso-a"
    let b = work / "iso-b"
    check runCrud(a, @["create_vm", "vm1"]).code == 0
    check runCrud(b, @["get_vm", "vm1"]).code == 3
    let envDir = work / "iso-env"
    check runCrud("", @["create_vm", "vmx"],
                  [("VMH_CRUD_STATE_DIR", envDir)]).code == 0
    check fileExists(envDir / "mock" / "vmx.json")
    check runCrud("", @["get_vm", "vmx"],
                  [("VMH_CRUD_STATE_DIR", envDir)]).vmState == "running"

  test "a record-trusting backend (noop) also persists across calls":
    let sd = work / "noop"
    var r = runCrud(sd, @["create_vm", "n1"], backend = "noop")
    check r.code == 0
    check r.env["data"]["vm"]["backend"].getStr == "noop"
    r = runCrud(sd, @["exec", "n1", "--", "echo", "hi"], backend = "noop")
    check r.code == 0
    check runCrud(sd, @["get_vm", "n1"], backend = "noop").vmState == "running"
    check runCrud(sd, @["delete_vm", "n1"], backend = "noop").code == 0
    check runCrud(sd, @["get_vm", "n1"], backend = "noop").code == 3

  when defined(posix):
    test "scripts/vm-harness-fixture.sh drives the same contract":
      # The consumer-facing wrapper (§8.6): real CLI, mock backend, per-test
      # state dir. VMH_FIXTURE_CLI points it at this binary's CLI role.
      let script = currentSourcePath().parentDir.parentDir.parentDir /
                   "scripts" / "vm-harness-fixture.sh"
      let sd = work / "fixture"
      proc fx(args: seq[string], extra: openArray[(string, string)] = []):
          (int, JsonNode) =
        var env = newStringTable(modeCaseSensitive)
        for k, v in envPairs(): env[k] = v
        env["VMH_FIXTURE_STATE_DIR"] = sd
        env["VMH_FIXTURE_CLI"] = getAppFilename() & " __vmh_cli"
        for (k, v) in extra: env[k] = v
        let p = startProcess("/usr/bin/env", args = @["bash", script] & args,
                             env = env, options = {})
        p.inputStream.close()
        let o = p.outputStream.readAll()
        let code = p.waitForExit()
        p.close()
        (code, parseJson(o.strip().splitLines()[^1]))
      check fx(@["create_vm", "vm1"])[0] == 0
      let (ec, ex) = fx(@["exec", "vm1", "--", "echo", "hi"])
      check ec == 0
      check ex["data"]["stdout"].getStr == "mock-exec: echo hi\n"
      check fx(@["exec", "vm1", "--", "true"], [("VMH_MOCK_FAIL", "exec")])[0] == 5
      check fx(@["delete_vm", "vm1"])[0] == 0
      check fx(@["get_vm", "vm1"])[0] == 3

  removeDir(work)
