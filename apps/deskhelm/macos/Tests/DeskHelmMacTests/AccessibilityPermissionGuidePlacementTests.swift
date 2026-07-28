import CoreGraphics
import Testing

@testable import DeskHelmMac

@Suite("Accessibility permission guide placement")
struct AccessibilityPermissionGuidePlacementTests {
  @Test("The guide prefers the right side of System Settings")
  func prefersRightSide() {
    let placement = AccessibilityPermissionGuidePlacement.beside(
      settingsFrame: CGRect(x: 100, y: 100, width: 600, height: 500),
      visibleFrame: CGRect(x: 0, y: 0, width: 1_400, height: 900),
      guideSize: CGSize(width: 358, height: 50)
    )

    #expect(placement.direction == .left)
    #expect(
      placement.frame
        == CGRect(x: 714, y: 317, width: 358, height: 50)
    )
  }

  @Test("The guide moves to the left when the right side is full")
  func usesLeftSide() {
    let placement = AccessibilityPermissionGuidePlacement.beside(
      settingsFrame: CGRect(x: 900, y: 100, width: 450, height: 500),
      visibleFrame: CGRect(x: 0, y: 0, width: 1_400, height: 900),
      guideSize: CGSize(width: 358, height: 50)
    )

    #expect(placement.direction == .right)
    #expect(
      placement.frame
        == CGRect(x: 528, y: 317, width: 358, height: 50)
    )
  }

  @Test("A cramped display keeps the guide inside its visible frame")
  func clampsCrampedPlacement() {
    let visibleFrame = CGRect(x: 0, y: 0, width: 700, height: 680)
    let placement = AccessibilityPermissionGuidePlacement.beside(
      settingsFrame: CGRect(x: 20, y: 100, width: 600, height: 500),
      visibleFrame: visibleFrame,
      guideSize: CGSize(width: 358, height: 50)
    )

    #expect(placement.direction == .left)
    #expect(visibleFrame.contains(placement.frame))
    #expect(
      placement.frame
        == CGRect(x: 244, y: 612, width: 358, height: 50)
    )
  }

  @Test("Vertical placement observes the visible-frame margin")
  func clampsVerticalPlacement() {
    let placement = AccessibilityPermissionGuidePlacement.beside(
      settingsFrame: CGRect(x: 100, y: -100, width: 500, height: 20),
      visibleFrame: CGRect(x: 0, y: 0, width: 1_200, height: 800),
      guideSize: CGSize(width: 358, height: 50)
    )

    #expect(placement.frame.minY == 12)
  }

  @Test("Core Graphics coordinates map through the matching display")
  func mapsScaledDisplayCoordinates() {
    let screens = [
      AccessibilityPermissionGuideScreen(
        frame: CGRect(x: 0, y: 0, width: 1_440, height: 900),
        visibleFrame: CGRect(x: 0, y: 0, width: 1_440, height: 870),
        coreGraphicsFrame: CGRect(
          x: 0,
          y: 0,
          width: 2_880,
          height: 1_800
        )
      ),
      AccessibilityPermissionGuideScreen(
        frame: CGRect(x: -1_280, y: 900, width: 1_280, height: 800),
        visibleFrame: CGRect(
          x: -1_280,
          y: 900,
          width: 1_280,
          height: 760
        ),
        coreGraphicsFrame: CGRect(
          x: -2_560,
          y: -1_600,
          width: 2_560,
          height: 1_600
        )
      ),
    ]

    let mapped = AccessibilityPermissionGuidePlacement.appKitWindowFrame(
      from: CGRect(x: -2_360, y: -1_400, width: 1_200, height: 800),
      screens: screens
    )

    #expect(
      mapped?.frame
        == CGRect(x: -1_180, y: 1_200, width: 600, height: 400)
    )
    #expect(mapped?.visibleFrame == screens[1].visibleFrame)
  }

  @Test("A window outside known displays has no placement target")
  func rejectsUnknownDisplay() {
    let mapped = AccessibilityPermissionGuidePlacement.appKitWindowFrame(
      from: CGRect(x: 5_000, y: 5_000, width: 400, height: 300),
      screens: [
        AccessibilityPermissionGuideScreen(
          frame: CGRect(x: 0, y: 0, width: 1_440, height: 900),
          visibleFrame: CGRect(x: 0, y: 0, width: 1_440, height: 870),
          coreGraphicsFrame: CGRect(
            x: 0,
            y: 0,
            width: 2_880,
            height: 1_800
          )
        )
      ]
    )

    #expect(mapped == nil)
  }
}
