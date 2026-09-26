import AppKit
import SwiftUI

// MARK: - Window atmosphere

/// The window's ground: a still sky. Deep night in dark appearance, warm paper
/// by day, with the first light gathering at the top edge.
///
/// It is static on purpose. Transcripts are read here for minutes at a time,
/// and nothing behind the words may move.
struct SessionsAtmosphere: View {
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    ZStack {
      LinearGradient(
        colors: [SessionsPalette.canvasTop, SessionsPalette.canvasBottom],
        startPoint: .top,
        endPoint: .bottom
      )
      // First light along the top edge: gold at the centre, coral drifting
      // to one side, the way a horizon warms unevenly.
      RadialGradient(
        colors: [
          SessionsPalette.sunriseGold.opacity(colorScheme == .dark ? 0.2 : 0.15),
          SessionsPalette.cloudCoral.opacity(colorScheme == .dark ? 0.07 : 0.05),
          .clear,
        ],
        center: UnitPoint(x: 0.5, y: -0.14),
        startRadius: 0,
        endRadius: 640
      )
      RadialGradient(
        colors: [
          SessionsPalette.cloudCoral.opacity(colorScheme == .dark ? 0.1 : 0.06),
          .clear,
        ],
        center: UnitPoint(x: 0.86, y: -0.06),
        startRadius: 0,
        endRadius: 420
      )
      // The night's cool side, low and to the leading edge.
      RadialGradient(
        colors: [
          SessionsPalette.novaCyan.opacity(colorScheme == .dark ? 0.10 : 0.06),
          .clear,
        ],
        center: UnitPoint(x: -0.1, y: 1.1),
        startRadius: 0,
        endRadius: 560
      )
    }
    .ignoresSafeArea()
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }
}

// MARK: - Night glass (floating chrome)

/// The floating capsule's material: a piece of night sky under glass.
///
/// A dark behind-window blur takes the colour out of whatever the capsule sits
/// on; a night gradient over it gives the object its own colour; a lit rim
/// gives it an edge on a white document. Reduce Transparency replaces all of
/// it with the opaque night.
struct SessionsNightGlass<S: InsettableShape>: ViewModifier {
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @Environment(\.colorSchemeContrast) private var colorSchemeContrast

  let shape: S
  var glow: Color? = nil
  var glowStrength: Double = 0
  var isHighlighted = false

  func body(content: Content) -> some View {
    content
      .background {
        ZStack {
          if reduceTransparency {
            shape.fill(SessionsPalette.nightSkyTop)
          } else {
            SessionsBehindWindowBlur()
              .clipShape(shape)
            shape.fill(
              LinearGradient(
                colors: [
                  SessionsPalette.nightSkyMid.opacity(0.78),
                  SessionsPalette.nightSkyTop.opacity(0.9),
                ],
                startPoint: .top,
                endPoint: .bottom
              ))
          }
          if let glow, glowStrength > 0 {
            // Light from the orb, pooled at the leading end.
            shape.fill(
              RadialGradient(
                colors: [glow.opacity(0.28 * glowStrength), .clear],
                center: UnitPoint(x: 0.1, y: 0.5),
                startRadius: 0,
                endRadius: 120
              )
            )
            .blendMode(.plusLighter)
          }
        }
      }
      .overlay { rim.allowsHitTesting(false) }
      .shadow(color: .black.opacity(0.28), radius: 2, x: 0, y: 1)
      .shadow(color: .black.opacity(0.22), radius: 14, x: 0, y: 7)
  }

  @ViewBuilder
  private var rim: some View {
    if colorSchemeContrast == .increased {
      shape.strokeBorder(SessionsPalette.cream.opacity(0.8), lineWidth: 1.5)
    } else {
      shape.strokeBorder(
        LinearGradient(
          stops: [
            .init(color: .white.opacity(isHighlighted ? 0.34 : 0.24), location: 0),
            .init(color: .white.opacity(0.06), location: 0.5),
            .init(color: .white.opacity(0.10), location: 1),
          ],
          startPoint: .top,
          endPoint: .bottom
        ),
        lineWidth: 1
      )
    }
  }
}

