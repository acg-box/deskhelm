---
type: Getting Started Guide
title: DeskHelm Quickstart
description: Introduces the DeskHelm native macOS menu-bar app and shared Rust CLI, supported LG 39GX950B USB-C hardware path, build commands, and documentation map.
tags: [deskhelm, quickstart, macos, ddc-ci]
---

# DeskHelm Quickstart

## What This Repository Is

DeskHelm is an early native macOS menu-bar prototype for controlling audio volume on an external LG display. A Rust core reads and sets DDC/CI VCP feature `0x62`; both a command-line interface and a native AppKit/SwiftUI app use that same core. DeskHelm does not invoke another display-control executable.

The Rust package lives in `apps/deskhelm/`. Its `rlib` supports the CLI and its `staticlib` exposes a narrow C ABI to the SwiftPM package under `apps/deskhelm/macos/`. The app uses an AppKit `NSStatusItem` and transparent borderless `NSPanel` to host a SwiftUI volume panel. [Architecture and Runtime](architecture-and-runtime.md) explains that call path and the hardware safety boundary. [Operations](operations.md) owns exact build, test, staging, launch, and diagnostic commands.

Sources: `README.md`, `apps/deskhelm/Cargo.toml`, `apps/deskhelm/src/`, `apps/deskhelm/macos/`, `script/build_and_run.sh`.

## Requirements

- An Apple Silicon Mac; the menu-bar app requires macOS 14 or later.
- One external LG display with DDC/CI enabled and audio volume exposed as 0–100.
- A cable, adapter, or dock path that passes DDC/CI traffic.
- Xcode/Swift 6.2 for the native app build; the repository Rust toolchain for the core and CLI.

The verified hardware point is an LG 39GX950B (`1e6d:7863`) connected directly to an M4 Max Mac over USB-C. macOS presents its DisplayPort Alt Mode connection through an external DCP/DP service path; that software path does not change the physical connector from USB-C. Compatibility still varies by display firmware and connection path.

## Run The Menu-Bar App

Build the Rust core and Swift package, stage `DeskHelm.app`, and open it:

```sh
./script/build_and_run.sh
```

DeskHelm runs with accessory activation policy and `LSUIElement=true`, so it has no Dock icon. Select its square control-deck status icon; the item has no text title. It opens a transparent borderless nonactivating panel that sizes itself to the hosted SwiftUI content and stays within the visible screen. The first successful refresh creates a verified display session and enables the slider. Dragging updates the UI immediately and sends coalesced latest-target preview writes through that session. A preview does not replace the confirmed value. DeskHelm reads the final target back after 150 ms without new input, or immediately on release. A mismatch triggers one exact write and readback. If recovery cannot read the display, DeskHelm clears the confirmed state and disables adjustment instead of restoring an unverified old value.

Confirm that the launched app created its AppKit status item:

```sh
./script/build_and_run.sh --verify
```

This verifies the app-owned status item, not whether macOS has enough visible menu-bar space. To also open the panel and verify that AppKit made it visible, key, nonactivating, and positioned on the status item's screen, run:

```sh
./script/build_and_run.sh --verify-panel
```

