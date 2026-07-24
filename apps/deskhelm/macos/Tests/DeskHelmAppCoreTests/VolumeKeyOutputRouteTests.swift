import Testing

@testable import DeskHelmAppCore

@Suite("Volume-key output routing")
struct VolumeKeyOutputRouteTests {
  @Test("LG UltraGear DisplayPort audio is intercepted")
  func lgUltraGearOutput() {
    let output = AudioOutputDeviceIdentity(
      name: "LG ULTRAGEAR+",
      manufacturer: "GSM",
      transport: .displayPort
    )

    #expect(VolumeKeyOutputRoutePolicy.shouldIntercept(output: output))
  }

  @Test("The LG model name accepts the full display identity")
  func lgModelOutput() {
    let output = AudioOutputDeviceIdentity(
      name: "LG 39GX950B",
      manufacturer: "LG Electronics Inc.",
      transport: .displayPort
    )

    #expect(VolumeKeyOutputRoutePolicy.shouldIntercept(output: output))
  }

  @Test("LG matching ignores outer whitespace and letter case")
  func normalizedLGOutput() {
    let output = AudioOutputDeviceIdentity(
      name: "  lg ultragear+ \n",
      manufacturer: " gsm ",
      transport: .displayPort
    )

    #expect(VolumeKeyOutputRoutePolicy.shouldIntercept(output: output))
  }

  @Test("Bluetooth headphones pass through to macOS")
  func bluetoothOutput() {
    let output = AudioOutputDeviceIdentity(
      name: "Bluetooth Headphones",
      manufacturer: "Apple Inc.",
      transport: .other
    )

    #expect(!VolumeKeyOutputRoutePolicy.shouldIntercept(output: output))
  }

  @Test("LG audio on a non-display transport passes through")
  func nonDisplayTransport() {
    let output = AudioOutputDeviceIdentity(
      name: "LG ULTRAGEAR+",
      manufacturer: "GSM",
      transport: .other
    )

    #expect(!VolumeKeyOutputRoutePolicy.shouldIntercept(output: output))
  }

  @Test("A different LG DisplayPort output passes through")
  func differentLGOutput() {
    let output = AudioOutputDeviceIdentity(
      name: "LG 32UN880",
      manufacturer: "GSM",
      transport: .displayPort
    )

    #expect(!VolumeKeyOutputRoutePolicy.shouldIntercept(output: output))
  }

  @Test("A similar name without LG hardware identity passes through")
  func unrelatedManufacturer() {
    let output = AudioOutputDeviceIdentity(
      name: "LG ULTRAGEAR+",
      manufacturer: "Example Audio",
      transport: .displayPort
    )

    #expect(!VolumeKeyOutputRoutePolicy.shouldIntercept(output: output))
  }

  @Test("Unknown output state fails open")
  func unknownOutput() {
    #expect(!VolumeKeyOutputRoutePolicy.shouldIntercept(output: nil))
  }

  @Test("Only the unique current LG endpoint can be intercepted")
  func uniqueCurrentTarget() {
    #expect(
      VolumeKeyOutputRoutePolicy.isUniqueCurrentTarget(
        defaultDeviceID: 42,
        matchingDeviceIDs: [42]
      )
    )
    #expect(
      !VolumeKeyOutputRoutePolicy.isUniqueCurrentTarget(
        defaultDeviceID: 42,
        matchingDeviceIDs: [42, 43]
      )
    )
    #expect(
      !VolumeKeyOutputRoutePolicy.isUniqueCurrentTarget(
        defaultDeviceID: 42,
        matchingDeviceIDs: [43]
      )
    )
    #expect(
      !VolumeKeyOutputRoutePolicy.isUniqueCurrentTarget(
        defaultDeviceID: nil,
        matchingDeviceIDs: nil
      )
    )
  }

  @Test("Every non-target volume-key state passes through")
  func nonTargetEventsPassThrough() {
    let press = VolumeMediaKeyEvent(action: .increase, isPressed: true)
    let release = VolumeMediaKeyEvent(action: .increase, isPressed: false)

    #expect(
      VolumeMediaKeyRoutingPolicy.disposition(
        for: press,
        outputMatchesTarget: false
      ) == .passThrough
    )
    #expect(
      VolumeMediaKeyRoutingPolicy.disposition(
        for: release,
        outputMatchesTarget: false
      ) == .passThrough
    )
  }

  @Test("A target press dispatches, while its release is only consumed")
  func targetEventDisposition() {
    let press = VolumeMediaKeyEvent(action: .decrease, isPressed: true)
    let release = VolumeMediaKeyEvent(action: .decrease, isPressed: false)

    #expect(
      VolumeMediaKeyRoutingPolicy.disposition(
        for: press,
        outputMatchesTarget: true
      ) == .consumeAndDispatch(.decrease)
    )
    #expect(
      VolumeMediaKeyRoutingPolicy.disposition(
        for: release,
        outputMatchesTarget: true
      ) == .consume
    )
  }
}
