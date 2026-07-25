import Testing

@testable import DeskHelmAppCore

@Suite("Application launch plan")
struct DeskHelmLaunchPlanTests {
  @Test("A normal launch restores requested volume keys")
  func normalLaunch() {
    #expect(
      DeskHelmLaunchPlan.actions(arguments: ["/Applications/DeskHelm.app"])
        == [.restoreRequestedVolumeKeys]
    )
  }

  @Test("Settings verification also restores requested volume keys")
  func settingsVerificationLaunch() {
    #expect(
      DeskHelmLaunchPlan.actions(
        arguments: [
          "/Applications/DeskHelm.app",
          "--verify-settings",
        ]
      )
        == [
          .restoreRequestedVolumeKeys,
          .showSettingsForVerification,
        ]
    )
  }
}
