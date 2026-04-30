import SwiftUI

enum CepessaChrome {
  static let windowRadius: CGFloat = 34
  static let canvasRadius: CGFloat = 36
  static let cardRadius: CGFloat = 28
  static let sectionRadius: CGFloat = 22
  static let controlRadius: CGFloat = 18
  static let chipRadius: CGFloat = 999
  static let paperRadius: CGFloat = 26
  static let instrumentRadius: CGFloat = 30
  static let stripRadius: CGFloat = 999
}

private struct CepessaPanelModifier: ViewModifier {
  let fill: Color
  let radius: CGFloat
  let stroke: Color?
  let shadowOpacity: Double
  let shadowRadius: CGFloat
  let shadowY: CGFloat

  @ViewBuilder
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
      .shadow(color: .white.opacity(0.18), radius: 1, x: 0, y: -1)
      .shadow(
        color: CepessaColors.warmShadow.opacity(min(shadowOpacity, 0.035)),
        radius: min(shadowRadius, 8), x: 0, y: min(shadowY, 4))
  }
}

private struct CepessaGlassPanelModifier: ViewModifier {
  let radius: CGFloat
  let fill: Color
  let fillOpacity: Double
  let strokeOpacity: Double
  let shadowOpacity: Double

  @ViewBuilder
  func body(content: Content) -> some View {
    if #available(macOS 26.0, *) {
      content
        .background {
          RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(Color.white.opacity(0.74))
            .glassEffect(
              .regular.tint(CepessaColors.ambientGlass.opacity(0.035)),
              in: .rect(cornerRadius: radius)
            )

          RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(Color.white.opacity(0.72))

          RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(
              LinearGradient(
                colors: [
                  Color.white.opacity(0.60),
                  CepessaColors.backgroundSecondary.opacity(0.18),
                  Color.white.opacity(0.44),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
              )
            )
        }
        .overlay {
          RoundedRectangle(cornerRadius: radius, style: .continuous)
            .stroke(Color.white.opacity(strokeOpacity), lineWidth: 0.7)
            .padding(0.5)
        }
        .overlay {
          RoundedRectangle(cornerRadius: radius, style: .continuous)
            .stroke(CepessaColors.hairline.opacity(0.26), lineWidth: 0.7)
        }
        .shadow(color: .white.opacity(0.45), radius: 1, x: 0, y: -1)
        .shadow(
          color: CepessaColors.warmShadow.opacity(shadowOpacity + 0.012),
          radius: 18, x: 0, y: 9)
    } else {
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
                  Color.white.opacity(0.34),
                  CepessaColors.backgroundSecondary.opacity(0.14),
                  Color.white.opacity(0.26),
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
        .shadow(color: .white.opacity(0.30), radius: 1, x: 0, y: -1)
        .shadow(
          color: CepessaColors.warmShadow.opacity(shadowOpacity + 0.014),
          radius: 16, x: 0, y: 8)
    }
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

  @ViewBuilder
  func body(content: Content) -> some View {
    if #available(macOS 26.0, *) {
      content
        .background {
          RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(Color.white.opacity(0.80))
            .glassEffect(
              .regular.tint(CepessaColors.ambientGlass.opacity(0.035)),
              in: .rect(cornerRadius: radius)
            )

          RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(Color.white.opacity(0.82))

          RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(
              LinearGradient(
                colors: [
                  Color.white.opacity(0.64),
                  CepessaColors.backgroundSecondary.opacity(0.16),
                  Color.white.opacity(0.52),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
              )
            )
        }
        .overlay {
          RoundedRectangle(cornerRadius: radius, style: .continuous)
            .stroke(Color.white.opacity(0.68), lineWidth: 0.8)
        }
        .overlay {
          RoundedRectangle(cornerRadius: radius, style: .continuous)
            .stroke(CepessaColors.hairline.opacity(0.30), lineWidth: 0.7)
            .padding(0.5)
        }
        .shadow(color: CepessaColors.warmShadow.opacity(0.055), radius: 24, x: 0, y: 12)
    } else {
      content
        .background {
          RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(.thinMaterial)

          RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(CepessaColors.paperRaised.opacity(0.70))

          RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(
              LinearGradient(
                colors: [
                  Color.white.opacity(0.42),
                  CepessaColors.backgroundSecondary.opacity(0.12),
                  Color.white.opacity(0.24),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
              )
            )
        }
        .overlay {
          RoundedRectangle(cornerRadius: radius, style: .continuous)
            .stroke(Color.white.opacity(0.74), lineWidth: 0.8)
        }
        .overlay {
          RoundedRectangle(cornerRadius: radius, style: .continuous)
            .stroke(CepessaColors.hairline.opacity(0.46), lineWidth: 1)
            .padding(0.5)
        }
        .shadow(color: CepessaColors.warmShadow.opacity(0.06), radius: 22, x: 0, y: 11)
    }
  }
}

private struct CepessaPaperModifier: ViewModifier {
  let radius: CGFloat

  @ViewBuilder
  func body(content: Content) -> some View {
    if #available(macOS 26.0, *) {
      content
        .background {
          RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(Color.white.opacity(0.78))
            .glassEffect(
              .regular.tint(CepessaColors.ambientGlass.opacity(0.03)),
              in: .rect(cornerRadius: radius)
            )

          RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(Color.white.opacity(0.82))
        }
        .overlay {
          RoundedRectangle(cornerRadius: radius, style: .continuous)
            .stroke(Color.white.opacity(0.66), lineWidth: 0.8)
        }
        .overlay {
          RoundedRectangle(cornerRadius: radius, style: .continuous)
            .stroke(CepessaColors.hairline.opacity(0.24), lineWidth: 0.7)
            .padding(0.5)
        }
        .shadow(color: CepessaColors.warmShadow.opacity(0.035), radius: 14, x: 0, y: 7)
    } else {
      content
        .background(
          RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(CepessaColors.paperRaised.opacity(0.76))
        )
        .overlay {
          RoundedRectangle(cornerRadius: radius, style: .continuous)
            .stroke(Color.white.opacity(0.70), lineWidth: 0.8)
        }
        .overlay {
          RoundedRectangle(cornerRadius: radius, style: .continuous)
            .stroke(CepessaColors.hairline.opacity(0.38), lineWidth: 1)
            .padding(0.5)
        }
        .shadow(color: CepessaColors.warmShadow.opacity(0.04), radius: 12, x: 0, y: 6)
    }
  }
}

private struct CepessaInstrumentStripModifier: ViewModifier {
  let radius: CGFloat

