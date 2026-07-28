import Testing

@testable import DeskHelmAppCore

@Suite("Application launch plan")
struct DeskHelmLaunchPlanTests {
  @Test("A normal launch starts volume keys")
  func normalLaunch() {
    #expect(
      DeskHelmLaunchPlan.actions(arguments: ["/Applications/DeskHelm.app"])
        == [.startVolumeKeys]
    )
  }

  @Test("Settings verification also starts volume keys")
  func settingsVerificationLaunch() {
    #expect(
      DeskHelmLaunchPlan.actions(
        arguments: [
          "/Applications/DeskHelm.app",
          "--verify-settings",
        ]
      )
        == [
          .startVolumeKeys,
          .showSettingsForVerification,
        ]
    )
  }
}
