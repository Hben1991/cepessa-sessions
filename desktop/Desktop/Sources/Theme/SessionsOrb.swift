import SwiftUI

/// The Sessions orb: a small warm light that is the recorder's face.
///
/// At rest it is a record mark lit from behind — a ring around a red core,
/// waiting. While recording it becomes a living ember: it breathes on the
/// Cepessa orb's period and its halo follows the *measured* audio level, so
/// the light moving is the room being heard, never decoration. Transcribing
/// dims it behind a gold arc that fills with real progress (or turns slowly
/// when there is none to report).
///
/// It only runs a clock in the states that move, pauses under Reduce Motion,
/// and is drawn with plain gradients: no offscreen passes, no shader.
struct SessionsOrb: View {
  enum Mood: Equatable {
    /// Nothing running. The orb is the record button.
    case idle
    /// Capture is starting or stopping.
    case preparing
    /// Capture is live and healthy.
    case recording
    /// Capture is live; the microphone is deliberately muted.
    case muted
    /// Capture is live but one source is missing.
    case degraded
    /// A transcript is being made. `nil` when no fraction is known.
    case processing(Double?)
    /// Something needs the owner's attention.
    case attention
  }

  let mood: Mood
  /// Measured audio level, 0...1. Read only while recording.
  var level: Double = 0
  var diameter: CGFloat = 28
  var isHighlighted = false

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.sessionsIsStill) private var isStill

  private var runsClock: Bool {
    guard !reduceMotion, !isStill else { return false }
    switch mood {
    case .recording, .degraded, .preparing: return true
    case .processing(let progress): return progress == nil
    case .idle, .muted, .attention: return false
    }
  }

  var body: some View {
    TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !runsClock)) { timeline in
      let t = runsClock ? timeline.date.timeIntervalSinceReferenceDate : 0
      orb(time: t)
    }
    .frame(width: diameter, height: diameter)
    .animation(reduceMotion ? nil : SessionsMotion.state, value: mood)
    .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: level)
    .accessibilityHidden(true)
  }

  @ViewBuilder
  private func orb(time: Double) -> some View {
    let breath = runsClock ? sin(time * 2 * .pi / SessionsMotion.breathPeriod) * 0.5 + 0.5 : 0.5
    ZStack {
      switch mood {
      case .idle:
        idle
      case .preparing:
        dimSphere(opacity: 0.55)
        turningArc(time: time, color: SessionsPalette.cream.opacity(0.85))
      case .recording:
        ember(breath: breath, heard: heardLevel)
      case .degraded:
        ember(breath: breath, heard: heardLevel)
        Circle()
          .strokeBorder(
            SessionsPalette.attention,
            style: StrokeStyle(lineWidth: 1.6, lineCap: .round, dash: [2.4, 2.6]))
      case .muted:
        mutedEmber
      case .processing(let progress):
        dimSphere(opacity: 0.5)
        if let progress {
          Circle()
            .trim(from: 0, to: CGFloat(min(max(progress, 0.03), 1)))
            .stroke(
              SessionsPalette.sunriseGold,
              style: StrokeStyle(lineWidth: 2, lineCap: .round))
            .rotationEffect(.degrees(-90))
            .padding(1)
            .shadow(color: SessionsPalette.sunriseGold.opacity(0.6), radius: 3)
        } else {
          turningArc(time: time, color: SessionsPalette.sunriseGold)
        }
      case .attention:
        Circle()
          .fill(
            RadialGradient(
              colors: [SessionsPalette.attention.opacity(0.95), SessionsPalette.attention.opacity(0.6)],
              center: UnitPoint(x: 0.4, y: 0.35),
              startRadius: 0,
              endRadius: diameter * 0.6))
        Text("!")
          .font(.system(size: diameter * 0.52, weight: .heavy, design: .rounded))
          .foregroundStyle(SessionsPalette.nightSkyTop)
      }
    }
  }

  /// Audio that is actually being heard, shaped so speech reads as movement
  /// without a loud room pinning the halo open.
  private var heardLevel: Double {
    let clamped = min(max(level, 0), 1)
    return min(1, sqrt(clamped) * 1.35)
  }

  // MARK: Pieces

  private var idle: some View {
    ZStack {
      Circle()
        .fill(
          RadialGradient(
            colors: [
              SessionsPalette.sunriseGold.opacity(isHighlighted ? 0.34 : 0.2),
              .clear,
            ],
            center: .center,
            startRadius: 0,
            endRadius: diameter * 0.62))
        .scaleEffect(1.25)
      Circle()
        .strokeBorder(SessionsPalette.cream.opacity(isHighlighted ? 0.85 : 0.6), lineWidth: 1.4)
      Circle()
        .fill(
          RadialGradient(
            colors: [SessionsPalette.cloudCoral, SessionsPalette.recording],
            center: UnitPoint(x: 0.38, y: 0.32),
            startRadius: 0,
            endRadius: diameter * 0.3))
        .frame(width: diameter * 0.44, height: diameter * 0.44)
        .shadow(color: SessionsPalette.recording.opacity(0.55), radius: isHighlighted ? 5 : 3)
    }
  }

  private func ember(breath: Double, heard: Double) -> some View {
    ZStack {
      // Halo: the room being heard.
      Circle()
        .fill(
          RadialGradient(
            colors: [
              SessionsPalette.sunriseGold.opacity(0.42),
              SessionsPalette.cloudCoral.opacity(0.22),
              .clear,
            ],
            center: .center,
            startRadius: diameter * 0.2,
            endRadius: diameter * 0.5))
        .scaleEffect(1.15 + 0.55 * heard + 0.08 * breath)
        .blendMode(.plusLighter)
      // The ember itself.
      Circle()
        .fill(
          RadialGradient(
            colors: [
              SessionsPalette.lightCore,
              SessionsPalette.sunriseGold,
              SessionsPalette.cloudCoral,
              SessionsPalette.recording,
            ],
            center: UnitPoint(x: 0.38, y: 0.32),
            startRadius: 0,
            endRadius: diameter * 0.62))
        .scaleEffect(0.9 + 0.06 * breath + 0.05 * heard)
        .shadow(color: SessionsPalette.recording.opacity(0.5), radius: 4)
    }
  }

  private var mutedEmber: some View {
    ZStack {
      Circle()
        .fill(
          RadialGradient(
            colors: [
              SessionsPalette.cream.opacity(0.7),
              SessionsPalette.novaLavender.opacity(0.7),
              SessionsPalette.nightSkyBottom,
            ],
            center: UnitPoint(x: 0.38, y: 0.32),
            startRadius: 0,
            endRadius: diameter * 0.62))
        .scaleEffect(0.9)
      Capsule()
        .fill(SessionsPalette.cream)
        .frame(width: diameter * 0.78, height: 1.8)
        .rotationEffect(.degrees(-45))
    }
  }

  private func dimSphere(opacity: Double) -> some View {
    Circle()
      .fill(
        RadialGradient(
          colors: [
            SessionsPalette.cream.opacity(0.42 * opacity),
            SessionsPalette.sunriseGold.opacity(0.22 * opacity),
            .clear,
          ],
          center: UnitPoint(x: 0.4, y: 0.36),
          startRadius: 0,
          endRadius: diameter * 0.55))
      .overlay(Circle().strokeBorder(SessionsPalette.cream.opacity(0.18), lineWidth: 1))
  }

  private func turningArc(time: Double, color: Color) -> some View {
    Circle()
      .trim(from: 0, to: 0.28)
      .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round))
      .rotationEffect(.degrees((time * 220).truncatingRemainder(dividingBy: 360)))
      .padding(1)
  }
}
