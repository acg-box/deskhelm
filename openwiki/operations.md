---
type: Operations Runbook
title: DeskHelm Operations and Validation
description: Documents DeskHelm Rust and Swift builds, Sparkle-aware app staging and signing, native status-menu and Settings diagnostics, validation, CI, and release packaging.
tags: [deskhelm, operations, swiftpm, ci, release]
---

# Operations And Validation

## Preconditions

Repository-native tasks are declared in `Makefile.toml` and invoked with `cargo make <task>`. Install only what the selected task needs:

| Tool | Needed by |
| --- | --- |
| Project Rust toolchain from `rust-toolchain.toml` | Rust check, lint, test, and build tasks |
| Nightly toolchain with rustfmt | `fmt-rust`, `fmt-rust-check` |
| Node.js/npm from `.node-version` | TypeScript check, format, lint, test, and template-marker tasks |
| Xcode/Swift 6.2 on macOS | SwiftPM app build and Swift tests; the app supports macOS 14 or later |
| `cargo-make` | Every `cargo make` entrypoint |
| `taplo` | TOML format tasks |
| `cargo-vstyle` | vstyle tasks and the composite lint/full gates |
| `cargo-nextest` | test tasks |

`rust-toolchain.toml` is the sole selector for ordinary Rust commands. It selects stable with the minimal profile and adds Clippy; Cargo and rustc come from that profile. Rust formatting is the only explicit toolchain exception: `fmt-rust` and `fmt-rust-check` run nightly rustfmt because `.rustfmt.toml` uses nightly features. Third-party Cargo tools remain separate prerequisites. `.node-version`, `package.json`, and `package-lock.json` pin Node.js, npm, and the TypeScript development graph. Run `npm ci --ignore-scripts` before a TypeScript task or the full aggregate; repository tasks validate but do not install dependencies. On macOS, `script/build_and_run.sh` requires `/Applications/Xcode-beta.app` when `DEVELOPER_DIR` is unset. SwiftPM declares tools version 6.2 and a macOS 14 deployment minimum. CI reads the ordinary Rust toolchain and components from `rust-toolchain.toml`, installs nightly rustfmt separately, installs Taplo for the TOML job, and performs the locked npm install for the TypeScript job.

Sources: `rust-toolchain.toml`, `Makefile.toml`, `.node-version`, `package.json`, `package-lock.json`, `.github/workflows/language.yml`, `.github/workflows/release.yml`.

## Public Check Aggregate

```sh
cargo make check
```

`check` is a cargo-make composite whose dependencies are `check-rust`, macOS-only `check-swift`, `check-typescript`, `fmt-check`, `lint`, and `test`. `check-swift` runs the native build script with `--build-only`; `test` includes macOS-only `test-swift`, which runs the script with `--test`. On non-macOS hosts cargo-make skips those conditioned tasks. `Makefile.toml` establishes the dependency set but does not state a runtime ordering contract. When deterministic, fail-fast diagnosis matters, invoke the targeted commands explicitly in this recommended sequence:

```sh
cargo make fmt-check
cargo make check-rust
cargo make check-typescript
cargo make lint
cargo make test
```

