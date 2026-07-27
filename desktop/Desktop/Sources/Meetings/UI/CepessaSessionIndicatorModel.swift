import CoreGraphics
import Foundation

/// Pure presentation model for the floating recording indicator.
///
/// The indicator is a micro-lozenge: a 22pt state ring at rest, growing only
/// far enough to carry an advancing monospaced timer while recording. It never
/// changes geometry because a pointer passed nearby — only a deliberate click
/// opens the control tray.
enum CepessaSessionFloatingBarMode: Equatable {
  /// Not recording, not processing. A 22pt hollow ring.
  case idle
  /// Finishing a transcript. A 22pt progress ring.
  case processing
  /// Capture is live. Ring plus timer.
  case recording
  /// The deliberate control tray is open.
  case tray
}

enum CepessaSessionFloatingBarCapabilities {
  /// Stop is reachable from the resting recording indicator (context menu /
  /// pointer path) and from the open tray, and only while capture is live.
  static func stopAvailable(in mode: CepessaSessionFloatingBarMode, isRecording: Bool) -> Bool {
    guard isRecording else { return false }
    switch mode {
    case .recording, .tray:
      return true
    case .idle, .processing:
      return false
    }
  }
}

struct CepessaSessionFloatingBarGeometry: Equatable {
  /// Resting footprint when nothing is being captured.
  static let idleSize = CGSize(width: 22, height: 22)
  /// Processing reuses the resting dot; progress reads as a ring, not a label.
  static let processingSize = CGSize(width: 22, height: 22)
  /// Healthy recording under one hour: ring + `MM:SS`.
  static let recordingSize = CGSize(width: 66, height: 22)
  /// Past one hour the timer gains an hours field and the lozenge grows once.
  static let longRecordingSize = CGSize(width: 82, height: 22)
  /// The deliberate control tray while nothing is being captured:
  /// ring · status · record, hide, menu.
  static let traySize = CGSize(width: 232, height: 32)
  /// Live capture puts three more controls in the same row (mute, capture,
  /// stop). Widening once is honest; cramming them into 232pt is not.
  static let recordingTraySize = CGSize(width: 264, height: 32)
  /// A confirmation ("Screenshot pinned at 12:34") is worth reading in full,
  /// so the tray stretches for the couple of seconds one is on screen rather
  /// than truncating it. Same deliberate morph, driven by state — not hover.
  static let noticeTraySize = CGSize(width: 312, height: 32)

  /// Transparent margin the host panel keeps around the lozenge.
  ///
  /// Without it the panel edge slices the glass rim and both shadow layers
  /// into a hard-edged square — the artefact that made the resting indicator
  /// look like a pale card rather than a floating object.
  static let panelBleed = CepessaChrome.Elevation.lifted.bleed

  /// Panel footprint for a given lozenge, bleed included.
  static func panelSize(for contentSize: CGSize, bleed: CGFloat = panelBleed) -> CGSize {
    CGSize(width: contentSize.width + bleed * 2, height: contentSize.height + bleed * 2)
  }

  static func contentSize(
    for mode: CepessaSessionFloatingBarMode,
    showsHours: Bool = false,
    isRecording: Bool = false,
    hasNotice: Bool = false,
    availableScreenWidth: CGFloat? = nil
  ) -> CGSize {
    let preferred: CGSize
    switch mode {
    case .idle:
      preferred = idleSize
    case .processing:
      preferred = processingSize
    case .recording:
      preferred = showsHours ? longRecordingSize : recordingSize
    case .tray:
      if hasNotice {
        preferred = noticeTraySize
      } else {
        preferred = isRecording ? recordingTraySize : traySize
      }
    }

    guard mode == .tray, let availableScreenWidth else {
      return preferred
    }

    // The bleed is part of the panel, so it comes out of the screen budget too.
    let safeWidth = max(recordingSize.width, availableScreenWidth - panelBleed * 2 - 16)
    return CGSize(width: min(preferred.width, safeWidth), height: preferred.height)
  }

