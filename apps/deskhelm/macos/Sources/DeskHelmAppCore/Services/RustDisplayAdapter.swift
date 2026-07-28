import CDeskHelm
import Foundation

public actor RustDisplayAdapter: VolumeControlling {
  private var session: DeskHelmSessionHandle?

  public init() {}

  public func readVolume() async throws -> VolumeReading {
    do {
      if let session {
        return try Self.readSynchronously(session: session.pointer)
      }

      return try connectSynchronously()
    } catch {
      invalidateSession()
      throw error
    }
  }

  public func setVolume(to level: Int) async throws -> VolumeReading {
    try validate(level)

    do {
      let session = try connectedSession()
      return try Self.setSynchronously(level, session: session.pointer)
    } catch {
      invalidateSession()
      throw error
    }
  }

  public func writeVolume(to level: Int) async throws {
    try validate(level)

    do {
      let session = try connectedSession()
      try Self.writeSynchronously(level, session: session.pointer)
    } catch {
      invalidateSession()
      throw error
    }
  }

  public func resetConnection() async {
    invalidateSession()
  }

  private func validate(_ level: Int) throws {
    guard (0...100).contains(level) else {
      throw VolumeControlError.invalidLevel(level)
    }
  }

  private func connectedSession() throws -> DeskHelmSessionHandle {
    if session == nil {
      _ = try connectSynchronously()
    }
    guard let session else {
      throw VolumeControlError.invalidResponse(
        "DeskHelm did not retain its validated display session."
      )
    }

    return session
  }

  private func connectSynchronously() throws -> VolumeReading {
    var createdSession: OpaquePointer?
    var result = DeskHelmVolumeResult()
    let status = deskhelm_session_create(&createdSession, &result)
    defer { deskhelm_volume_result_free(&result) }

    let reading: VolumeReading
    do {
      reading = try Self.decode(status: status, result: result)
    } catch {
      if let createdSession {
        deskhelm_session_free(createdSession)
      }
      throw error
    }
    guard let createdSession else {
      throw VolumeControlError.invalidResponse(
        "DeskHelm core returned no display session."
      )
    }

    session = DeskHelmSessionHandle(pointer: createdSession)
    return reading
  }

  private static func readSynchronously(
    session: OpaquePointer
  ) throws -> VolumeReading {
    var result = DeskHelmVolumeResult()
    let status = deskhelm_session_read(session, &result)
    defer { deskhelm_volume_result_free(&result) }

    return try decode(status: status, result: result)
  }

  private static func setSynchronously(
    _ level: Int,
    session: OpaquePointer
  ) throws -> VolumeReading {
    var result = DeskHelmVolumeResult()
    let status = deskhelm_session_set(session, Int32(level), &result)
    defer { deskhelm_volume_result_free(&result) }

    return try decode(status: status, result: result)
  }

  private static func writeSynchronously(
    _ level: Int,
    session: OpaquePointer
  ) throws {
    var result = DeskHelmVolumeResult()
    let status = deskhelm_session_write(session, Int32(level), &result)
    defer { deskhelm_volume_result_free(&result) }

    _ = try decode(status: status, result: result)
  }

  private func invalidateSession() {
    session = nil
  }

  private static func decode(
    status: Int32,
    result: DeskHelmVolumeResult
  ) throws -> VolumeReading {
    let message =
      result.error.map { String(cString: UnsafePointer($0)) }
      ?? "DeskHelm core did not provide an error message."

    guard status == Int32(DESKHELM_STATUS_OK) else {
      switch status {
      case Int32(DESKHELM_STATUS_RUNTIME_ERROR):
        throw VolumeControlError.runtime(message)
      case Int32(DESKHELM_STATUS_INVALID_ARGUMENT):
        throw VolumeControlError.invalidArgument(message)
      case Int32(DESKHELM_STATUS_PANIC):
        throw VolumeControlError.corePanic(message)
      default:
        throw VolumeControlError.unknownStatus(status, message)
      }
    }

    return try validatedReading(
      display: result.display.map({ String(cString: UnsafePointer($0)) }),
      current: Int(result.current),
      maximum: Int(result.maximum)
    )
  }

  static func validatedReading(
    display: String?,
    current: Int,
    maximum: Int
  ) throws -> VolumeReading {
    guard let display else {
      throw VolumeControlError.invalidResponse(
        "DeskHelm core returned no display name."
      )
    }

    guard maximum == 100 else {
      throw VolumeControlError.invalidResponse(
        "The display reports a maximum volume of \(maximum). "
          + "DeskHelm supports displays with a 0–100 volume range."
      )
    }

    guard (0...maximum).contains(current) else {
      throw VolumeControlError.invalidResponse(
        "DeskHelm core returned an invalid volume \(current)/\(maximum)."
      )
    }

    return VolumeReading(display: display, current: current, maximum: maximum)
  }
}

private final class DeskHelmSessionHandle: @unchecked Sendable {
  let pointer: OpaquePointer

  init(pointer: OpaquePointer) {
    self.pointer = pointer
  }

  deinit {
    deskhelm_session_free(pointer)
  }
}