  @ViewBuilder
  func body(content: Content) -> some View {
    if #available(macOS 26.0, *) {
      content
        .background {
          RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(Color.white.opacity(0.78))
            .glassEffect(
              .regular.tint(CepessaColors.ambientGlass.opacity(0.03)),
              in: .rect(cornerRadius: radius)
            )

          RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(Color.white.opacity(0.78))
        }
        .overlay {
          RoundedRectangle(cornerRadius: radius, style: .continuous)
            .stroke(Color.white.opacity(0.70), lineWidth: 0.8)
        }
        .overlay {
          RoundedRectangle(cornerRadius: radius, style: .continuous)
            .stroke(CepessaColors.hairline.opacity(0.24), lineWidth: 0.7)
            .padding(0.5)
        }
        .shadow(color: CepessaColors.warmShadow.opacity(0.045), radius: 18, x: 0, y: 9)
    } else {
      content
        .background(
          RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(
              LinearGradient(
                colors: [
                  CepessaColors.paperRaised.opacity(0.76),
                  CepessaColors.backgroundSecondary.opacity(0.72),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
              )
            )
        )
        .overlay {
          RoundedRectangle(cornerRadius: radius, style: .continuous)
            .stroke(Color.white.opacity(0.66), lineWidth: 0.8)
        }
        .overlay {
          RoundedRectangle(cornerRadius: radius, style: .continuous)
            .stroke(CepessaColors.border.opacity(0.48), lineWidth: 1)
            .padding(0.5)
        }
        .shadow(color: CepessaColors.warmShadow.opacity(0.05), radius: 16, x: 0, y: 8)
    }
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
