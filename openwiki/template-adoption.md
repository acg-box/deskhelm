---
type: Migration Guide
title: DeskHelm Template Adoption
description: Records the completed conversion from the former workspace template to DeskHelm and identifies identity, runtime, release, documentation, and validation surfaces to keep aligned.
tags: [deskhelm, migration, template]
---

# DeskHelm Template Adoption

## Status

The repository has adopted the former workspace template as DeskHelm. The current worktree replaces the placeholder package and CLI with `apps/deskhelm/`, sets real workspace and npm identities, defines the shared Rust DDC/CI core and native macOS menu-bar prototype, rewrites the public README, and renames release package and artifact paths.

This page is no longer a procedure for an unstarted adoption. It records the coupled surfaces changed by the migration so future renames or product pivots do not leave mixed identity behind. Current runtime behavior is canonical in [Architecture and Runtime](architecture-and-runtime.md); commands are canonical in [Operations](operations.md).

Sources: `README.md`, `Cargo.toml`, `Cargo.lock`, `package.json`, `package-lock.json`, `apps/deskhelm/`, `.github/workflows/release.yml`.

## Completed Identity Transition

The migration changed these coupled values together:

- Cargo package, binary, and app directory: the former placeholder values changed to `deskhelm` and `apps/deskhelm/`.
- Private npm tooling package: the former placeholder value changed to `deskhelm-workspace`.
- Workspace description, homepage, and repository metadata to DeskHelm and `acg-box/deskhelm`.
- README content from placeholder/TODO guidance to the public product pitch, supported status, workspace ownership, installation, interaction, update, development, and release-download guidance.
- Release selectors, executable paths, archive names, artifact globs, and crates.io publication target to `deskhelm`.
- Placeholder logging/build-metadata runtime to a shared Rust library, direct CLI, C ABI, and AppKit/SwiftUI menu-bar app over the Apple Silicon DDC/CI transport.

The migration preserves the workspace-first ownership model: runnable code remains under `apps/`, maintenance TypeScript remains under `scripts/`, and `packages/` remains reserved for actual reuse.

## Runtime Replacement

The old parser accepted a single placeholder option and logged it. DeskHelm instead provides a shared Rust `read_volume`/`set_volume` core: the CLI exposes it through the required `volume` subcommand, while a native image-only AppKit status item owns a system menu and opens a reusable Settings window whose SwiftUI Display pane calls the core through a C ABI. The old project-directory logging, custom panic hook, and compile-time Git/target version build script were removed.

That replacement changes the risk profile: product correctness now depends on conservative display selection, DDC/CI packet validation, an undocumented macOS transport, C-memory ownership and panic containment, Swift confirmed-state behavior, and physical compatibility. Those contracts are detailed in [Architecture and Runtime](architecture-and-runtime.md#display-selection-and-safety), while build and test entrypoints are in [Operations](operations.md#native-app-build-and-run).

## Release Reconciliation

`.github/workflows/release.yml` now builds, packages, uploads, and publishes `deskhelm`. The GitHub Release job still depends on all matrix builds; crates.io publication remains independent and may run concurrently. The matrix includes Linux and Windows even though hardware operations are supported only on Apple Silicon macOS, so successful cross-platform compilation does not imply functional display control.

Any future package rename must update the app directory and manifest, root metadata and lockfiles, README commands, workflow package selectors, executable/archive names, crates.io target, and owning OpenWiki pages as one change. See [Operations](operations.md#release-pipeline) for the current exact flow.

## Residual Identity Checks

The tracked `scripts/list-template-markers.ts` helper remains after adoption so old identity cannot silently return:

```sh
npm ci --ignore-scripts
cargo make list-template-markers
```

A clean adopted repository should produce no marker records. The helper scans tracked files with `git grep`; it intentionally ignores untracked and ignored files. If Node/npm is unavailable, a narrowly scoped `rg` over repository source can bootstrap the same investigation, but the cargo-make task is the maintained command.

Also check manually that user-facing product names, repository URLs, release paths, and OpenWiki claims use DeskHelm consistently. Generated lockfiles should be regenerated with the pinned package manager rather than edited by hand.

## Knowledge Transition

`openwiki/` remains the maintained knowledge surface. Update the owning source or configuration first, then run the OpenWiki generator and review its changes. No recurring OpenWiki automation is authorized. [Knowledge Maintenance](knowledge-maintenance.md#manual-regeneration) owns the review and authority rules.

Generated text is not authoritative over source. Review it for unsupported claims, stale paths, and cross-page consistency.

## Validation

After future identity or runtime migrations, run the narrow checks while iterating and then the available full gate:

```sh
npm ci --ignore-scripts
cargo make list-template-markers
cargo make check
cargo run --locked -p deskhelm -- --help
cargo build --locked -p deskhelm --profile final-release
```

For hardware behavior, also run read and set operations on a supported Apple Silicon Mac and confirm the write readback. Independently verify OpenWiki links, cited paths, and routing from [Quickstart](quickstart.md); source validation does not replace documentation review.
