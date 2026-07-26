---
type: Operations Runbook
title: DeskHelm Operations and Validation
description: Documents DeskHelm Rust and Swift builds, native diagnostics, validation and CI, plus source-validated Developer ID signing, notarization, Sparkle-signed archive metadata, and draft-first GitHub release publication.
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

`check` is a cargo-make composite whose dependencies are `check-rust`, macOS-only `check-swift`, `check-typescript`, `fmt-check`, `lint`, and `test`. `check-swift` runs the native build script with `--build-only`; `test` includes credential-free `test-release` plus Rust, macOS-only Swift, and TypeScript tests. On non-macOS hosts cargo-make skips the conditioned Swift task, but the release self-check still runs. `Makefile.toml` establishes the dependency set but does not state a runtime ordering contract. When deterministic, fail-fast diagnosis matters, invoke the targeted commands explicitly in this recommended sequence:

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
| `check-swift` | On macOS, run `./script/build_and_run.sh --build-only` | Rebuilds caches and stages/signs the app without launching |
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
| `test` | Composite: `test-release`, `test-rust`, macOS-only `test-swift`, `test-typescript` | Build/tool caches only |
| `test-release` | Run `script/release/self-check.py` without release credentials | Temporary self-check fixtures only |
| `test-macos-release` | On macOS, run `test-release`, then Swift tests and app staging with `DESKHELM_CONFIGURATION=release` | Cargo/Swift build caches and staged app |
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

The script uses `DESKHELM_CONFIGURATION=debug` by default; set it to `release` for Cargo and Swift release builds. It exports `DESKHELM_RUST_LIB_DIR` as `target/<configuration>` so `apps/deskhelm/macos/Package.swift` can link `libdeskhelm`. The staged short version defaults to the workspace package version; `DESKHELM_APP_VERSION` and `DESKHELM_BUILD_VERSION` can supply validated release metadata. `DESKHELM_APP_STAGE_DIR` can redirect staging only to a child of an existing `RUNNER_TEMP`, keeping release work in ephemeral storage. Swift build, test, and binary-path queries receive explicit `-platform_version macos` linker arguments with deployment minimum 14.0 and the SDK version selected by `xcrun`; after an app build, `vtool` must report that same linked SDK or the script fails. This avoids SwiftPM's swiftbuild backend recording the deployment target as both build-version values, which would lose current linked-on UI behavior.

Every non-test mode stages `DeskHelm.app` under `apps/deskhelm/macos/dist/` by default, including `--build-only`. The staged bundle contains executable `DeskHelmMac`, bundle ID `com.acgbox.deskhelm`, macOS 14 minimum, `LSUIElement=true`, and the exact SwiftPM Sparkle 2.9.4 framework from the selected binary directory under `Contents/Frameworks`; the script rejects a framework version that differs from `Package.resolved`. Staging removes development-only rpaths, adds `@executable_path/../Frameworks` when missing, and delegates inside-out signing of known Sparkle nested code to `script/release/sign-macos-app.sh`. Development signing is ad hoc by default; `DESKHELM_CODE_SIGN_IDENTITY` selects an authorized Apple Development identity when Accessibility authorization must persist across rebuilds. The release path invokes the same signer in hardened-runtime Developer ID mode.

`DESKHELM_SPARKLE_APPCAST_URL` and `DESKHELM_SPARKLE_PUBLIC_ED_KEY` are optional staging inputs and must be supplied together. When present, the script adds the HTTPS feed, Ed25519 public key, daily checks, and automatic-update capability to `Info.plist`; `SoftwareUpdater` still validates the feed URL and requires a base64-decoded 32-byte public key before enabling Sparkle. When absent, the app labels the action **View Releases…** and opens GitHub Releases. These values are release configuration, not source defaults. This local development bundle remains separate from the signed and notarized app archive produced by the release workflow.

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

Four jobs run independently:

- **Rust check:** rustfmt check → Cargo check → vstyle action → Clippy → nextest. The setup action reads the ordinary toolchain and Clippy component from `rust-toolchain.toml`; the job installs nightly rustfmt with the minimal profile, installs cargo-make and nextest separately, and gets vstyle from `acg-box/vibe-style`.
- **Swift check:** on `macos-26`, prints the Apple toolchain, installs Rust and cargo-make, then runs `check-swift`, `test-swift`, and the credential-free `test-release` self-check.
- **TOML check:** installs cargo-make and Taplo, then runs `fmt-toml-check`.
- **TypeScript check:** reads the exact Node.js version from `.node-version`, installs the locked npm graph without lifecycle scripts, then runs TypeScript format, compiler, type-aware lint, and test tasks through cargo-make.

The language workflow does **not** invoke `cargo make check` as one command or validate OpenWiki. Running on a documentation-only diff proves only its listed Rust, Swift, release-contract, TOML, and TypeScript checks. The former CodeQL workflow has been removed, so no tracked workflow currently provides that security-analysis coverage. Actions in the language and release workflows are SHA-pinned. Dependabot covers Cargo, root npm, and GitHub Actions.

Source: `.github/workflows/language.yml`.

## Release Pipeline

A push of an annotated stable tag matching `v<major>.<minor>.<patch>` starts `.github/workflows/release.yml`. There is no manual preparation or dry-run trigger. The first Linux job checks that the run belongs to `acg-box/deskhelm`, the tag points directly to a commit, its version matches the workspace package and lockfile, the exact Sparkle declaration matches `Package.resolved`, and the commit is reachable from canonical `origin/main`. These outputs bind the later jobs to one validated source commit. The tag must be annotated, but the scripts do not verify a cryptographic tag signature; tag-push controls and approval of the protected `release` environment remain part of the trust boundary.

