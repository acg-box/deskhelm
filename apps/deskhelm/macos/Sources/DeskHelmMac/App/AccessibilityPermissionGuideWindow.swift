import AppKit
import CoreGraphics
import SwiftUI

enum AccessibilityPermissionGuideDirection: Equatable {
  case left
  case right

  var symbolName: String {
    switch self {
    case .left:
      "arrow.left"
    case .right:
      "arrow.right"
    }
  }
}

struct AccessibilityPermissionGuideScreen: Equatable {
  let frame: CGRect
  let visibleFrame: CGRect
  let coreGraphicsFrame: CGRect
}

struct AccessibilityPermissionGuidePlacement: Equatable {
  private static let accessibilityListAlignmentOffset: CGFloat = -8

  let frame: CGRect
  let direction: AccessibilityPermissionGuideDirection

  static func beside(
    settingsFrame: CGRect,
    visibleFrame: CGRect,
    guideSize: CGSize,
    gap: CGFloat = 14
  ) -> Self {
    let y = min(
      max(
        settingsFrame.midY
          - guideSize.height / 2
          + accessibilityListAlignmentOffset,
        visibleFrame.minY + 12
      ),
      visibleFrame.maxY - guideSize.height - 12
    )
    let rightOrigin = CGPoint(
      x: settingsFrame.maxX + gap,
      y: y
    )
    if rightOrigin.x + guideSize.width <= visibleFrame.maxX - 8 {
      return Self(
        frame: CGRect(origin: rightOrigin, size: guideSize),
        direction: .left
      )
    }

    let leftOrigin = CGPoint(
      x: settingsFrame.minX - gap - guideSize.width,
      y: y
    )
    if leftOrigin.x >= visibleFrame.minX + 8 {
      return Self(
        frame: CGRect(origin: leftOrigin, size: guideSize),
        direction: .right
      )
    }

    let fallbackOrigin = CGPoint(
      x: min(
        max(settingsFrame.maxX - guideSize.width - 18, visibleFrame.minX + 8),
        visibleFrame.maxX - guideSize.width - 8
      ),
      y: min(
        max(settingsFrame.maxY + 12, visibleFrame.minY + 8),
        visibleFrame.maxY - guideSize.height - 8
      )
    )
    return Self(
      frame: CGRect(origin: fallbackOrigin, size: guideSize),
      direction: .left
    )
  }

  static func fallback(
    in visibleFrame: CGRect,
    guideSize: CGSize
  ) -> Self {
    let origin = CGPoint(
      x: visibleFrame.maxX - guideSize.width - 30,
      y: visibleFrame.maxY - guideSize.height - 86
    )
    return Self(
      frame: CGRect(origin: origin, size: guideSize),
      direction: .left
    )
  }

  static func appKitWindowFrame(
    from coreGraphicsWindowFrame: CGRect,
    screens: [AccessibilityPermissionGuideScreen]
  ) -> (frame: CGRect, visibleFrame: CGRect)? {
    guard
      let screen = screens.max(by: {
        intersectionArea($0.coreGraphicsFrame, coreGraphicsWindowFrame)
          < intersectionArea($1.coreGraphicsFrame, coreGraphicsWindowFrame)
      }),
      intersectionArea(screen.coreGraphicsFrame, coreGraphicsWindowFrame) > 0,
      screen.coreGraphicsFrame.width > 0,
      screen.coreGraphicsFrame.height > 0
    else {
      return nil
    }

    let xScale = screen.frame.width / screen.coreGraphicsFrame.width
    let yScale = screen.frame.height / screen.coreGraphicsFrame.height
    let localX =
      (coreGraphicsWindowFrame.minX - screen.coreGraphicsFrame.minX) * xScale
    let localYFromTop =
      (coreGraphicsWindowFrame.minY - screen.coreGraphicsFrame.minY) * yScale
    let width = coreGraphicsWindowFrame.width * xScale
    let height = coreGraphicsWindowFrame.height * yScale
    let frame = CGRect(
      x: screen.frame.minX + localX,
      y: screen.frame.maxY - localYFromTop - height,
      width: width,
      height: height
    )
    return (frame, screen.visibleFrame)
  }

