import SwiftUI

/// One vocabulary for "what is this recording doing right now", shared by the
/// library, the reader, the menu-bar item and the floating capsule.
///
/// Truthful, not decorative: each case says one thing the app actually knows.
/// A finished transcript is the normal case, so `ready` carries no colour at
/// all — the absence of a signal is the signal. Red belongs to live capture;
/// the orb's gold means work in progress; amber means look at this.
enum CepessaStatusStyle: Equatable {
  /// Capture is live right now.
  case capturing
  /// Local work is still running (transcription, normalisation).
  case working
  /// Finished and readable.
  case ready
  /// Stopped early, or finished with something the owner has to look at.
  case needsAttention

  var label: String {
    switch self {
    case .capturing: return "Recording"
    case .working: return "Transcribing"
    case .ready: return "Ready"
    case .needsAttention: return "Needs attention"
    }
  }

  var symbol: String {
    switch self {
    case .capturing: return "record.circle"
    case .working: return "waveform"
    case .ready: return "checkmark.circle"
    case .needsAttention: return "exclamationmark.triangle.fill"
    }
  }

  var tint: Color {
    switch self {
    case .capturing: return SessionsPalette.recording
    case .working: return SessionsPalette.accent
    case .ready: return SessionsPalette.inkTertiary
    case .needsAttention: return SessionsPalette.attention
    }
  }

  /// True for the states a user is expected to wait through. Callers use this
  /// to decide whether a row deserves a status line at all — a `ready` session
  /// says so in its timestamp, and repeating "Ready" on every row is noise.
  var isTransient: Bool {
    self == .capturing || self == .working
  }
}

extension CepessaStatusStyle {
  static func resolve(_ status: LocalMeetingSessionStatus) -> Self {
    switch status {
    case .recording: return .capturing
    case .transcribing: return .working
    case .ready: return .ready
    case .failed: return .needsAttention
    }
  }
}

/// A point of light that says what a session is doing: a red pulse while it
/// records, a gold glow while it transcribes, amber when it needs a look, and
/// nothing at all when it is simply ready.
struct SessionsStatusLight: View {
  let style: CepessaStatusStyle
  var diameter: CGFloat = 7

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var isLit = false

  var body: some View {
    Group {
      switch style {
      case .ready:
        Color.clear
      case .capturing, .working, .needsAttention:
        Circle()
          .fill(style.tint)
          .shadow(color: style.tint.opacity(0.7), radius: isLit ? 5 : 2)
          .opacity(style.isTransient && isLit ? 0.55 : 1)
      }
    }
    .frame(width: diameter, height: diameter)
    .onAppear { pulse() }
    .onChange(of: style) { _, _ in pulse() }
    .accessibilityHidden(true)
  }

  private func pulse() {
    isLit = false
    guard style.isTransient, !reduceMotion else { return }
    withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
      isLit = true
    }
  }
}
