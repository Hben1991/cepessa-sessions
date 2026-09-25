import CoreGraphics
import Foundation

/// Pure presentation model for the floating capsule.
///
/// The capsule is one object that changes width. At rest it is the orb and a
/// menu; one click on the orb records. While recording it carries the timer,
/// the two measured levels and the three controls a meeting needs (mute,
/// capture, stop), or — collapsed by the owner — just the orb, the timer and
/// the levels. Hover never changes its geometry; only state and deliberate
/// clicks do.
enum CepessaSessionCapsulePhase: Equatable {
  /// Nothing running. The orb records.
  case idle
  /// Capture is starting or stopping.
  case preparing
  /// Capture is live.
  case recording
  /// A transcript is being made.
  case processing
  /// Nothing running, but the recorder reported a problem.
  case attention
}

struct CepessaSessionCapsuleLayout: Equatable {
  var phase: CepessaSessionCapsulePhase
  /// Owner-chosen compact form while recording. Ignored in every other phase.
  var isCompact = false
  var showsHours = false
  var hasNotice = false
}

enum CepessaSessionCapsuleMetrics {
  static let height: CGFloat = 44
  static let inset: CGFloat = 6
  static let orb: CGFloat = 32
  static let control: CGFloat = 30
  static let controlSpacing: CGFloat = 2
  static let gap: CGFloat = 10
  static let timer: CGFloat = 50
  static let timerWithHours: CGFloat = 66
  /// Two measured level bars: microphone, then system audio.
  static let levels: CGFloat = 12
  static let statusColumn: CGFloat = 164
  static let notice: CGFloat = 196
  static let divider: CGFloat = 1

  /// Transparent margin the host panel keeps around the capsule so neither
  /// shadow is cut into a hard square by the window edge.
  static let shadowRadius: CGFloat = 14
  static let shadowOffset: CGFloat = 7
  static let panelBleed: CGFloat = ceil(shadowRadius * 3 + shadowOffset + 2)

  static func contentSize(
    for layout: CepessaSessionCapsuleLayout,
    availableScreenWidth: CGFloat? = nil
  ) -> CGSize {
    var width = inset + orb
    let more = control

    switch layout.phase {
    case .idle:
      if layout.hasNotice { width += gap + notice }
      width += gap / 2 + more
    case .preparing, .processing, .attention:
      width += gap + (layout.hasNotice ? notice : statusColumn) + gap / 2 + more
    case .recording:
      width += gap
      if layout.hasNotice {
        width += notice
      } else {
        width += (layout.showsHours ? timerWithHours : timer) + 8 + levels
      }
      if !layout.isCompact {
        width += gap + divider + gap
        width += control * 3 + controlSpacing * 3 + more
      } else {
        width += gap / 2
      }
    }
    width += inset

    let preferred = CGSize(width: even(width), height: height)
    guard let availableScreenWidth else { return preferred }
    // The bleed is part of the panel, so it comes out of the screen budget too.
    let budget = max(inset * 2 + orb, even(availableScreenWidth - panelBleed * 2 - 16, down: true))
    return CGSize(width: min(preferred.width, budget), height: height)
  }

  /// Widths are always whole, even points: the capsule then grows by the same
  /// amount on each side of its anchor and never lands on a half point.
  private static func even(_ value: CGFloat, down: Bool = false) -> CGFloat {
    ((value / 2).rounded(down ? .down : .up)) * 2
  }

  static func panelSize(for contentSize: CGSize, bleed: CGFloat = panelBleed) -> CGSize {
    CGSize(width: contentSize.width + bleed * 2, height: contentSize.height + bleed * 2)
  }

  /// Where the capsule sits inside its panel: centred, so growing the panel in
  /// either direction leaves the visible object where the owner put it.
  static func contentRect(contentSize: CGSize, inPanelOfSize panelSize: CGSize) -> CGRect {
    CGRect(
      x: ((panelSize.width - contentSize.width) / 2).rounded(),
      y: ((panelSize.height - contentSize.height) / 2).rounded(),
      width: contentSize.width,
      height: contentSize.height
    )
  }

  /// The persisted position: the capsule's top-centre point. Width changes
  /// grow the capsule around its centre and hang it from its top edge, so this
  /// point is the one thing every state agrees on.
  static func anchor(ofPanelFrame frame: CGRect, bleed: CGFloat = panelBleed) -> CGPoint {
    CGPoint(x: frame.midX, y: frame.maxY - bleed)
  }

  /// Not rounded: rounding a half point here would move the anchor, and a
  /// capsule that changes shape all day would slowly walk across the screen.
  static func panelFrame(
    anchor: CGPoint, contentSize: CGSize, bleed: CGFloat = panelBleed
  ) -> CGRect {
    let size = panelSize(for: contentSize, bleed: bleed)
    return CGRect(
      x: anchor.x - size.width / 2,
      y: anchor.y + bleed - size.height,
      width: size.width,
      height: size.height
    )
  }

  /// Upgrade of a position saved by the former 22pt indicator (its content
  /// origin, bottom-left in screen space) to the capsule's top-centre anchor.
  static func migratedAnchor(fromLegacyContentOrigin origin: CGPoint) -> CGPoint {
    CGPoint(x: origin.x + 11, y: origin.y + 22)
  }
}

