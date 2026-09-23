## Unit tests for the Hyper-V per-job EPHEMERAL clone PowerShell builder
## (`buildEphemeralCloneCommand`) — the host-lifecycle primitive RA4's
## `t_vmharness_serve_win_hyperv` gate drives on win-ci-bare-001.
##
## Like `t_hyperv_boot_media`, these assert on the emitted PowerShell text,
## so they run on any host with no Hyper-V role, no VM, no elevation — the
## only coverage the New-VHD/New-VM/Enable-VMTPM host-lifecycle paths can get
## before they run for real on the bare-metal Windows host. Mock policy: NO
## mocks — the function under test is pure (spec → PowerShell string).
##
## The behaviour under test is the Hyper-V analog of libvirt's CoW-overlay
## ephemeral clone: a per-job disk derived from a golden VHDX (differencing
## overlay or ReFS block-clone copy), a fresh Gen-2 VM around it, and safety
## guards that make teardown unable to touch a long-lived VM or the golden.

import std/[strutils, unittest]
import vm_harness

proc win11Spec(): HyperVEphemeralCloneSpec =
  ## A spec shaped like a per-job clone of the Windows 11 Hyper-V golden.
  HyperVEphemeralCloneSpec(
    name: EphemeralVmNamePrefix & "job-42",
    goldenVhdx: "D:\\golden\\win11-golden.vhdx",
    useDifferencing: true,
    cpus: 4,
    memoryMB: 8192,
    generation: 2,
    secureBootEnabled: true,
    tpmEnabled: true,
    switchName: "NAT-Switch",
    configDriveIso: "D:\\jit\\job-42.config-drive.iso")

proc render(spec: HyperVEphemeralCloneSpec): string =
  ## The emitted script with its `#` comment lines removed (so ordering
  ## assertions do not match prose that names a cmdlet before it runs).
  let b = newHyperVBackend()
  let raw = b.buildEphemeralCloneCommand(spec, ephemeralClonePathFor(spec))
  var kept: seq[string] = @[]
  for line in raw.splitLines():
    if not line.strip().startsWith("#"):
      kept.add(line)
  kept.join("\n")

suite "buildEphemeralCloneCommand: host-lifecycle ops (New-VHD/New-VM/Remove)":
  test "the golden is CoW-cloned and a fresh VM is created on the clone":
    let ps = render(win11Spec())
    # The differencing overlay keeps the golden read-only (never written).
    check "New-VHD -Path $clone -ParentPath $golden -Differencing" in ps
    check "New-VM -Name $vmName -Generation $gen" in ps
    check "-VHDPath $clone" in ps
    # New-VM binds the CLONE, never the golden directly.
    check "-VHDPath $golden" notin ps

  test "a per-job clone never checkpoints (no .avhdx absorbing guest writes)":
    let ps = render(win11Spec())
    check "-AutomaticCheckpointsEnabled $false" in ps
    check "-CheckpointType Disabled" in ps
    # ...set straight after New-VM, while the VM is still Off (this script
    # never starts it), so no checkpoint can exist before the first boot.
    check ps.find("New-VM -Name $vmName") < ps.find("-CheckpointType Disabled")
    check "Start-VM" notin ps

  test "clone-path defaults next to the golden and is namespaced by VM name":
    let spec = win11Spec()
    let p = ephemeralClonePathFor(spec)
    check p == "D:\\golden\\" & EphemeralVmNamePrefix & "job-42.vhdx"

  test "an explicit clonePath is honoured verbatim":
    var spec = win11Spec()
    spec.clonePath = "E:\\scratch\\my-clone.vhdx"
    check ephemeralClonePathFor(spec) == "E:\\scratch\\my-clone.vhdx"

  test "a full-copy clone is emitted when differencing is disabled (ReFS)":
    var spec = win11Spec()
    spec.useDifferencing = false
    let ps = render(spec)
    check "$useDiff = $false" in ps
    check "Copy-Item -LiteralPath $golden -Destination $clone" in ps

suite "buildEphemeralCloneCommand: a per-job clone never checkpoints":
  # Client Hyper-V (Windows 11 Pro 26200) enables AUTOMATIC checkpoints on
  # every New-VM, so the first Start-VM moves the VM onto a
  # `<name>_<GUID>.avhdx` the teardown did not know about. Untested on a real
  # Hyper-V host: these pin the emitted script only.
  test "automatic and manual checkpoints are disabled before the VM can start":
    let script = render(win11Spec())
    check "Set-VM -Name $vmName -AutomaticCheckpointsEnabled $false -CheckpointType Disabled" in script
    check script.find("New-VM -Name $vmName") < script.find("-AutomaticCheckpointsEnabled $false")
    check "Start-VM" notin script   # started separately, after this script

