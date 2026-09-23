## t_ephemeral_inventory — `ephemeral-list` and the verified incus teardown.
##
## Gates the two vm-harness halves of the GARM instance-lifecycle fix:
##
##   (A) `ephemeral-list` makes `run --ephemeral --keep` instances VISIBLE, and
##       fails CLOSED. The remote GARM provider answered ListInstances with an
##       empty list because nothing could enumerate kept instances; GARM read
##       that as "the provider lost them", deleted the rows, never called
##       DeleteInstance, and ~210 Windows libvirt domains leaked on
##       high-mem-server. So the property is two-sided: a kept instance is
##       listed with its state, AND a backend that cannot be enumerated yields
##       a non-zero exit with no result line — never an empty list.
##
##   (A') a pool's list contains ONLY that pool's instances. GARM's scale-set
##       worker DELETES every listed instance it has no record of, so a
##       host-wide answer would let one pool destroy another's runners. The
##       `ephemeral-label` record + `--label` filter is gated here: attributed
##       instances match, unattributed ones and stale records never do, and a
##       successful destroy drops the record.
##
##   (B) `ephemeral-destroy --backend incus` no longer reports success for a
##       container that still exists. `incus delete` failing transiently with
##       ZFS `dataset is busy` (measured on gpu-server-001) is retried with
##       backoff; a container that outlives the budget makes the verb exit
##       non-zero; an absent container is still success; and an incus that
##       cannot answer is a failure, not "already gone".
##
## MOCK JUSTIFICATION (required by the workspace test policy). `incus` and
## `virsh` are replaced by small shell scripts on the backend's own command
## seam (`VMH_INCUS_CMD`, and `virsh` resolved through PATH). This is the
## established pattern of t_cli_incus.nim. It is necessary because the failure
## being gated — a ZFS destroy that is transiently busy under load, and an
## incus/libvirt daemon that is unreachable — cannot be produced on demand on
## a real host, and the deterministic catalog must not require a hypervisor.
## Everything above the tool boundary is real: the CLI dispatcher, the
## backend code, the retry loop, the result-line encoding. The fakes are
## STATEFUL (a file of existing containers) so "the container is really gone
## afterwards" is checked, not assumed.

import std/[os, strutils, tables, tempfiles, unittest]
import vm_harness/cli
import vm_harness/ephemeral_inventory
import vm_harness/backends/incus

proc writeExe(path, body: string) =
  writeFile(path, body)
  setFilePermissions(path, {fpUserRead, fpUserWrite, fpUserExec})

proc fakeIncus(work: string; busyDeletes: int; listFails = false): string =
  ## A stateful fake incus. `<work>/containers` holds `name,STATE` rows.
  ## `delete --force <n>` fails with the measured ZFS message `busyDeletes`
  ## times (counted in `<work>/busy`), then removes the row.
  let exe = work / "incus"
  writeFile(work / "busy", $busyDeletes)
  writeExe(exe, "#!/bin/sh\n" &
    "W='" & work & "'\n" &
    "echo \"$*\" >> \"$W/log\"\n" &
    "case \"$1\" in\n" &
    "  list)\n" &
    (if listFails: "    echo 'Error: failed to connect to the incus daemon' >&2; exit 1 ;;\n"
     else: "    cat \"$W/containers\"; exit 0 ;;\n") &
    "  delete)\n" &
    "    n=$(cat \"$W/busy\")\n" &
    "    if [ \"$n\" -gt 0 ]; then\n" &
    "      echo $((n-1)) > \"$W/busy\"\n" &
    "      echo \"Error: Failed deleting instance \\\"$3\\\": zfs destroy -r zfs_root/containers/$3: dataset is busy\" >&2\n" &
    "      exit 1\n" &
    "    fi\n" &
    "    grep -v \"^$3,\" \"$W/containers\" > \"$W/c.tmp\"; mv \"$W/c.tmp\" \"$W/containers\"; exit 0 ;;\n" &
    "esac\n" &
    "exit 0\n")
  exe

proc deleteAttempts(work: string): int =
  if not fileExists(work / "log"): return 0
  for l in readFile(work / "log").splitLines():
    if l.startsWith("delete --force"): inc result

template withEnv(key, value: string; body: untyped) =
  let previous = getEnv(key)
  let had = existsEnv(key)
  putEnv(key, value)
  try:
    body
  finally:
    if had: putEnv(key, previous) else: delEnv(key)

