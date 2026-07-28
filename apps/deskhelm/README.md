# DeskHelm

This package owns DeskHelm's Rust display core, C ABI, and command-line
application. The native macOS application is in `macos/`. Its Swift native
application layer owns app lifecycle, interactive state, Core Audio route
qualification, media-key handling, and AppKit/SwiftUI presentation. It links the
Rust static library in process for display discovery and verified DDC/CI access.
See the repository root `README.md` for build and usage instructions.
