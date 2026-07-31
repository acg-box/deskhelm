import AppKit
import Testing

@testable import DeskHelmMac

@MainActor
@Suite("DeskHelm status icon")
struct DeskHelmStatusIconTests {
  @Test("The monitor control uses stable menu-bar image metadata")
  func configuresTemplateImage() {
    let image = DeskHelmStatusIcon.makeImage()

    #expect(image.size == NSSize(width: 18, height: 17))
    #expect(
      image.alignmentRect
        == NSRect(x: 0, y: 2.5, width: 18, height: 10.5)
    )
    #expect(image.accessibilityDescription == "DeskHelm")
    #expect(image.isTemplate)
  }
}