suite "ephemeral inventory: value logic":
  test "incus csv rows map onto GARM states":
    let e = parseIncusListCsv("garm-a,RUNNING\ngarm-b,STOPPED\n" &
                              "garm-c,FROZEN\ngarm-d,ERROR\ngarm-e,WEIRD\n")
    check e.len == 5
    check e[0] == EphemeralEntry(name: "garm-a", state: "running")
    check e[1].state == "stopped"
    check e[2].state == "running"   # frozen still exists and holds its runner
    check e[3].state == "error"
    check e[4].state == "unknown"

  test "a malformed incus row is an error, not a silently shorter list":
    expect ValueError:
      discard parseIncusListCsv("garm-a,RUNNING\nnonsense\n")

  test "libvirt: defined-but-inactive is stopped, active is running":
    let e = libvirtEntries(@["garm-a", "garm-b", "other vm"], @["garm-a"])
    check e == @[EphemeralEntry(name: "garm-a", state: "running"),
                 EphemeralEntry(name: "garm-b", state: "stopped"),
                 EphemeralEntry(name: "other vm", state: "stopped")]

  test "filters: exact name and prefix":
    let e = @[EphemeralEntry(name: "garm-a", state: "running"),
              EphemeralEntry(name: "garm-ab", state: "running"),
              EphemeralEntry(name: "keep-me", state: "stopped")]
    check filterEntries(e, name = "garm-a").len == 1
    check filterEntries(e, prefix = "garm-").len == 2
    check filterEntries(e).len == 3

  test "result line round-trips, and an empty list is still a result":
    let line = inventoryLine("libvirt",
      @[EphemeralEntry(name: "garm-x", state: "running")])
    check "\n" notin line
    check InventoryMarker in line
    let back = parseInventoryLine(line)
    check back.ok
    check back.entries == @[EphemeralEntry(name: "garm-x", state: "running")]
    check parseInventoryLine(inventoryLine("incus", @[])).entries.len == 0
    expect ValueError:
      discard parseInventoryLine("""{"v":"1","type":"log"}""")

  test "busy-family delete failures are classified transient":
    check isTransientIncusDeleteError(
      "Error: zfs destroy -r zfs_root/root/var/lib/incus-storage/containers/garm-x: dataset is busy")
    check isTransientIncusDeleteError("umount: target is busy (Device or resource busy)")
    check not isTransientIncusDeleteError("Error: Instance not found")

