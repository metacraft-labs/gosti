# SPDX-FileCopyrightText: 2026 Metacraft Labs / Schelling Point Labs
# SPDX-License-Identifier: Apache-2.0
## Slice 3 (composable resource types): gosti authors three native
## reprobuild resource providers on slice 2's generic external-provider lane.
##
## Pins:
##   (a) importing `gosti/repro/resources` registers the three providers
##       + their attribute marshallers, and the marshallers round-trip attrs
##       by typeId;
##   (b) the typed wrappers build a small dependency graph
##       container -> exec -> snapshot with the right topological order;
##   (c) against REAL incus (when usable) `reconcileResources` launches the
##       container, runs the exec (a marker file appears), and takes the
##       snapshot in dependsOn order — then everything is torn down with a
##       residue check. When incus is unusable the on-incus half is skipped
##       but registration + graph construction + topo order are still pinned.
##
## Throwaway container/snapshot/image names embed the PID so a stray run can
## never collide with live garm/k3s/nomad containers or the `gosti-base` image.

import std/[os, options, tables, strutils, unittest, osproc]

import repro_resources
import repro_project_dsl

import gosti/repro/resources as gosti
import gosti/backends/incus
import gosti/types            # VmHandle

# ---------------------------------------------------------------------------
# Throwaway, PID-tagged names.

let pid = getCurrentProcessId()
let containerName = "gosti-s3-c-" & $pid
let snapName = "s3snap-" & $pid
let publishAlias = "gosti-s3-img-" & $pid
let markerPath = "/opt/gosti-s3-mark-" & $pid

proc incusUsable(): bool =
  ## The real-incus half runs only when the backend can reach the daemon.
  let b = newIncusBackend()   # honours GOSTI_INCUS_CMD
  try: b.probeAvailability()
  except CatchableError: false

proc bestEffortTeardown() =
  ## Remove any residue this test could have created, regardless of where a
  ## failure landed. Never raises.
  let b = newIncusBackend()
  try: b.removeSnapshot(containerName, snapName)
  except CatchableError: discard
  try: discard b.deleteContainer(containerName)
  except CatchableError: discard
  try: discard b.runIncus(@["image", "delete", publishAlias], timeoutSec = 60)
  except CatchableError: discard

suite "slice 3: gosti native resource providers":

  test "importing the module registers all three providers":
    check isResourceProviderRegistered(gosti.TypeContainer)
    check isResourceProviderRegistered(gosti.TypeExec)
    check isResourceProviderRegistered(gosti.TypeSnapshot)
    # Determinism classes per the spec.
    check lookupResourceProvider(gosti.TypeContainer).determinism == rdVolatile
    check lookupResourceProvider(gosti.TypeExec).determinism == rdVolatile
    check lookupResourceProvider(gosti.TypeSnapshot).determinism == rdHostBound
    # Drivers are non-nil vtables.
    check lookupResourceProvider(gosti.TypeContainer).driver.apply != nil
    check lookupResourceProvider(gosti.TypeSnapshot).driver.observe != nil

  test "attribute marshallers round-trip by typeId":
    resetDesiredResources()
    let c = gosti.container("rt", baseImage = "gosti-base", profiles = @["p1"])
    discard gosti.exec("rt-exec", container = c.address,
                     run = @["sh", "-c", "true"], dependsOn = @[c.address])
    discard gosti.snapshot("rt-snap", container = c.address,
                         publishAlias = "img", dependsOn = @[c.address])
    for inst in collectedResources():
      let wire = marshalAttrs(inst.attrs)
      let back = unmarshalAttrs(inst.typeId, wire)
      check back.typeId == inst.typeId
    # Concretely check the container attrs survive the round-trip.
    let cInst = collectedResources()[0]
    let orig = TypedExtensionBox[gosti.ContainerAttrs](cInst.attrs).val
    let got = TypedExtensionBox[gosti.ContainerAttrs](
      unmarshalAttrs(cInst.typeId, marshalAttrs(cInst.attrs))).val
    check got == orig
    check got.baseImage == "gosti-base"
    check got.profiles == @["p1"]

  test "wrappers build a container -> exec -> snapshot graph in topo order":
    resetDesiredResources()
    let base = gosti.container(containerName, baseImage = "gosti-base",
                             profiles = @[])
    let touch = gosti.exec("touch", container = base.address,
                         run = @["sh", "-c", "touch " & markerPath],
                         dependsOn = @[base.address])
    discard gosti.snapshot(snapName, container = base.address,
                         publishAlias = "", dependsOn = @[touch.address])
    let desired = collectedResources()
    check desired.len == 3

    if not incusUsable():
      stderr.writeLine "  [slice3] incus unusable -> asserting graph/topo only"
      # No incus: a real reconcile can't run (drivers hit incus), so assert
      # the collected graph shape + edges here.
      check desired[0].address == containerName
      check desired[1].dependsOn == @[containerName]
      check desired[2].dependsOn == @["touch"]
      skip()
    else:
      stderr.writeLine "  [slice3] incus usable -> running real reconcile on " &
        containerName
      bestEffortTeardown()   # start from a clean slate
      let b = newIncusBackend()
      var ok = false
      try:
        let r = reconcileResources(desired)
        # Three creates, applied in dependency order.
        check r.actions.len == 3
        check r.actions[0].address == containerName   # container first
        check r.actions[1].address == "touch"          # then the exec
        check r.actions[2].address == snapName          # then the snapshot
        for act in r.actions:
          check act.kind == rakCreate

        # The container is live.
        check b.containerExists(containerName)
        # The exec ran: the marker file exists in the guest.
        let mark = b.execInGuest(
          VmHandle(name: containerName, extra: initTable[string, string]()),
          initTable[string, string](),
          @["test", "-f", markerPath])
        check mark.exitCode == 0
        # The snapshot was taken.
        check snapName in b.listSnapshots(containerName)
        ok = true
      finally:
        bestEffortTeardown()

      check ok
      # Residue check: nothing this test made survives teardown.
      check not b.containerExists(containerName)
      check snapName notin b.listSnapshots(containerName)
      let imgs = b.runIncus(@["image", "list", publishAlias,
                              "--format", "csv", "-c", "l"], timeoutSec = 30)
      check imgs.stdout.strip().len == 0

# Final safety net in case a check above raised past the finally.
bestEffortTeardown()
