# SPDX-FileCopyrightText: 2026 Metacraft Labs / Schelling Point Labs
# SPDX-License-Identifier: Apache-2.0
## One QMP command on a QEMU monitor socket.
##
## Shared by every QEMU backend that publishes a ``-qmp`` socket: the
## Windows-on-ARM per-job boot (its reboot lifecycle, ``set-action``) and
## the generic ``qemu-boot`` backend (``system_reset``, the hard reset a
## crash-consistency gate needs). QMP rather than HMP because it is a
## framed, negotiated protocol whose replies can be recognised; see
## https://www.qemu.org/docs/master/interop/qmp-spec.html.

import std/[json, net, os, times]

proc socketPresent(path: string): bool =
  ## Any inode at ``path``: ``os.fileExists`` is ``S_ISREG`` and reports a
  ## unix-domain socket as absent.
  try:
    discard getFileInfo(path, followSymlink = false)
    true
  except OSError:
    false

const
  DefaultQmpTimeoutMs* = 4_000
    ## How long one command may take, greeting and negotiation included.

proc qmpCommand*(qmpPath, command: string, arguments: JsonNode = nil,
                 timeoutMs: int = DefaultQmpTimeoutMs):
                 tuple[ok: bool, detail: string] =
  ## Run ONE QMP command on ``qmpPath`` and report whether QEMU accepted it.
  ##
  ## Deliberately NOT modelled on ``queryQemuMonitor``, because QMP is not
  ## HMP and the differences are the whole reason this exists:
  ##
  ## * every message is one newline-terminated JSON object, so a reply is
  ##   recognisable rather than guessed at from a prompt with no newline;
  ## * the connection opens with a greeting and REFUSES every command until
  ##   ``qmp_capabilities`` has been executed, so the negotiation is not
  ##   optional politeness;
  ## * asynchronous EVENTS share the stream and can arrive between a command
  ##   and its reply, so anything carrying an ``event`` key is skipped rather
  ##   than mistaken for the answer.
  ##
  ## A failure is returned, never raised, and ``detail`` says which step
  ## failed — the caller's decision is a lifecycle one (see
  ## ``QwaOneShotRebootAction``) and it needs the reason in its own message.
  when defined(posix):
    if qmpPath.len == 0 or not socketPresent(qmpPath):
      return (ok: false, detail: "no QMP socket at " & qmpPath &
              " (QEMU publishes one only for the per-job boot; an instance " &
              "started by an older harness has none)")
    var sock: Socket
    try:
      sock = newSocket(net.Domain.AF_UNIX, net.SockType.SOCK_STREAM,
                       net.Protocol.IPPROTO_IP)
    except CatchableError as e:
      return (ok: false, detail: "cannot create a unix socket: " & e.msg)
    try:
      sock.connectUnix(qmpPath)
    except CatchableError as e:
      try: sock.close()
      except CatchableError: discard
      return (ok: false, detail: "cannot connect to " & qmpPath & ": " & e.msg)
    defer:
      try: sock.close()
      except CatchableError: discard

    let deadline = epochTime() + timeoutMs.float / 1000.0
    proc nextMessage(): JsonNode =
      ## The next JSON object that is not an asynchronous event, or nil.
      while epochTime() < deadline:
        var line = ""
        let remainingMs = max(1, int((deadline - epochTime()) * 1000.0))
        try:
          sock.readLine(line, timeout = remainingMs)
        except CatchableError:
          return nil
        if line.len == 0:
          return nil          # the peer went away
        var parsed: JsonNode
        try:
          parsed = parseJson(line)
        except CatchableError:
          continue
        if parsed.kind == JObject and parsed.hasKey("event"):
          continue
        return parsed
      nil

    try:
      let greeting = nextMessage()
      if greeting.isNil or not greeting.hasKey("QMP"):
        return (ok: false, detail: qmpPath & " did not send a QMP greeting")
      sock.send($(%*{"execute": "qmp_capabilities"}) & "\n")
      let negotiated = nextMessage()
      if negotiated.isNil or not negotiated.hasKey("return"):
        return (ok: false, detail: "qmp_capabilities was not accepted on " &
                qmpPath & ": " &
                (if negotiated.isNil: "no reply" else: $negotiated))
      var request = %*{"execute": command}
      if not arguments.isNil:
        request["arguments"] = arguments
      sock.send($request & "\n")
      let reply = nextMessage()
      if reply.isNil:
        return (ok: false, detail: command & " got no reply on " & qmpPath)
      if reply.hasKey("error"):
        return (ok: false, detail: command & " was refused: " & $reply["error"])
      if not reply.hasKey("return"):
        return (ok: false, detail: command & " got an unrecognised reply: " &
                $reply)
      return (ok: true, detail: $reply)
    except CatchableError as e:
      return (ok: false, detail: command & " on " & qmpPath & " failed: " &
              e.msg)
  else:
    (ok: false, detail: "QMP requires a POSIX host")
