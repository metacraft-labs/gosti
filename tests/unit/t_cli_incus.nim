import std/[os, strutils, tempfiles, unittest]
import vm_harness/cli

suite "CLI Incus lifecycle":
  test "nested capability flags parse only for ephemeral Incus runs":
    let both = parseCliOpts(@[
      "run", "--ephemeral", "--backend", "incus",
      "--incus-security-nesting", "--incus-nested-kvm",
      "--baseline", "runner-1", "--", "true",
    ])
    check both.incusSecurityNesting
    check both.incusNestedKvm

    let kvmOnly = parseCliOpts(@[
      "run", "--ephemeral", "--backend", "incus",
      "--incus-nested-kvm", "--baseline", "runner-2", "--", "true",
    ])
    check not kvmOnly.incusSecurityNesting
    check kvmOnly.incusNestedKvm

    for invalid in [
      @["run", "--backend", "incus", "--incus-nested-kvm"],
      @["run", "--ephemeral", "--backend", "libvirt",
        "--incus-nested-kvm"],
      @["provision", "--backend", "incus", "--incus-security-nesting"],
      @["run", "--ephemeral", "--backend", "auto",
        "--incus-security-nesting"],
    ]:
      expect ValueError:
        discard parseCliOpts(invalid)

  test "privileged Incus CLI path keeps the configured container running":
    when defined(linux):
      let work = createTempDir("vmh-cli-incus-capability", "")
      defer: removeDir(work)
      let logPath = work / "incus.log"
      let fakeIncus = work / "incus"
      writeFile(fakeIncus,
        "#!/bin/sh\n" &
        "printf '%s\\n' \"$*\" >> '" & logPath & "'\n" &
        "case \"$*\" in\n" &
        "  'info runner-cap') exit 1 ;;\n" &
        "  'exec runner-cap -- stat -c %a /dev/kvm') printf '666\\n' ;;\n" &
        "esac\n")
      setFilePermissions(fakeIncus, {fpUserRead, fpUserWrite, fpUserExec})

      let previous = getEnv("VMH_INCUS_CMD")
      putEnv("VMH_INCUS_CMD", fakeIncus)
      defer: putEnv("VMH_INCUS_CMD", previous)

      check runCli(@[
        "run", "--ephemeral", "--backend", "incus",
        "--baseline", "runner-cap", "--base-image", "runner-base",
        "--incus-security-nesting", "--incus-nested-kvm", "--keep",
      ]) == 0
      let lines = readFile(logPath).splitLines()
      check "init runner-base runner-cap" in lines
      check "launch runner-base runner-cap" notin lines
      check "start runner-cap" in lines
      check "exec runner-cap -- chmod 0666 /dev/kvm" in lines
      check "exec runner-cap -- stat -c %a /dev/kvm" in lines
      check "exec runner-cap -- sh -c exec 3<>/dev/kvm" in lines
      check "delete --force runner-cap" notin lines
    else:
      skip()

  test "ephemeral-destroy delegates only the named container to Incus":
    when defined(linux):
      let work = createTempDir("vmh-cli-incus", "")
      defer: removeDir(work)
      let logPath = work / "incus.log"
      let fakeIncus = work / "incus"
      writeFile(fakeIncus,
        "#!/bin/sh\n" &
        "printf '%s\\n' \"$*\" >> '" & logPath & "'\n")
      setFilePermissions(fakeIncus, {fpUserRead, fpUserWrite, fpUserExec})

      let previous = getEnv("VMH_INCUS_CMD")
      putEnv("VMH_INCUS_CMD", fakeIncus)
      defer: putEnv("VMH_INCUS_CMD", previous)

      check runCli(@[
        "ephemeral-destroy",
        "--backend", "incus",
        "--baseline", "reproos-only-this",
      ]) == 0
      check readFile(logPath).strip() ==
        "delete --force reproos-only-this"
    else:
      skip()

  test "instance operations use typed Incus backend methods":
    when defined(linux):
      let work = createTempDir("vmh-cli-incus-instance", "")
      defer: removeDir(work)
      let logPath = work / "incus.log"
      let statePath = work / "state"
      let fakeIncus = work / "incus"
      let sourcePath = work / "source.txt"
      let pulledPath = work / "pulled.txt"
      writeFile(statePath, "STOPPED\n")
      writeFile(sourcePath, "payload\n")
      writeFile(fakeIncus,
        "#!/bin/sh\n" &
        "printf '%s\\n' \"$*\" >> '" & logPath & "'\n" &
        "case \"$*\" in\n" &
        "  'list reproos-instance --format csv -c s') cat '" & statePath & "' ;;\n" &
        "  'start reproos-instance') printf 'RUNNING\\n' > '" & statePath & "' ;;\n" &
        "  'stop --force reproos-instance') printf 'STOPPED\\n' > '" & statePath & "' ;;\n" &
        "  'exec reproos-instance -- /bin/echo contract') printf 'contract\\n' ;;\n" &
        "esac\n")
      setFilePermissions(fakeIncus, {fpUserRead, fpUserWrite, fpUserExec})

      let previous = getEnv("VMH_INCUS_CMD")
      putEnv("VMH_INCUS_CMD", fakeIncus)
      defer: putEnv("VMH_INCUS_CMD", previous)

      check runCli(@["instance", "start", "--backend", "incus",
                     "reproos-instance"]) == 0
      check runCli(@["instance", "wait", "--backend", "incus",
                     "reproos-instance"]) == 0
      check runCli(@["instance", "exec", "--backend", "incus",
                     "reproos-instance", "--", "/bin/echo", "contract"]) == 0
      check runCli(@["instance", "copy-to", "--backend", "incus",
                     "reproos-instance", sourcePath, "/tmp/source.txt"]) == 0
      check runCli(@["instance", "copy-from", "--backend", "incus",
                     "reproos-instance", "/tmp/result.txt", pulledPath]) == 0
      check runCli(@["instance", "stop", "--backend", "incus",
                     "reproos-instance"]) == 0

      let lines = readFile(logPath).splitLines()
      for expected in [
        "start reproos-instance",
        "exec reproos-instance -- true",
        "exec reproos-instance -- /bin/echo contract",
        "file push " & sourcePath & " reproos-instance/tmp/source.txt",
        "file pull -r reproos-instance/tmp/result.txt " & pulledPath,
        "stop --force reproos-instance",
      ]:
        check expected in lines
    else:
      skip()
