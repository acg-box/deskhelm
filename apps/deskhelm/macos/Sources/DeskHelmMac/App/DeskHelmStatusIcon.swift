import AppKit

@MainActor
enum DeskHelmStatusIcon {
  static func makeImage() -> NSImage? {
    let image = NSImage(
      systemSymbolName: "slider.vertical.3",
      accessibilityDescription: "DeskHelm"
    )
    let configuration = NSImage.SymbolConfiguration(
      pointSize: 15,
      weight: .medium
    )
    let configuredImage = image?.withSymbolConfiguration(configuration) ?? image

    configuredImage?.isTemplate = true
    return configuredImage
  }
}