```mermaid
flowchart TD
    Tag["Push annotated vX.Y.Z tag"] --> Source["Validate repository, tag, versions, and main ancestry"]
    Source --> Mac["macos-26 ARM64 release tests"]
    Mac --> Build["Build versioned app in temporary staging"]
    Build --> Sign["Sign nested Sparkle code and app with Developer ID"]
    Sign --> Notary["Submit, wait, staple, and assess notarization"]
    Notary --> Assets["Create ZIP, appcast with archive signature, and SHA-256 checksum"]
    Assets --> Draft["Upload and validate private GitHub draft"]
    Draft --> Recheck["Recheck remote tag and main ancestry"]
    Recheck --> Publish["Publish with semantic-version latest selection"]
```

The release moves from immutable source validation through Apple trust checks to draft-first publication; any failure before the final publish operation leaves no new public release.

The macOS job runs `cargo make test-macos-release`, then `script/release/package-macos.sh` on an ARM64 `macos-26` runner. It builds before writing credentials to disk, stages only inside `RUNNER_TEMP`, verifies the app's version, update key, canonical feed, and embedded Sparkle 2.9.4 layout, then imports the Developer ID certificate into a temporary keychain. `sign-macos-app.sh` signs the known Sparkle code graph inside-out with hardened runtime and secure timestamps, rejecting ad hoc signatures, team mismatches, missing timestamps, and unsafe outer entitlements.

Packaging submits a temporary archive to Apple notarization, waits up to 30 minutes, requires an accepted result, staples the ticket, and passes `codesign`, stapler, and Gatekeeper assessment before creating the public ZIP. `sparkle-appcast.sh` signs that exact ZIP with DeskHelm's private Ed25519 key and emits an ARM64, macOS 14 appcast entry. The final artifact set is exactly:

- `deskhelm-aarch64-apple-darwin.zip` containing `DeskHelm.app`
- `appcast.xml` for the in-app Sparkle feed
- `deskhelm-aarch64-apple-darwin.zip.sha256`

The Linux publisher has the workflow's only `contents: write` permission. Concurrency is isolated by tag, so a later version cannot replace another version's pending run; repeated runs for one tag share that tag's group. The publisher creates or reuses a draft, uploads only those three assets, validates metadata, checksum, archive contents, appcast URLs and signature, downloads the assets to compare their bytes, and rechecks the remote annotated tag and `main` ancestry immediately before setting `draft=false`. The final call asks GitHub to select the latest release by its semantic-version and creation-date policy, so a delayed older tag does not replace a newer update feed. A retry against an existing public release validates its immutable downloaded bytes rather than comparing a newly timestamped build. Failures before publication can leave a private draft for a retry, while package cleanup removes partial local assets and temporary credentials. The final publish API call is intentionally last; a retry safely validates an already-published release if that call's network result was ambiguous.

Configure the protected `release` environment with public variable `DESKHELM_SPARKLE_PUBLIC_ED_KEY` and secrets `DESKHELM_SPARKLE_PRIVATE_ED_KEY`, `APPLE_DEVELOPER_ID_APPLICATION_IDENTITY`, `APPLE_DEVELOPER_ID_APPLICATION_P12_BASE64`, `APPLE_DEVELOPER_ID_APPLICATION_P12_PASSWORD`, `APPLE_NOTARY_ISSUER_ID`, `APPLE_NOTARY_KEY_ID`, and `APPLE_NOTARY_KEY_P8`. DeskHelm forbids the generic `SPARKLE_PRIVATE_ED_KEY` name to reduce accidental key reuse. Do not put credential values in source or documentation.

This pipeline publishes only the signed and notarized Apple Silicon app. It no longer emits Windows/Linux CLI archives and does not publish the Rust crate. Hardware operation still depends on the compatible display path in [Architecture and Runtime](architecture-and-runtime.md#lg-39gx950b-usb-c-boundary).

Run the credential-free contract suite before changing the workflow or release scripts:

```sh
cargo make test-release
```

It exercises source/version rejection, signing order and metadata, appcast and artifact validation, notarization outcomes, draft/public retry paths, moved tags, corrupt assets, and shell/Python static checks with fixtures and stubs. It does not perform real Developer ID signing, Apple notarization, or live GitHub publication.

Sources: `.github/workflows/release.yml`, `Makefile.toml`, `script/build_and_run.sh`, `script/release/`, `Cargo.toml`, `Cargo.lock`, `apps/deskhelm/macos/Package.swift`, `apps/deskhelm/macos/Package.resolved`.

## Failure Interpretation

- Missing command/tool: satisfy the prerequisite; do not rewrite the task to bypass the expected tool without a deliberate contract change.
- Format failure: run `cargo make fmt`, inspect changes, then rerun `fmt-check`.
- Cargo check failure: resolve compilation/features/targets before interpreting downstream lint/test noise.
- TypeScript check failure: resolve compiler diagnostics under the pinned Node/TypeScript versions before interpreting type-aware lint noise.
- Clippy/vstyle failure: fix directly or use the matching `lint-fix*` task, then review all mutations before rerunning read-only gates.
- Oxlint failure: fix the diagnostic directly or use `lint-fix-typescript` for safe fixes only; review every mutation before rerunning compiler, lint, and tests.
- Test failure: treat as a regression or broken assumption in the current diff until evidence shows an environment/tool issue.
- Release failure: distinguish source validation, release-mode tests/build, signing, notarization, appcast/artifact validation, draft upload, and final publication. Before the final API operation, retries may reuse and repair a private draft; a public release retry validates the existing remote bytes.

Before merge, prefer `cargo make check` plus the focused OpenWiki drift checks and any release-specific contract checks justified by the changed surface. Record unavailable tools and unrun checks explicitly rather than claiming readiness.