  /// Where the lozenge sits inside its panel: centred, so growing the panel in
  /// either direction leaves the visible object exactly where the user put it.
  static func contentRect(contentSize: CGSize, inPanelOfSize panelSize: CGSize) -> CGRect {
    CGRect(
      x: ((panelSize.width - contentSize.width) / 2).rounded(),
      y: ((panelSize.height - contentSize.height) / 2).rounded(),
      width: contentSize.width,
      height: contentSize.height
    )
  }

  /// Converts the dragged frame of any expanded state back into the origin
  /// that the resting micro-lozenge should persist. Panel resizing preserves
  /// the horizontal centre and top edge, so storing the expanded frame's
  /// literal left edge would make the resting indicator jump after relaunch.
  ///
  /// The persisted value is the *content* origin rather than the panel origin,
  /// so changing how much bleed the panel carries never moves anyone's
  /// indicator.
  static func restingContentOrigin(
    afterDragging draggedPanelFrame: CGRect,
    restingContentSize: CGSize,
    bleed: CGFloat = panelBleed
  ) -> CGPoint {
    CGPoint(
      x: draggedPanelFrame.midX - restingContentSize.width / 2,
      y: draggedPanelFrame.maxY - bleed - restingContentSize.height
    )
  }

  static func panelOrigin(forContentOrigin origin: CGPoint, bleed: CGFloat = panelBleed) -> CGPoint
  {
    CGPoint(x: origin.x - bleed, y: origin.y - bleed)
  }

  /// One-time upgrade of a position saved before the panel carried any bleed.
  /// The old panel padded the lozenge by `legacyPadding` split evenly on both
  /// axes, so the stored panel origin is half a padding away from the content.
  static func migratedContentOrigin(
    fromLegacyPanelOrigin origin: CGPoint,
    legacyPadding: CGFloat = 10
  ) -> CGPoint {
    CGPoint(x: origin.x + legacyPadding / 2, y: origin.y + legacyPadding / 2)
  }
}

/// The expand/collapse contract.
///
/// The indicator is one object that changes shape, not two views that swap.
/// That only holds if the panel is never smaller than the shape inside it, so
/// the panel takes the *union* of the outgoing and incoming footprints for the
/// duration of the morph and settles onto the final one afterwards. Growing
/// first and shrinking last means the glass is never clipped mid-flight.
enum CepessaSessionIndicatorTransition {
  static func panelContentSize(from: CGSize, to: CGSize) -> CGSize {
    CGSize(width: max(from.width, to.width), height: max(from.height, to.height))
  }

  /// Clicks are swallowed for as long as the shape is moving.
  ///
  /// A tray collapsing under the pointer would otherwise deliver the release
  /// to whichever control happens to slide beneath it — including Record and
  /// Stop. Nothing about capture may be decided by an animation.
  static func acceptsClicks(isTransitioning: Bool) -> Bool {
    !isTransitioning
  }

  /// While the shape is moving the whole union is inert, so a click cannot
  /// fall through the transparent bleed to whatever is behind the panel
  /// either. Once settled, only the lozenge itself is live.
  static func interactiveRect(
    contentSize: CGSize,
    panelContentSize: CGSize,
    panelSize: CGSize,
    isTransitioning: Bool
  ) -> CGRect {
    CepessaSessionFloatingBarGeometry.contentRect(
      contentSize: isTransitioning ? panelContentSize : contentSize,
      inPanelOfSize: panelSize
    )
  }
}

/// Interaction reducer for the indicator.
///
/// Hover is opacity-only: `isHovered` never feeds `isExpanded`. The tray opens
/// on a deliberate click and stays open until the user closes it, presses
/// Escape, or the pointer leaves it.
struct CepessaSessionFloatingBarInteractionState: Equatable {
  private(set) var isHovered = false
  private(set) var isTrayOpen = false
  private(set) var isHiddenForCurrentRecording = false

  /// True only when the control tray is deliberately open.
  var isExpanded: Bool { isTrayOpen }

  mutating func recordingDidStart() {
    isHovered = false
    isTrayOpen = false
    isHiddenForCurrentRecording = false
  }

  mutating func recordingDidEnd() {
    isHovered = false
    isTrayOpen = false
    isHiddenForCurrentRecording = false
  }

  /// Pointer proximity. Affects opacity only — never geometry.
  mutating func hoverChanged(_ isHovered: Bool) {
    self.isHovered = isHovered
  }

