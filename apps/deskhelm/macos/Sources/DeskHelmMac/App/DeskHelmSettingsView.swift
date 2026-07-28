import DeskHelmAppCore
import Observation
import SwiftUI

enum SettingsSection: String, CaseIterable, Identifiable {
  case display
  case volumeKeys
  case general
  case about

  var id: Self { self }

  var title: String {
    switch self {
    case .display:
      "Display"
    case .volumeKeys:
      "Volume Keys"
    case .general:
      "General"
    case .about:
      "About"
    }
  }

  var symbolName: String {
    switch self {
    case .display:
      "display"
    case .volumeKeys:
      "keyboard"
    case .general:
      "gearshape"
    case .about:
      "info.circle"
    }
  }

  var contentHeight: CGFloat {
    switch self {
    case .display:
      198
    case .volumeKeys:
      180
    case .general:
      135
    case .about:
      212
    }
  }
}

@MainActor
@Observable
final class SettingsSelection {
  private(set) var section: SettingsSection
  private let defaults: UserDefaults
  @ObservationIgnored private var selectionChange: (@MainActor (SettingsSection) -> Void)?

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    section =
      defaults.string(forKey: Self.preferenceKey)
      .flatMap(SettingsSection.init(rawValue:))
      ?? .display
  }

  func select(_ section: SettingsSection) {
    guard self.section != section else { return }
    self.section = section
    defaults.set(section.rawValue, forKey: Self.preferenceKey)
    selectionChange?(section)
  }

  func onSelectionChange(
    _ action: @escaping @MainActor (SettingsSection) -> Void
  ) {
    selectionChange = action
  }

  private static let preferenceKey = "SelectedSettingsSection"
}

@MainActor
struct DeskHelmSettingsView: View {
  @Bindable private var selection: SettingsSelection
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private let store: VolumeStore
  private let volumeKeyState: VolumeKeyFeatureState
  private let accessibilityPermission: AccessibilityPermission
  private let launchAtLogin: LaunchAtLoginController
  private let softwareUpdater: SoftwareUpdater
  private let presentAccessibilityPermissionGuide: @MainActor () -> Void

  init(
    selection: SettingsSelection,
    store: VolumeStore,
    volumeKeyState: VolumeKeyFeatureState,
    accessibilityPermission: AccessibilityPermission,
    launchAtLogin: LaunchAtLoginController,
    softwareUpdater: SoftwareUpdater,
    presentAccessibilityPermissionGuide:
      @escaping @MainActor () -> Void
  ) {
    self.selection = selection
    self.store = store
    self.volumeKeyState = volumeKeyState
    self.accessibilityPermission = accessibilityPermission
    self.launchAtLogin = launchAtLogin
    self.softwareUpdater = softwareUpdater
    self.presentAccessibilityPermissionGuide =
      presentAccessibilityPermissionGuide
  }

  var body: some View {
    Form {
      activePane
    }
    .formStyle(.grouped)
    .scrollIndicators(.hidden)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .id(selection.section)
    .transition(.opacity)
    .animation(
      reduceMotion ? nil : .easeInOut(duration: 0.16),
      value: selection.section
    )
  }

  @ViewBuilder
  private var activePane: some View {
    switch selection.section {
    case .display:
      DisplaySettingsPane(store: store)
    case .volumeKeys:
      VolumeKeysSettingsPane(
        state: volumeKeyState,
        permission: accessibilityPermission,
        presentPermissionGuide: presentAccessibilityPermissionGuide
      )
    case .general:
      GeneralSettingsPane(launchAtLogin: launchAtLogin)
    case .about:
      AboutSettingsPane(softwareUpdater: softwareUpdater)
    }
  }
}