Neither diagnostic proves click-away dismissal, Accessibility prompting, media-key interception, HUD presentation, or physical DDC/CI behavior. On macOS 26 or later the panel uses public Liquid Glass APIs; macOS 14 through 25 use adaptive system material. See [Architecture and Runtime](architecture-and-runtime.md#native-appkit-shell) for lifecycle and state details, and [Operations](operations.md#script-modes-and-diagnostics) for the exact diagnostic contract.

### Optional Keyboard Volume Keys

From the panel's ellipsis menu, select **Enable Volume Keys…**. DeskHelm first confirms that it can read the display, then asks for macOS Accessibility permission; after granting access, select the command again. While enabled, each volume-up or volume-down press or system repeat moves the display by one point only when the current macOS default audio output is the one unique matching LG UltraGear DisplayPort route. Holding a key uses the existing macOS repeat events for continuous adjustment. DeskHelm coalesces rapid repeats into latest-target preview writes, confirms once after input stops, and shows an app-owned passive HUD. Mute is not intercepted.

This opt-in path receives only macOS system-defined events. It consumes recognized volume-up/down events for the target display, but passes them through for Mac speakers, headphones, other displays, an ambiguous LG match, or an unreadable output route; Accessibility trust is broader than that filter. If permission is missing, macOS disables the event tap, or display communication fails, DeskHelm stops interception so later keys return to normal system handling. [Architecture and Runtime](architecture-and-runtime.md#optional-keyboard-volume-control) owns the security, routing, lifecycle, and failure contract.

## Run The CLI

```sh
cargo build --locked -p deskhelm
cargo run --locked -p deskhelm -- volume
cargo run --locked -p deskhelm -- volume 25
```

A successful command prints `<display>: <current>/<maximum>`. Input outside 0–100 is rejected before hardware access. A set first requires maximum 100, writes the value, then reads it back and fails unless the display confirms the request. DeskHelm also stops for no external display, a non-LG display, more than one external display, or no unique matching DDC/CI service.

## Validate Changes

Install the locked TypeScript tool graph and run the repository aggregate:

```sh
npm ci --ignore-scripts
cargo make check
```

On macOS, the aggregate builds the native app and runs its Swift tests in addition to Rust and TypeScript compilation, formatting, lint, vstyle, and tests. Run only the Swift tests with:

```sh
./script/build_and_run.sh --test
```

The Swift tests cover volume-state validation, refresh outcomes, preview coalescing, automatic and release-time confirmation, stale-result protection, hardware-state recovery, media-key decoding, and one-point adjustment. Rust tests cover the CLI, session identity policy, DDC message pacing, packet behavior, and C ABI ownership. Neither suite replaces live Accessibility/event-tap checks or a physical LG 39GX950B check. [Operations](operations.md#public-check-aggregate) gives the full task contract and diagnostic sequence.

## Wiki Map

- [Architecture and Runtime](architecture-and-runtime.md) - Rust core, C ABI, AppKit shell, SwiftUI panel, DDC/CI flow, and LG 39GX950B USB-C boundary.
- [Operations](operations.md) - SwiftPM build-and-run script, Swift tests, repository validation, CI, and CLI release packaging.
- [Template Adoption](template-adoption.md) - completed transition from the placeholder template to DeskHelm and identity consistency checks.
- [Knowledge Maintenance](knowledge-maintenance.md) - OpenWiki routing, claim ownership, manual regeneration, evidence rules, and historical documentation decisions.

## Repository Boundaries

- `apps/deskhelm/src/` owns the Rust core, C ABI, and CLI; `apps/deskhelm/macos/` owns the SwiftPM native app.
- `script/build_and_run.sh` owns local native build, staging, launch, and diagnostics. `scripts/` separately owns Node.js-executed TypeScript maintenance programs.
- `packages/` is reserved for reusable packages. Root `Cargo.toml` owns workspace membership and shared Rust versions.
- `Makefile.toml` owns local validation tasks. Existing GitHub workflows continue to own CI and CLI release orchestration.
- `openwiki/` is the maintained repository knowledge surface. [Knowledge Maintenance](knowledge-maintenance.md) defines how to update it without creating competing documentation or recurring automation.

## Before Changing Anything

1. Read the page that owns the affected contract and verify it against cited source.
2. Keep the Rust API, C header, and Swift adapter aligned when changing the native boundary.
3. Preserve strict one-display selection, 0–100 validation, preview-versus-confirmed state separation, final readback, and failure recovery unless the product contract deliberately changes.
4. Run the narrow Rust or Swift check while iterating, then `cargo make check` when prerequisites are available.
5. Verify hardware-affecting changes on the documented USB-C LG 39GX950B setup and record any untested boundary explicitly.
