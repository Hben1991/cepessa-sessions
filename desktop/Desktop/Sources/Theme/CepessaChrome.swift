import SwiftUI

/// Distilled chrome: exactly two surface treatments.
/// 1. Bar surface — the floating bar and transient popover chrome (Liquid Glass on macOS 26+).
/// 2. Window surface — flat paper panels separated by hairlines, one soft shadow.
/// Legacy modifier names are kept so call sites don't churn; they all resolve here.
enum CepessaChrome {
  static let windowRadius: CGFloat = 16
  static let canvasRadius: CGFloat = 16
  static let cardRadius: CGFloat = 14
  static let sectionRadius: CGFloat = 14
  static let controlRadius: CGFloat = 8
  static let chipRadius: CGFloat = 999
  static let paperRadius: CGFloat = 14
  static let instrumentRadius: CGFloat = 14
  static let stripRadius: CGFloat = 999
}

// MARK: - Window surface

/// Flat panel: one fill, one hairline, one soft shadow. Nothing else.
private struct CepessaWindowSurfaceModifier: ViewModifier {
  let fill: Color
  let radius: CGFloat
  let stroke: Color?
  let shadowOpacity: Double
  let shadowRadius: CGFloat
  let shadowY: CGFloat

  func body(content: Content) -> some View {
    content
      .background(
        RoundedRectangle(cornerRadius: radius, style: .continuous)
          .fill(fill)
      )
      .overlay {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
          .stroke(stroke ?? CepessaColors.hairline.opacity(0.5), lineWidth: 1)
      }
      .shadow(
        color: CepessaColors.warmShadow.opacity(shadowOpacity),
        radius: shadowRadius, x: 0, y: shadowY)
  }
}

// MARK: - Bar surface

/// The one glass treatment in the app. Liquid Glass on macOS 26+, a single
/// material with a near-solid fill before that. One stroke, one shadow.
private struct CepessaBarSurfaceModifier<S: InsettableShape>: ViewModifier {
  let shape: S

  @ViewBuilder
  func body(content: Content) -> some View {
    if #available(macOS 26.0, *) {
      content
        .glassEffect(
          .regular.tint(CepessaColors.paper.opacity(0.55)),
          in: shape
        )
        .overlay {
          shape.strokeBorder(CepessaColors.hairline.opacity(0.5), lineWidth: 1)
        }
        .shadow(color: CepessaColors.warmShadow.opacity(0.10), radius: 14, x: 0, y: 6)
    } else {
      content
        .background {
          shape.fill(.ultraThinMaterial)
          shape.fill(CepessaColors.paper.opacity(0.86))
        }
        .overlay {
          shape.strokeBorder(CepessaColors.hairline.opacity(0.6), lineWidth: 1)
        }
        .shadow(color: CepessaColors.warmShadow.opacity(0.10), radius: 14, x: 0, y: 6)
    }
  }
}

// MARK: - Press feedback

struct CepessaPressStyle: ButtonStyle {
  var scale: CGFloat = 0.97
  var pressedBrightness: Double = -0.03

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .scaleEffect(configuration.isPressed && !reduceMotion ? scale : 1)
      .brightness(configuration.isPressed ? pressedBrightness : 0)
      .animation(
        reduceMotion ? nil : .timingCurve(0.23, 1, 0.32, 1, duration: 0.16),
        value: configuration.isPressed)
  }
}

// MARK: - Public API (legacy names preserved)

extension View {
  func cepessaPanel(
    fill: Color = CepessaColors.backgroundSecondary,
    radius: CGFloat = CepessaChrome.cardRadius,
    stroke: Color? = nil,
    shadowOpacity: Double = 0.04,
    shadowRadius: CGFloat = 6,
    shadowY: CGFloat = 2
  ) -> some View {
    modifier(
      CepessaWindowSurfaceModifier(
        fill: fill,
        radius: radius,
        stroke: stroke,
        shadowOpacity: shadowOpacity,
        shadowRadius: shadowRadius,
        shadowY: shadowY
      )
    )
  }

  func cepessaControlSurface(
    fill: Color = CepessaColors.backgroundSecondary,
    radius: CGFloat = CepessaChrome.controlRadius,
    stroke: Color? = nil
  ) -> some View {
    modifier(
      CepessaWindowSurfaceModifier(
        fill: fill,
        radius: radius,
        stroke: stroke,
        shadowOpacity: 0.05,
        shadowRadius: 4,
        shadowY: 2
      )
    )
  }

  func cepessaGlassPanel(
    radius: CGFloat = CepessaChrome.cardRadius,
    fill: Color = CepessaColors.backgroundRaised,
    fillOpacity: Double = 1,
    strokeOpacity: Double = 0.5,
    shadowOpacity: Double = 0.06
  ) -> some View {
    modifier(
      CepessaWindowSurfaceModifier(
        fill: fill.opacity(fillOpacity),
        radius: radius,
        stroke: CepessaColors.hairline.opacity(strokeOpacity),
        shadowOpacity: shadowOpacity,
        shadowRadius: 10,
        shadowY: 4
      )
    )
  }

  func cepessaCanvas(radius: CGFloat = CepessaChrome.canvasRadius) -> some View {
    modifier(
      CepessaWindowSurfaceModifier(
        fill: CepessaColors.backgroundRaised,
        radius: radius,
        stroke: nil,
        shadowOpacity: 0.05,
        shadowRadius: 12,
        shadowY: 5
      )
    )
  }

  func cepessaPaper(radius: CGFloat = CepessaChrome.paperRadius) -> some View {
    modifier(
      CepessaWindowSurfaceModifier(
        fill: CepessaColors.backgroundRaised,
        radius: radius,
        stroke: nil,
        shadowOpacity: 0.04,
        shadowRadius: 8,
        shadowY: 3
      )
    )
  }

  func cepessaInstrumentStrip(radius: CGFloat = CepessaChrome.instrumentRadius) -> some View {
    modifier(
      CepessaWindowSurfaceModifier(
        fill: CepessaColors.backgroundSecondary,
        radius: radius,
        stroke: nil,
        shadowOpacity: 0.04,
        shadowRadius: 8,
        shadowY: 3
      )
    )
  }

  /// The floating bar capsule.
  func cepessaFloatingToolbarSurface() -> some View {
    modifier(CepessaBarSurfaceModifier(shape: Capsule()))
  }

  /// Inset pill inside the floating bar (waveform region).
  func cepessaFloatingToolbarPillSurface() -> some View {
    background(
      Capsule().fill(CepessaColors.backgroundSecondary.opacity(0.8))
    )
    .overlay {
      Capsule().strokeBorder(CepessaColors.hairline.opacity(0.5), lineWidth: 1)
    }
  }

  /// Bar-style surface for arbitrary rounded rects (popovers, transient chrome).
  func cepessaBarSurface(radius: CGFloat = CepessaChrome.cardRadius) -> some View {
    modifier(
      CepessaBarSurfaceModifier(
        shape: RoundedRectangle(cornerRadius: radius, style: .continuous)))
  }
}
