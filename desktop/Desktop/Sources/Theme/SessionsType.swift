import AppKit
import CoreText
import SwiftUI

/// Type for Sessions, after Cepessa's First Light.
///
/// - `display` — Cal Sans: titles, the few lines that are *said*.
/// - `text` — Geist: everything that is read, transcripts included.
/// - `figure` — SF with monospaced digits: timers and times, so nothing
///   reflows while a clock runs.
///
/// Neither Cal Sans nor Geist draws Hebrew. Each face therefore carries a
/// cascade: the matching system face, then that face's own fallbacks for
/// Hebrew and English. A Hebrew title or transcript renders in SF Hebrew at
/// the same size and weight. (SF itself has no Hebrew glyphs, so a cascade of
/// SF alone ended in Lucida Grande.) Both faces ship inside the app (SIL OFL 1.1, see
/// `Resources/Fonts/OFL.txt`); if registration ever fails, every call falls
/// back to the system face and nothing else changes.
enum SessionsType {
  static let displayFaceName = "CalSans-SemiBold"

  /// Registers the bundled faces for this process. Safe to call more than once.
  @MainActor
  static func registerBundledFonts(bundle: Bundle = .module) {
    guard !didRegister else { return }
    didRegister = true
    for url in bundledFontURLs(in: bundle) {
      CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }
  }

  /// The packaged faces. SwiftPM flattens processed resources, so the fonts
  /// sit at the bundle's top level, not in `Fonts/` (and a missing
  /// subdirectory answers with an empty list, not nil).
  static func bundledFontURLs(in bundle: Bundle = .module) -> [URL] {
    let nested = bundle.urls(forResourcesWithExtension: "otf", subdirectory: "Fonts") ?? []
    return nested.isEmpty
      ? bundle.urls(forResourcesWithExtension: "otf", subdirectory: nil) ?? [] : nested
  }

  static func display(_ size: CGFloat) -> Font {
    Font(cachedFont(name: displayFaceName, size: size, weight: .semibold, rounded: true))
  }

  static func text(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
    Font(cachedFont(name: textFaceName(for: weight), size: size, weight: weight, rounded: false))
  }

  static func figure(_ size: CGFloat, weight: Font.Weight = .medium) -> Font {
    .system(size: size, weight: weight).monospacedDigit()
  }

  /// Small uppercase labels: speaker names, section heads.
  static func label(_ size: CGFloat = 11) -> Font {
    text(size, weight: .semibold)
  }

  // MARK: - Faces

  private static func textFaceName(for weight: Font.Weight) -> String {
    switch weight {
    case .semibold, .bold, .heavy, .black: return "Geist-SemiBold"
    case .medium: return "Geist-Medium"
    default: return "Geist-Regular"
    }
  }

  private static func systemWeight(_ weight: Font.Weight) -> NSFont.Weight {
    switch weight {
    case .ultraLight: return .ultraLight
    case .thin: return .thin
    case .light: return .light
    case .medium: return .medium
    case .semibold: return .semibold
    case .bold: return .bold
    case .heavy: return .heavy
    case .black: return .black
    default: return .regular
    }
  }

  @MainActor private static var didRegister = false
  nonisolated(unsafe) private static let cache = NSCache<NSString, CTFont>()

  static func cachedFont(
    name: String, size: CGFloat, weight: Font.Weight, rounded: Bool
  ) -> CTFont {
    let key = "\(name)|\(size)|\(rounded)" as NSString
    if let font = cache.object(forKey: key) { return font }

    var system = NSFont.systemFont(ofSize: size, weight: systemWeight(weight))
    if rounded, let descriptor = system.fontDescriptor.withDesign(.rounded) {
      system = NSFont(descriptor: descriptor, size: size) ?? system
    }

    let font: CTFont
    if let face = NSFont(name: name, size: size) {
      let fallbacks =
        CTFontCopyDefaultCascadeListForLanguages(system as CTFont, ["he", "en"] as CFArray)
        as? [NSFontDescriptor] ?? []
      let descriptor = face.fontDescriptor.addingAttributes([
        .cascadeList: [system.fontDescriptor] + fallbacks
      ])
      font = (NSFont(descriptor: descriptor, size: size) ?? face) as CTFont
    } else {
      font = system as CTFont
    }
    cache.setObject(font, forKey: key)
    return font
  }
}
