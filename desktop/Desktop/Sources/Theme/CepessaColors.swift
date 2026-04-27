import AppKit
import SwiftUI

/// Shared adaptive palette for the native macOS app.
/// Prefer system colors so the UI follows macOS contrast, vibrancy, and appearance settings.
enum CepessaColors {
  // MARK: - Lavender Glass Reference Palette
  static let paper = Color(hex: 0xF7F3FF)
  static let paperDeep = Color(hex: 0xEDE5FF)
  static let paperRaised = Color(hex: 0xFFFDFE)
  static let ink = Color(hex: 0x17152B)
  static let graphite = Color(hex: 0xF0E9FF)
  static let graphiteRaised = Color(hex: 0xF8F4FF)
  static let graphiteLine = Color(hex: 0xD7CBF5)
  static let copper = Color(hex: 0x7D52F4)
  static let copperDeep = Color(hex: 0x5A33D6)
  static let moss = Color(hex: 0x55C989)
  static let mossDeep = Color(hex: 0x379A65)
  static let signalRed = Color(hex: 0xFF4B55)
  static let agedLine = Color(hex: 0xD9D0F3)
  static let warmShadow = Color(hex: 0xA799D8)

  static let capture = copper
  static let captureDeep = copperDeep
  static let processing = capture
  static let ready = moss
  static let lifted = paperRaised
  static let hairline = agedLine

  // MARK: - Background Colors
  static let backgroundPrimary = paper
  static let backgroundSecondary = Color(hex: 0xF1EAFE)
  static let backgroundTertiary = paperDeep
  static let backgroundQuaternary = agedLine
  static let backgroundRaised = paperRaised

  // MARK: - Border Colors
  static let border = agedLine

  // MARK: - Accent System
  static let purplePrimary = processing
  static let purpleSecondary = copper.opacity(0.78)
  static let purpleAccent = capture
  static let purpleLight = copper.opacity(0.18)

  // MARK: - Text Colors
  static let textPrimary = ink
  static let textSecondary = Color(hex: 0x55506D)
  static let textTertiary = Color(hex: 0x827AA3)
  static let textQuaternary = Color(hex: 0xA79FC6)

  // MARK: - Status Colors
  static let success = ready
  static let warning = Color(hex: 0xF2A33B)
  static let error = signalRed
  static let info = Color(hex: 0x5C7CFA)
  static let amber = copper

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
  static let userBubble = copper

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
