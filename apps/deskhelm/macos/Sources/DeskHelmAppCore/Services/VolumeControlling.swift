public protocol VolumeControlling: Sendable {
  func readVolume() async throws -> VolumeReading
  func writeVolume(to level: Int) async throws
  func setVolume(to level: Int) async throws -> VolumeReading
  func resetConnection() async
}
