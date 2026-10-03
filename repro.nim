# SPDX-FileCopyrightText: 2026 Metacraft Labs / Schelling Point Labs
# SPDX-License-Identifier: Apache-2.0
## Pure reprobuild graph for vm-harness.
##
## The default collection builds the shipping CLI and benchmark. The test
## collection builds and executes the deterministic, host-independent suite on
## every supported platform. scripts/test-catalog.txt is shared with the native
## runner, including each fixture's existing platform guards. Live hypervisor
## lifecycles remain in the explicit host tier.

import ./scripts/test_catalog
import repro_project_dsl
import repro_dsl_stdlib/foreign_env
import repro_dsl_stdlib/packages/sh
import ct_test_nim_unittest
import ./repro_support/qemu_img as qemuImageTools
when defined(posix):
  import ./repro_support/tar as testTar
  import ./repro_support/xorriso
import repro_dsl_stdlib/nixpkgs_pin
import repro_resources/run_edge
when defined(linux):
  import repro_dsl_stdlib/packages/pcre_config
  import ./repro_support/swtpm

# TI2 producer-surface declaration: vm-harness's resource providers live in a
# SEPARATE module (`src/vm_harness/repro/resources.nim`, re-authored via the RP4
# `resourceType` macro for RP5c1), NOT inline in this `repro.nim`. This marker
# NAMES that module + the extra `--path` its imports need, so a consumer that
# `uses: "vm-harness"` is routed to the driver-free interface-artifact accessor
# splice (TI2): detection reads it TEXTUALLY, the interface lift compiles the
# module with the declared `--path`, and the accessor-cache freshness folds the
# module's import closure in. It expands to NOTHING — this `repro.nim` imports
# only `repro_project_dsl`, so the core `just build` never pulls in the resource
# module's incus-backend driver closure (the RP5c1 reprobuild-free invariant).
resourceModule "src/vm_harness/repro/resources.nim":
  path "src"

package vm_harness:
  devEnv:
    when not defined(windows):
      useFlakeDevShell()

  # The Reprobuild CI environment does not activate this project's Nix shell.
  # Resolve declared POSIX tools even when they are absent from the host PATH.
  defaultToolProvisioning(when defined(windows): path else: nix)

  uses:
    "nim >=2.2 <3.0"
    "sh"
    "bash >=4"
    "cat"
    "cp"
    "chmod"
    "ln"
    "mkdir"
    "rm"
    "sed"
    "grep"
    "head"
    "tail"
    "cut"
    "tr"
    "dirname"
    "awk"
    "tar"
    "qemu-img"
    "sha256sum"
    "git >=2"
    when defined(posix):
      "sleep"
      "xorriso"
    when defined(linux):
      "pcre-config >=0"
      "uname"
      "nix"
      "swtpm"
    when defined(macosx):
      "clang"
    else:
      "gcc"

  runtimeDeps:
    when defined(linux):
      "vmHarnessPcre"
      "vmHarnessVirsh"
      "vmHarnessVirtInstall"
      "vmHarnessQemuImg"
      "vmHarnessSsh"
      "vmHarnessSshpass"

  library vm_harness

  executable vmHarness:
    name: "vm-harness"

  executable snapshotRevertBench:
    name: "vm-harness-bench-snapshot-revert"

  build:
    const backendCompiler = (when defined(macosx): "clang" else: "gcc")
    const exeSuffix = (when defined(windows): ".exe" else: "")
    const binDir = "build/bin/"
    const testBinDir = "build/test-bin/"

    let cliBuild = nim.c(
      source = "src/vm_harness/cli.nim",
      binary = binDir & "vm-harness" & exeSuffix,
      extraInputs = @["src", "config.nims", "guest-scripts", "guest-recipes"],
      actionId = "vm_harness.cli.build")
    when defined(linux):
      appendRegisteredActionToolIdentityRefs(cliBuild.id, ["pcre-config", "uname"])
    let benchBuild = nim.c(
      source = "tools/bench/snapshot_revert_bench.nim",
      binary = binDir & "vm-harness-bench-snapshot-revert" & exeSuffix,
      extraInputs = @["src", "config.nims", "tools", "guest-scripts", "guest-recipes"],
      actionId = "vm_harness.snapshot_revert_bench.build")
    when defined(linux):
      appendRegisteredActionToolIdentityRefs(benchBuild.id, ["pcre-config", "uname"])
    discard collect("default", @[cliBuild, benchBuild])

    var testBuildActions: seq[BuildActionDef] = @[]
    var testExecuteActions: seq[BuildActionDef] = @[]

    when defined(linux):
      # The native shell realizes this same pinned guest. The graph owns its
      # realization explicitly, and passes the output path to the real TPM gate.
      let tpmGuest = shell(
        "nix build .#guest-linux-tpm --out-link build/test-tpm-guest",
        actionId = "vm_harness.test_tpm_guest",
        extraInputs = @["flake.nix", "flake.lock", "nix/guest-linux-tpm.nix"],
        extraOutputs = @["build/test-tpm-guest"])
      appendRegisteredActionToolIdentityRefs(tpmGuest.id, ["nix"])

    proc emitTestPair(spec: TestSpec;
                      buildActions, executeActions: var seq[BuildActionDef]) =
      let output = testBinDir & spec.binary & exeSuffix
      let edge = buildNimUnittest.build(
        source = spec.source,
        binary = output,
        # vm_harness.nimble is an input because the MA3 golden-build gate
        # asserts that the version it stamps into every golden manifest is
        # still the package version — a drift guard that has to be able to
        # read the package version.
        extraInputs = @["src", "config.nims", "guest-scripts", "guest-recipes",
                        "vm_harness.nimble", "tests", "scripts", "docs"],
        actionId = "vm_harness.test_build." & spec.binary)
      # The unittest adapter does not register Nim's C compiler itself.
      appendRegisteredActionToolIdentityRefs(edge.action.id, [backendCompiler])
      when defined(linux):
        appendRegisteredActionToolIdentityRefs(edge.action.id, ["pcre-config", "uname"])
      buildActions.add(edge.action)
      var executionAfter: seq[BuildActionDef] = @[]
      var executionEnv: seq[(string, string)] = @[]
      var executionInputs: seq[string] = @[]
      when defined(linux):
        if spec.binary == "t_guest_sees_tpm_device":
          executionAfter.add(tpmGuest)
          executionInputs.add("build/test-tpm-guest")
          executionEnv.add(("VMH_TPM_GUEST_DIR", "build/test-tpm-guest"))
      let execute = edge.testBinary.run(
        actionId = "vm_harness.test_execute." & spec.binary,
        after = executionAfter,
        extraInputs = executionInputs,
        extraEnv = executionEnv,
        registerImplicitName = false)
      # The full suite compiles real child CLIs and runs repository shell
      # fixtures. Declaring tools only on the build edge omits them from the
      # execution action's isolated PATH.
      appendRegisteredActionToolIdentityRefs(execute.id,
        ["nim", backendCompiler, "sh", "bash", "cat", "cp", "chmod", "ln",
         "mkdir", "rm", "sed", "grep", "head", "tail", "cut", "tr", "dirname",
         "awk", "tar", "qemu-img", "sha256sum", "git"])
      when defined(posix):
        appendRegisteredActionToolIdentityRefs(execute.id,
          ["sleep"])
        if spec.binary == "t_libvirt_backend":
          appendRegisteredActionToolIdentityRefs(execute.id, ["xorriso"])
      when defined(linux):
        appendRegisteredActionToolIdentityRefs(execute.id,
          ["pcre-config", "uname", "swtpm"])
      executeActions.add(execute)
      run("test-" & spec.binary, build = execute.id,
        owningPackage = "vm_harness")

    for spec in loadTestCatalog(".").selectedTests("test"):
      emitTestPair(spec, testBuildActions, testExecuteActions)

    discard collect("test-builds", testBuildActions)
    discard collect("test", testExecuteActions)

