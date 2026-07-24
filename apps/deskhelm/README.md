# DeskHelm

This package owns the DeskHelm Rust core, C ABI, and command-line application.
The native menu bar application is in `macos/`. Its small AppKit shell hosts a
SwiftUI panel and links the Rust static library in-process. See the repository
root `README.md` for build and usage instructions.