  private static func intersectionArea(
    _ lhs: CGRect,
    _ rhs: CGRect
  ) -> CGFloat {
    let intersection = lhs.intersection(rhs)
    guard !intersection.isNull, !intersection.isInfinite else { return 0 }
    return max(0, intersection.width) * max(0, intersection.height)
  }
}

@MainActor
final class AccessibilityPermissionGuideWindowController:
  NSWindowController
{
  private static let windowSize = NSSize(width: 358, height: 50)
  private static let cornerRadius: CGFloat = 17
  private static let positioningRetryCount = 8
  private static let pollingInterval = Duration.milliseconds(500)

  private let permission: AccessibilityPermission
  private let materialView = NSVisualEffectView()
  private var hostingController: NSHostingController<AccessibilityPermissionGuideView>?
  private var guideDirection: AccessibilityPermissionGuideDirection = .left
  private var sessionTask: Task<Void, Never>?
  init(permission: AccessibilityPermission) {
    self.permission = permission

    let panel = NSPanel(
      contentRect: NSRect(origin: .zero, size: Self.windowSize),
      styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
      backing: .buffered,
      defer: false
    )
    panel.backgroundColor = .clear
    panel.becomesKeyOnlyIfNeeded = true
    panel.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
    panel.hasShadow = true
    panel.hidesOnDeactivate = false
    panel.isFloatingPanel = true
    panel.isMovable = false
    panel.isOpaque = false
    panel.isReleasedWhenClosed = false
    panel.level = .floating
    panel.title = "Accessibility Permission Guide"
    panel.setAccessibilityLabel("Accessibility permission guide")

    super.init(window: panel)
    configureMaterialView()
    updateRootView()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func present() {
    guard permission.refresh() == .required else {
      close()
      return
    }

    _ = permission.openSystemSettings()
    beginGuidanceSession()
  }

  override func close() {
    sessionTask?.cancel()
    sessionTask = nil
    super.close()
  }

  private func beginGuidanceSession() {
    sessionTask?.cancel()
    window?.orderOut(nil)
    updateRootView()

    sessionTask = Task { @MainActor [weak self] in
      var positionAttempt = 0
      while !Task.isCancelled {
        guard let self else { return }

        if permission.refresh() == .granted {
          close()
          return
        }

        if let target = Self.systemSettingsWindowTarget() {
          positionGuide(
            AccessibilityPermissionGuidePlacement.beside(
              settingsFrame: target.frame,
              visibleFrame: target.visibleFrame,
              guideSize: Self.windowSize
            )
          )
          revealGuideWindow()
        } else if positionAttempt >= Self.positioningRetryCount,
          window?.isVisible != true
        {
          positionAtFallbackLocation()
          revealGuideWindow()
        }
        positionAttempt += 1

        do {
          try await Task.sleep(for: Self.pollingInterval)
        } catch {
          return
        }
      }
    }
  }

  private func reopenSystemSettings() {
    _ = permission.openSystemSettings()
    beginGuidanceSession()
  }

  private func updateRootView() {
    let bundleURL = Bundle.main.bundleURL
    let rootView = AccessibilityPermissionGuideView(
      direction: guideDirection,
      bundleURL: bundleURL,
      appIcon: NSWorkspace.shared.icon(forFile: bundleURL.path),
      canDragApp: bundleURL.pathExtension.lowercased() == "app",
      openSettings: { [weak self] in
        self?.reopenSystemSettings()
      },
      dismiss: { [weak self] in
        self?.close()
      }
    )

    if let hostingController {
      hostingController.rootView = rootView
      return
    }

    let hostingController = NSHostingController(rootView: rootView)
    hostingController.sizingOptions = []
    hostingController.view.translatesAutoresizingMaskIntoConstraints = false
    hostingController.view.wantsLayer = true
    hostingController.view.layer?.backgroundColor = NSColor.clear.cgColor
    materialView.addSubview(hostingController.view)
    NSLayoutConstraint.activate([
      hostingController.view.leadingAnchor.constraint(
        equalTo: materialView.leadingAnchor
      ),
      hostingController.view.trailingAnchor.constraint(
        equalTo: materialView.trailingAnchor
      ),
      hostingController.view.topAnchor.constraint(
        equalTo: materialView.topAnchor
      ),
      hostingController.view.bottomAnchor.constraint(
        equalTo: materialView.bottomAnchor
      ),
    ])
    self.hostingController = hostingController
  }

  private func configureMaterialView() {
    materialView.frame = NSRect(origin: .zero, size: Self.windowSize)
    materialView.autoresizingMask = [.width, .height]
    materialView.blendingMode = .withinWindow
    materialView.material = .popover
    materialView.state = .active
    materialView.wantsLayer = true
    materialView.layer?.cornerRadius = Self.cornerRadius
    materialView.layer?.cornerCurve = .continuous
    materialView.layer?.masksToBounds = true
    materialView.maskImage = Self.roundedMaskImage(
      size: Self.windowSize,
      cornerRadius: Self.cornerRadius
    )
    window?.contentView = materialView
  }

  private func positionGuide(
    _ placement: AccessibilityPermissionGuidePlacement
  ) {
    if guideDirection != placement.direction {
      guideDirection = placement.direction
      updateRootView()
    }
    guard window?.frame != placement.frame else { return }
    window?.setFrame(placement.frame, display: true)
  }

  private func positionAtFallbackLocation() {
    guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
    positionGuide(
      AccessibilityPermissionGuidePlacement.fallback(
        in: screen.visibleFrame,
        guideSize: Self.windowSize
      )
    )
  }

  private func revealGuideWindow() {
    guard window?.isVisible != true else { return }
    showWindow(nil)
    window?.orderFrontRegardless()
  }

  private static func systemSettingsWindowTarget()
    -> (frame: CGRect, visibleFrame: CGRect)?
  {
    guard
      let windowInfos = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements],
        kCGNullWindowID
      ) as? [[String: Any]]
    else {
      return nil
    }

    let processIdentifiers = Set(
      NSRunningApplication.runningApplications(
        withBundleIdentifier: "com.apple.systempreferences"
      )
      .map { Int($0.processIdentifier) }
    )
    let coreGraphicsFrame = windowInfos.compactMap {
      info -> CGRect? in
      let layer =
        (info[kCGWindowLayer as String] as? NSNumber)?.intValue
      let ownerIdentifier =
        (info[kCGWindowOwnerPID as String] as? NSNumber)?.intValue
      let ownerName = info[kCGWindowOwnerName as String] as? String
      let matchesSystemSettings =
        ownerIdentifier.map(processIdentifiers.contains) == true
        || ownerName == "System Settings"
        || ownerName == "System Preferences"
      guard
        matchesSystemSettings,
        layer == 0,
        let bounds = info[kCGWindowBounds as String] as? [String: Any],
        let frame = CGRect(
          dictionaryRepresentation: bounds as CFDictionary
        )
      else {
        return nil
      }
      return frame
    }
    .max {
      $0.width * $0.height < $1.width * $1.height
    }
    guard let coreGraphicsFrame else { return nil }

    return AccessibilityPermissionGuidePlacement.appKitWindowFrame(
      from: coreGraphicsFrame,
      screens: screenGeometries()
    )
  }

  private static func screenGeometries()
    -> [AccessibilityPermissionGuideScreen]
  {
    NSScreen.screens.compactMap { screen in
      guard
        let number = screen.deviceDescription[
          NSDeviceDescriptionKey("NSScreenNumber")
        ] as? NSNumber
      else {
        return nil
      }
      let displayID = CGDirectDisplayID(number.uint32Value)
      return AccessibilityPermissionGuideScreen(
        frame: screen.frame,
        visibleFrame: screen.visibleFrame,
        coreGraphicsFrame: CGDisplayBounds(displayID)
      )
    }
  }

  private static func roundedMaskImage(
    size: NSSize,
    cornerRadius: CGFloat
  ) -> NSImage {
    let image = NSImage(size: size)
    image.lockFocus()
    NSColor.black.setFill()
    NSBezierPath(
      roundedRect: NSRect(origin: .zero, size: size),
      xRadius: cornerRadius,
      yRadius: cornerRadius
    )
    .fill()
    image.unlockFocus()
    return image
  }
}

