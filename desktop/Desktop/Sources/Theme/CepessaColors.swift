import AppKit
import SwiftUI

/// Shared adaptive palette for the native macOS app.
/// Prefer system colors so the UI follows macOS contrast, vibrancy, and appearance settings.
enum CepessaColors {
  // MARK: - Background Colors
  static let backgroundPrimary = Color(nsColor: .windowBackgroundColor)
  static let backgroundSecondary = Color(nsColor: .controlBackgroundColor)
  static let backgroundTertiary = Color(nsColor: .underPageBackgroundColor)
  static let backgroundQuaternary = Color(nsColor: .separatorColor)
  static let backgroundRaised = Color(nsColor: .textBackgroundColor)

  // MARK: - Border Colors
  static let border = Color(nsColor: .separatorColor)

  // MARK: - Accent System
  static let purplePrimary = Color.accentColor
  static let purpleSecondary = Color(nsColor: .controlAccentColor)
  static let purpleAccent = Color.accentColor
  static let purpleLight = Color(nsColor: .selectedContentBackgroundColor)

  // MARK: - Text Colors
  static let textPrimary = Color(nsColor: .labelColor)
  static let textSecondary = Color(nsColor: .secondaryLabelColor)
  static let textTertiary = Color(nsColor: .tertiaryLabelColor)
  static let textQuaternary = Color(nsColor: .quaternaryLabelColor)

  // MARK: - Status Colors
  static let success = Color(nsColor: .systemGreen)
  static let warning = Color(nsColor: .systemOrange)
  static let error = Color(nsColor: .systemRed)
  static let info = Color(nsColor: .systemBlue)
  static let amber = Color(nsColor: .systemOrange)

  // MARK: - Mac Window Button Colors
  static let windowButtonClose = Color(hex: 0xFF5F57)
  static let windowButtonMinimize = Color(hex: 0xFFBD2E)
  static let windowButtonMaximize = Color(hex: 0x28CA42)

  // MARK: - Speaker Colors (for transcript bubbles)
  static let speakerColors: [Color] = [
    Color(hex: 0x2D3748),  // Dark blue-gray
    Color(hex: 0x1E3A5F),  // Navy
    Color(hex: 0x2D4A3E),  // Dark teal
    Color(hex: 0x4A3728),  // Dark brown
    Color(hex: 0x3D2E4A),  // Dark purple
    Color(hex: 0x4A3A2D),  // Dark amber
  ]

  /// User bubble color: richer than the page chrome, softer than a flat primary fill.
  static let userBubble = Color(hex: 0x43389F)

  // MARK: - Gradients
  static let purpleGradient = LinearGradient(
    colors: [purplePrimary, purpleAccent],
    startPoint: .topLeading,
    endPoint: .bottomTrailing
  )

  static let purpleLightGradient = LinearGradient(
    colors: [purpleSecondary, purpleLight],
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
