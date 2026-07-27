import SwiftUI

/// The app has exactly two surface treatments.
///
/// 1. **Content surface** — opaque, semantic, no blur. Everything the user
///    reads sits on one of these. Separation comes from `Divider`s and
///    whitespace, not from borders and shadows on every card.
/// 2. **Glass surface** — Liquid Glass on macOS 26, `.regularMaterial` before
///    that, and a plain opaque fill when Reduce Transparency is on. Reserved
///    for transient/floating chrome: the recording indicator, its control
///    tray, and popover menus. Never used behind long-form text.
///
/// Legacy modifier names are kept so unreachable call sites keep compiling;
/// they all resolve to the two treatments above.
enum CepessaChrome {
  // 8pt rhythm. Half-steps only where a control genuinely needs optical trim.
  enum Space {
    static let hairline: CGFloat = 1
    static let xxs: CGFloat = 2
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 12
    static let l: CGFloat = 16
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
  }

  /// Compact pointer-sized controls. Nothing in the app is taller than 28pt
  /// unless AppKit owns it.
  enum Control {
    static let micro: CGFloat = 22
    static let small: CGFloat = 24
    static let regular: CGFloat = 28
  }

  static let windowRadius: CGFloat = 12
  static let canvasRadius: CGFloat = 10
  static let cardRadius: CGFloat = 10
  static let sectionRadius: CGFloat = 10
  static let controlRadius: CGFloat = 6
  static let chipRadius: CGFloat = 999
  static let paperRadius: CGFloat = 10
  static let instrumentRadius: CGFloat = 10
  static let stripRadius: CGFloat = 999

  /// How far a glass surface is separated from what is behind it.
  ///
  /// Two tiers, because the app only ever has two: something resting on the
  /// desktop, and something the user deliberately opened on top of it. Each
  /// tier is a *pair* of shadows — a tight contact shadow that draws the edge
  /// and a wide ambient one that carries the lift. A single mid-radius shadow
  /// reads as a smudge; the pair is what makes pale glass legible on a white
  /// document without turning it into a grey card.
  enum Elevation {
    case resting
    case lifted

    var contact: CepessaShadow {
      switch self {
      case .resting: return CepessaShadow(opacity: 0.20, radius: 2, y: 1)
      case .lifted: return CepessaShadow(opacity: 0.24, radius: 3, y: 1)
      }
    }

    var ambient: CepessaShadow {
      switch self {
      case .resting: return CepessaShadow(opacity: 0.12, radius: 8, y: 3)
      case .lifted: return CepessaShadow(opacity: 0.17, radius: 14, y: 6)
      }
    }

    /// The transparent margin a host window must keep around the surface so
    /// neither shadow is clipped into a hard square by the window edge.
    var bleed: CGFloat {
      let widest = ambient
      // SwiftUI's shadow radius describes the blur kernel, not its final
      // visible footprint. A one-radius allowance still leaves enough of the
      // Gaussian tail to reveal the NSPanel edge on pale backgrounds. Three
      // radii carries that tail below visible contrast; the offset and final
      // two points keep the lower edge clear as well.
      return ceil(widest.radius * 3 + abs(widest.y) + 2)
    }
  }

  /// Timing for the one geometric transition in the app: the floating
  /// indicator expanding into its control tray and collapsing back.
  ///
  /// The container morphs on a spring; its contents cross-fade on shorter
  /// curves so text never stretches with the shape. Outgoing content leaves
  /// first and incoming content arrives late, which is what makes the two
  /// states read as one object rather than two views swapping.
  enum Motion {
    static let expandDuration: TimeInterval = 0.34
    static let expand = Animation.spring(response: 0.34, dampingFraction: 0.86)
    static let contentIn = Animation.easeOut(duration: 0.18).delay(0.08)
    static let contentOut = Animation.easeIn(duration: 0.12)
    /// State changes that carry meaning but no geometry (ring shape, tint).
    static let state = Animation.easeOut(duration: 0.18)

    static func expand(reduceMotion: Bool) -> Animation? {
      reduceMotion ? nil : expand
    }

