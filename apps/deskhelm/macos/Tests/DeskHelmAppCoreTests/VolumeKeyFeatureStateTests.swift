import Testing

@testable import DeskHelmAppCore

@MainActor
@Suite("Volume-key feature state")
struct VolumeKeyFeatureStateTests {
  @Test("Only the enabled phase claims active interception")
  func enabledState() {
    let state = VolumeKeyFeatureState()

    #expect(!state.isEnabled)

    state.update(to: .enabling)
    #expect(!state.isEnabled)

    state.update(to: .enabled)
    #expect(state.isEnabled)

    state.update(to: .unavailable("Waiting for the display."))
    #expect(!state.isEnabled)
  }

  @Test("Permission and failure states explain why interception is inactive")
  func blockedStates() {
    let state = VolumeKeyFeatureState()

    state.update(to: .permissionRequired)
    #expect(!state.isEnabled)
    #expect(
      state.statusMessage
        == "Volume keys start automatically after Accessibility access is granted."
    )

    state.update(to: .failed("Communication failed."))
    #expect(!state.isEnabled)
    #expect(state.statusMessage == "Communication failed.")
  }

  @Test("Cancel invalidates an in-flight enable request")
  func cancelInvalidatesRequest() {
    var requests = VolumeKeyEnableRequestState()
    let token = requests.begin()

    #expect(requests.hasActiveRequest)
    #expect(requests.isCurrent(token))

    requests.cancel()
    let canceledRequestFinished = requests.finish(token)

    #expect(!requests.hasActiveRequest)
    #expect(!requests.isCurrent(token))
    #expect(!canceledRequestFinished)
  }

  @Test("A newer enable request rejects an older completion")
  func newerRequestRejectsOlderCompletion() {
    var requests = VolumeKeyEnableRequestState()
    let first = requests.begin()
    let second = requests.begin()
    let firstWasCurrent = requests.isCurrent(first)
    let secondWasCurrent = requests.isCurrent(second)
    let olderRequestFinished = requests.finish(first)
    let newerRequestFinished = requests.finish(second)

    #expect(!firstWasCurrent)
    #expect(secondWasCurrent)
    #expect(!olderRequestFinished)
    #expect(newerRequestFinished)
    #expect(!requests.hasActiveRequest)
  }
}