private struct AccessibilityPermissionGuideView: View {
  let direction: AccessibilityPermissionGuideDirection
  let bundleURL: URL
  let appIcon: NSImage
  let canDragApp: Bool
  let openSettings: () -> Void
  let dismiss: () -> Void

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.colorScheme) private var colorScheme
  @State private var pulse = false

  var body: some View {
    HStack(alignment: .center, spacing: 7) {
      if direction == .left {
        arrowGuide
        appChip
        instructionText
        openSettingsButton
        dismissButton
      } else {
        dismissButton
        openSettingsButton
        instructionText
        appChip
        arrowGuide
      }
    }
    .padding(.horizontal, 10)
    .frame(width: 358, height: 50)
    .onAppear {
      guard !reduceMotion else { return }
      withAnimation(
        .easeInOut(duration: 0.78).repeatForever(autoreverses: true)
      ) {
        pulse = true
      }
    }
  }

  private var arrowGuide: some View {
    AccessibilityPermissionGuideArrow(
      direction: direction,
      pulse: pulse
    )
    .frame(width: 38, height: 31)
    .accessibilityHidden(true)
  }

  @ViewBuilder
  private var appChip: some View {
    if canDragApp {
      PermissionAppDragSource(
        bundleURL: bundleURL,
        icon: appIcon,
        label: "DeskHelm.app"
      )
      .frame(width: 126, height: 31)
      .overlay {
        Capsule()
          .stroke(
            Color.accentColor.opacity(pulse ? 0.58 : 0.20),
            lineWidth: 1.2
          )
          .scaleEffect(reduceMotion ? 1 : (pulse ? 1.055 : 1))
          .allowsHitTesting(false)
      }
    } else {
      Text("Open the staged app")
        .font(.system(size: 10.5, weight: .semibold))
        .foregroundStyle(.secondary)
        .frame(width: 126, height: 31)
        .background(.quaternary, in: Capsule())
    }
  }

  private var instructionText: some View {
    Text(canDragApp ? "Drag in, turn on" : "Allow access")
      .font(.system(size: 11.2, weight: .semibold))
      .foregroundStyle(
        Color.primary.opacity(colorScheme == .light ? 0.78 : 0.86)
      )
      .lineLimit(1)
      .minimumScaleFactor(0.86)
      .frame(maxWidth: .infinity, alignment: .leading)
      .layoutPriority(1)
  }

  private var openSettingsButton: some View {
    guideButton(
      symbolName: "arrow.up.forward.app",
      help: "Open Accessibility settings",
      action: openSettings
    )
  }

  private var dismissButton: some View {
    guideButton(
      symbolName: "xmark",
      help: "Close permission guide",
      action: dismiss
    )
  }

  private func guideButton(
    symbolName: String,
    help: String,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Image(systemName: symbolName)
        .font(.system(size: 11.4, weight: .semibold))
        .frame(width: 24, height: 24)
    }
    .buttonStyle(.plain)
    .foregroundStyle(Color.accentColor)
    .background(
      Color.accentColor.opacity(colorScheme == .light ? 0.075 : 0.13),
      in: RoundedRectangle(cornerRadius: 7, style: .continuous)
    )
    .frame(width: 28, height: 31)
    .help(help)
    .accessibilityLabel(help)
  }
}

private struct AccessibilityPermissionGuideArrow: View {
  let direction: AccessibilityPermissionGuideDirection
  let pulse: Bool

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    HStack(spacing: 3) {
      if direction == .left {
        arrow
        dots
      } else {
        dots
        arrow
      }
    }
  }

  private var arrow: some View {
    Image(systemName: direction.symbolName)
      .font(.system(size: 19, weight: .bold))
      .foregroundStyle(Color.accentColor)
      .offset(x: arrowOffset)
  }

  private var dots: some View {
    HStack(spacing: 3) {
      ForEach(0..<3) { index in
        Circle()
          .fill(Color.accentColor.opacity(dotOpacity(index: index)))
          .frame(width: 3.8, height: 3.8)
      }
    }
  }

  private func dotOpacity(index: Int) -> Double {
    guard !reduceMotion else { return 0.34 }
    let activeIndex = pulse ? 2 : 0
    return index == activeIndex ? 0.80 : 0.26
  }

  private var arrowOffset: CGFloat {
    guard !reduceMotion else { return 0 }
    switch direction {
    case .left:
      return pulse ? -3 : 1
    case .right:
      return pulse ? 3 : -1
    }
  }
}
