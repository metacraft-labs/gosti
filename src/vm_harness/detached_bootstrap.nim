# SPDX-FileCopyrightText: 2026 Metacraft Labs / Schelling Point Labs
# SPDX-License-Identifier: Apache-2.0
## Starting a guest-side script so that it OUTLIVES the SSH session that
## starts it, and following it afterwards through short, independent sessions.
##
## Two callers:
##  * `run --ephemeral --keep` (the central GARM's remote provider) launches
##    the runner bootstrap and returns; the guest is left running.
##  * `run --detach-script <path>` (the per-host GARM's local provider) launches
##    the bootstrap the same way and then WAITS for it by polling, so the
##    `vm-harness run` process still anchors the instance's life — but no single
##    SSH connection does. Before this, the bootstrap ran in the foreground of
##    one SSH session for the whole job; a single stalled connection
##    ("Read from remote host …: Operation timed out") SIGHUPed the runner
##    mid-job and the run's cleanup then deleted the guest under it.

import std/[os, strutils, tables, times]
import ./types
import ./backends/qemu_windows_arm

proc buildDetachedBootstrapCommand*(guest: GuestOs, guestPath: string): seq[string] =
  ## Start the injected bootstrap so it OUTLIVES the session that starts it.
  ##
  ## This is the whole difference between the local and remote models. Locally
  ## the provider runs the bootstrap in the FOREGROUND and keeps the
  ## `vm-harness run` process alive for the instance's life, so the runner
  ## agent it spawns is anchored to that process. `run --ephemeral --keep`
  ## returns immediately, so the bootstrap must be detached in the GUEST or the
  ## runner dies with the SSH session that launched it.
  ##
  ## On Windows that means `Win32_Process.Create`, NOT `Start-Process`, and the
  ## reason is measured rather than assumed: Windows OpenSSH puts every process
  ## of a session into a job object and kills the job at session end, and a
  ## `Start-Process` child stays inside it. The same finding — and the same
  ## `$`-free constraint, because sshd's DefaultShell is powershell and an
  ## OUTER parse expands `$` inside double quotes — is recorded at length on
  ## `buildSysprepRemoteCommand`, which solved this first for sysprep.
  case guest
  of goWindows:
    @["powershell.exe", "-NoLogo", "-NoProfile", "-Command",
      "if ((Invoke-CimMethod -ClassName Win32_Process -MethodName Create " &
      "-Arguments @{CommandLine = " &
      powershellLiteral("powershell.exe -ExecutionPolicy Bypass -NoProfile -File " &
                        guestPath) &
      "}).ReturnValue -ne 0) { exit 1 }; exit 0"]
  else:
    # `nohup … &` detaches from the SSH session and survives its hangup. All
    # three streams of the BACKGROUNDED process must be redirected: anything
    # still holding the session's stdout keeps the SSH channel open, and
    # `execInGuest` then blocks for the runner's entire life.
    #
    # The `&` must apply to a SIMPLE command, never to a list. The previous
    # form was `chmod +x P && nohup P >/dev/null … & echo started`, and `&`
    # binds looser than `&&`, so what went to the background was the SUBSHELL
    # `(chmod && nohup P …)`. The redirections belonged to the inner `nohup`
    # only; the subshell itself kept the SSH session's stdout open and waited
    # for the bootstrap. dash happens to exec the last command of such a
    # subshell (so Ubuntu tart-linux-arm guests escaped), but bash — macOS's
    # `/bin/sh` — forks it, so on every tart-macos guest the launch SSH never
    # returned. At the exec timeout (600s) `timeout` killed it, the launch was
    # reported as failed, and the error path DESTROYED the guest under a
    # runner that had long since registered and taken a job: every macOS job
    # longer than ~10 minutes died with "lost communication with the server".
    #
    # The bootstrap's own output goes to `<path>.log` and its exit status to
    # `<path>.exit` (written by a wrapper shell, since the bootstrap is not
    # our child once we return), so `buildBootstrapStatusCommand` can check
    # readiness in a SEPARATE, short session.
    let q = quoteShellPosix(guestPath)
    let logQ = quoteShellPosix(guestPath & ".log")
    let exitQ = quoteShellPosix(guestPath & ".exit")
    let pidQ = quoteShellPosix(guestPath & ".pid")
    let wrapper = q & "; echo $? > " & exitQ
    @["/bin/sh", "-c",
      "chmod +x " & q & " || exit 1; rm -f " & exitQ & " " & pidQ & "; " &
      "nohup /bin/sh -c " & quoteShellPosix(wrapper) &
      " </dev/null >" & logQ & " 2>&1 & " &
      "echo $! > " & pidQ & "; echo started"]

const BootstrapRunning* = "bootstrap: running"
const BootstrapExitedOk* = "bootstrap: exited 0"
const BootstrapFailedPrefix* = "bootstrap: exited "