when defined(linux):
  # The pinned pcre-config shell script invokes uname even for --libs.
  package uname:
    provisioning:
      nixPackage "nixpkgs#coreutils", executablePath = "bin/uname",
        nixpkgsRev = CanonicalNixpkgsRev,
        nixpkgsNarHash = CanonicalNixpkgsNarHash

  package vmHarnessPcre:
    provisioning:
      nixPackage "nixpkgs#pcre.out", executablePath = "lib/libpcre.so",
        nixpkgsRev = CanonicalNixpkgsRev,
        nixpkgsNarHash = CanonicalNixpkgsNarHash

    library pcre

  package vmHarnessVirsh:
    provisioning:
      nixPackage "nixpkgs#libvirt", executablePath = "bin/virsh",
        nixpkgsRev = CanonicalNixpkgsRev,
        nixpkgsNarHash = CanonicalNixpkgsNarHash

    executable virsh:
      name: "virsh"

  package vmHarnessVirtInstall:
    provisioning:
      nixPackage "nixpkgs#virt-manager", executablePath = "bin/virt-install",
        nixpkgsRev = CanonicalNixpkgsRev,
        nixpkgsNarHash = CanonicalNixpkgsNarHash

    executable virtInstall:
      name: "virt-install"

  package vmHarnessQemuImg:
    provisioning:
      nixPackage "nixpkgs#qemu", executablePath = "bin/qemu-img",
        nixpkgsRev = CanonicalNixpkgsRev,
        nixpkgsNarHash = CanonicalNixpkgsNarHash

    executable qemuImg:
      name: "qemu-img"

  package vmHarnessSsh:
    provisioning:
      nixPackage "nixpkgs#openssh", executablePath = "bin/ssh",
        nixpkgsRev = CanonicalNixpkgsRev,
        nixpkgsNarHash = CanonicalNixpkgsNarHash

    executable ssh:
      name: "ssh"

  package vmHarnessSshpass:
    provisioning:
      nixPackage "nixpkgs#sshpass", executablePath = "bin/sshpass",
        nixpkgsRev = CanonicalNixpkgsRev,
        nixpkgsNarHash = CanonicalNixpkgsNarHash

    executable sshpass:
      name: "sshpass"
