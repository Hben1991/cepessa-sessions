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
/// cascade to the matching system face, so a Hebrew title or transcript
/// renders in SF at the same size and weight instead of the system's generic
/// last-resort font. Both faces ship inside the app (SIL OFL 1.1, see
/// `Resources/Fonts/OFL.txt`); if registration ever fails, every call falls
/// back to the system face and nothing else changes.
enum SessionsType {
  static let displayFaceName = "CalSans-SemiBold"

  /// Registers the bundled faces for this process. Safe to call more than once.
  @MainActor
  static func registerBundledFonts(bundle: Bundle = .module) {
    guard !didRegister else { return }
    didRegister = true
    let urls = bundle.urls(forResourcesWithExtension: "otf", subdirectory: "Fonts")
      ?? bundle.urls(forResourcesWithExtension: "otf", subdirectory: nil) ?? []
    for url in urls {
      CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }
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

  private static func cachedFont(
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
      let descriptor = face.fontDescriptor.addingAttributes([
        .cascadeList: [system.fontDescriptor]
      ])
      font = (NSFont(descriptor: descriptor, size: size) ?? face) as CTFont
    } else {
      font = system as CTFont
    }
    cache.setObject(font, forKey: key)
    return font
  }
}
