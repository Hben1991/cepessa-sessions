import SwiftUI

/// One vocabulary for "what is this recording doing right now", shared by
/// sessions, clips, the menu-bar item and the floating indicator.
///
/// The point is truthfulness, not decoration. Each case says exactly one thing
/// the app actually knows, and nothing is painted green just because it
/// finished — `ready` is deliberately neutral, because a finished transcript is
/// the normal case, not an achievement. Red belongs to live capture only.
enum CepessaStatusStyle: Equatable {
  /// Capture is live right now.
  case capturing
  /// Local work is still running (transcription, normalisation).
  case working
  /// Finished and readable.
  case ready
  /// Stopped early, or finished with something the user has to look at.
  case needsAttention

  var label: String {
    switch self {
    case .capturing: return "Recording"
    case .working: return "Processing"
    case .ready: return "Ready"
    case .needsAttention: return "Needs attention"
    }
  }

  /// SF Symbols only — nothing here is a drawn or invented glyph.
  var symbol: String {
    switch self {
    case .capturing: return "record.circle"
    case .working: return "arrow.triangle.2.circlepath"
    case .ready: return "checkmark.circle"
    case .needsAttention: return "exclamationmark.triangle.fill"
    }
  }

  var tint: Color {
    switch self {
    case .capturing: return CepessaColors.signalRed
    case .working: return CepessaColors.accent
    case .ready: return CepessaColors.textSecondary
    case .needsAttention: return CepessaColors.warning
    }
  }

  /// True for the states a user is expected to wait through. Callers use this
  /// to decide whether a row deserves a status line at all — a `ready` clip
  /// says so in its timestamp, and repeating "Ready" on every row is noise.
  var isTransient: Bool {
    self == .capturing || self == .working
  }
}

extension CepessaStatusStyle {
  static func resolve(_ status: LocalClipStatus) -> Self {
    switch status {
    case .recording: return .capturing
    case .processing: return .working
    case .ready: return .ready
    case .failed: return .needsAttention
    }
  }

  static func resolve(_ status: LocalMeetingSessionStatus) -> Self {
    switch status {
    case .recording: return .capturing
    case .transcribing: return .working
    case .ready: return .ready
    case .failed: return .needsAttention
    }
  }
}

/// The shared status line: symbol, label, and — only when the app has one to
/// give — the real reason. Used in list rows and detail panes so a clip and a
/// session describe themselves identically.
struct CepessaStatusLabel: View {
  let style: CepessaStatusStyle
  var detail: String?
  var font: Font = .caption

  var body: some View {
    Label {
      Text(text)
        .foregroundStyle(
          style == .needsAttention ? CepessaColors.textPrimary : CepessaColors.textSecondary)
    } icon: {
      Image(systemName: style.symbol)
        .foregroundStyle(style.tint)
    }
    .font(font)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(text)
  }

  private var text: String {
    guard let detail = detail?.trimmingCharacters(in: .whitespacesAndNewlines), !detail.isEmpty
    else {
      return style.label
    }
    return "\(style.label) · \(detail)"
  }
}
