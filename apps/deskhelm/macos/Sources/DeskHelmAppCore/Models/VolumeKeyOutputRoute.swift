import Foundation

public enum AudioOutputTransport: Equatable, Sendable {
  case displayPort
  case other
}

public struct AudioOutputDeviceIdentity: Equatable, Sendable {
  public let name: String
  public let manufacturer: String
  public let transport: AudioOutputTransport

  public init(
    name: String,
    manufacturer: String,
    transport: AudioOutputTransport
  ) {
    self.name = name
    self.manufacturer = manufacturer
    self.transport = transport
  }
}

public enum VolumeKeyOutputRoutePolicy {
  public static func shouldIntercept(
    output: AudioOutputDeviceIdentity?
  ) -> Bool {
    guard let output, output.transport == .displayPort else {
      return false
    }

    let manufacturer = normalized(output.manufacturer)
    let isLGManufacturer =
      manufacturer == "GSM"
      || manufacturer.hasPrefix("LG ELECTRONICS")

    return isTargetDisplayAudioName(output.name) && isLGManufacturer
  }

  public static func isTargetDisplayAudioName(_ name: String) -> Bool {
    let name = normalized(name)
    return name == "LG ULTRAGEAR+" || name.contains("39GX950")
  }

  public static func isUniqueCurrentTarget(
    defaultDeviceID: UInt32?,
    matchingDeviceIDs: [UInt32]?
  ) -> Bool {
    guard let defaultDeviceID, let matchingDeviceIDs else {
      return false
    }
    return matchingDeviceIDs == [defaultDeviceID]
  }

  private static func normalized(_ value: String) -> String {
    value
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .uppercased()
  }
}
