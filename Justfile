# SPDX-FileCopyrightText: 2026 Metacraft Labs / Schelling Point Labs
# SPDX-License-Identifier: Apache-2.0

set shell := ["bash", "-eu", "-o", "pipefail", "-c"]

default:
    just lint

# Build the CLI and the snapshot-revert benchmark into build/bin through the
# reprobuild graph (the `default` collection of `repro.nim`).
build:
    repro build

# Run the deterministic, host-independent suite through `repro test` (the
# `test` collection of `repro.nim`; scripts/test-catalog.txt is shared with
# the native runner `scripts/run_tests.nim`, which `just test-host` extends to
# the live hypervisor tier).
test:
    repro test

t: test

test-host:
    mkdir -p test-logs
    bash scripts/run-host-tests.sh 2>&1 | tee test-logs/test-host.log

lint:
    mkdir -p test-logs
    nim check --hints:off --path:src src/gosti/cli.nim 2>&1 | tee test-logs/lint.log
    nixfmt --check flake.nix nix/*.nix 2>&1 | tee -a test-logs/lint.log
    reuse lint 2>&1 | tee -a test-logs/lint.log

format:
    find src tests tools -type f -name '*.nim' -exec nimpretty {} +
    nixfmt flake.nix nix/*.nix

fmt: format

nix-build:
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p test-logs
    nix build .#default 2>&1 | tee test-logs/nix-build.log
    # The Linux-only guest fixture is consumed by the declared development
    # environment. Exercise its reproducibility check in the existing CI gate.
    if [[ "$(uname -s)" == Linux ]]; then
        system="$(nix eval --raw --impure --expr builtins.currentSystem)"
        nix build ".#checks.${system}.guest-linux-tpm-reproducible" 2>&1 | tee -a test-logs/nix-build.log
    fi

# Entering the dev shell from another git repository must write nothing there.
# Runs `nix develop`, so it is not part of the in-shell test recipes.
test-dev-shell:
    bash tests/test_dev_shell_writes_nothing_elsewhere.sh

# Documentation-site recipes (delegating to docs/site)
dev-docs *args:
    just -f docs/site/Justfile --working-directory docs/site dev-docs {{args}}

build-docs:
    just -f docs/site/Justfile --working-directory docs/site build

serve-docs:
    just -f docs/site/Justfile --working-directory docs/site serve-docs

open-docs *args:
    just -f docs/site/Justfile --working-directory docs/site open-docs {{args}}
