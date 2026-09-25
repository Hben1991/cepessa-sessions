import AppKit
import SwiftUI

/// The Sessions palette: Cepessa's First Light, carried into a recorder.
///
/// Names mirror `CepessaBrandPalette` in the Cepessa app on purpose, so the
/// two apps can share one set of tokens when Sessions is embedded there.
///
/// Three families, never mixed up:
/// - **Sky** — the night the floating capsule and the dark window are made of.
/// - **Light** — the orb's warm light: identity, emphasis, "working". Never a
///   status colour; "done" is shown by the absence of a signal.
/// - **Signal** — operational meaning only: live capture and needing attention.
enum SessionsPalette {
  // MARK: Sky

  static let nightSkyTop = Color(hex: 0x06101F)
  static let nightSkyMid = Color(hex: 0x152C43)
  static let nightSkyBottom = Color(hex: 0x344A59)

  // MARK: Light

  /// Warm white, the brightest part of the light.
  static let lightCore = Color(red: 1.0, green: 0.965, blue: 0.9)
  static let sunriseGold = Color(red: 1.0, green: 0.61, blue: 0.18)
  static let cloudCoral = Color(red: 0.965, green: 0.414, blue: 0.416)
  static let novaCyan = Color(red: 106 / 255, green: 147 / 255, blue: 157 / 255)
  static let novaLavender = Color(red: 152 / 255, green: 126 / 255, blue: 150 / 255)
  static let novaPink = Color(red: 206 / 255, green: 119 / 255, blue: 141 / 255)

  /// Ink on the night: the stage's cream.
  static let cream = Color(red: 0.945, green: 0.933, blue: 0.910)

  // MARK: Window (follows the system appearance)

  /// Top of the window's atmosphere: warm paper by day, deep sky at night.
  static let canvasTop = Color.adaptive(light: 0xFBF7F1, dark: 0x0C1829)
  static let canvasBottom = Color.adaptive(light: 0xF2EBE1, dark: 0x06101F)

  static let ink = Color.adaptive(light: 0x1B1A1E, dark: 0xF1EEE8)
  static let inkSecondary = Color.adaptive(
    light: 0x131313, lightAlpha: 0.66, dark: 0xF4F1EC, darkAlpha: 0.68)
  static let inkTertiary = Color.adaptive(
    light: 0x131313, lightAlpha: 0.46, dark: 0xF4F1EC, darkAlpha: 0.46)
  static let inkQuiet = Color.adaptive(
    light: 0x131313, lightAlpha: 0.28, dark: 0xF4F1EC, darkAlpha: 0.28)
  /// Ink on a surface filled with `ink`.
  static let inkInverse = Color.adaptive(light: 0xF6F1EA, dark: 0x111A28)

  static let hairline = Color.adaptive(
    light: 0x2B2430, lightAlpha: 0.10, dark: 0xE5DFE6, darkAlpha: 0.11)
  /// A raised field on the atmosphere: search, controls, attachment tiles.
  static let raised = Color.adaptive(
    light: 0xFFFFFF, lightAlpha: 0.66, dark: 0x1A2B3E, darkAlpha: 0.62)
  static let raisedHover = Color.adaptive(
    light: 0xFFFFFF, lightAlpha: 0.9, dark: 0x22364B, darkAlpha: 0.8)

  /// Light as an accent on the window. Gold reads as light at night; by day
  /// it darkens to stay legible on paper.
  static let accent = Color.adaptive(light: 0x9C5208, dark: 0xFFB45C)
  static let accentWash = Color.adaptive(
    light: 0xFF9C2E, lightAlpha: 0.16, dark: 0xFF9C2E, darkAlpha: 0.16)

  // MARK: Signal

  /// Live capture. Deliberately redder than the coral light so the two are
  /// never confused.
  static let recording = Color(red: 1.0, green: 0.31, blue: 0.27)
  static let attention = Color(nsColor: .systemOrange)

  // MARK: Speakers

  /// Speakers take turns through the orb's light, darkened by day so a name
  /// always clears contrast on paper.
  static let speakers: [Color] = [
    .adaptive(light: 0x9C5208, dark: 0xFFB45C),
    .adaptive(light: 0x2F6A77, dark: 0x8FC3CE),
    .adaptive(light: 0xB03B3D, dark: 0xF58B85),
    .adaptive(light: 0x6B4F69, dark: 0xC7AEC5),
    .adaptive(light: 0x9A3F5B, dark: 0xE79BB0),
    .adaptive(light: 0x4A4442, dark: 0xC9C4C0),
  ]

  /// A voice's colour by its order of first appearance in a conversation.
  static func speakerColor(at index: Int) -> Color {
    speakers[max(0, index) % speakers.count]
  }

  /// A stable colour for a voice seen outside its conversation.
  static func speakerColor(for key: String) -> Color {
    guard !key.isEmpty else { return speakers[speakers.count - 1] }
    var hash: UInt64 = 5381
    for scalar in key.unicodeScalars {
      hash = (hash &* 33) &+ UInt64(scalar.value)
    }
    return speakers[Int(hash % UInt64(speakers.count - 1))]
  }
}

/// The floating capsule is always night, whatever the window's appearance:
/// it sits on top of arbitrary documents, and a dark object with cream ink is
/// the one combination that reads on all of them.
enum SessionsNight {
  static let ink = SessionsPalette.cream
  static let inkSecondary = SessionsPalette.cream.opacity(0.66)
  static let inkQuiet = SessionsPalette.cream.opacity(0.38)
  static let hairline = SessionsPalette.cream.opacity(0.14)
  static let controlFill = SessionsPalette.cream.opacity(0.08)
  static let controlHover = SessionsPalette.cream.opacity(0.16)
}

// MARK: - Colour helpers

extension Color {
  init(hex: UInt, alpha: Double = 1) {
    self.init(
      .sRGB,
      red: Double((hex >> 16) & 0xFF) / 255,
      green: Double((hex >> 8) & 0xFF) / 255,
      blue: Double(hex & 0xFF) / 255,
      opacity: alpha
    )
  }

  static func adaptive(
    light: UInt, lightAlpha: Double = 1, dark: UInt, darkAlpha: Double = 1
  ) -> Color {
    Color(
      nsColor: NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let hex = isDark ? dark : light
        return NSColor(
          srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
          green: CGFloat((hex >> 8) & 0xFF) / 255,
          blue: CGFloat(hex & 0xFF) / 255,
          alpha: isDark ? darkAlpha : lightAlpha
        )
      })
  }

  static func adaptive(light: UInt, dark: UInt) -> Color {
    adaptive(light: light, lightAlpha: 1, dark: dark, darkAlpha: 1)
  }
}
