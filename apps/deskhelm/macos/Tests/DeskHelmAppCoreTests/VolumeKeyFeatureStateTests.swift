import Testing

@testable import DeskHelmAppCore

@MainActor
@Suite("Volume-key feature state")
struct VolumeKeyFeatureStateTests {
  @Test("Requested state stays on while enablement is in progress")
  func requestedState() {
    let state = VolumeKeyFeatureState()

    #expect(!state.isRequested)
    #expect(!state.isEnabled)

    state.update(to: .enabling)
    #expect(state.isRequested)
    #expect(!state.isEnabled)

    state.update(to: .enabled)
    #expect(state.isRequested)
    #expect(state.isEnabled)
  }

  @Test("Permission and failure states do not claim active interception")
  func blockedStates() {
    let state = VolumeKeyFeatureState()

    state.update(to: .permissionRequired)
    #expect(!state.isRequested)
    #expect(!state.isEnabled)

    state.update(to: .failed("Communication failed."))
    #expect(!state.isRequested)
    #expect(!state.isEnabled)
  }
}