suite "buildEphemeralCloneCommand: safety guards make teardown/golden safe":
  test "refuses a VM name outside the ephemeral namespace":
    var spec = win11Spec()
    spec.name = "some-long-lived-vm"
    # A name outside the prefix is refused by the guard AND by the builder's
    # emitted check.
    let b = newHyperVBackend()
    let ps = b.buildEphemeralCloneCommand(spec, "D:\\x.vhdx")
    check "SAFETY: refusing to create ephemeral VM" in ps
    check EphemeralVmNamePrefix in ps

  test "refuses to clobber an existing VM or an existing clone disk":
    let ps = render(win11Spec())
    check "already exists; per-job clones require a fresh name" in ps
    check "per-job clone disk already exists (refusing to clobber)" in ps

  test "aborts when the golden VHDX is missing (never creates a stray VM)":
    let ps = render(win11Spec())
    check "golden VHDX not found" in ps

suite "buildEphemeralCloneCommand: Windows 11 hardware gates":
  test "vTPM is enabled with the key protector created FIRST":
    let ps = render(win11Spec())
    check "Set-VMKeyProtector" in ps
    check "-NewLocalKeyProtector" in ps
    check "Enable-VMTPM" in ps
    check ps.find("Set-VMKeyProtector") < ps.find("Enable-VMTPM")

  test "Secure Boot stays On for the Windows golden":
    let ps = render(win11Spec())
    check "$secureBoot = 'On'" in ps
    check "-EnableSecureBoot $secureBoot" in ps

  test "a TPM request on Generation 1 is refused, not silently emitted":
    var spec = win11Spec()
    spec.generation = 1
    spec.tpmEnabled = true
    let ps = render(spec)
    check "$wantTpm = $false" in ps

  test "defaults: 2 vCPU / 4096 MB / Gen 2 when the fields are unset":
    let spec = HyperVEphemeralCloneSpec(
      name: EphemeralVmNamePrefix & "bare",
      goldenVhdx: "D:\\g\\golden.vhdx",
      useDifferencing: true)
    let ps = render(spec)
    check "$gen     = 2" in ps
    check "$memMB   = 4096" in ps
    check "$cpus    = 2" in ps

suite "buildEphemeralCloneCommand: JIT bootstrap + networking seams":
  test "a vSwitch NIC is connected for the metadata endpoint when requested":
    let ps = render(win11Spec())
    check "Connect-VMNetworkAdapter" in ps
    check "-SwitchName $switch" in ps

  test "the guest is network-isolated when no switch is given":
    var spec = win11Spec()
    spec.switchName = ""
    let ps = render(spec)
    check "Remove-VMNetworkAdapter" in ps

  test "a cloudbase-init ConfigDrive ISO is attached read-only when set":
    let ps = render(win11Spec())
    check "Add-VMDvdDrive -VMName $vmName -Path $configDrive" in ps
    check "configDriveIso not found" in ps

suite "guest metadata proxy: locate + rewrite the controller URL in a bootstrap":
  const boot = "#ps1_sysnative\n" &
    "$MetadataUrl = \"http://100.83.180.254:9997/api/v1/metadata\"\n" &
    "$CallbackUrl = \"http://100.83.180.254:9997/api/v1/callbacks\"\n" &
    "wget -Uri \"$MetadataUrl/install-script/\"\n"

  test "finds the controller host and port from the metadata URL":
    let (found, t) = findGuestMetadataTarget(boot)
    check found
    check t.host == "100.83.180.254"
    check t.port == 9997

  test "rewrites BOTH the metadata and the callback URL to the proxy":
    let (_, t) = findGuestMetadataTarget(boot)
    let r = rewriteGuestMetadataHost(boot, t, "172.17.208.1")
    check "http://172.17.208.1:9997/api/v1/metadata" in r
    check "http://172.17.208.1:9997/api/v1/callbacks" in r
    check "100.83.180.254" notin r

  test "a bootstrap with no metadata URL is left alone":
    let (found, _) = findGuestMetadataTarget("echo hello")
    check not found

  test "a portless metadata URL defaults to port 80":
    let (found, t) = findGuestMetadataTarget("x=\"http://garm.example/api/v1/metadata\"")
    check found
    check t.host == "garm.example"
    check t.port == 80

