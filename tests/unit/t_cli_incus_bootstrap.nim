# SPDX-FileCopyrightText: 2026 Metacraft Labs / Schelling Point Labs
# SPDX-License-Identifier: Apache-2.0
## t_cli_incus_bootstrap — incus ephemeral bootstrap exec-injection.
##
## Proves that the incus ephemeral path, when given a runner BOOTSTRAP payload
## (``--user-data``), delivers it into the guest and launches it DETACHED via
## ``incus exec`` AFTER launch + readiness — instead of relying on cloud-init,
## which incus does not drive (its guest API is on ``/dev/incus/sock`` while a
## golden's cloud-init probes ``/dev/lxd/sock``). See
## ``src/vm_harness/backends/incus.nim`` (``injectAndRunBootstrap``).
##
## MOCK JUSTIFICATION: this test uses the same hermetic seam as the sibling
## ``t_cli_incus`` — a FAKE ``incus`` shell script installed via the
## ``VMH_INCUS_CMD`` command-vector env seam. The fake logs the exact argv of
## every invocation and answers the two calls the flow depends on (existence
## probe → "absent", readiness/state → "RUNNING"). No real Incus daemon,
## container, or network is touched. This is the most hermetic level the
## backend's command-vector seam supports and lets the test assert precisely
## (a) delivery, (b) detached launch, (c) that the token never hits the argv —
## which a real-Incus e2e gate (``t_incus_linux_jit_boot``) cannot inspect.
##
## The test FAILS without the exec-injection change: the old ``--keep`` path
## returned right after launch (no ``setsid`` in the log, no readiness poll)
## and wrote the payload — token and all — onto the ``incus config set
## cloud-init.user-data <payload>`` command line (so the token appeared in the
## argv log). Both are asserted against here.

import std/[os, strutils, tempfiles, unittest]
import vm_harness/cli

suite "CLI Incus bootstrap exec-injection":
  test "ephemeral --keep delivers the bootstrap on stdin and execs it detached":
    when defined(linux):
      let work = createTempDir("vmh-cli-incus-boot", "")
      defer: removeDir(work)
      let logPath = work / "incus-argv.log"
      let fakeIncus = work / "incus"
      let payloadFile = work / "user-data.sh"
      # A stand-in GARM-style bootstrap: a directly-executable #!/bin/bash
      # script carrying a registration token. Neither the token nor the body
      # may leak onto any incus command line.
      const SecretToken = "BEARER-TOKEN-super-secret-do-not-log-4242"
      writeFile(payloadFile,
        "#!/bin/bash\nset -ex\n" &
        "export BEARER_TOKEN=" & SecretToken & "\n" &
        "export METADATA_URL=http://example/meta\n" &
        "./config.sh --unattended\n./run.sh\n")

      # Fake incus: log the argv of every call; report the per-job container as
      # ABSENT (info -> non-zero) so provisionEphemeralClone proceeds, and
      # report state RUNNING so startAndAwaitReady returns. Everything else
      # (launch, exec deliver, exec setsid launch) succeeds with exit 0.
      writeFile(fakeIncus,
        "#!/bin/sh\n" &
        "printf '%s\\n' \"$*\" >> '" & logPath & "'\n" &
        "case \"$*\" in\n" &
        "  'info '*) exit 1 ;;\n" &
        "  *'--format csv -c s') printf 'RUNNING\\n'; exit 0 ;;\n" &
        "  *) exit 0 ;;\n" &
        "esac\n")
      setFilePermissions(fakeIncus, {fpUserRead, fpUserWrite, fpUserExec})

      let previous = getEnv("VMH_INCUS_CMD")
      putEnv("VMH_INCUS_CMD", fakeIncus)
      defer: putEnv("VMH_INCUS_CMD", previous)

      let rc = runCli(@[
        "run", "--ephemeral", "--backend", "incus", "--keep",
        "--baseline", "vmh-boot-test",
        "--base-image", "vmh-base",
        "--user-data", payloadFile])
      check rc == 0

      let argv = readFile(logPath)
      let lines = argv.splitLines()

      # (a) the container was launched from the base image.
      check "launch vmh-base vmh-boot-test" in lines
      # readiness was awaited before injecting (state poll + exec true).
      check "list vmh-boot-test --format csv -c s" in lines
      check "exec vmh-boot-test -- true" in lines
      # (b) the payload was delivered via an in-guest `cat` fed on STDIN — the
      #     argv carries the sh -c wrapper + guest path, NOT the payload.
      check argv.contains("exec vmh-boot-test -- sh -c umask 077 && cat > " &
                          "'/root/garm-bootstrap.sh'")
      # (b2) the guest NETWORK was gated before the bootstrap launched: a
      #      default-route + DNS probe runs, so the script never fires its first
      #      curl before DHCP/resolv are up (the "HTTP 000000"/exit-7 race).
      check argv.contains("ip route")
      check argv.contains("getent hosts github.com")
      # (c) it was exec'd DETACHED via setsid --fork, redirected to a guest log.
      check argv.contains("setsid --fork bash -lc '/root/garm-bootstrap.sh'")
      check "garm-bootstrap.sh" in argv
      # (d) the create call RETURNED (rc == 0, asserted above) without waiting
      #     on the runner: run.sh is never invoked on the host and the payload
      #     body is absent from the argv log.
      check "run.sh" notin argv
      check "config.sh" notin argv
      # (e) the TOKEN never reached any command line / the backend's log, and
      #     cloud-init.user-data is no longer set (the old leak path).
      check SecretToken notin argv
      check "cloud-init.user-data" notin argv
    else:
      skip()
