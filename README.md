<div align="center">

# DeskHelm

Native macOS menu-bar volume control for an external LG display.

[![License](https://img.shields.io/badge/License-GPLv3%20only-blue.svg)](https://spdx.org/licenses/GPL-3.0-only.html)
[![Docs](https://img.shields.io/docsrs/deskhelm)](https://docs.rs/deskhelm)
[![Language Checks](https://github.com/acg-box/deskhelm/actions/workflows/language.yml/badge.svg?branch=main)](https://github.com/acg-box/deskhelm/actions/workflows/language.yml)
[![Release](https://github.com/acg-box/deskhelm/actions/workflows/release.yml/badge.svg)](https://github.com/acg-box/deskhelm/actions/workflows/release.yml)
[![GitHub tag (latest by date)](https://img.shields.io/github/v/tag/acg-box/deskhelm)](https://github.com/acg-box/deskhelm/tags)
[![GitHub last commit](https://img.shields.io/github/last-commit/acg-box/deskhelm?color=red&style=plastic)](https://github.com/acg-box/deskhelm)

</div>

## Feature Highlights

### Native LG Display Volume Control

DeskHelm provides an AppKit and SwiftUI menu-bar app and a Rust CLI that share
one direct DDC/CI core. It controls display audio volume through VCP feature
`0x62` without another display-control executable. The app keeps preview writes
separate from confirmed hardware readback and can optionally route macOS volume
keys to the supported LG output.

## Status

DeskHelm is an early Apple Silicon macOS prototype. The verified hardware point
is an LG 39GX950B connected directly to an M4 Max Mac through USB-C. Display
firmware, cables, adapters, and docks can change DDC/CI compatibility.

## Workspace Posture

- `apps/deskhelm/` owns the shared Rust core, CLI, and C ABI.
- `apps/deskhelm/macos/` owns the native AppKit and SwiftUI menu-bar app.
- `script/` owns native build and diagnostic commands, while `scripts/` owns
  repository-maintenance TypeScript programs.
- `packages/` is reserved for reusable shared packages.
- The root `Cargo.toml` owns Rust workspace metadata, profiles, and dependency
  versions.
- The root `package.json`, `package-lock.json`, and `tsconfig.json` own the
  TypeScript maintenance toolchain and its exact development dependencies.
- `openwiki/` is the authoritative repository knowledge and agent-routing
  surface.

## Usage

### Installation

#### Build from Source

The native app requires an Apple Silicon Mac, macOS 14 or later, and Xcode with
Swift 6.2. The display must expose DDC/CI audio volume as a 0–100 range.

```sh
# Clone the repository.
git clone https://github.com/acg-box/deskhelm
cd deskhelm

# Build the Rust CLI.
cargo build --locked -p deskhelm

# Build, stage, and open the native menu-bar app.
./script/build_and_run.sh
```

#### Download Pre-built Binary

- **macOS**
    - Tagged releases publish the CLI through [GitHub Releases](https://github.com/acg-box/deskhelm/releases/latest). Build the native menu-bar app from source.
- **Windows**
    - Tagged releases publish a CLI archive, but display control is not implemented on Windows.
- **Unix**
    - Tagged releases publish a Linux CLI archive, but display control is not implemented on Linux.

### Configuration

#### Optional Volume Keys

Open the panel's ellipsis menu and select **Enable Volume Keys…**. DeskHelm asks
for macOS Accessibility permission and intercepts volume-up and volume-down only
when the default audio output uniquely matches the supported LG display. Set
`DESKHELM_CODE_SIGN_IDENTITY` to an authorized Apple Development identity when
Accessibility authorization must persist across rebuilds.

### Interaction

Select the DeskHelm menu-bar icon to open the volume panel. Drag the control, use
the arrow keys, or use the VoiceOver adjustable action. DeskHelm coalesces rapid
preview writes and confirms the final target through hardware readback.

Use the CLI to read or set the display volume:

```sh
cargo run --locked -p deskhelm -- volume
cargo run --locked -p deskhelm -- volume 25
```

### Update

Pull the latest `main` branch and rebuild the selected interface:

```sh
git pull --ff-only
./script/build_and_run.sh
cargo build --locked -p deskhelm
```

## Development

Install the exact TypeScript development graph without running package lifecycle
scripts:

```sh
npm ci --ignore-scripts
```

List tracked template markers:

```sh
cargo make list-template-markers
```

Run the complete Rust, Swift, TypeScript, and TOML validation gate:

```sh
cargo make check
```

### Architecture

DeskHelm is a workspace-first monorepo:

- the Rust core, CLI, and C ABI belong under `apps/deskhelm/`
- the native macOS app belongs under `apps/deskhelm/macos/`
- repository-maintenance programs belong under `scripts/`
- repository-native checks are exposed through `Makefile.toml`
- durable architecture, runbook, and routing notes belong under `openwiki/`

## Support Me

If you find this project helpful and would like to support its development, you can buy me a coffee!

Your support is greatly appreciated and motivates me to keep improving this project.

- **Fiat**
    - [Ko-fi](https://ko-fi.com/hack_ink)
    - [Afdian](https://afdian.com/a/hack_ink)
- **Crypto**
    - **Bitcoin**
        - `bc1pedlrf67ss52md29qqkzr2avma6ghyrt4jx9ecp9457qsl75x247sqcp43c`
    - **Ethereum**
        - `0x3e25247CfF03F99a7D83b28F207112234feE73a6`
    - **Polkadot**
        - `156HGo9setPcU2qhFMVWLkcmtCEGySLwNqa3DaEiYSWtte4Y`

Thank you for your support!

## Appreciation

We would like to extend our heartfelt gratitude to the following projects and contributors:

- The Rust community for their continuous support and development of the Rust ecosystem.

## Additional Acknowledgements

- TODO

---

<div align="right">

### License

<sup>Licensed under [GPL-3.0-only](LICENSE).</sup>

</div>