/// A dark behind-window blur, whatever the system appearance.
private struct SessionsBehindWindowBlur: NSViewRepresentable {
  func makeNSView(context: Context) -> NSVisualEffectView {
    let view = NSVisualEffectView()
    view.material = .hudWindow
    view.blendingMode = .behindWindow
    view.state = .active
    view.appearance = NSAppearance(named: .darkAqua)
    return view
  }

  func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

extension View {
  func sessionsNightGlass<S: InsettableShape>(
    in shape: S, glow: Color? = nil, glowStrength: Double = 0, isHighlighted: Bool = false
  ) -> some View {
    modifier(
      SessionsNightGlass(
        shape: shape, glow: glow, glowStrength: glowStrength, isHighlighted: isHighlighted))
  }

  /// A raised field on the window's atmosphere. Opaque enough that text on it
  /// never depends on what is behind.
  func sessionsRaised(radius: CGFloat = 14, isHighlighted: Bool = false) -> some View {
    background(
      RoundedRectangle(cornerRadius: radius, style: .continuous)
        .fill(isHighlighted ? SessionsPalette.raisedHover : SessionsPalette.raised)
    )
    .overlay(
      RoundedRectangle(cornerRadius: radius, style: .continuous)
        .strokeBorder(SessionsPalette.hairline, lineWidth: 1)
    )
  }
}

// MARK: - Buttons

/// Press feedback shared by every custom control: a small give, never a bounce.
struct SessionsPressStyle: ButtonStyle {
  var scale: CGFloat = 0.96

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .scaleEffect(configuration.isPressed && !reduceMotion ? scale : 1)
      .brightness(configuration.isPressed ? -0.04 : 0)
      .animation(reduceMotion ? nil : SessionsMotion.press, value: configuration.isPressed)
  }
}

/// A round icon control on the window: a raised disc that lifts on hover.
struct SessionsRoundButtonStyle: ButtonStyle {
  var diameter: CGFloat = 32

  @Environment(\.isEnabled) private var isEnabled
  @State private var isHovered = false

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: 13, weight: .medium))
      .foregroundStyle(isEnabled ? SessionsPalette.ink : SessionsPalette.inkQuiet)
      .frame(width: diameter, height: diameter)
      .background(Circle().fill(isHovered && isEnabled ? SessionsPalette.raisedHover : SessionsPalette.raised))
      .overlay(Circle().strokeBorder(SessionsPalette.hairline, lineWidth: 1))
      .contentShape(Circle())
      .scaleEffect(configuration.isPressed ? 0.96 : 1)
      .animation(SessionsMotion.press, value: configuration.isPressed)
      .animation(SessionsMotion.hover, value: isHovered)
      .onHover { isHovered = $0 }
      // A 40pt target around a smaller disc.
      .padding((max(40, diameter) - diameter) / 2)
      .contentShape(Circle())
  }
}

/// The one bright capsule on a surface: ink-filled, the primary move.
struct SessionsCapsuleButtonStyle: ButtonStyle {
  @Environment(\.isEnabled) private var isEnabled
  @State private var isHovered = false

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(SessionsType.text(13, weight: .semibold))
      .foregroundStyle(SessionsPalette.inkInverse)
      .padding(.horizontal, 16)
      .frame(height: 32)
      .background(
        Capsule().fill(SessionsPalette.ink.opacity(isEnabled ? (isHovered ? 1 : 0.92) : 0.3)))
      .contentShape(Capsule())
      .scaleEffect(configuration.isPressed ? 0.96 : 1)
      .animation(SessionsMotion.press, value: configuration.isPressed)
      .onHover { isHovered = $0 }
  }
}

/// A quiet text action: words only, full ink on hover.
struct SessionsLinkButtonStyle: ButtonStyle {
  var size: CGFloat = 13
  var color: Color = SessionsPalette.ink

  @Environment(\.isEnabled) private var isEnabled
  @State private var isHovered = false

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(SessionsType.text(size, weight: .medium))
      .foregroundStyle(
        color.opacity(
          isEnabled ? (configuration.isPressed ? 0.5 : (isHovered ? 1 : 0.68)) : 0.3))
      .contentShape(Rectangle())
      .onHover { isHovered = $0 && isEnabled }
      .animation(SessionsMotion.hover, value: isHovered)
  }
}
