---
type: Getting Started Guide
title: DeskHelm Quickstart
description: Introduces the DeskHelm native macOS status-menu app, four-pane Settings workflow, shared Rust CLI, supported LG 39GX950B USB-C hardware path, and validation commands.
tags: [deskhelm, quickstart, macos, ddc-ci]
---

# DeskHelm Quickstart

## What This Repository Is

DeskHelm is an early native macOS menu-bar prototype for controlling audio volume on an external LG display. A Rust core reads and sets DDC/CI VCP feature `0x62`; both a command-line interface and a native AppKit/SwiftUI app use that same core. DeskHelm does not invoke another display-control executable.

The Rust package lives in `apps/deskhelm/`. Its `rlib` supports the CLI and its `staticlib` exposes a narrow C ABI to the SwiftPM package under `apps/deskhelm/macos/`. The app uses an AppKit `NSStatusItem` with a native menu and a reusable Settings window whose SwiftUI panes own display control, volume-key setup, login behavior, and update preferences. [Architecture and Runtime](architecture-and-runtime.md) explains that call path and the hardware safety boundary. [Operations](operations.md) owns exact build, test, staging, launch, and diagnostic commands.

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

DeskHelm normally runs with accessory activation policy and `LSUIElement=true`, so it has no Dock icon. Select its square, image-only control-deck status icon to open the native menu. Choose **Settings…**, or press Command-, while DeskHelm is active, to open the reusable Settings window; Command-Q quits. Its compact toolbar switches among Display, Volume Keys, General, and About panes.

The Display pane starts a hardware refresh when it appears. The first successful refresh creates a verified display session and enables the volume control. Pointer dragging updates the UI immediately and sends coalesced latest-target preview writes through that session; arrow keys and the VoiceOver adjustable action move by one point. A preview does not replace the confirmed value. DeskHelm reads the final target back after 150 ms without new input, or immediately when a drag ends. Selecting refresh during preview or confirmation retains one request and reads when the active work finishes. A mismatch triggers one exact write and readback. If recovery cannot read the display, DeskHelm clears the confirmed state and disables adjustment instead of restoring an unverified old value.

Confirm that the launched app created its AppKit status item:

```sh
./script/build_and_run.sh --verify
```

This verifies app-owned native status-menu construction, not whether macOS has enough visible menu-bar space. To also open Settings and verify that AppKit made its window visible, key, main, on-screen, and toolbar-backed, run:

```sh
./script/build_and_run.sh --verify-settings
```

Neither diagnostic proves toolbar interaction, Accessibility prompting or app dragging, login-item registration, Sparkle presentation, media-key interception, HUD presentation, or physical DDC/CI behavior. See [Architecture and Runtime](architecture-and-runtime.md#native-appkit-shell-and-settings) for lifecycle and state details, and [Operations](operations.md#script-modes-and-diagnostics) for the exact diagnostic contract.

### Optional Keyboard Volume Keys

Open **Settings > Volume Keys**. If Accessibility access is missing, request it, open the correct System Settings page, or drag the DeskHelm app chip into the Accessibility application list; then enable **Keyboard Volume Control**. While enabled, each volume-up or volume-down press or system repeat moves the display by one point only when the current macOS default audio output is the one unique matching LG UltraGear route that Core Audio classifies as DisplayPort. The verified physical connection remains USB-C. Holding a key uses the existing macOS repeat events for continuous adjustment. DeskHelm coalesces rapid repeats into latest-target preview writes and confirms once after input stops. When Settings is not being presented, an app-owned transient HUD shows the projected value; opening Settings dismisses that HUD and suppresses a second overlay. Mute is not intercepted.

DeskHelm follows the macOS **Play feedback when volume is changed** preference. It plays the installed macOS volume cue through the same LG Core Audio endpoint after the final preview write is accepted and the key is released. A held key produces one release cue instead of one cue for every repeat. At maximum volume, feedback starts immediately and repeats about once per second until release. Holding Shift alone reverses the preference for that key sequence. A failed write, canceled sequence, or route change stays silent. This cue marks DDC/CI transport acceptance; the later readback remains authoritative. If the compatible system sound cannot be loaded, volume control continues without audible feedback.

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

The Swift tests cover volume-state validation, refresh outcomes, one requested refresh waiting for an active preview, a direct caller joining that request, preview coalescing and cancellation, automatic and release-time confirmation, stale-result protection, hardware-state recovery, cadence-derived animation planning, presentation-scalar clamping, per-place digit-transition mapping, media-key decoding, one-point adjustment, feedback preference and modifier policy, release and held-key feedback sequencing, maximum-volume cadence, route loss, and launch-plan selection for Settings verification. They do not render-test the custom pointer, keyboard, or VoiceOver control, rolling number, Settings toolbar and focus, permission dragging, login-item registration, Sparkle UI, or Settings/HUD coordination. They also do not play audio or validate `NSSound` device routing. Rust tests cover the CLI, session identity policy, DDC message pacing, packet behavior, and C ABI ownership. Neither suite replaces live Accessibility/event-tap checks or a physical LG 39GX950B check. [Operations](operations.md#public-check-aggregate) gives the full task contract and diagnostic sequence.

## Wiki Map

- [Architecture and Runtime](architecture-and-runtime.md) - Rust core, C ABI, AppKit status menu and Settings shell, SwiftUI display workflow, app services, DDC/CI flow, and hardware boundary.
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