suite "Hyper-V ephemeral teardown + enumeration (remote ephemeral-destroy / ephemeral-list)":
  # `ephemeral-destroy --backend hyperv` used to fall through to the libvirt
  # branch and fail on a missing `virsh` (measured in central GARM's log for
  # win-ci-bare-001); the provider reported that as success and every kept
  # VM leaked. These pin the replacement's safety and fail-loud properties.
  let name = EphemeralVmNamePrefix & "job-77"
  let clonePath = "D:\\golden\\" & name & ".vhdx"
  let script = buildEphemeralDestroyCommand(name, clonePath)
  proc code(s: string): string =
    ## The script without its comment lines, for ordering assertions.
    var kept: seq[string] = @[]
    for line in s.splitLines():
      if not line.strip().startsWith("#"): kept.add(line)
    kept.join("\n")
  let body = code(script)

  test "refuses to touch a VM outside the ephemeral namespace":
    check "SAFETY: refusing to destroy" in script
    check ("StartsWith('" & EphemeralVmNamePrefix & "')") in script

  test "the per-job disk location comes from the RECORD, not the VM":
    check "$diskDir = 'D:\\golden'" in script
    check ("$diskStem = '" & name & "'") in script
    check "Get-ChildItem -LiteralPath $d -File" in script

  test "an absent VM does NOT short-circuit the disk sweep (retry after a failed delete)":
    # The old script `exit 0`-ed as soon as Get-VM came back empty, so a
    # retry after `Remove-VM` succeeded but the disk delete failed reported
    # success and leaked the disk for good.
    check "if (-not $vm) { Write-Output \"vmh-destroy: $vmName absent\"; exit 0 }" notin script
    let absentBranch = body.find("vmh-destroy: VM $vmName absent")
    check absentBranch > 0
    check body.find("Get-ChildItem -LiteralPath $d -File", absentBranch) > absentBranch
    check body.find("per-job disk(s) of $vmName still exist", absentBranch) > absentBranch

  test "the sweep covers checkpoint .avhdx files and is anchored on the per-job stem":
    check "[regex]::Escape($diskStem)" in script
    check "\\.a?vhdx$'" in script
    check "(_\\{?[0-9A-Fa-f]{8}(-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}\\}?)?" in script
    check "$diskRe = '^'" in script           # anchored: never the golden

  test "checkpoints are removed and merged BEFORE Remove-VM":
    check "Get-VMSnapshot -VMName $vmName" in body
    check "Remove-VMSnapshot -Confirm:$false" in body
    check body.find("Remove-VMSnapshot") < body.find("Remove-VM -Name")
    check "checkpoint merge for $vmName did not finish" in body
    check "$_.Path -like '*.avhdx'" in body

  test "teardown is VERIFIED: a surviving VM or disk is an error, not success":
    check "$ErrorActionPreference = 'Stop'" in script
    check "throw \"VM $vmName still exists after Remove-VM\"" in script
    check "throw \"per-job disk(s) of $vmName still exist: $($left -join ', ')\"" in script
    check "SilentlyContinue | Out-Null" notin script   # nothing swallowed
    check body.find("Stop-VM") < body.find("Remove-VM -Name")
    check body.find("Remove-VM -Name") < body.find("Remove-Item -LiteralPath")

  test "the VM's own disk paths are swept too (a clone that predates the record)":
    check "Get-VMHardDiskDrive -VMName $vmName | ForEach-Object { $_.Path }" in script
    check "$dirs.Add($d)" in script

  test "no record and no VM is success: nothing is left this call could find":
    let bare = buildEphemeralDestroyCommand(name)
    check "$diskDir = ''" in bare
    check ("$diskStem = '" & name & "'") in bare
    check "if ($dirs.Count -eq 0) { Write-Output \"vmh-destroy: $vmName absent, no per-job disk recorded\"; exit 0 }" in bare

  test "a recorded clone path splits on its Windows separator on any host":
    check splitWindowsPath("D:\\golden\\garm-1.vhdx") == (dir: "D:\\golden", file: "garm-1.vhdx")
    check ephemeralDiskStem("D:\\golden\\garm-1.vhdx") == "garm-1"
    check splitWindowsPath("garm-1.vhdx").dir == ""

  test "enumeration is namespaced and throws rather than printing nothing":
    let list = buildEphemeralListCommand()
    check "$ErrorActionPreference = 'Stop'" in list
    check ("StartsWith('" & EphemeralVmNamePrefix & "')") in list

  test "Hyper-V states map onto GARM states":
    check normalizeHyperVState("Off") == "stopped"
    check normalizeHyperVState("Running") == "running"
    check normalizeHyperVState("Saved") == "running"
    check normalizeHyperVState("") == "unknown"