    static func settleDelay(reduceMotion: Bool) -> TimeInterval {
      reduceMotion ? 0 : expandDuration
    }

    /// Backstop for the expand/collapse completion callback.
    ///
    /// Deliberately far longer than `expandDuration`: a spring keeps moving
    /// well past its `response`, so anything near that value would fire while
    /// the shape is still travelling. This exists only for the case where the
    /// completion never arrives at all.
    static let settleTimeout: TimeInterval = 1.5
  }
}

/// One shadow layer. `opacity` is the alpha of a neutral shadow; dark
/// appearances need a heavier one to read at all.
struct CepessaShadow: Equatable {
  var opacity: Double
  var radius: CGFloat
  var y: CGFloat

  func color(for colorScheme: ColorScheme) -> Color {
    Color.black.opacity(colorScheme == .dark ? opacity * 1.45 : opacity)
  }
}

// MARK: - Glass surface

/// The one glass treatment in the app.
///
/// macOS 26 gets native Liquid Glass. macOS 14/15 fall back to a single
/// `.regularMaterial`. Reduce Transparency always wins and produces an opaque
/// window-background fill so nothing behind the surface bleeds through.
///
/// On top of whichever fill applies, every glass surface gets the same two
/// things: a **rim** and a **shadow pair**. Native Liquid Glass alone is close
/// to invisible when it floats over a white document — which is exactly where
/// the recording indicator spends most of its life — so the rim gives the
/// shape an edge in both appearances and the shadow pair gives it a floor.
struct CepessaGlassSurface<S: InsettableShape>: ViewModifier {
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @Environment(\.colorSchemeContrast) private var colorSchemeContrast
  @Environment(\.colorScheme) private var colorScheme

  let shape: S
  var interactive = false
  var elevation: CepessaChrome.Elevation = .resting
  /// Pointer is over the surface. Lighting only — never geometry.
  var isHighlighted = false

  func body(content: Content) -> some View {
    filled(content)
      // The rim is lighting, not a control. It is drawn *over* the content, so
      // without this it sits between the pointer and everything inside the
      // surface: SwiftUI resolves a click on the glass to the rim and the
      // controls underneath never see it. That is invisible on a surface whose
      // only hit target is stacked above the glass (the resting indicator), and
      // fatal for one whose controls live inside it (the open control tray).
      .overlay { rim.allowsHitTesting(false) }
      .shadow(
        color: elevation.contact.color(for: colorScheme),
        radius: elevation.contact.radius,
        x: 0,
        y: elevation.contact.y
      )
      .shadow(
        color: elevation.ambient.color(for: colorScheme),
        radius: elevation.ambient.radius,
        x: 0,
        y: elevation.ambient.y
      )
  }

  @ViewBuilder
  private func filled(_ content: Content) -> some View {
    if reduceTransparency {
      content.background(shape.fill(CepessaColors.backgroundPrimary))
    } else if #available(macOS 26.0, *) {
      if interactive {
        content.glassEffect(.regular.interactive(), in: shape)
      } else {
        content.glassEffect(.regular, in: shape)
      }
    } else {
      content.background(shape.fill(.regularMaterial))
    }
  }

  /// Increase Contrast and Reduce Transparency both want a literal border.
  /// Everything else gets a lit edge: bright where a light would catch the top
  /// of a solid, dark where it turns away. The white/black stops here are not
  /// palette colours — they are the lighting model, composited over whatever
  /// the surface happens to be floating on, so they adapt on their own.
  @ViewBuilder
  private var rim: some View {
    if colorSchemeContrast == .increased {
      shape.strokeBorder(CepessaColors.textPrimary, lineWidth: 1.5)
    } else if reduceTransparency {
      shape.strokeBorder(CepessaColors.border, lineWidth: 1)
    } else {
      shape.strokeBorder(rimGradient, lineWidth: 1)
    }
  }

  private var rimGradient: LinearGradient {
    let isDark = colorScheme == .dark
    let highlight = (isDark ? 0.34 : 0.70) + (isHighlighted ? 0.10 : 0)
    let midpoint = isDark ? 0.08 : 0.20
    let shade = (isDark ? 0.34 : 0.16) + (isHighlighted ? 0.04 : 0)

    return LinearGradient(
      stops: [
        .init(color: .white.opacity(highlight), location: 0),
        .init(color: .white.opacity(midpoint), location: 0.42),
        .init(color: .black.opacity(shade), location: 1),
      ],
      startPoint: .top,
      endPoint: .bottom
    )
  }
}

