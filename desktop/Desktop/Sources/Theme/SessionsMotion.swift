import SwiftUI

/// Motion, after Cepessa's First Light: things arrive out of focus and settle;
/// things leave by receding. Nothing bounces, nothing slides in from a side.
enum SessionsMotion {
  /// A line arriving: opacity from nothing while a blur falls away.
  static let arrive = Animation.easeOut(duration: 0.55)
  static let arrivalBlur: CGFloat = 14
  static let arrivalDelay: Double = 0.12
  /// Between lines of one arrival. Capped, so a long list never makes the
  /// last line wait.
  static let stagger: Double = 0.06
  static let maximumStaggeredItems = 10

  /// A beat leaving: out of focus, a little smaller.
  static let depart = Animation.easeIn(duration: 0.28)

  /// The floating capsule changing shape. Calm deceleration, no overshoot.
  static let capsule = Animation.spring(response: 0.46, dampingFraction: 0.88)
  static let capsuleContentIn = Animation.easeOut(duration: 0.26).delay(0.1)
  static let capsuleContentOut = Animation.easeIn(duration: 0.12)
  /// Backstop for the capsule's completion callback. A spring keeps moving
  /// well past its response, so this only exists for a completion that never
  /// arrives at all.
  static let capsuleSettleTimeout: TimeInterval = 1.6

  /// State that changes meaning but not geometry: a tint, a glyph.
  static let state = Animation.easeOut(duration: 0.2)
  static let hover = Animation.easeOut(duration: 0.16)
  static let press = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.16)

  /// The orb breathes on the same period as the Cepessa orb's halo.
  static let breathPeriod: Double = 5.4

  /// A said line reveals word by word: the whole line takes this long.
  static func revealDuration(wordCount: Int) -> Double {
    min(0.45 + 0.07 * Double(max(wordCount, 1)), 1.6)
  }
}

// MARK: - Still rendering

private struct SessionsIsStillKey: EnvironmentKey {
  static let defaultValue = false
}

extension EnvironmentValues {
  /// A still frame — a fixture render, not the running app. Arrivals are
  /// settled and reveals complete, because a still has no time for them.
  var sessionsIsStill: Bool {
    get { self[SessionsIsStillKey.self] }
    set { self[SessionsIsStillKey.self] = newValue }
  }
}

// MARK: - Arrival

private struct SessionsArrival: ViewModifier {
  let order: Int
  let after: Double

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.sessionsIsStill) private var isStill
  @State private var arrived = false

  private var isShown: Bool { arrived || isStill }

  func body(content: Content) -> some View {
    content
      .opacity(isShown ? 1 : 0)
      .blur(radius: isShown || reduceMotion ? 0 : SessionsMotion.arrivalBlur)
      .offset(y: isShown || reduceMotion ? 0 : 6)
      .onAppear {
        guard !arrived, !isStill else { return }
        let slot = Double(min(order, SessionsMotion.maximumStaggeredItems))
        let delay = after + SessionsMotion.arrivalDelay + slot * SessionsMotion.stagger
        withAnimation(
          reduceMotion
            ? .easeOut(duration: 0.18)
            : SessionsMotion.arrive.delay(delay)
        ) {
          arrived = true
        }
      }
  }
}

extension View {
  /// Staggered arrival: `order` is the line's place in its group; `after`
  /// holds the whole group back.
  func sessionsArrival(_ order: Int = 0, after: Double = 0) -> some View {
    modifier(SessionsArrival(order: order, after: after))
  }
}

extension AnyTransition {
  /// Leaving: the view recedes out of focus. Arriving is left to the new
  /// content's own `sessionsArrival`, so a change is never a crossfade of two
  /// complete copies.
  static func sessionsRecede(reduceMotion: Bool) -> AnyTransition {
    .asymmetric(
      insertion: .identity,
      removal: reduceMotion
        ? .opacity.animation(.easeIn(duration: 0.12))
        : .modifier(
          active: SessionsRecede(progress: 1),
          identity: SessionsRecede(progress: 0)
        ).animation(SessionsMotion.depart)
    )
  }
}

private struct SessionsRecede: ViewModifier {
  let progress: Double

  func body(content: Content) -> some View {
    content
      .opacity(1 - progress)
      .blur(radius: SessionsMotion.arrivalBlur * progress)
      .scaleEffect(1 - 0.03 * progress)
  }
}

// MARK: - Word reveal

/// Marks a word with its place in the line.
struct SessionsWord: TextAttribute {
  let index: Int
}

/// Draws a line's words in reading order: each arrives from a blur, a few
/// points low, overlapping the next. Layout is the text's own, so wrapping,
/// right-to-left order and accessibility are untouched; only drawing is staged.
struct SessionsWordReveal: TextRenderer, Animatable {
  var progress: Double
  let wordCount: Int

  var animatableData: Double {
    get { progress }
    set { progress = newValue }
  }

  func draw(layout: Text.Layout, in context: inout GraphicsContext) {
    for line in layout {
      for run in line {
        let index = run[SessionsWord.self]?.index ?? 0
        let local = Self.localProgress(progress: progress, index: index, count: wordCount)
        guard local > 0 else { continue }
        if local >= 1 {
          context.draw(run)
          continue
        }
        let eased = 1 - pow(1 - local, 3)
        var word = context
        word.opacity = eased
        word.addFilter(.blur(radius: (1 - eased) * 12))
        word.translateBy(x: 0, y: (1 - eased) * 8)
        word.draw(run)
      }
    }
  }

  /// Each word takes 45% of the line's time, starting in turn.
  static func localProgress(progress: Double, index: Int, count: Int) -> Double {
    guard progress < 1 else { return 1 }
    guard count > 1 else { return max(progress, 0) }
    let window = 0.45
    let start = Double(min(index, count - 1)) / Double(count - 1) * (1 - window)
    return min(max((progress - start) / window, 0), 1)
  }
}

/// A line set in the display face, revealed word by word when it appears and
/// again whenever its words change.
struct SessionsRevealedLine: View {
  let text: String
  let font: Font
  var color: Color = SessionsPalette.ink
  var alignment: TextAlignment = .leading
  var tracking: CGFloat = 0
  var delay: Double = 0

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.sessionsIsStill) private var isStill
  @State private var progress: Double = 0

  private var words: [String] {
    text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
  }

  var body: some View {
    staged
      .font(font)
      .tracking(tracking)
      .multilineTextAlignment(alignment)
      .foregroundStyle(color)
      .textRenderer(
        SessionsWordReveal(
          progress: isStill || reduceMotion ? 1 : progress, wordCount: words.count)
      )
      .fixedSize(horizontal: false, vertical: true)
      .accessibilityLabel(text)
      .onAppear(perform: reveal)
      .onChange(of: text) { _, _ in
        progress = 0
        reveal()
      }
  }

  private func reveal() {
    guard !isStill, !reduceMotion else { return }
    withAnimation(
      .linear(duration: SessionsMotion.revealDuration(wordCount: words.count)).delay(delay)
    ) {
      progress = 1
    }
  }

  private var staged: Text {
    var line = Text(verbatim: "")
    for (index, word) in words.enumerated() {
      let piece = Text(verbatim: index == words.count - 1 ? word : word + " ")
        .customAttribute(SessionsWord(index: index))
      line = Text("\(line)\(piece)")
    }
    return line
  }
}
