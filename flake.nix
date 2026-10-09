# SPDX-FileCopyrightText: 2026 Metacraft Labs / Schelling Point Labs
# SPDX-License-Identifier: Apache-2.0

{
  description = "vm-harness — cross-platform VM lifecycle orchestration library";

  inputs = {
    # nixos-modules is this repo's only upstream flake: nixpkgs, flake-parts and
    # git-hooks all come through it, and so does the org's single reprobuild
    # pin. Keep the lock fresh rather than adding a reprobuild input here.
    nixos-modules.url = "github:metacraft-labs/devops-modules/dev";
    nixpkgs.follows = "nixos-modules/nixpkgs-unstable";
    flake-parts.follows = "nixos-modules/flake-parts";
    git-hooks.follows = "nixos-modules/git-hooks-nix";
  };

  outputs =
    inputs@{
      flake-parts,
      git-hooks,
      ...
    }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];

      perSystem =
        { pkgs, system, ... }:
        let
          # These fixtures boot an x86_64 guest even on an ARM64 host. Keep
          # their kernel, userspace and firmware on that guest architecture;
          # packaging tools and QEMU itself still run natively on the host.
          # These are guest payload files, never build-host executables. Use
          # the pinned x86 package outputs available from the binary cache;
          # pkgsCross would rebuild a compiler and kernel for the same guest.
          x86GuestPkgs = inputs.nixpkgs.legacyPackages.x86_64-linux;
          # The vTPM gate's Linux guest (kernel + busybox initramfs). Only
          # meaningful on Linux, where the gate runs.
          guest-linux-tpm =
            if pkgs.stdenv.isLinux then
              import ./nix/guest-linux-tpm.nix {
                inherit pkgs;
                guestPkgs = x86GuestPkgs;
              }
            else
              null;

          backendTools =
            if pkgs.stdenv.isDarwin then
              [
                # Tart and UTM live outside nixpkgs on macOS; the README
                # documents the Homebrew install path.
                pkgs.lima
                pkgs.qemu
              ]
            else if pkgs.stdenv.isLinux then
              [
                pkgs.libvirt
                pkgs.qemu
                pkgs.lima
                # The QemuBootBackend boots UEFI guests through
                # `-drive if=pflash` and needs an edk2 firmware pair;
                # `OVMF.fd` carries no binaries, it is here so the pair
                # is realised in the store and the shellHook can name it
                # exactly (see VMH_OVMF_CODE / VMH_OVMF_VARS below).
                x86GuestPkgs.OVMF.fd
                # swtpm backs QEMU's `-tpmdev emulator`. The
                # qemu_windows_arm backend already drives a full swtpm
                # lifecycle and its `probeAvailability` fails without
                # this on PATH; the libvirt backend's vTPM support needs
                # the same binary.
                pkgs.swtpm
              ]
            else
              [ ];

          # git-hooks.nix installs `.pre-commit-config.yaml` and git hooks into
          # `git rev-parse --show-toplevel` of the directory the shell is entered
          # from, so `nix develop /path/to/<this repo>` run inside another checkout
          # would plant this repository's hooks there. `ownRepoOnly` runs a snippet
          # only when that toplevel is this repository, recognised by a `flake.nix`
          # identical to the one this shell was evaluated from; anything it cannot
          # establish counts as another repository, so it fails safe.
          # tests/test_dev_shell_writes_nothing_elsewhere.sh
          ownRepoOnly = script: ''
            _own_repo_root="$(${pkgs.git}/bin/git rev-parse --show-toplevel 2>/dev/null || true)"
            if [ -n "$_own_repo_root" ] && [ -f "$_own_repo_root/flake.nix" ] \
              && [ "$(${pkgs.coreutils}/bin/sha256sum "$_own_repo_root/flake.nix" | ${pkgs.coreutils}/bin/cut -d' ' -f1)" \
                = "${builtins.hashFile "sha256" ./flake.nix}" ]; then
            ${script}
            # git-hooks.nix's installer leaves core.hooksPath as the RELATIVE
            # `.git/hooks`, in the config every worktree shares. A linked worktree
            # cannot resolve it (there `.git` is a file), so git silently runs no
            # hooks there. Point it at the common hooks directory instead.
            if [ "$(${pkgs.git}/bin/git config --local --get core.hooksPath 2>/dev/null)" = .git/hooks ]; then
              ${pkgs.git}/bin/git config --local core.hooksPath "$(${pkgs.git}/bin/git rev-parse --path-format=absolute --git-common-dir)/hooks"
            fi
            # The installer moves each Reprobuild hook dispatcher aside to
            # `<hook>.legacy` and puts pre-commit's shim in its slot, so the managed
            # hook (for pre-push, the publication gate) runs only by accident. Put the
            # dispatcher back and chain the shim as `<hook>.repro-local`, which the
            # dispatcher runs: the layout `repro hooks ensure --vcs` produces.
            #
            # This mirrors devops-modules lib/git-hooks-reprobuild-handoff.nix,
            # including its stale-shim pruning (devops-modules#724). The pinned
            # devops-modules predates that file; import it instead of this copy
            # once the pin moves past a7245933.
            _hooks="$(${pkgs.git}/bin/git rev-parse --path-format=absolute --git-path hooks 2>/dev/null || true)"
            _rechained=" "
            for _legacy in "$_hooks"/*.legacy; do
              [ -f "$_legacy" ] && grep -q 'reprobuild hook dispatcher' "$_legacy" || continue
              _slot="''${_legacy%.legacy}"
              if [ -f "$_slot" ] && grep -q 'reprobuild hook dispatcher' "$_slot"; then
                rm -f "$_legacy"
              elif [ ! -e "$_slot" ] || grep -Eq '^# File generated by (pre-commit|prek)' "$_slot"; then
                if [ -f "$_slot.repro-local" ] && ! grep -Eq '^# File generated by (pre-commit|prek)' "$_slot.repro-local"; then
                  echo "git-hooks: $_slot.repro-local is your own hook; run 'repro hooks ensure --vcs' to reconcile." >&2
                  continue
                fi
                if [ -e "$_slot" ]; then mv -f "$_slot" "$_slot.repro-local"; fi
                mv -f "$_legacy" "$_slot"
                _rechained="$_rechained$(basename "$_slot") "
              else
                echo "git-hooks: $_slot is not a pre-commit shim; run 'repro hooks ensure --vcs' to reconcile." >&2
              fi
            done
            # A generated shim chained for a hook type this installer run did
            # NOT re-chain belongs to an older config: prek then fails it with
            # "No hooks found for stage" -- for pre-push, that blocks every
            # push. Remove it; a hand-written `.repro-local` is never touched,
            # and nothing is pruned when the installer did not run.
            if [ "$_rechained" != " " ]; then
              for _stale in "$_hooks"/*.repro-local; do
                [ -f "$_stale" ] || continue
                _name="$(basename "''${_stale%.repro-local}")"
                case "$_rechained" in *" $_name "*) continue ;; esac
                grep -Eq '^# File generated by (pre-commit|prek):' "$_stale" || continue
                grep -q 'reprobuild hook dispatcher' "$_hooks/$_name" 2>/dev/null || continue
                rm -f "$_stale" && echo "git-hooks: removed $_stale (shim for a stage the current config no longer installs)" >&2
              done
            fi
            unset _hooks _legacy _slot _rechained _stale _name
            fi
            unset _own_repo_root
          '';
          pre-commit-check = git-hooks.lib.${system}.run {
            src = ./.;
            hooks.just-lint = {
              enable = true;
              name = "just lint";
              entry = "${pkgs.writeShellScript "vm-harness-just-lint" ''
                export PATH=${
                  pkgs.lib.makeBinPath (
                    [
                      pkgs.bash
                      pkgs.coreutils
                      pkgs.just
                      pkgs.nim
                      pkgs.nixfmt
                      pkgs.reuse
                    ]
                    ++ pkgs.lib.optionals pkgs.stdenv.isLinux [ pkgs.pcre.dev ]
                  )
                }:$PATH
                exec ${pkgs.just}/bin/just lint
              ''}";
              language = "system";
              pass_filenames = false;
            };
          };

          vm-harness = pkgs.stdenv.mkDerivation {
            pname = "gosti";
            version =
              let
                declarations = builtins.filter (line: builtins.match "version[[:space:]]*=.*" line != null) (
                  pkgs.lib.splitString "\n" (builtins.readFile ./vm_harness.nimble)
                );
              in
              assert builtins.length declarations == 1;
              builtins.head (
                builtins.match ''version[[:space:]]*=[[:space:]]*"([^"]+)"[[:space:]]*'' (
                  builtins.head declarations
                )
              );
            src = ./.;
            nativeBuildInputs = [ pkgs.nim ];
            buildInputs = pkgs.lib.optionals pkgs.stdenv.isLinux [ pkgs.pcre ];
            buildPhase = ''
              runHook preBuild
              # Nix sandboxes HOME to /homeless-shelter. Keep Nim's cache in
              # the writable build directory.
              nim c --hints:off --opt:speed \
                --nimcache:$TMPDIR/nimcache \
                -o:gosti src/vm_harness/cli.nim
              runHook postBuild
            '';
            installPhase = ''
              runHook preInstall
              mkdir -p $out/bin \
                $out/share/vm-harness/guest-scripts \
                $out/share/vm-harness/guest-recipes
              # `gosti` plus the `vm-harness` compatibility symlink — the
              # shared layout script, so `just build` produces the same names.
              bash scripts/install-binaries.sh gosti $out/bin
              # Hermetic-consumer fixture (docs/design.md §8.6): the real CLI
              # against the file-backed mock backend.
              install -m755 scripts/vm-harness-fixture.sh \
                $out/bin/vm-harness-fixture
              cp -R guest-scripts/* $out/share/vm-harness/guest-scripts/
              cp -R guest-recipes/* $out/share/vm-harness/guest-recipes/
              runHook postInstall
            '';
            meta = {
              description = "Cross-platform VM lifecycle orchestration";
              homepage = "https://github.com/metacraft-labs/vm-harness";
              license = pkgs.lib.licenses.asl20;
              # `lib.getExe` consumers now run `bin/gosti`; `bin/vm-harness`
              # remains as a symlink for everything that names it directly.
              mainProgram = "gosti";
              platforms = [
                "x86_64-linux"
                "aarch64-linux"
                "x86_64-darwin"
                "aarch64-darwin"
              ];
            };
          };
        in
        {
          packages = {
            default = vm-harness;
            gosti = vm-harness;
          }
          // pkgs.lib.optionalAttrs pkgs.stdenv.isLinux {
            # The fast-booting libvirt test golden needs a Linux kernel,
            # module tree, and qemu-img, so it is not exported on Darwin.
            golden-linux-tiny = import ./nix/golden-linux-tiny.nix {
              inherit pkgs;
              guestPkgs = x86GuestPkgs;
            };
            # The vTPM gate's guest: a stock kernel plus a busybox
            # initramfs that reports what it sees of /dev/tpm0. Same
            # reason it is Linux-only.
            inherit guest-linux-tpm;
          };

          checks = {
            inherit pre-commit-check;
            package-build = vm-harness;
          };

          # Packaging the CLI does not require hypervisors or booting a guest.
          # Keep the pinned compiler and runtime inputs, without realising the
          # development shell's x86-specific vTPM fixture on ARM64 builders.
          devShells.release = pkgs.mkShell {
            RELEASE_PCRE_SRC = if pkgs.stdenv.isLinux then pkgs.pcre.src else "";
            buildInputs = pkgs.lib.optionals pkgs.stdenv.isLinux [ pkgs.pcre ];
            packages = [
              pkgs.nodejs
              pkgs.nim
            ]
            ++ pkgs.lib.optionals pkgs.stdenv.isLinux [
              pkgs.zig
              pkgs.patchelf
              pkgs.binutils
              pkgs.dpkg
              pkgs.rpm
            ];
          };

          devShells.default = pkgs.mkShell {
            RELEASE_PCRE_SRC = if pkgs.stdenv.isLinux then pkgs.pcre.src else "";
            buildInputs = pkgs.lib.optionals pkgs.stdenv.isLinux [ pkgs.pcre ];
            packages = [
              pkgs.nodejs
              pkgs.git
              pkgs.just
              pkgs.nim
              pkgs.nimble
              pkgs.nixfmt
              pkgs.openssh
              pkgs.pre-commit
              pkgs.reuse
              pkgs.sshpass
              # guest-recipes/*/fetch-iso.sh use xorriso to validate that a
              # Windows ISO carries a UEFI El Torito boot record.
              pkgs.xorriso
            ]
            ++ backendTools
            ++ pkgs.lib.optionals pkgs.stdenv.isLinux [
              pkgs.zig
              pkgs.patchelf
              pkgs.binutils
              pkgs.dpkg
              pkgs.rpm
            ];

            shellHook = ''
              ${ownRepoOnly pre-commit-check.shellHook}
              export VM_HARNESS_ROOT="$PWD"
              ${pkgs.lib.optionalString pkgs.stdenv.isLinux ''
                # Pin the firmware pair src/vm_harness/firmware.nim resolves
                # to. Its last-resort fallback is a /nix/store glob whose
                # winner is the lexically greatest store hash, which is not a
                # stable choice; naming the flake's own OVMF makes a UEFI boot
                # gate assert against the firmware this shell pins. Respects an
                # operator override.
                export VMH_OVMF_CODE="''${VMH_OVMF_CODE:-${x86GuestPkgs.OVMF.fd}/FV/OVMF_CODE.fd}"
                export VMH_OVMF_VARS="''${VMH_OVMF_VARS:-${x86GuestPkgs.OVMF.fd}/FV/OVMF_VARS.fd}"
                # The vTPM gate's guest, pinned the same way. Naming the
                # store path here is what lets
                # tests/integration/t_guest_sees_tpm_device.nim run with
                # no network and no build step of its own: entering the
                # shell realises it once. Respects an operator override.
                export VMH_TPM_GUEST_DIR="''${VMH_TPM_GUEST_DIR:-${guest-linux-tpm}}"
              ''}
              echo "vm-harness dev shell"
              echo "  nim:    $(nim --version | head -n1)"
              echo "  nimble: $(nimble --version | head -n1)"
            '';
          };
        };
    };
}