This diagnostic order catches mechanical formatting drift before compilation/lint/test analysis; it does not change the task definitions. `check` is the public aggregate for source validation, but it no longer includes the deleted Decodex `check-docs` task. Review OpenWiki separately with the focused checks in [Knowledge Maintenance](knowledge-maintenance.md#openwiki-drift-check).

## Complete Task Matrix

| Task | Exact behavior | Mutates files? |
| --- | --- | --- |
| `check` | Composite: `check-rust`, macOS-only `check-swift`, `check-typescript`, `fmt-check`, `lint`, `test` | Build/tool caches |
| `check-rust` | `cargo check --all-features --all-targets --workspace` | Build cache only |
| `check-swift` | On macOS, run `./script/build_and_run.sh --build-only` | Rebuilds Cargo/Swift caches without staging or launching |
| `check-typescript` | Run the installed TypeScript compiler with `--noEmit --project tsconfig.json` | Tool cache only |
| `fmt` | Composite: `fmt-rust`, `fmt-toml`, `fmt-typescript` | Yes |
| `fmt-check` | Composite: `fmt-rust-check`, `fmt-toml-check`, `fmt-typescript-check` | No |
| `fmt-rust` | `rustup run nightly cargo fmt --all` | Yes |
| `fmt-rust-check` | Same with `-- --check` | No |
| `fmt-toml` | `taplo fmt` | Yes |
| `fmt-toml-check` | `taplo fmt --check` | No |
| `fmt-typescript` | Oxfmt over `scripts/` and the owned TypeScript JSON configuration files | Yes |
| `fmt-typescript-check` | Same Oxfmt scope with `--check` | No |
| `lint` | Composite: `lint-rust`, `lint-typescript`, `lint-vstyle` | No |
| `lint-fix` | Composite: `lint-fix-rust`, `lint-fix-typescript`, `lint-fix-vstyle` | Yes |
| `lint-rust` | Workspace/all-target/all-feature Clippy with repository deny policy | Build cache only |
| `lint-fix-rust` | Same Clippy policy with `--fix --allow-dirty` | Yes |
| `lint-typescript` | Oxlint over `scripts/` with the checked-in type-aware deny policy | No |
| `lint-fix-typescript` | Same Oxlint policy with safe `--fix`; suggestions and dangerous fixes remain disabled | Yes |
| `lint-vstyle` | Composite: `lint-vstyle-rust` | No |
| `lint-vstyle-rust` | `cargo vstyle curate --language rust --workspace --all-features --strict` | No |
| `lint-fix-vstyle` | Composite: `lint-fix-vstyle-rust` | Yes |
| `lint-fix-vstyle-rust` | `cargo vstyle tune --language rust --workspace --all-features --strict` | Yes |
| `list-template-markers` | Run the tracked-file marker inventory through Node.js | No |
| `test` | Composite: `test-rust`, macOS-only `test-swift`, `test-typescript` | Build/tool caches only |
| `test-rust` | `cargo nextest run --workspace --all-targets --all-features` | Build cache only |
| `test-swift` | On macOS, build the Rust library and run `swift test` through `./script/build_and_run.sh --test` | Cargo/Swift build caches only |
| `test-typescript` | `node --test` over the discovered `*.test.ts` files | Tool cache only |

The Clippy tasks deny `clippy::all`, `clippy::too_many_lines`, `clippy::unwrap_used`, `clippy::use_self`, `clippy::wildcard_imports`, `missing-docs`, `unused-crate-dependencies`, and all warnings. `clippy.toml` allows unwrap only in tests, sets a 120-line threshold, and warns on wildcard imports. Rust formatting intentionally uses nightly features from `.rustfmt.toml`; Taplo excludes `Makefile.toml` and generated/local trees.

The TypeScript compiler enables strict checking, indexed-access uncertainty, exact optional-property semantics, control-flow checks, and Node-erasable syntax. Oxlint denies correctness, suspicious, and performance diagnostics plus explicit `any`, unsafe type operations, non-null assertions, unhandled or misused promises, non-`Error` throws, and non-exhaustive switches. Warnings and unused suppression directives fail the task. Oxfmt is the sole TypeScript formatter; the prior root Prettier files were unused and are removed. The npm lock contains platform-specific optional binary packages for TypeScript and Oxc; `.npmrc` disables lifecycle scripts and requires exact saved versions.

History: commit `452039e` separated `cargo check` from Clippy and made task contracts explicit; `b250fc0` split vstyle wrappers by language for monorepo extension.

Sources: `Makefile.toml`, `clippy.toml`, `.rustfmt.toml`, `.taplo.toml`, `tsconfig.json`, `.oxfmtrc.json`, `.oxlintrc.json`, `.npmrc`; history: commits `452039e`, `b250fc0`.

## TypeScript Template Maintenance

Install the exact development graph and list every tracked template marker:

```sh
npm ci --ignore-scripts
cargo make list-template-markers
```

The marker script forwards `git grep` output as `path:line:text` records. A marker record means the repository still contains template identity. No marker records means no configured marker was found; cargo-make can still print its own task status. Both inventory results are successful; inability to execute Git or another Git failure fails the task. The helper scans all tracked files, so it does not read untracked or ignored secret-bearing files.

Before Node/npm is installed, use a narrowly scoped `rg` fallback over repository source as described in [Template Adoption](template-adoption.md#residual-identity-checks). Keep that fallback for bootstrap only; `list-template-markers` owns the installed repository command.

Sources: `scripts/list-template-markers.ts`, `scripts/list-template-markers.test.ts`, `Makefile.toml`, `openwiki/template-adoption.md`.

## Native App Build And Run

The repository-owned SwiftPM entrypoint builds the Rust static library, links the Swift package, verifies the executable's linked SDK identity, creates a local app bundle, and opens it:

```sh
./script/build_and_run.sh
```

The script uses `DESKHELM_CONFIGURATION=debug` by default; set it to `release` for Cargo and Swift release builds. It exports `DESKHELM_RUST_LIB_DIR` as `target/<configuration>` so `apps/deskhelm/macos/Package.swift` can link `libdeskhelm`. Swift build, test, and binary-path queries receive explicit `-platform_version macos` linker arguments with deployment minimum 14.0 and the SDK version selected by `xcrun`; after an app build, `vtool` must report that same linked SDK or the script fails. This avoids SwiftPM's swiftbuild backend recording the deployment target as both build-version values, which would lose current linked-on UI behavior.

Every non-test mode now stages `apps/deskhelm/macos/dist/DeskHelm.app`, including `--build-only`. The staged bundle contains executable `DeskHelmMac`, bundle ID `com.acgbox.deskhelm`, macOS 14 minimum, `LSUIElement=true`, and the exact SwiftPM Sparkle 2.9.4 framework under `Contents/Frameworks`. Staging removes development-only rpaths, adds `@executable_path/../Frameworks` when missing, signs the framework and app, verifies the deep signature, and confirms the executable links Sparkle. Signing is ad hoc by default; `DESKHELM_CODE_SIGN_IDENTITY` selects an authorized Apple Development identity when Accessibility authorization must persist across rebuilds.

`DESKHELM_SPARKLE_APPCAST_URL` and `DESKHELM_SPARKLE_PUBLIC_ED_KEY` are optional staging inputs and must be supplied together. When present, the script adds the HTTPS feed, Ed25519 public key, daily checks, and automatic-update capability to `Info.plist`; `SoftwareUpdater` still validates the feed URL and requires a base64-decoded 32-byte public key before enabling Sparkle. When absent, the app labels the action **View Releases…** and opens GitHub Releases. These values are release configuration, not source defaults. This local development bundle remains separate from the CLI artifact produced by the release workflow.

```mermaid
flowchart TD
    Start["Run build_and_run.sh"] --> Rust["Build locked Rust library"]
    Rust --> Mode{"Selected mode"}
    Mode -->|test| Tests["Run swift test"]
    Mode -->|other| Swift["Build SwiftPM executable"]
    Swift --> SDK["Verify linked SDK identity"]
    SDK --> BuildOnly{"Build only"}
    BuildOnly -->|yes| Stage["Stage and sign DeskHelm.app"]
    BuildOnly -->|no| Stage
    Stage --> Finish{"Build only"}
    Finish -->|yes| Stop["Report staged app"]
    Finish -->|no| Launch["Stop prior process and open app"]
    Launch --> Action{"Run or diagnostic mode"}
    Action --> Verify["Verify native status menu"]
    Action --> VerifySettings["Verify Settings window state"]
    Action --> Debug["Attach LLDB"]
    Action --> Logs["Stream unified logs"]
    Action --> Telemetry["Record Time Profiler trace"]
```

The script owns the native build, staging, launch, and diagnostic branches.

### Script Modes And Diagnostics

| Mode | Behavior |
| --- | --- |
| no argument or `--run` | Build Rust and Swift, stage the app, replace a running `DeskHelmMac`, and launch |
| `--build-only` | Build Rust and Swift, verify the linked SDK, stage and sign the app with Sparkle, and stop without launching; used by `check-swift` |
| `--test` | Build the Rust library and run Swift tests with the explicit platform-version linker arguments, without staging or launching |
| `--verify` | Launch, then confirm the process stays alive and publishes the expected native `NSStatusItem` menu readiness state |
| `--verify-settings` | Launch with Settings requested, then confirm status-menu readiness plus visible, key, main, on-screen Settings state, toolbar/pane metadata, and positive dimensions |
| `--debug` | Launch and attach LLDB to the process |
| `--logs` | Launch and stream unified logs for `DeskHelmMac` |
| `--telemetry` | Launch and record a Time Profiler trace under `apps/deskhelm/macos/dist/` |

`--verify` checks through app-published `UserDefaults` that DeskHelm created its square, image-only status item and attached a native menu. It cannot prove that macOS visually presents the item when menu-bar space, a notch, or a third-party menu manager intervenes. `--verify-settings` additionally checks the published Settings phase, visibility, key/main state, screen intersection, icon-toolbar pane metadata, window number, and dimensions. Both normal and Settings-verification launches start the always-on volume-key controller; missing Accessibility trust remains silent and opens no permission UI. Neither mode tests menu and toolbar interaction, Accessibility trust changes, permission-guide interaction or drag-and-drop, login registration, Sparkle UI, successful media-key interception, the transient HUD, or physical DDC/CI behavior. The app lifecycle behind these checks is documented in [Architecture and Runtime](architecture-and-runtime.md#native-appkit-shell-and-settings), and the event path is documented in [Architecture and Runtime](architecture-and-runtime.md#keyboard-volume-control).

SwiftPM declares two test targets. `DeskHelmAppCoreTests` exercises always-on launch actions in normal and Settings-verification modes, initial-loading visibility, refresh-state separation, one requested refresh waiting for an active preview, a direct caller joining that request, explicit skipped-refresh reporting while busy, continuous draft clamping, volume-state validation, refresh behavior, latest-target preview coalescing, preview-acceptance joining and cancellation, automatic and release-time confirmation, refresh and stale-result races, failure recovery, cadence-derived animation planning, shared visual-presentation clamping, per-place digit-transition mapping, decoder allowlisting, system-repeat acceptance, one-point media-key adjustment, active-interception state, and generation-token cancellation or replacement of in-flight enable requests. `DeskHelmMacTests` links the executable target and Sparkle. Its controller tests cover full event forwarding, off-route cancellation, silent startup without Accessibility, grant/revoke/regrant, idempotent start, transient display-failure recovery, queued-write cancellation, in-flight-write/reset ordering, stale pre-reconfiguration read rejection, pre-settlement gating, and invalidation during a blocked read or scheduled recovery. Display-reconfiguration monitor tests cover callback-burst coalescing, waiting for a post-change callback, ordered callback delivery, and dropping queued delivery after deactivation. Feedback tests cover system preference and standalone-Shift inversion, resource fallback order, final accepted-write release playback, held-key coalescing, stale sequence replacement, failure silence, maximum-volume cadence, route loss, and cancellation.

The suites do not separately cover a refresh requested during confirmation or duplicate button requests. They also do not exercise the custom control's pointer, keyboard, or VoiceOver interaction, rolling-number rendering, native menu commands, Settings toolbar/window focus, a live Accessibility trust change or permission-guide drag, login-item registration, Sparkle UI, Settings/HUD coordination, the live event tap, live Core Graphics callbacks on physical hot-plug hardware, rendered interpolation, actual `NSSound` output routing, audible cadence, recovery wall-clock timing, or opaque-session timing on physical hardware. The tested contracts support the [SwiftUI Display and keyboard HUD runtime](architecture-and-runtime.md#swiftui-display-settings).

Sources: `script/build_and_run.sh`, `apps/deskhelm/macos/Package.swift`, `apps/deskhelm/macos/Sources/`, `apps/deskhelm/macos/Tests/`, `Makefile.toml`.

## CLI Build And Run

Common CLI commands are direct Cargo commands rather than cargo-make tasks:

```sh
cargo build --locked -p deskhelm
cargo run --locked -p deskhelm -- volume
cargo run --locked -p deskhelm -- volume 25
cargo build --locked -p deskhelm --profile final-release
```

- The `volume` subcommand reads when `LEVEL` is omitted. It sets an integer from 0 through 100 only after the display reports a 0–100 volume range.
- Default debug output is `target/debug/deskhelm`; `final-release` output is `target/final-release/deskhelm` unless `--target` adds a target-triple directory.
- Hardware operations are implemented only for Apple Silicon macOS and compatible DDC/CI paths. Other compiled targets return an explicit unsupported-platform error.
- Release reproducibility relies on `--locked`; an out-of-date lockfile is a release blocker rather than permission to omit the flag.

The CLI reaches the conservative display-selection and DDC/CI pipeline described in [Architecture and Runtime](architecture-and-runtime.md#display-selection-and-safety).

Sources: `README.md`, `Cargo.toml`, `apps/deskhelm/Cargo.toml`, `apps/deskhelm/src/cli.rs`, `apps/deskhelm/src/display.rs`.

## CI Checks

Current `.github/workflows/language.yml` runs on pushes and pull requests targeting `main`, plus merge queues. It has no path filters, so documentation-only changes trigger the language checks too.

Three jobs run independently:

- **Rust check:** rustfmt check → Cargo check → vstyle action → Clippy → nextest. The setup action reads the ordinary toolchain and Clippy component from `rust-toolchain.toml`; the job installs nightly rustfmt with the minimal profile, installs cargo-make and nextest separately, and gets vstyle from `hack-ink/vibe-style`.
- **TOML check:** installs cargo-make and Taplo, then runs `fmt-toml-check`.
- **TypeScript check:** reads the exact Node.js version from `.node-version`, installs the locked npm graph without lifecycle scripts, then runs TypeScript format, compiler, type-aware lint, and test tasks through cargo-make.

The language workflow does **not** invoke `cargo make check` as one command or validate OpenWiki. Running on a documentation-only diff proves only its listed Rust/TOML/TypeScript checks. The former CodeQL workflow has been removed, so no tracked workflow currently provides that security-analysis coverage. Actions in the language and release workflows are SHA-pinned. Dependabot covers Cargo, root npm, and GitHub Actions.

Source: `.github/workflows/language.yml`.

## Release Pipeline

A tag matching `v<major>.<minor>.<patch>` triggers `.github/workflows/release.yml`:

1. Build `deskhelm` with locked `final-release` for Apple arm64, Linux x86_64 GNU, and Windows x86_64 MSVC.
2. Package macOS/Windows as ZIP and Linux as tar.gz; upload one-day intermediate artifacts named `deskhelm-<target>`.
3. After all builds, combine and publish artifacts to a GitHub Release with generated notes.
4. Independently publish package `deskhelm` to crates.io using the configured repository secret.

The crates.io job does not depend on the build or GitHub Release jobs and may run concurrently. The Linux and Windows artifacts compile and package the CLI, but display operations return the unsupported-platform error there. The Apple Silicon macOS artifact is the only hardware-capable target, and it still requires the compatible display path in [Architecture and Runtime](architecture-and-runtime.md#lg-39gx950b-usb-c-boundary).

Sources: `.github/workflows/release.yml`, `Cargo.toml`, `apps/deskhelm/Cargo.toml`, `apps/deskhelm/src/display.rs`.

## Failure Interpretation

- Missing command/tool: satisfy the prerequisite; do not rewrite the task to bypass the expected tool without a deliberate contract change.
- Format failure: run `cargo make fmt`, inspect changes, then rerun `fmt-check`.
- Cargo check failure: resolve compilation/features/targets before interpreting downstream lint/test noise.
- TypeScript check failure: resolve compiler diagnostics under the pinned Node/TypeScript versions before interpreting type-aware lint noise.
- Clippy/vstyle failure: fix directly or use the matching `lint-fix*` task, then review all mutations before rerunning read-only gates.
- Oxlint failure: fix the diagnostic directly or use `lint-fix-typescript` for safe fixes only; review every mutation before rerunning compiler, lint, and tests.
- Test failure: treat as a regression or broken assumption in the current diff until evidence shows an environment/tool issue.
- Release failure: distinguish build, packaging/path, GitHub publication, and crates.io publication; they have different ownership and dependency edges.

Before merge, prefer `cargo make check` plus the focused OpenWiki drift checks and any release-specific dry checks justified by the changed surface. Record unavailable tools and unrun checks explicitly rather than claiming readiness.