// MARK: - Content surface

/// Flat, opaque, semantic. One fill and — only when the layout genuinely needs
/// an edge — one hairline. No decorative shadow.
private struct CepessaContentSurface: ViewModifier {
  let fill: Color
  let radius: CGFloat
  let stroke: Color?

  func body(content: Content) -> some View {
    content
      .background(
        RoundedRectangle(cornerRadius: radius, style: .continuous)
          .fill(fill)
      )
      .overlay {
        if let stroke {
          RoundedRectangle(cornerRadius: radius, style: .continuous)
            .strokeBorder(stroke, lineWidth: 1)
        }
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

// MARK: - Public API

extension View {
  /// Transient floating chrome (recording indicator, control tray, popovers).
  func cepessaGlass<S: InsettableShape>(
    in shape: S,
    interactive: Bool = false,
    elevation: CepessaChrome.Elevation = .resting,
    isHighlighted: Bool = false
  ) -> some View {
    modifier(
      CepessaGlassSurface(
        shape: shape,
        interactive: interactive,
        elevation: elevation,
        isHighlighted: isHighlighted
      )
    )
  }

  /// Opaque content surface. Pass `stroke:` only where an edge carries meaning.
  func cepessaSurface(
    fill: Color = CepessaColors.backgroundRaised,
    radius: CGFloat = CepessaChrome.cardRadius,
    stroke: Color? = nil
  ) -> some View {
    modifier(CepessaContentSurface(fill: fill, radius: radius, stroke: stroke))
  }

  // Legacy names — all resolve to the opaque content surface.

  func cepessaPanel(
    fill: Color = CepessaColors.backgroundSecondary,
    radius: CGFloat = CepessaChrome.cardRadius,
    stroke: Color? = nil,
    shadowOpacity: Double = 0,
    shadowRadius: CGFloat = 0,
    shadowY: CGFloat = 0
  ) -> some View {
    cepessaSurface(fill: fill, radius: radius, stroke: stroke)
  }

  func cepessaControlSurface(
    fill: Color = CepessaColors.backgroundRaised,
    radius: CGFloat = CepessaChrome.controlRadius,
    stroke: Color? = nil
  ) -> some View {
    cepessaSurface(fill: fill, radius: radius, stroke: stroke)
  }

  func cepessaGlassPanel(
    radius: CGFloat = CepessaChrome.cardRadius,
    fill: Color = CepessaColors.backgroundRaised,
    fillOpacity: Double = 1,
    strokeOpacity: Double = 0,
    shadowOpacity: Double = 0
  ) -> some View {
    cepessaSurface(fill: fill.opacity(fillOpacity), radius: radius)
  }

  func cepessaCanvas(radius: CGFloat = CepessaChrome.canvasRadius) -> some View {
    cepessaSurface(fill: CepessaColors.backgroundRaised, radius: radius)
  }

  func cepessaPaper(radius: CGFloat = CepessaChrome.paperRadius) -> some View {
    cepessaSurface(fill: CepessaColors.backgroundRaised, radius: radius)
  }

  func cepessaInstrumentStrip(radius: CGFloat = CepessaChrome.instrumentRadius) -> some View {
    cepessaSurface(fill: CepessaColors.backgroundSecondary, radius: radius)
  }

  func cepessaFloatingToolbarSurface() -> some View {
    cepessaGlass(in: Capsule(), interactive: true)
  }

  func cepessaFloatingToolbarPillSurface() -> some View {
    background(Capsule().fill(CepessaColors.backgroundSecondary))
  }

  func cepessaBarSurface(radius: CGFloat = CepessaChrome.cardRadius) -> some View {
    cepessaGlass(
      in: RoundedRectangle(cornerRadius: radius, style: .continuous),
      interactive: true
    )
  }
}
