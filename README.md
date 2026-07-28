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

DeskHelm has a Rust display core and a Swift native application layer. The Rust
display core owns display discovery and identity verification, DDC/CI transport,
verified sessions, the CLI, and the C ABI. The Swift layer owns the macOS
lifecycle, application state, Core Audio route qualification, media-key handling,
and AppKit/SwiftUI presentation. The Swift app links the Rust core in process;
neither product entrypoint invokes another display-control executable.

## Status

DeskHelm is an early Apple Silicon macOS prototype. The verified hardware point
is an LG 39GX950B connected directly to an M4 Max Mac through USB-C. Display
firmware, cables, adapters, and docks can change DDC/CI compatibility.

## Workspace Posture

- `apps/deskhelm/` owns the Rust display core, CLI, and C ABI.
- `apps/deskhelm/macos/` owns the Swift native application layer, including app
  state, native services, and AppKit/SwiftUI presentation.
- `script/` owns native build, release, and diagnostic commands, while
  `scripts/` owns repository-maintenance TypeScript programs.
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

#### Download DeskHelm for macOS

Stable [GitHub Releases](https://github.com/acg-box/deskhelm/releases/latest)
provide `deskhelm-aarch64-apple-darwin.zip`. The archive contains the signed and
unnotarized `DeskHelm.app` for Apple Silicon. On first launch, macOS can block
the app because this open-source release uses a free Apple Development
certificate. Open **System Settings > Privacy & Security**, select **Open
Anyway** for DeskHelm, then confirm **Open**. DeskHelm does not publish Windows
or Linux archives because display control is not implemented on those platforms.

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
current update configuration. A source build without the production Sparkle
public key opens GitHub Releases instead of claiming that an in-app update is
available.

### Interaction

Select the image-only DeskHelm menu-bar icon to open its native menu. Select
**Settings…**, or press Command-, while DeskHelm is active. Press Command-Q to
quit. Settings uses four compact toolbar panes: Display, Volume Keys, General,
and About. Settings and update windows keep DeskHelm in accessory mode, so they
do not add a Dock icon.

Use the Display pane to drag the volume control, use the arrow keys, or use the
VoiceOver adjustable action. DeskHelm coalesces rapid preview writes and
confirms the final target through hardware readback. When keyboard volume
control is enabled, a transient HUD shows accepted LG volume changes, including
while Settings is open. The HUD does not take keyboard focus from Settings.

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

A distributed app uses `appcast.xml`; each enclosure carries the Sparkle
signature for its release archive. Open **Settings > About** and select
**Check Now**, or choose an automatic update mode. A source build has no
production update key and opens GitHub Releases instead.

To update a source build, pull `main` and rebuild:

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

Run the credential-free release contract checks separately when changing the
release workflow:

```sh
cargo make test-release
```

### Release Maintainers

The release workflow starts only for an annotated `vX.Y.Z` tag. The tag version
must match the workspace version, and its commit must be reachable from the
canonical `main` branch. The workflow validates on Linux, builds and signs the
app on `macos-26`, then returns to Linux to validate a GitHub draft before
it publishes the draft. All tag releases share one non-canceling concurrency
group. Before it changes a draft and again immediately before publication, the
publisher checks the remote annotated tag, `main` ancestry, and every published
stable version. A release must advance the complete stable history.

The Node 24 TypeScript publisher validates local artifacts before its first
GitHub mutation. It repairs only a same-tag private draft by replacing all draft
assets with the exact release triplet. After the final source and version checks,
it downloads and validates the exact draft bytes again as the last operation
before publication. It then fetches the public release and validates its
downloaded bytes. A retry of an already public same-tag release is read-only and
validates the downloaded public bytes. The publisher also supports a
credential-free `--dry-run` that performs local validation only. There is no
manual preparation, `workflow_dispatch`, or dry-run workflow.

The checked-in `script/release/sparkle-public-ed-key.txt` contains DeskHelm's
public Sparkle key. Configure the matching private key as the repository secret
`DESKHELM_SPARKLE_PRIVATE_ED_KEY`. The key verifier accepts the Sparkle 2.9.4
32-byte seed and legacy 96-byte secret formats, and rejects a private secret
whose public key does not match the checked-in key. Make these organization
secrets available to the repository:

- `APPLE_CERTIFICATE_P12_BASE64`
- `APPLE_CERTIFICATE_PASSWORD`
- `APPLE_SIGNING_IDENTITY`

DeskHelm must use its own Sparkle key pair. Do not reuse another application's
private or public key. The `release` environment protects only the final Linux
publisher. The release scripts bind Apple Development signing to Personal Team
`RD3D4LH465`; a different Apple team is rejected. The build uses Hardened
Runtime without a signing timestamp and is not notarized. Only the final
publisher receives GitHub contents write permission. The workflow does not
publish the Rust crate.

### Architecture

DeskHelm is a workspace-first monorepo:

- the Rust display core, CLI, and C ABI belong under `apps/deskhelm/`
- the Swift native application layer belongs under `apps/deskhelm/macos/`
- repository-maintenance programs belong under `scripts/`
- repository-native checks are exposed through `Makefile.toml`
- durable architecture, runbook, and routing notes belong under `openwiki/`

The Swift native application layer uses AppKit for the status menu, windows, and
HUD panel, and it uses SwiftUI for Settings and HUD content. It also owns native
app state and services. The Rust display core remains the sole owner of display
discovery, verified DDC/CI sessions, and transport. The app links that core in
process, and the CLI calls the same Rust API.

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
