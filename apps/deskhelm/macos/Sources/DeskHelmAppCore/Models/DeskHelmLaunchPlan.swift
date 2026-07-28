package enum DeskHelmLaunchAction: Equatable, Sendable {
  case startVolumeKeys
  case showSettingsForVerification
}

package enum DeskHelmLaunchPlan {
  package static func actions(
    arguments: [String]
  ) -> [DeskHelmLaunchAction] {
    var actions: [DeskHelmLaunchAction] = [
      .startVolumeKeys
    ]

    if arguments.contains("--verify-settings") {
      actions.append(.showSettingsForVerification)
    }

    return actions
  }
}
