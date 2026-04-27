import SwiftUI

enum CepessaChrome {
  static let windowRadius: CGFloat = 28
  static let canvasRadius: CGFloat = 28
  static let cardRadius: CGFloat = 18
  static let sectionRadius: CGFloat = 14
  static let controlRadius: CGFloat = 12
  static let chipRadius: CGFloat = 999
  static let paperRadius: CGFloat = 8
  static let instrumentRadius: CGFloat = 24
  static let stripRadius: CGFloat = 999
}

private struct CepessaPanelModifier: ViewModifier {
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
        if let stroke {
          RoundedRectangle(cornerRadius: radius, style: .continuous)
            .stroke(stroke, lineWidth: 1)
        }
      }
      .shadow(
        color: .black.opacity(min(shadowOpacity, 0.04)), radius: min(shadowRadius, 6), x: 0,
        y: min(shadowY, 2))
  }
}

private struct CepessaGlassPanelModifier: ViewModifier {
  let radius: CGFloat
  let fill: Color
  let fillOpacity: Double
  let strokeOpacity: Double
  let shadowOpacity: Double

  func body(content: Content) -> some View {
    content
      .background {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
          .fill(.ultraThinMaterial)

        RoundedRectangle(cornerRadius: radius, style: .continuous)
          .fill(fill.opacity(fillOpacity))

        RoundedRectangle(cornerRadius: radius, style: .continuous)
          .fill(
            LinearGradient(
              colors: [
                Color.white.opacity(0.28),
                Color.white.opacity(0.08),
                Color.black.opacity(0.015),
              ],
              startPoint: .topLeading,
              endPoint: .bottomTrailing
            )
          )
      }
      .overlay {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
          .stroke(Color.white.opacity(strokeOpacity), lineWidth: 0.8)
          .padding(0.5)
      }
      .overlay {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
          .stroke(CepessaColors.border.opacity(0.20), lineWidth: 1)
      }
      .shadow(color: .white.opacity(0.25), radius: 1, x: 0, y: -1)
      .shadow(color: .black.opacity(shadowOpacity), radius: 18, x: 0, y: 10)
  }
}

struct CepessaPressStyle: ButtonStyle {
  var scale: CGFloat = 0.975
  var pressedBrightness: Double = -0.025

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .scaleEffect(configuration.isPressed && !reduceMotion ? scale : 1)
      .brightness(configuration.isPressed ? pressedBrightness : 0)
      .animation(
        reduceMotion ? nil : .spring(response: 0.22, dampingFraction: 0.86),
        value: configuration.isPressed)
  }
}

private struct CepessaCanvasModifier: ViewModifier {
  let radius: CGFloat

  func body(content: Content) -> some View {
    content
      .background(
        RoundedRectangle(cornerRadius: radius, style: .continuous)
          .fill(CepessaColors.paper.opacity(0.96))
      )
      .overlay {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
          .stroke(CepessaColors.hairline.opacity(0.72), lineWidth: 1)
      }
      .shadow(color: CepessaColors.warmShadow.opacity(0.08), radius: 28, x: 0, y: 18)
  }
}

private struct CepessaPaperModifier: ViewModifier {
  let radius: CGFloat

  func body(content: Content) -> some View {
    content
      .background(
        RoundedRectangle(cornerRadius: radius, style: .continuous)
          .fill(CepessaColors.paperRaised.opacity(0.88))
      )
      .overlay {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
          .stroke(CepessaColors.hairline.opacity(0.58), lineWidth: 1)
      }
  }
}

private struct CepessaInstrumentStripModifier: ViewModifier {
  let radius: CGFloat

  func body(content: Content) -> some View {
    content
      .background(
        RoundedRectangle(cornerRadius: radius, style: .continuous)
          .fill(
            LinearGradient(
              colors: [
                CepessaColors.paperRaised.opacity(0.72),
                CepessaColors.graphite.opacity(0.88),
              ],
              startPoint: .topLeading,
              endPoint: .bottomTrailing
            )
          )
      )
      .overlay {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
          .stroke(Color.white.opacity(0.70), lineWidth: 1)
      }
      .overlay {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
          .stroke(CepessaColors.border.opacity(0.48), lineWidth: 1)
          .padding(0.5)
      }
      .shadow(color: CepessaColors.warmShadow.opacity(0.16), radius: 28, x: 0, y: 16)
  }
}

extension View {
  func cepessaPanel(
    fill: Color = CepessaColors.backgroundSecondary,
    radius: CGFloat = CepessaChrome.cardRadius,
    stroke: Color? = CepessaColors.border.opacity(0.55),
    shadowOpacity: Double = 0.02,
    shadowRadius: CGFloat = 4,
    shadowY: CGFloat = 1
  ) -> some View {
    modifier(
      CepessaPanelModifier(
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
    stroke: Color? = CepessaColors.border.opacity(0.45)
  ) -> some View {
    modifier(
      CepessaPanelModifier(
        fill: fill,
        radius: radius,
        stroke: stroke,
        shadowOpacity: 0.08,
        shadowRadius: 8,
        shadowY: 4
      )
    )
  }

  func cepessaGlassPanel(
    radius: CGFloat = CepessaChrome.cardRadius,
    fill: Color = CepessaColors.backgroundSecondary,
    fillOpacity: Double = 0.54,
    strokeOpacity: Double = 0.38,
    shadowOpacity: Double = 0.055
  ) -> some View {
    modifier(
      CepessaGlassPanelModifier(
        radius: radius,
        fill: fill,
        fillOpacity: fillOpacity,
        strokeOpacity: strokeOpacity,
        shadowOpacity: shadowOpacity
      )
    )
  }

  func cepessaCanvas(radius: CGFloat = CepessaChrome.canvasRadius) -> some View {
    modifier(CepessaCanvasModifier(radius: radius))
  }

  func cepessaPaper(radius: CGFloat = CepessaChrome.paperRadius) -> some View {
    modifier(CepessaPaperModifier(radius: radius))
  }

  func cepessaInstrumentStrip(radius: CGFloat = CepessaChrome.instrumentRadius) -> some View {
    modifier(CepessaInstrumentStripModifier(radius: radius))
  }
}
