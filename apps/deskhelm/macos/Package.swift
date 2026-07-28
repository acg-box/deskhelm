// swift-tools-version: 6.2

import Foundation
import PackageDescription

let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let defaultRustLibraryDirectory =
  packageRoot
  .appendingPathComponent("../../../target/debug")
  .standardizedFileURL
  .path
let rustLibraryDirectory =
  ProcessInfo.processInfo.environment["DESKHELM_RUST_LIB_DIR"]
  ?? defaultRustLibraryDirectory

let deskHelmLinkerSettings: [LinkerSetting] = [
  .unsafeFlags(["-L", rustLibraryDirectory]),
  .linkedLibrary("deskhelm"),
  .linkedFramework("CoreFoundation"),
  .linkedFramework("CoreGraphics"),
  .linkedFramework("IOKit"),
]

let package = Package(
  name: "DeskHelmMac",
  platforms: [
    .macOS(.v14)
  ],
  products: [
    .executable(name: "DeskHelmMac", targets: ["DeskHelmMac"])
  ],
  dependencies: [
    .package(
      url: "https://github.com/sparkle-project/Sparkle",
      exact: "2.9.4"
    )
  ],
  targets: [
    .target(
      name: "CDeskHelm",
      publicHeadersPath: "include"
    ),
    .target(
      name: "DeskHelmAppCore",
      dependencies: ["CDeskHelm"],
      linkerSettings: deskHelmLinkerSettings
    ),
    .executableTarget(
      name: "DeskHelmMac",
      dependencies: [
        "DeskHelmAppCore",
        .product(name: "Sparkle", package: "Sparkle"),
      ],
      linkerSettings: [
        .linkedFramework("ApplicationServices"),
        .linkedFramework("CoreAudio"),
        .linkedFramework("ServiceManagement"),
      ]
    ),
    .testTarget(
      name: "DeskHelmAppCoreTests",
      dependencies: [
        "CDeskHelm",
        "DeskHelmAppCore",
      ]
    ),
    .testTarget(
      name: "DeskHelmMacTests",
      dependencies: [
        "DeskHelmMac",
        .product(name: "Sparkle", package: "Sparkle"),
      ],
      linkerSettings: [
        .unsafeFlags([
          "-Xlinker",
          "-rpath",
          "-Xlinker",
          "@loader_path/../../..",
        ])
      ]
    ),
  ]
)