  mutating func toggleTray() {
    isTrayOpen.toggle()
    if isTrayOpen {
      isHiddenForCurrentRecording = false
    }
  }

  mutating func openTray() {
    isTrayOpen = true
    isHiddenForCurrentRecording = false
  }

  /// Closes the tray back to the resting lozenge.
  mutating func closeTray() {
    isTrayOpen = false
  }

  mutating func hideForCurrentRecording() {
    isHiddenForCurrentRecording = true
    isTrayOpen = false
  }

  mutating func show() {
    isHiddenForCurrentRecording = false
  }
}

/// The one line of text the open tray shows next to the state ring.
///
/// It only ever reports something the app actually knows. There is no
/// marketing line and no invented readiness claim: when nothing is running it
/// says so, and it says the same thing the menu-bar item says.
enum CepessaSessionIndicatorTrayStatus {
  /// `hasFault` is the recorder's own error, not derived capture health: with
  /// nothing running every source is inactive, which resolves to
  /// `.unavailable` and would otherwise make an idle indicator claim a
  /// problem it does not have.
  static func text(
    isRecording: Bool,
    isTranscribing: Bool,
    hasFault: Bool,
    compactTimerText: String,
    progress: Double?,
    notice: String? = nil
  ) -> String {
    if let notice = notice?.trimmingCharacters(in: .whitespacesAndNewlines), !notice.isEmpty {
      return notice
    }
    if isRecording {
      return compactTimerText
    }
    if isTranscribing {
      guard let progress else { return "Transcribing" }
      return "Transcribing \(Int((progress * 100).rounded()))%"
    }
    return hasFault ? "Needs attention" : "Not recording"
  }

  /// The timer is the only status that must never reflow as digits change.
  static func usesMonospacedDigits(isRecording: Bool, hasNotice: Bool) -> Bool {
    isRecording && !hasNotice
  }
}

enum CepessaSessionCaptureHealth: Equatable {
  case healthy
  case partial
  case muted
  case unavailable

  static func resolve(
    microphoneActive: Bool,
    microphoneMuted: Bool,
    systemAudioActive: Bool,
    hasError: Bool
  ) -> Self {
    if hasError {
      return .unavailable
    }

    if microphoneMuted {
      return systemAudioActive ? .muted : .unavailable
    }

    switch (microphoneActive, systemAudioActive) {
    case (true, true):
      return .healthy
    case (true, false), (false, true):
      return .partial
    case (false, false):
      return .unavailable
    }
  }

  var accessibilityLabel: String {
    switch self {
    case .healthy:
      return "Microphone and system audio are recording"
    case .partial:
      return "Only one audio source is recording"
    case .muted:
      return "Microphone muted; system audio is recording"
    case .unavailable:
      return "Audio capture needs attention"
    }
  }
}

/// How the single state ring is drawn.
///
/// Shape carries the meaning; colour only confirms it. Healthy capture is
/// never painted with a success colour — the absence of a warning *is* the
/// healthy signal.
enum CepessaSessionIndicatorRing: Equatable {
  /// Hollow neutral ring. Ready, nothing running.
  case idle
  /// Progress arc. Determinate when a fraction is known.
  case processing(progress: Double?)
  /// Ring with a solid core — the platform record glyph.
  case recording
  /// Ring with a slash: still recording, microphone deliberately muted.
  case recordingMuted
  /// Broken (dashed) ring: one source is missing.
  case degraded
  /// A single warning glyph replaces the ring: capture needs attention.
  case fault

  static func resolve(
    mode: CepessaSessionFloatingBarMode,
    isRecording: Bool,
    health: CepessaSessionCaptureHealth,
    progress: Double?
  ) -> Self {
    if isRecording {
      switch health {
      case .healthy:
        return .recording
      case .muted:
        return .recordingMuted
      case .partial:
        return .degraded
      case .unavailable:
        return .fault
      }
    }

    switch mode {
    case .processing:
      return .processing(progress: progress)
    case .idle, .recording, .tray:
      return .idle
    }
  }
}

