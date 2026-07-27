import AppKit
import SwiftUI

/// Shared palette for the native macOS app.
///
/// Every token resolves to a semantic AppKit color so the UI follows the
/// system appearance (light/dark), Increase Contrast, and vibrancy for free.
/// Hardcoded hex values are reserved for the two places where a fixed hue is
/// the meaning itself: the recording ring and the capture-warning glyph, and
/// even those use the system's accessible `systemRed` / `systemOrange`.
enum CepessaColors {
  // MARK: - Surfaces

  /// The window background. Opaque; never blurred.
  static let backgroundPrimary = Color(nsColor: .windowBackgroundColor)
  /// Grouped/secondary surface behind lists and sidebars.
  static let backgroundSecondary = Color(nsColor: .underPageBackgroundColor)
  static let backgroundTertiary = Color(nsColor: .controlBackgroundColor)
  static let backgroundQuaternary = Color(nsColor: .separatorColor)
  /// Raised control surface (fields, rows, buttons).
  static let backgroundRaised = Color(nsColor: .controlBackgroundColor)
  /// Opaque reading surface for long-form transcript text.
  static let readingSurface = Color(nsColor: .textBackgroundColor)

  static let border = Color(nsColor: .separatorColor)
  static let hairline = Color(nsColor: .separatorColor)

  // MARK: - Text

  static let textPrimary = Color(nsColor: .labelColor)
  static let textSecondary = Color(nsColor: .secondaryLabelColor)
  static let textTertiary = Color(nsColor: .tertiaryLabelColor)
  static let textQuaternary = Color(nsColor: .quaternaryLabelColor)

  // MARK: - Accent

  /// The single restrained accent. Follows the user's system accent colour.
  static let accent = Color(nsColor: .controlAccentColor)
  static let accentPrimary = accent
  static let accentSecondary = Color(nsColor: .secondaryLabelColor)
  static let accentLight = Color(nsColor: .controlAccentColor).opacity(0.14)

  static let capture = accent
  static let captureDeep = Color(nsColor: .labelColor)
  static let processing = accent
  static let ready = Color(nsColor: .systemGreen)
  static let lifted = backgroundRaised

  // MARK: - Status

  /// Recording. Red is the platform's meaning for "capture is live" — it is
  /// deliberately not used as a success colour anywhere else.
  static let signalRed = Color(nsColor: .systemRed)
  static let warning = Color(nsColor: .systemOrange)
  static let error = Color(nsColor: .systemRed)
  static let success = Color(nsColor: .systemGreen)
  static let info = Color(nsColor: .systemBlue)

  // MARK: - Speaker attribution (transcript)

  /// Neutral-first speaker ramp; the accent only appears for the last slot so
  /// a transcript never turns into a colour chart.
  static let speakerColors: [Color] = [
    Color(nsColor: .labelColor),
    Color(nsColor: .secondaryLabelColor),
    Color(nsColor: .systemBlue),
    Color(nsColor: .systemTeal),
    Color(nsColor: .systemIndigo),
    Color(nsColor: .controlAccentColor),
  ]

  // MARK: - Legacy aliases
  //
  // Kept so the unreachable legacy workspace/recap source keeps compiling.
  // They all resolve to the semantic tokens above.

  static let paper = backgroundPrimary
  static let paperDeep = backgroundSecondary
  static let paperRaised = backgroundRaised
  static let ink = textPrimary
  static let graphite = backgroundSecondary
  static let graphiteRaised = backgroundRaised
  static let graphiteLine = border
  static let copper = accent
  static let copperDeep = captureDeep
  static let moss = success
  static let mossDeep = success
  static let agedLine = border
  static let warmShadow = Color(nsColor: .shadowColor)
  static let ambientGlass = backgroundRaised
  static let parchmentTint = backgroundPrimary
  static let amber = warning
  static let userBubble = accent

  static let purplePrimary = accentPrimary
  static let purpleSecondary = accentSecondary
  static let purpleAccent = accent
  static let purpleLight = accentLight

  static let windowButtonClose = Color(nsColor: .systemRed)
  static let windowButtonMinimize = Color(nsColor: .systemYellow)
  static let windowButtonMaximize = Color(nsColor: .systemGreen)

  static let purpleGradient = LinearGradient(
    colors: [accentSecondary, accent],
    startPoint: .topLeading,
    endPoint: .bottomTrailing
  )

  static let purpleLightGradient = LinearGradient(
    colors: [backgroundRaised, backgroundSecondary],
    startPoint: .topLeading,
    endPoint: .bottomTrailing
  )
}

// MARK: - Color Extension for Hex

extension Color {
  init(hex: UInt, alpha: Double = 1.0) {
    self.init(
      .sRGB,
      red: Double((hex >> 16) & 0xFF) / 255.0,
      green: Double((hex >> 8) & 0xFF) / 255.0,
      blue: Double(hex & 0xFF) / 255.0,
      opacity: alpha
    )
  }

  /// Initialize from a hex string like "#6B7280" or "6B7280"
  init?(hex hexString: String) {
    var cleanedString = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
    cleanedString = cleanedString.replacingOccurrences(of: "#", with: "")

    guard cleanedString.count == 6,
      let hexValue = UInt(cleanedString, radix: 16)
    else {
      return nil
    }

    self.init(hex: hexValue)
  }
}