/// The expand/collapse contract.
///
/// The capsule is one object that changes width, not two views that swap.
/// That only holds if the panel is never smaller than the shape inside it, so
/// the panel takes the *union* of the outgoing and incoming footprints for the
/// duration of the morph and settles onto the final one afterwards.
enum CepessaSessionCapsuleTransition {
  static func panelContentSize(from: CGSize, to: CGSize) -> CGSize {
    CGSize(width: max(from.width, to.width), height: max(from.height, to.height))
  }

  /// Controls ignore clicks while the shape is moving, so a collapsing capsule
  /// can never deliver a release to whichever control slid beneath the
  /// pointer — Stop above all. Nothing about capture may be decided by an
  /// animation.
  static func acceptsClicks(isTransitioning: Bool) -> Bool {
    !isTransitioning
  }

  /// While moving, the whole union is inert so a click cannot fall through the
  /// transparent bleed either. Once settled, only the capsule itself is live.
  static func interactiveRect(
    contentSize: CGSize,
    panelContentSize: CGSize,
    panelSize: CGSize,
    isTransitioning: Bool
  ) -> CGRect {
    CepessaSessionCapsuleMetrics.contentRect(
      contentSize: isTransitioning ? panelContentSize : contentSize,
      inPanelOfSize: panelSize
    )
  }
}

/// Interaction state the owner controls. Hover is lighting only.
struct CepessaSessionCapsuleInteraction: Equatable {
  private(set) var isHovered = false
  private(set) var isHiddenForCurrentRecording = false

  mutating func hoverChanged(_ isHovered: Bool) {
    self.isHovered = isHovered
  }

  /// Every recording starts visible.
  mutating func recordingDidStart() {
    isHovered = false
    isHiddenForCurrentRecording = false
  }

  mutating func recordingDidEnd() {
    isHovered = false
    isHiddenForCurrentRecording = false
  }

  mutating func hideForCurrentRecording() {
    isHiddenForCurrentRecording = true
  }

  mutating func show() {
    isHiddenForCurrentRecording = false
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

extension SessionsOrb.Mood {
  /// The orb's face for a capsule state. Shape and light carry the meaning;
  /// healthy capture is never painted with a success colour.
  static func resolve(
    phase: CepessaSessionCapsulePhase,
    health: CepessaSessionCaptureHealth,
    progress: Double?
  ) -> Self {
    switch phase {
    case .idle: return .idle
    case .preparing: return .preparing
    case .processing: return .processing(progress)
    case .attention: return .attention
    case .recording:
      switch health {
      case .healthy: return .recording
      case .muted: return .muted
      case .partial: return .degraded
      case .unavailable: return .attention
      }
    }
  }
}

/// Compact timer text. The recorder publishes `HH:MM:SS`; under an hour the
/// capsule drops the hour field, past an hour it shows an unpadded hour and
/// grows once.
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

/// The one or two lines the capsule's status column shows. It only ever
/// reports something the app actually knows.
enum CepessaSessionCapsuleStatus {
  static func title(phase: CepessaSessionCapsulePhase, isStopping: Bool) -> String {
    switch phase {
    case .preparing: return isStopping ? "Saving recording" : "Starting"
    case .processing: return "Transcribing"
    case .attention: return "Needs attention"
    case .idle: return "Ready to record"
    case .recording: return "Recording"
    }
  }

  static func detail(
    phase: CepessaSessionCapsulePhase,
    progress: Double?,
    stage: String?
  ) -> String? {
    switch phase {
    case .processing:
      let percent = progress.map { "\(Int(($0 * 100).rounded()))%" }
      let stage = stage?.trimmingCharacters(in: .whitespacesAndNewlines)
      return [percent, stage?.isEmpty == false ? stage : nil]
        .compactMap { $0 }
        .joined(separator: " · ")
        .nilIfEmpty ?? "On this Mac"
    case .attention:
      return "Open for details"
    case .preparing:
      return "Microphone and system audio"
    case .idle, .recording:
      return nil
    }
  }
}

/// VoiceOver strings for the capsule and the menu-bar item. Pure functions so
/// every state is covered by tests.
enum CepessaSessionIndicatorAccessibility {
  static func orbLabel(
    phase: CepessaSessionCapsulePhase,
    isCompact: Bool
  ) -> String {
    switch phase {
    case .idle: return "Start recording"
    case .recording: return isCompact ? "Show recording controls" : "Collapse recording controls"
    case .processing: return "Open the session being transcribed"
    case .attention: return "Open the session that needs attention"
    case .preparing: return "Recording is starting or stopping"
    }
  }

  static func capsuleValue(
    phase: CepessaSessionCapsulePhase,
    health: CepessaSessionCaptureHealth,
    timerText: String,
    progress: Double?
  ) -> String {
    switch phase {
    case .recording:
      return "Recording \(compactSpokenTimer(timerText)). \(health.accessibilityLabel)."
    case .processing:
      if let progress {
        return "Transcribing, \(percentText(progress)) complete."
      }
      return "Transcribing."
    case .preparing:
      return "Preparing capture."
    case .attention:
      return "Needs attention."
    case .idle:
      return "Not recording."
    }
  }

  /// Menu-bar status item. Must read meaningfully in every state, including
  /// when the floating capsule has been hidden for the current recording.
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
      parts.append("Floating recorder hidden; choose Show Recorder to bring it back")
    }

    return parts.joined(separator: ". ")
  }

  static let statusItemAction = "Open the Cepessa Sessions menu"

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

extension String {
  fileprivate var nilIfEmpty: String? { isEmpty ? nil : self }
}