when defined(linux):
  suite "ephemeral-list (CLI)":
    test "incus: kept containers are listed with their state":
      let work = createTempDir("vmh-eph-list-incus", "")
      defer: removeDir(work)
      writeFile(work / "containers", "garm-a,RUNNING\ngarm-b,STOPPED\n")
      withEnv("VMH_INCUS_CMD", fakeIncus(work, 0)):
        let inv = ephemeralInventoryFor("incus")
        check inv.ok
        check inv.entries == @[EphemeralEntry(name: "garm-a", state: "running"),
                               EphemeralEntry(name: "garm-b", state: "stopped")]
        check runCli(@["ephemeral-list", "--backend", "incus"]) == 0

    test "incus: an unreachable daemon FAILS the verb instead of listing nothing":
      let work = createTempDir("vmh-eph-list-incus-down", "")
      defer: removeDir(work)
      writeFile(work / "containers", "garm-a,RUNNING\n")
      withEnv("VMH_INCUS_CMD", fakeIncus(work, 0, listFails = true)):
        let inv = ephemeralInventoryFor("incus")
        check not inv.ok
        check inv.entries.len == 0
        check runCli(@["ephemeral-list", "--backend", "incus"]) != 0

    test "libvirt: ephemeral domains are visible, and virsh failure fails closed":
      let work = createTempDir("vmh-eph-list-libvirt", "")
      defer: removeDir(work)
      # `virsh --connect <uri> list [--all] --name`
      writeExe(work / "virsh", "#!/bin/sh\n" &
        "if [ -f '" & work & "/down' ]; then echo 'error: failed to connect to the hypervisor' >&2; exit 1; fi\n" &
        "case \"$*\" in\n" &
        "  *'list --all --name'*) printf 'garm-qglasrc9bvey\\ngarm-stopped\\n\\n' ;;\n" &
        "  *'list --name'*) printf 'garm-qglasrc9bvey\\n\\n' ;;\n" &
        "esac\n")
      withEnv("PATH", work & ":" & getEnv("PATH")):
        let inv = ephemeralInventoryFor("libvirt")
        check inv.ok
        check inv.entries == @[
          EphemeralEntry(name: "garm-qglasrc9bvey", state: "running"),
          EphemeralEntry(name: "garm-stopped", state: "stopped")]
        writeFile(work / "down", "")
        let down = ephemeralInventoryFor("libvirt")
        check not down.ok
        check runCli(@["ephemeral-list", "--backend", "libvirt"]) != 0

    test "vm-harness-run backends list their kept-instance records":
      let work = createTempDir("vmh-eph-list-vmrun", "")
      defer: removeDir(work)
      createDir(work / "tart-linux-arm")
      writeFile(work / "tart-linux-arm" / "garm-t1.json",
                """{"schema":"vm-harness/ephemeral-handle/1","baseline":"garm-t1"}""")
      withEnv("VMH_EPHEMERAL_STATE_DIR", work):
        let inv = ephemeralInventoryFor("tart-linux-arm")
        check inv.ok
        check inv.entries == @[EphemeralEntry(name: "garm-t1", state: "running")]
        check ephemeralInventoryFor("qemu-windows-arm").entries.len == 0

    test "a backend with no enumerator fails rather than answering empty":
      check not ephemeralInventoryFor("hyperv").ok
      check ephemeralInventoryFor("noop").ok

    test "noop teardown is a success without touching any hypervisor tool":
      # It used to fall into the libvirt branch and exit 1 without `virsh`.
      withEnv("PATH", "/nonexistent"):
        check runCli(@["ephemeral-destroy", "--backend", "noop",
                       "--baseline", "garm-noop"]) == 0

  suite "attribution labels":
    test "a pool sees only its own instances; stale and unlabelled never match":
      let work = createTempDir("vmh-eph-labels", "")
      defer: removeDir(work)
      writeFile(work / "containers",
        "garm-p1a,RUNNING\ngarm-p2a,RUNNING\ngarm-legacy,RUNNING\ndurable-vm,RUNNING\n")
      withEnv("VMH_EPHEMERAL_LABEL_DIR", work / "labels"):
        withEnv("VMH_INCUS_CMD", fakeIncus(work, 0)):
          check runCli(@["ephemeral-label", "--backend", "incus", "--baseline",
            "garm-p1a", "--label", "garm-pool=P1", "--label", "garm-controller=C"]) == 0
          check runCli(@["ephemeral-label", "--backend", "incus", "--baseline",
            "garm-p2a", "--label", "garm-pool=P2", "--label", "garm-controller=C"]) == 0
          # A record whose instance no longer exists must not resurrect it.
          check runCli(@["ephemeral-label", "--backend", "incus", "--baseline",
            "garm-gone", "--label", "garm-pool=P1"]) == 0

          var all = ephemeralInventoryFor("incus").entries
          attachLabels("incus", all)
          let p1 = filterEntries(all, labels = @["garm-pool=P1"])
          check p1.len == 1
          check p1[0].name == "garm-p1a"
          check p1[0].labels["garm-controller"] == "C"
          check filterEntries(all, labels = @["garm-controller=C"]).len == 2
          check filterEntries(all, labels = @["garm-pool=P3"]).len == 0
          # the list line carries the labels to the provider
          check "garm-pool" in inventoryLine("incus", p1)

          check runCli(@["ephemeral-destroy", "--backend", "incus",
                         "--baseline", "garm-p1a"]) == 0
          check not fileExists(labelRecordPath("incus", "garm-p1a"))
          check fileExists(labelRecordPath("incus", "garm-p2a"))

    test "labels are validated as a usage error":
      check runCli(@["ephemeral-label", "--backend", "incus", "--baseline",
                     "x", "--label", "novalue"]) == 2
      expect ValueError:   # no --label: dispatch raises; the binary exits 2
        discard runCli(@["ephemeral-label", "--backend", "incus",
                         "--baseline", "x"])

  suite "ephemeral-destroy --backend incus (verified teardown)":
    test "a transiently busy delete is retried until the container is gone":
      let work = createTempDir("vmh-eph-destroy-busy", "")
      defer: removeDir(work)
      writeFile(work / "containers", "garm-busy,STOPPED\ngarm-other,RUNNING\n")
      withEnv("VMH_INCUS_CMD", fakeIncus(work, busyDeletes = 1)):
        check runCli(@["ephemeral-destroy", "--backend", "incus",
                       "--baseline", "garm-busy"]) == 0
      check deleteAttempts(work) == 2
      check readFile(work / "containers") == "garm-other,RUNNING\n"

    test "a container that outlives the budget is a FAILURE, not success":
      let work = createTempDir("vmh-eph-destroy-stuck", "")
      defer: removeDir(work)
      writeFile(work / "containers", "garm-stuck,STOPPED\n")
      withEnv("VMH_INCUS_CMD", fakeIncus(work, busyDeletes = 1000)):
        var slept: seq[int]
        let ib = IncusBackend(newIncusBackend(@[work / "incus"]))
        expect CatchableError:
          ib.destroyContainerVerified("garm-stuck", budgetSec = 60,
            sleeper = proc (ms: int) = slept.add(ms))
        # Exponential backoff, capped — not a hot loop against a busy pool.
        check slept.len >= 2
        check slept[0] == 2000
        check slept[1] == 4000
        for ms in slept: check ms <= 30_000
      check readFile(work / "containers") == "garm-stuck,STOPPED\n"

    test "an absent container is success without issuing a delete":
      let work = createTempDir("vmh-eph-destroy-absent", "")
      defer: removeDir(work)
      writeFile(work / "containers", "garm-other,RUNNING\n")
      withEnv("VMH_INCUS_CMD", fakeIncus(work, 0)):
        check runCli(@["ephemeral-destroy", "--backend", "incus",
                       "--baseline", "garm-gone"]) == 0
      check deleteAttempts(work) == 0

    test "an incus that cannot answer is not 'already gone'":
      let work = createTempDir("vmh-eph-destroy-down", "")
      defer: removeDir(work)
      writeFile(work / "containers", "garm-x,STOPPED\n")
      withEnv("VMH_INCUS_CMD", fakeIncus(work, 0, listFails = true)):
        let ib = IncusBackend(newIncusBackend(@[work / "incus"]))
        expect CatchableError:
          ib.destroyContainerVerified("garm-x", budgetSec = 5,
                                      sleeper = proc (ms: int) = discard)
