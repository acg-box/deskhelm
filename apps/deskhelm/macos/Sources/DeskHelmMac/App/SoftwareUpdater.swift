import AppKit
import Combine
import Foundation
@preconcurrency import Sparkle

@MainActor
final class SoftwareUpdater: NSObject, ObservableObject, SPUUpdaterDelegate,
  SPUStandardUserDriverDelegate
{
  enum Mode: String, CaseIterable, Identifiable {
    case off
    case notify
    case install

    var id: Self { self }

    var title: String {
      switch self {
      case .off:
        "Off"
      case .notify:
        "Notify"
      case .install:
        "Install"
      }
    }
  }

  struct Snapshot: Equatable {
    let isConfigured: Bool
    let canCheckForUpdates: Bool
    let allowsAutomaticUpdates: Bool
    let mode: Mode
    let currentVersion: String
    let lastCheckSummary: String

    var modeDescription: String {
      guard isConfigured else {
        return "Automatic updates need a signed DeskHelm appcast."
      }

      switch mode {
      case .off:
        return "DeskHelm does not check automatically."
      case .notify:
        return lastCheckSummary
      case .install:
        return "DeskHelm downloads updates automatically. \(lastCheckSummary)"
      }
    }
  }

  private var updaterController: SPUStandardUpdaterController?
  private var presentationFinished: (@MainActor () -> Void)?
  @Published private(set) var snapshotRevision: UInt = 0

  override init() {
    super.init()
    guard Self.hasSparkleConfiguration else { return }

    updaterController = SPUStandardUpdaterController(
      startingUpdater: true,
      updaterDelegate: self,
      userDriverDelegate: self
    )
  }

  func onPresentationFinished(
    _ action: @escaping @MainActor () -> Void
  ) {
    presentationFinished = action
  }

  func snapshot() -> Snapshot {
    guard let updater = updaterController?.updater else {
      return Snapshot(
        isConfigured: false,
        canCheckForUpdates: true,
        allowsAutomaticUpdates: false,
        mode: .off,
        currentVersion: Self.currentVersion,
        lastCheckSummary: "Never checked."
      )
    }

    return Snapshot(
      isConfigured: true,
      canCheckForUpdates: updater.canCheckForUpdates,
      allowsAutomaticUpdates: updater.allowsAutomaticUpdates,
      mode: Self.mode(
        automaticallyChecks: updater.automaticallyChecksForUpdates,
        automaticallyDownloads: updater.automaticallyDownloadsUpdates
      ),
      currentVersion: Self.currentVersion,
      lastCheckSummary: Self.lastCheckSummary(for: updater.lastUpdateCheckDate)
    )
  }

  func setMode(_ mode: Mode) {
    guard let updater = updaterController?.updater else { return }

    switch mode {
    case .off:
      updater.automaticallyDownloadsUpdates = false
      updater.automaticallyChecksForUpdates = false
    case .notify:
      updater.automaticallyChecksForUpdates = true
      updater.automaticallyDownloadsUpdates = false
    case .install:
      updater.automaticallyChecksForUpdates = true
      if updater.allowsAutomaticUpdates {
        updater.automaticallyDownloadsUpdates = true
      }
    }
    publishSnapshotChange()
  }

  func checkForUpdates(_ sender: Any? = nil) {
    guard let updaterController else {
      NSWorkspace.shared.open(Self.releasePageURL)
      return
    }

    NSApp.setActivationPolicy(.regular)
    NSRunningApplication.current.activate(options: [.activateAllWindows])
    updaterController.checkForUpdates(sender)
    publishSnapshotChange()
  }

  nonisolated func standardUserDriverWillFinishUpdateSession() {
    Task { @MainActor [weak self] in
      self?.finishUpdatePresentation()
    }
  }

  func updater(
    _ updater: SPUUpdater,
    didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
    error: (any Error)?
  ) {
    finishUpdatePresentation()
  }

  private func finishUpdatePresentation() {
    publishSnapshotChange()
    presentationFinished?()
  }

  private func publishSnapshotChange() {
    snapshotRevision &+= 1
  }

  private static var hasSparkleConfiguration: Bool {
    guard
      let feedValue = nonEmptyInfoValue(forKey: "SUFeedURL"),
      let feedURL = URL(string: feedValue),
      feedURL.scheme == "https",
      feedURL.host != nil,
      let publicKey = nonEmptyInfoValue(forKey: "SUPublicEDKey"),
      let keyData = Data(base64Encoded: publicKey),
      keyData.count == 32
    else {
      return false
    }
    return true
  }

  private static var currentVersion: String {
    nonEmptyInfoValue(forKey: "CFBundleShortVersionString")
      ?? "Development Build"
  }

  private static func mode(
    automaticallyChecks: Bool,
    automaticallyDownloads: Bool
  ) -> Mode {
    guard automaticallyChecks else { return .off }
    return automaticallyDownloads ? .install : .notify
  }

  private static func lastCheckSummary(for date: Date?) -> String {
    guard let date else { return "Never checked." }
    return "Last checked \(date.formatted(date: .abbreviated, time: .shortened))."
  }

  private static func nonEmptyInfoValue(forKey key: String) -> String? {
    guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String
    else {
      return nil
    }

    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private static let releasePageURL: URL = {
    var components = URLComponents()
    components.scheme = "https"
    components.host = "github.com"
    components.path = "/acg-box/deskhelm/releases"
    guard let url = components.url else {
      preconditionFailure("Invalid DeskHelm release URL.")
    }
    return url
  }()
}