/// Compact timer text for the resting lozenge.
///
/// The recorder publishes `HH:MM:SS`. Under an hour the indicator drops the
/// leading hour field so the lozenge stays 66pt wide; past an hour it shows an
/// unpadded hour and grows once.
enum CepessaSessionIndicatorTimer {
  static func compactText(from source: String) -> String {
    let parts = source.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
    guard parts.count == 3, let hours = Int(parts[0]) else {
      return source
    }
    return hours == 0 ? "\(parts[1]):\(parts[2])" : "\(hours):\(parts[1]):\(parts[2])"
  }

  static func showsHours(_ source: String) -> Bool {
    let parts = source.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
    guard parts.count == 3, let hours = Int(parts[0]) else { return false }
    return hours > 0
  }
}

/// VoiceOver strings for the indicator and the menu-bar status item.
/// Pure functions so every state is covered by tests.
enum CepessaSessionIndicatorAccessibility {
  static func indicatorLabel(
    mode: CepessaSessionFloatingBarMode,
    isRecording: Bool,
    health: CepessaSessionCaptureHealth,
    timerText: String,
    progress: Double?
  ) -> String {
    if isRecording {
      return "Recording \(compactSpokenTimer(timerText)). \(health.accessibilityLabel)."
    }

    switch mode {
    case .processing:
      if let progress {
        return "Transcribing, \(percentText(progress)) complete."
      }
      return "Transcribing."
    case .idle, .recording, .tray:
      return "Sessions idle. Not recording."
    }
  }

  static func indicatorValue(
    isRecording: Bool,
    timerText: String,
    progress: Double?
  ) -> String {
    if isRecording {
      return compactSpokenTimer(timerText)
    }
    if let progress {
      return percentText(progress)
    }
    return "Idle"
  }

  static func indicatorHint(isTrayOpen: Bool) -> String {
    isTrayOpen
      ? "Closes the recording controls. Press Escape to close."
      : "Opens the recording controls."
  }

  /// Menu-bar status item. Must read meaningfully in every state, including
  /// when the floating indicator has been hidden for the current recording.
  static func statusItemLabel(
    isRecording: Bool,
    isTranscribing: Bool,
    hasFault: Bool
  ) -> String {
    if isRecording {
      return hasFault
        ? "Cepessa Sessions, recording, needs attention"
        : "Cepessa Sessions, recording"
    }
    if hasFault { return "Cepessa Sessions, needs attention" }
    if isTranscribing { return "Cepessa Sessions, transcribing" }
    return "Cepessa Sessions, idle"
  }

  static func statusItemValue(
    isRecording: Bool,
    isTranscribing: Bool,
    hasFault: Bool,
    timerText: String,
    progress: Double?,
    indicatorHidden: Bool
  ) -> String {
    var parts: [String] = []

    if isRecording {
      parts.append("Recording \(compactSpokenTimer(timerText))")
      if hasFault {
        parts.append("Capture needs attention")
      }
    } else if hasFault {
      parts.append("Capture needs attention")
    } else if isTranscribing {
      parts.append(progress.map { "Transcribing \(percentText($0))" } ?? "Transcribing")
    } else {
      parts.append("Not recording")
    }

    if indicatorHidden {
      parts.append("Floating indicator hidden; choose Show Recording Indicator to bring it back")
    }

    return parts.joined(separator: ". ")
  }

  static let statusItemAction = "Open the Cepessa Sessions menu"

  // MARK: Helpers

  private static func percentText(_ progress: Double) -> String {
    "\(Int((progress * 100).rounded())) percent"
  }

  /// "00:04:07" -> "4 minutes 7 seconds"; kept short so VoiceOver stays usable
  /// while a timer refreshes every second.
  static func compactSpokenTimer(_ source: String) -> String {
    let parts = source.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
    guard parts.count == 3,
      let hours = Int(parts[0]),
      let minutes = Int(parts[1]),
      let seconds = Int(parts[2])
    else {
      return source
    }

    var components: [String] = []
    if hours > 0 { components.append("\(hours) hour\(hours == 1 ? "" : "s")") }
    if minutes > 0 { components.append("\(minutes) minute\(minutes == 1 ? "" : "s")") }
    components.append("\(seconds) second\(seconds == 1 ? "" : "s")")
    return components.joined(separator: " ")
  }
}
