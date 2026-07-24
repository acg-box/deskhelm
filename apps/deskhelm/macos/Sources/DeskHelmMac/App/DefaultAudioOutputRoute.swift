import CoreAudio
import DeskHelmAppCore
import Foundation

enum DefaultAudioOutputRoute {
  static var shouldInterceptVolumeKeys: Bool {
    // Read the route at event time so a switch away from the display fails open
    // immediately, including during a held key's repeat sequence.
    guard
      let defaultDeviceID = defaultOutputDeviceID(),
      let defaultIdentity = identity(for: defaultDeviceID),
      VolumeKeyOutputRoutePolicy.shouldIntercept(output: defaultIdentity),
      let matchingDeviceIDs = matchingTargetDeviceIDs(),
      let finalDefaultDeviceID = defaultOutputDeviceID()
    else {
      return false
    }

    // Core Audio exposes only the generic "LG ULTRAGEAR+" name for this model.
    // Do not guess which display to control when more than one endpoint matches.
    // Read the default again after enumeration to close the route-switch window.
    return VolumeKeyOutputRoutePolicy.isUniqueCurrentTarget(
      defaultDeviceID: finalDefaultDeviceID,
      matchingDeviceIDs: matchingDeviceIDs
    )
  }

  private static func identity(
    for deviceID: AudioDeviceID
  ) -> AudioOutputDeviceIdentity? {
    guard
      let name = stringProperty(
        kAudioObjectPropertyName,
        on: deviceID
      ),
      let manufacturer = stringProperty(
        kAudioObjectPropertyManufacturer,
        on: deviceID
      ),
      let transportType = uint32Property(
        kAudioDevicePropertyTransportType,
        on: deviceID
      )
    else {
      return nil
    }

    let transport: AudioOutputTransport =
      transportType == kAudioDeviceTransportTypeDisplayPort
      ? .displayPort
      : .other

    return AudioOutputDeviceIdentity(
      name: name,
      manufacturer: manufacturer,
      transport: transport
    )
  }

  private static func matchingTargetDeviceIDs() -> [AudioDeviceID]? {
    guard let deviceIDs = audioDeviceIDs() else {
      return nil
    }

    var matches: [AudioDeviceID] = []
    for deviceID in deviceIDs {
      guard
        let name = stringProperty(
          kAudioObjectPropertyName,
          on: deviceID
        )
      else {
        return nil
      }

      guard VolumeKeyOutputRoutePolicy.isTargetDisplayAudioName(name) else {
        continue
      }

      guard
        let manufacturer = stringProperty(
          kAudioObjectPropertyManufacturer,
          on: deviceID
        ),
        let transportType = uint32Property(
          kAudioDevicePropertyTransportType,
          on: deviceID
        )
      else {
        return nil
      }

      let identity = AudioOutputDeviceIdentity(
        name: name,
        manufacturer: manufacturer,
        transport:
          transportType == kAudioDeviceTransportTypeDisplayPort
          ? .displayPort
          : .other
      )
      if VolumeKeyOutputRoutePolicy.shouldIntercept(output: identity) {
        matches.append(deviceID)
      }
    }
    return matches
  }

  private static func audioDeviceIDs() -> [AudioDeviceID]? {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDevices,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var dataSize: UInt32 = 0
    guard
      AudioObjectGetPropertyDataSize(
        AudioObjectID(kAudioObjectSystemObject),
        &address,
        0,
        nil,
        &dataSize
      ) == noErr,
      dataSize % UInt32(MemoryLayout<AudioDeviceID>.stride) == 0
    else {
      return nil
    }

    let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.stride
    guard count > 0 else {
      return []
    }

    var deviceIDs = Array(
      repeating: AudioDeviceID(kAudioObjectUnknown),
      count: count
    )
    let status = deviceIDs.withUnsafeMutableBufferPointer { buffer in
      AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject),
        &address,
        0,
        nil,
        &dataSize,
        buffer.baseAddress!
      )
    }

    return status == noErr ? deviceIDs : nil
  }

  private static func defaultOutputDeviceID() -> AudioDeviceID? {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDefaultOutputDevice,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var deviceID = AudioDeviceID(kAudioObjectUnknown)
    var dataSize = UInt32(MemoryLayout.size(ofValue: deviceID))
    let status = AudioObjectGetPropertyData(
      AudioObjectID(kAudioObjectSystemObject),
      &address,
      0,
      nil,
      &dataSize,
      &deviceID
    )

    guard status == noErr, deviceID != kAudioObjectUnknown else {
      return nil
    }
    return deviceID
  }

  private static func stringProperty(
    _ selector: AudioObjectPropertySelector,
    on objectID: AudioObjectID
  ) -> String? {
    var address = AudioObjectPropertyAddress(
      mSelector: selector,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var value: Unmanaged<CFString>?
    var dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    let status = AudioObjectGetPropertyData(
      objectID,
      &address,
      0,
      nil,
      &dataSize,
      &value
    )

    guard status == noErr, let value else {
      return nil
    }
    return value.takeRetainedValue() as String
  }

  private static func uint32Property(
    _ selector: AudioObjectPropertySelector,
    on objectID: AudioObjectID
  ) -> UInt32? {
    var address = AudioObjectPropertyAddress(
      mSelector: selector,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var value: UInt32 = 0
    var dataSize = UInt32(MemoryLayout.size(ofValue: value))
    let status = AudioObjectGetPropertyData(
      objectID,
      &address,
      0,
      nil,
      &dataSize,
      &value
    )

    return status == noErr ? value : nil
  }
}