proc buildBootstrapStatusCommand*(guestPath: string): seq[string] =
  ## Readiness probe for a bootstrap started by `buildDetachedBootstrapCommand`
  ## (unix guests). Runs in its own short SSH session, so the launch itself
  ## never has to wait on the bootstrap. Prints exactly one of
  ## `BootstrapRunning`, `BootstrapExitedOk`, or `BootstrapFailedPrefix<code>`
  ## followed by the tail of the bootstrap log; exits non-zero only for a
  ## bootstrap that already failed or never started.
  let logQ = quoteShellPosix(guestPath & ".log")
  let exitQ = quoteShellPosix(guestPath & ".exit")
  let pidQ = quoteShellPosix(guestPath & ".pid")
  @["/bin/sh", "-c",
    "if [ -s " & exitQ & " ]; then c=$(cat " & exitQ & "); " &
    "if [ \"$c\" = 0 ]; then echo '" & BootstrapExitedOk & "'; exit 0; fi; " &
    "echo \"" & BootstrapFailedPrefix & "$c\"; tail -n 20 " & logQ &
    " 2>/dev/null; exit 1; fi; " &
    "p=$(cat " & pidQ & " 2>/dev/null); " &
    "if [ -n \"$p\" ] && kill -0 \"$p\" 2>/dev/null; then echo '" &
    BootstrapRunning & "'; exit 0; fi; " &
    # Lost the race between the wrapper exiting and the status file landing.
    "sleep 1; if [ -s " & exitQ & " ] && [ \"$(cat " & exitQ & ")\" = 0 ]; " &
    "then echo '" & BootstrapExitedOk & "'; exit 0; fi; " &
    "echo 'bootstrap: not running'; tail -n 20 " & logQ & " 2>/dev/null; exit 1"]

const BootstrapLaunchTimeoutSec* = 120
  ## The launch returns as soon as the bootstrap is backgrounded, so it needs
  ## seconds, not the ready-timeout. Bounding it separately means a launch
  ## that DOES hang fails fast at provision time, before any runner exists,
  ## instead of ten minutes later under a running job.


type
  DetachedState* = enum
    dsRunning      ## the script is still running
    dsExited       ## the script finished; `exitCode` holds its status
    dsVanished     ## no pid alive and no exit status: killed, or never ran
    dsUnreachable  ## the probe itself failed (SSH down, guest stalled)

proc classifyBootstrapStatus*(probe: ExecResult): tuple[state: DetachedState,
                                                        exitCode: int] =
  ## Interpret one run of `buildBootstrapStatusCommand`. Only the probe's
  ## OUTPUT decides the script's state; an exit code without one of the
  ## sentinel lines means the probe never ran (SSH exits 255, a local timeout
  ## gives -1/124), which is "unreachable", never "failed".
  let o = probe.stdout & probe.stderr
  if BootstrapRunning in o: return (dsRunning, 0)
  if BootstrapExitedOk in o: return (dsExited, 0)
  let i = o.find(BootstrapFailedPrefix)
  if i >= 0:
    var j = i + BootstrapFailedPrefix.len
    var digits = ""
    while j < o.len and o[j] in {'0'..'9'}:
      digits.add(o[j]); inc j
    if digits.len > 0:
      return (dsExited, parseInt(digits))
  if "bootstrap: not running" in o: return (dsVanished, -1)
  (dsUnreachable, -1)

proc runDetachedScript*(backend: VmBackend, vm: VmHandle, guest: GuestOs,
                        guestPath: string, timeoutSec: int,
                        pollSec = 15, unreachableGraceSec = 900): ExecResult =
  ## Launch `guestPath` detached, then follow it to completion.
  ##
  ## Returns the script's own exit status. A probe that cannot reach the guest
  ## is retried until `unreachableGraceSec` of CONSECUTIVE failures — a guest
  ## that is merely busy (a heavy build starving sshd, a transient network
  ## stall) keeps its job; one that is gone for good still ends the run.
  if guest == goWindows:
    raise newException(ValueError,
      "--detach-script is supported for linux and macOS guests only")
  let start = epochTime()
  let launch = backend.execInGuest(vm, initTable[string, string](),
                                   buildDetachedBootstrapCommand(guest, guestPath),
                                   timeoutSec = BootstrapLaunchTimeoutSec)
  if launch.exitCode != 0:
    return ExecResult(exitCode: (if launch.exitCode == 0: 1 else: launch.exitCode),
                      stdout: launch.stdout,
                      stderr: launch.stderr & "\ndetached launch failed",
                      elapsedMs: int((epochTime() - start) * 1000))
  let deadline = if timeoutSec > 0: start + timeoutSec.float else: 0.0
  var unreachableSince = 0.0
  var lastOut = ""
  while true:
    sleep(pollSec * 1000)
    let probe = backend.execInGuest(vm, initTable[string, string](),
                                    buildBootstrapStatusCommand(guestPath),
                                    timeoutSec = 60)
    let (state, code) = classifyBootstrapStatus(probe)
    let now = epochTime()
    case state
    of dsRunning:
      unreachableSince = 0.0
    of dsExited:
      return ExecResult(exitCode: code, stdout: probe.stdout,
                        stderr: probe.stderr,
                        elapsedMs: int((now - start) * 1000))
    of dsVanished:
      return ExecResult(exitCode: 1, stdout: probe.stdout,
                        stderr: "detached script is no longer running and " &
                                "left no exit status",
                        elapsedMs: int((now - start) * 1000))
    of dsUnreachable:
      lastOut = (probe.stdout & probe.stderr).strip()
      if unreachableSince == 0.0: unreachableSince = now
      if now - unreachableSince >= unreachableGraceSec.float:
        return ExecResult(exitCode: 255, stdout: "",
                          stderr: "guest unreachable for " &
                                  $int(now - unreachableSince) & "s: " & lastOut,
                          elapsedMs: int((now - start) * 1000))
    if deadline > 0.0 and now > deadline:
      return ExecResult(exitCode: 124, stdout: "",
                        stderr: "detached script still running after " &
                                $timeoutSec & "s",
                        elapsedMs: int((now - start) * 1000))
