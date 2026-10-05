# Gosti

> Cross-platform VM and container lifecycle orchestration library and CLI. Drive Hyper-V, libvirt/QEMU, Tart, UTM, WSL, Lima, and Incus through a single set of primitives.

📖 **Documentation: <https://metacraft-labs.github.io/gosti/>** — complete user guide, CLI reference, backend guides, and recipes.

---

## Installation

### Quick install

Install the latest release using the official Metacraft Labs bootstrapper:

- **POSIX Shell (Linux, macOS, WSL)**:
  ```bash
  curl -fsSL https://install-package.metacraft-labs.com/gosti/sh | sh
  ```
- **PowerShell (Windows)**:
  ```powershell
  irm https://install-package.metacraft-labs.com/gosti/pwsh | iex
  ```

### Package managers

Gosti is published across official Metacraft package repositories:

- **Debian / Ubuntu**:
  ```bash
  sudo apt-get install -y metacraft-gosti
  ```
  *(Requires `deb.metacraft-labs.com` repository keyring; see [docs](https://metacraft-labs.github.io/gosti/getting_started/getting-started))*
- **Fedora / RHEL / openSUSE**:
  ```bash
  sudo dnf install -y metacraft-gosti
  ```
  *(Requires `rpm.metacraft-labs.com` repository)*
- **macOS (Homebrew)**:
  ```bash
  brew tap metacraft-labs/metacraft
  brew install gosti
  ```
- **Windows (Scoop)**:
  ```powershell
  scoop bucket add metacraft https://github.com/metacraft-labs/metacraft-desktop-packages
  scoop install gosti
  ```
- **Nix**:
  ```bash
  nix profile install github:metacraft-labs/nixpkgs#gosti
  ```

Direct binary archives and release checksums are available on [GitHub Releases](https://github.com/metacraft-labs/gosti/releases).

---

## Quick Start

### Command Line CLI

#### 1. Inspect Available Backends

Detect hypervisors and container managers installed on the current host:

```bash
gosti probe
```

View a summary table of all supported backends:

```bash
gosti backends
```

#### 2. Run Commands in a Guest

The one-shot `run` command provisions the baseline, reverts cleanly, executes your command inside the guest, collects output, and tears down safely:

```bash
gosti run \
  --backend auto \
  --guest linux \
  --baseline demo-linux \
  --output-dir ./out \
  -- /bin/sh -c 'uname -s && uptime'
```

Process exit codes encode the verdict: `0` PASS, `1` FAIL, `2` ERROR, `130` INTERRUPTED. The `--output-dir` receives the complete execution envelope (`00-provision.log`, `02-<cmd>-run.txt`, `RESULT.txt`, `DONE`).

#### 3. Ephemeral Per-Job Containers (Incus)

Launch a clean container from a base image, run a command, and destroy it leaving zero residue:

```bash
gosti run --ephemeral --backend incus \
  --baseline demo-job --base-image vmh-base \
  -- true
```

#### 4. Boot Media and Console Screenshots

Boot an ISO, VHDX, or QCOW2 in a transient VM, await serial output, and capture the graphical console:

```bash
gosti boot --backend auto --source-image installer.iso \
  --screenshot boot.png --screenshot-delay-sec 2 \
  --expect 'INSTALL COMPLETE'
```

### Nim Library

Call Gosti's lifecycle primitives directly from Nim test suites or orchestration tools:

```nim
import std/tables
import vm_harness

# Select an appropriate backend for Linux guests on the current host
let backend = newBackendForGuest(goLinux)

# Ensure the baseline image exists
backend.provisionBaseline(BaselineSpec(
  name: "demo",
  guestOs: goLinux
))

# Fast revert to clean baseline
let vm = backend.revertToBaseline("demo")
defer: backend.stopAndCleanup(vm) # Guaranteed cleanup on scope exit

# Execute command inside the guest
let res = backend.execInGuest(
  vm,
  initTable[string, string](),
  @["/bin/sh", "-c", "uname -s"]
)

assert res.exitCode == 0
echo res.stdout
```

---

## Supported Backends

Gosti selects a backend automatically from the `(host OS, guest OS)` pair via `--backend auto`, or accepts `--backend <id>` explicitly:

| Host OS | Guest OS | Backend ID | Technology & Reset Mechanism |
| :--- | :--- | :--- | :--- |
| **Windows** | Windows | `hyperv` | Hyper-V checkpoint revert (`Restore-VMCheckpoint`) |
| **Windows** | Linux | `wsl` | WSL2 import from cached rootfs |
| **Linux** | Linux | `libvirt` | QEMU/KVM snapshot revert (`virsh snapshot-revert`) |
| **Linux** | Windows | `libvirt` | QEMU/KVM with autounattend recipe |
| **Linux** | Linux (containers) | `incus` | Incus system container (`incus launch` / ephemeral delete) |
| **macOS (Apple Silicon)** | macOS | `tart-macos` | Tart VM clone from OCI cache |
| **macOS (Apple Silicon)** | Linux | `tart-linux-arm` | Tart VM clone from OCI cache |
| **macOS (Apple Silicon)** | Windows | `utm-windows-arm` | UTM clone from local VM bundle |
| **macOS / Linux** | Linux | `lima` | Lima VM instance recreate (`limactl`) |

---

## Documentation

Comprehensive user documentation is published at **<https://metacraft-labs.github.io/gosti/>**:

- **Getting Started**:
  - [Overview and Concepts](https://metacraft-labs.github.io/gosti/getting_started/overview-and-concepts) — The `VmBackend` abstraction, per-gate reset performance contract, and three-tier ownership model.
  - [Getting Started Guide](https://metacraft-labs.github.io/gosti/getting_started/getting-started) — Walkthrough from installation to first in-guest assertion.
- **Guides**:
  - [Driving a VM from Code](https://metacraft-labs.github.io/gosti/guides/driving-a-vm) — Using the library API, ephemeral per-job workflows, and serial boot assertions.
  - [Supported Backends](https://metacraft-labs.github.io/gosti/guides/backends) — Host prerequisites, configuration, and caveats for each hypervisor.
  - [Authoring Guest Recipes](https://metacraft-labs.github.io/gosti/guides/guest-recipes) — Reproducible baseline image creation for Linux and Windows.
  - [Durable Media Instances](https://metacraft-labs.github.io/gosti/guides/durable-media) — Managing persistent Linux/libvirt VM lifecycles under logical names.
- **Reference**:
  - [CLI Reference](https://metacraft-labs.github.io/gosti/reference/cli-reference) — Complete flags and subcommand manual for `gosti`.
  - [Parameters Catalog](https://metacraft-labs.github.io/gosti/reference/parameters) — Stable parameter contract for runner recipes and provider options.

### Contributor Documentation

- Architecture and design references: [`docs/design.md`](docs/design.md)
- Per-backend technical implementation notes: `docs/per-backend-notes/`
- Agent onboarding and workspace workflows: [`AGENTS.md`](AGENTS.md)

---

## License

Apache-2.0 — see [`LICENSE`](LICENSE) and [`NOTICE`](NOTICE).
