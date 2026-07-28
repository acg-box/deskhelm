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

#### Keyboard Volume Keys

Keyboard volume control starts automatically. If Accessibility access is
missing, open **Settings > Volume Keys** and select **Grant**. DeskHelm
opens the correct macOS settings page and shows a floating guide with a
draggable app chip. It does not request the native macOS Accessibility prompt.
The guide closes when you close DeskHelm Settings. After you grant access,
DeskHelm starts volume-key interception automatically.

DeskHelm intercepts volume-up and volume-down only when the current output
uniquely matches the supported LG display. macOS classifies this USB-C audio
route as a DisplayPort transport. Other outputs, including Bluetooth
headphones and Mac speakers, keep normal system volume-key behavior. Set
`DESKHELM_CODE_SIGN_IDENTITY` to an authorized Apple Development identity when
Accessibility authorization must persist across rebuilds.

DeskHelm follows the macOS **Play feedback when volume is changed** preference.
A tap plays the installed macOS volume cue through the current LG audio endpoint
after its final DDC/CI preview write is accepted. A held key does not stack a cue
for every system repeat: it plays once on release. At maximum volume, the cue
starts immediately and repeats about once per second until release. Holding
Shift alone reverses the feedback preference for that key sequence, as macOS
does. A failed write or output-route change stays silent.

During display reconfiguration or a temporary DDC/CI failure, DeskHelm stops
interception and cancels queued display work, so volume keys return to macOS. It
discards the old display session. After the connection settles, it discovers the
display again, uses bounded fresh reads, and restores interception.

Open **Settings > General** to enable launch at login. The About pane shows the
current update configuration. A source build without a signed Sparkle appcast
opens GitHub Releases instead of claiming that an in-app update is available.

### Interaction

Select the image-only DeskHelm menu-bar icon to open its native menu. Select
**Settings…**, or press Command-, while DeskHelm is active. Press Command-Q to
quit. Settings uses four compact toolbar panes: Display, Volume Keys, General,
and About.

Use the Display pane to drag the volume control, use the arrow keys, or use the
VoiceOver adjustable action. DeskHelm coalesces rapid preview writes and
confirms the final target through hardware readback. When keyboard volume
control is enabled, a transient HUD shows accepted LG volume changes.

Audible feedback starts after the display transport accepts the final preview
write; the later readback remains the authoritative confirmed value. If the
compatible macOS sound resource is not available, volume control continues
without a cue and DeskHelm records the condition in its log.

Use the CLI to read or set the display volume:

```sh
cargo run --locked -p deskhelm -- volume
cargo run --locked -p deskhelm -- volume 25
```

Confirm native menu construction, or also open and validate Settings:

```sh
./script/build_and_run.sh --verify
./script/build_and_run.sh --verify-settings
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

The AppKit shell owns an image-only `NSStatusItem`, a native `NSMenu`, a reusable
Settings window, and the transient HUD panel. SwiftUI owns the Settings panes
and HUD content. Both the app and CLI call the Rust DDC/CI core directly; they
do not invoke another display-control CLI.

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
