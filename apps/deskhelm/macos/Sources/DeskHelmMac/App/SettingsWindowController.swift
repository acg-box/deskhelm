import AppKit
import DeskHelmAppCore
import OSLog
import SwiftUI

@MainActor
final class SettingsWindowController: NSWindowController,
  NSWindowDelegate,
  NSToolbarDelegate
{
  private let logger = Logger(
    subsystem: "com.acgbox.deskhelm",
    category: "Settings"
  )
  private let accessibilityPermissionGuide: AccessibilityPermissionGuideWindowController
  private let accessibilityPermission: AccessibilityPermission
  private let launchAtLogin: LaunchAtLoginController
  private let selection: SettingsSelection
  private let volumeKeyController: VolumeKeyController
  private var presentationRequested = false

  var isPresentingSettings: Bool {
    presentationRequested || window?.isVisible == true
  }

  init(
    store: VolumeStore,
    volumeKeyState: VolumeKeyFeatureState,
    volumeKeyController: VolumeKeyController,
    accessibilityPermission: AccessibilityPermission,
    launchAtLogin: LaunchAtLoginController,
    softwareUpdater: SoftwareUpdater
  ) {
    let selection = SettingsSelection()
    let accessibilityPermissionGuide =
      AccessibilityPermissionGuideWindowController(
        permission: accessibilityPermission
      )
    self.selection = selection
    self.accessibilityPermissionGuide = accessibilityPermissionGuide
    self.accessibilityPermission = accessibilityPermission
    self.launchAtLogin = launchAtLogin
    self.volumeKeyController = volumeKeyController

    let rootView = DeskHelmSettingsView(
      selection: selection,
      store: store,
      volumeKeyState: volumeKeyState,
      accessibilityPermission: accessibilityPermission,
      launchAtLogin: launchAtLogin,
      softwareUpdater: softwareUpdater,
      presentAccessibilityPermissionGuide: {
        accessibilityPermissionGuide.present()
      }
    )
    let hostingController = NSHostingController(rootView: rootView)
    hostingController.sizingOptions = []
    let initialSize = NSSize(
      width: Self.contentWidth,
      height: Self.contentHeight(
        for: selection.section,
        launchAtLoginState: launchAtLogin.state
      )
    )
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: initialSize),
      styleMask: [.titled, .closable],
      backing: .buffered,
      defer: false
    )

    window.contentViewController = hostingController
    window.setContentSize(initialSize)
    window.title = selection.section.title
    window.titleVisibility = .hidden
    window.isReleasedWhenClosed = false
    window.collectionBehavior.insert(.moveToActiveSpace)

    super.init(window: window)

    selection.onSelectionChange { [weak self] section in
      self?.selectPane(section)
    }
    accessibilityPermission.onStateChange { [weak self] permissionState in
      guard let self else { return }
      self.volumeKeyController.accessibilityPermissionDidChange(permissionState)
      guard self.selection.section == .volumeKeys else { return }
      resizeWindow(
        for: .volumeKeys,
        animated: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
      )
    }
    launchAtLogin.onStateChange { [weak self] _ in
      guard let self, selection.section == .general else { return }
      resizeWindow(
        for: .general,
        animated: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
      )
    }
    let toolbar = NSToolbar(identifier: "DeskHelmSettingsToolbar")
    toolbar.delegate = self
    toolbar.displayMode = .iconOnly
    toolbar.sizeMode = .regular
    toolbar.allowsUserCustomization = false
    toolbar.autosavesConfiguration = false
    toolbar.selectedItemIdentifier = selection.section.toolbarIdentifier
    toolbar.centeredItemIdentifiers = Set(
      SettingsSection.allCases.map(\.toolbarIdentifier)
    )
    window.toolbar = toolbar
    window.toolbarStyle = .unifiedCompact
    window.standardWindowButton(.miniaturizeButton)?.isEnabled = false
    window.standardWindowButton(.zoomButton)?.isEnabled = false
    window.delegate = self
    window.center()

    NotificationCenter.default.addObserver(
      self,
      selector: #selector(applicationDidBecomeActive(_:)),
      name: NSApplication.didBecomeActiveNotification,
      object: nil
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(otherWindowWillClose(_:)),
      name: NSWindow.willCloseNotification,
      object: nil
    )
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func present() {
    guard let window else { return }

    presentationRequested = true
    volumeKeyController.dismissHUD()
    NSApp.setActivationPolicy(.regular)
    refreshSystemState()
    resizeWindow(for: selection.section, animated: false)
    showWindow(nil)
    NSRunningApplication.current.activate(options: [.activateAllWindows])
    NSApp.activate(ignoringOtherApps: true)
    window.makeKeyAndOrderFront(nil)
    window.makeFirstResponder(nil)
    publishState(phase: "shown")

    Task { @MainActor [weak self, weak window] in
      await Task.yield()
      guard let self, let window, window.isVisible else { return }
      window.makeKeyAndOrderFront(nil)
      window.makeFirstResponder(nil)
      publishState(phase: "focused")
    }
  }

  func closeForTermination() {
    NotificationCenter.default.removeObserver(self)
    accessibilityPermissionGuide.close()
    window?.delegate = nil
    close()
  }

  func externalWindowPresentationDidFinish() {
    Task { @MainActor [weak self] in
      await Task.yield()
      try? await Task.sleep(for: .milliseconds(150))
      self?.restoreAccessoryActivationIfPossible()
    }
  }

  func windowDidBecomeKey(_ notification: Notification) {
    refreshSystemState()
    publishState(phase: "key")
  }

  func windowWillClose(_ notification: Notification) {
    presentationRequested = false
    accessibilityPermissionGuide.close()
    publishState(phase: "closed")
    Task { @MainActor [weak self] in
      await Task.yield()
      self?.restoreAccessoryActivationIfPossible()
    }
  }

  func toolbarAllowedItemIdentifiers(
    _ toolbar: NSToolbar
  ) -> [NSToolbarItem.Identifier] {
    SettingsSection.allCases.map(\.toolbarIdentifier)
  }

  func toolbarDefaultItemIdentifiers(
    _ toolbar: NSToolbar
  ) -> [NSToolbarItem.Identifier] {
    SettingsSection.allCases.map(\.toolbarIdentifier)
  }

  func toolbarSelectableItemIdentifiers(
    _ toolbar: NSToolbar
  ) -> [NSToolbarItem.Identifier] {
    SettingsSection.allCases.map(\.toolbarIdentifier)
  }

  func toolbar(
    _ toolbar: NSToolbar,
    itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
    willBeInsertedIntoToolbar flag: Bool
  ) -> NSToolbarItem? {
    guard let section = SettingsSection(itemIdentifier: itemIdentifier) else {
      return nil
    }

    let item = NSToolbarItem(itemIdentifier: itemIdentifier)
    item.label = section.title
    item.paletteLabel = section.title
    item.toolTip = section.title
    item.image = NSImage(
      systemSymbolName: section.symbolName,
      accessibilityDescription: section.title
    )
    item.target = self
    item.action = #selector(selectPaneFromToolbar(_:))
    return item
  }

  @objc
  private func selectPaneFromToolbar(_ sender: NSToolbarItem) {
    guard
      let section = SettingsSection(
        itemIdentifier: sender.itemIdentifier
      )
    else {
      return
    }
    selection.select(section)
  }

  private func selectPane(_ section: SettingsSection) {
    window?.title = section.title
    window?.toolbar?.selectedItemIdentifier = section.toolbarIdentifier
    resizeWindow(
      for: section,
      animated: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    )
    publishState(phase: "pane-\(section.rawValue)")
  }

  @objc
  private func applicationDidBecomeActive(_ notification: Notification) {
    accessibilityPermission.refresh()
    guard window?.isVisible == true else { return }
    launchAtLogin.refresh()
    resizeWindow(
      for: selection.section,
      animated: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    )
  }

  @objc
  private func otherWindowWillClose(_ notification: Notification) {
    guard let closingWindow = notification.object as? NSWindow,
      closingWindow !== window
    else {
      return
    }
    Task { @MainActor [weak self] in
      await Task.yield()
      self?.restoreAccessoryActivationIfPossible()
    }
  }

  private func refreshSystemState() {
    accessibilityPermission.refresh()
    launchAtLogin.refresh()
  }

  private func resizeWindow(
    for section: SettingsSection,
    animated: Bool
  ) {
    guard let window else { return }

    let contentSize = NSSize(
      width: Self.contentWidth,
      height: Self.contentHeight(
        for: section,
        launchAtLoginState: launchAtLogin.state
      )
    )
    let contentRect = NSRect(origin: .zero, size: contentSize)
    var targetFrame = window.frameRect(forContentRect: contentRect)
    targetFrame.origin.x = window.frame.midX - targetFrame.width / 2
    targetFrame.origin.y = window.frame.maxY - targetFrame.height

    if let visibleFrame = window.screen?.visibleFrame {
      targetFrame.origin.x = min(
        max(targetFrame.minX, visibleFrame.minX),
        visibleFrame.maxX - targetFrame.width
      )
      targetFrame.origin.y = min(
        max(targetFrame.minY, visibleFrame.minY),
        visibleFrame.maxY - targetFrame.height
      )
    }

    window.setFrame(targetFrame, display: true, animate: animated)
  }

  private func restoreAccessoryActivationIfPossible() {
    guard window?.isVisible != true else { return }

    let hasOtherVisibleWindow = NSApp.windows.contains { candidate in
      candidate !== window
        && candidate.isVisible
        && !(candidate is NSPanel)
    }
    guard !hasOtherVisibleWindow else { return }
    NSApp.setActivationPolicy(.accessory)
  }

  private func publishState(phase: String) {
    guard let window else { return }

    let visibleFrame = window.screen?.visibleFrame
    let isOnScreen = visibleFrame.map(window.frame.intersects) ?? false
    let summary =
      "phase=\(phase) visible=\(window.isVisible) key=\(window.isKeyWindow) "
      + "main=\(window.isMainWindow) onScreen=\(isOnScreen) "
      + "toolbar=icons pane=\(selection.section.rawValue) "
      + "windowNumber=\(window.windowNumber) "
      + "width=\(Int(window.frame.width.rounded())) "
      + "height=\(Int(window.frame.height.rounded()))"
    let defaults = UserDefaults.standard

    defaults.set(
      ProcessInfo.processInfo.processIdentifier,
      forKey: "SettingsWindowStatePID"
    )
    defaults.set(summary, forKey: "SettingsWindowStateSummary")
    defaults.synchronize()
    logger.notice("settings-window-state \(summary, privacy: .public)")
  }

  private static let contentWidth: CGFloat = 520

  private static func contentHeight(
    for section: SettingsSection,
    launchAtLoginState: LaunchAtLoginState
  ) -> CGFloat {
    if section == .general {
      switch launchAtLoginState {
      case .requiresApproval:
        return 180
      case .error:
        return 170
      case .enabled, .notRegistered:
        break
      }
    }
    return section.contentHeight
  }
}

extension SettingsSection {
  fileprivate var toolbarIdentifier: NSToolbarItem.Identifier {
    NSToolbarItem.Identifier("DeskHelm.Settings.\(rawValue)")
  }

  fileprivate init?(itemIdentifier: NSToolbarItem.Identifier) {
    let prefix = "DeskHelm.Settings."
    guard itemIdentifier.rawValue.hasPrefix(prefix) else { return nil }
    self.init(rawValue: String(itemIdentifier.rawValue.dropFirst(prefix.count)))
  }
}
