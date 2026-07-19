import AppKit
import SwiftUI

/// Shared adaptive palette for the native macOS app.
/// Prefer system colors so the UI follows macOS contrast, vibrancy, and appearance settings.
enum CepessaColors {
  // MARK: - Apple Native Neutral Palette
  static let paper = Color(hex: 0xFFFFFF)
  static let paperDeep = Color(hex: 0xFAFAFC)
  static let paperRaised = Color(hex: 0xFFFFFF)
  static let ink = Color(hex: 0x1D1D1F)
  static let graphite = Color(hex: 0xF7F8FA)
  static let graphiteRaised = Color(hex: 0xFFFFFF)
  static let graphiteLine = Color(hex: 0xE8EBF0)
  static let copper = Color(hex: 0x6E6E73)
  static let copperDeep = Color(hex: 0x3A3A3C)
  static let moss = Color(hex: 0x34C759)
  static let mossDeep = Color(hex: 0x248A3D)
  static let signalRed = Color(hex: 0xE5484D)
  static let agedLine = Color(hex: 0xE8EBF0)
  static let warmShadow = Color(hex: 0x667085)
  static let ambientGlass = Color(hex: 0xFFFFFF)
  static let parchmentTint = Color(hex: 0xFFFFFF)

  static let capture = copper
  static let captureDeep = copperDeep
  static let processing = capture
  static let ready = moss
  static let lifted = paperRaised
  static let hairline = agedLine

  // MARK: - Background Colors
  static let backgroundPrimary = paper
  static let backgroundSecondary = paperDeep
  static let backgroundTertiary = paperDeep
  static let backgroundQuaternary = graphiteLine
  static let backgroundRaised = paperRaised

  // MARK: - Border Colors
  static let border = agedLine

  // MARK: - Accent System
  static let accentPrimary = processing
  static let accentSecondary = copper.opacity(0.78)
  static let accent = capture
  static let accentLight = copper.opacity(0.18)

  // Legacy API aliases. These resolve to the neutral spatial palette above.
  static let purplePrimary = accentPrimary
  static let purpleSecondary = accentSecondary
  static let purpleAccent = accent
  static let purpleLight = accentLight

  // MARK: - Text Colors
  static let textPrimary = ink
  static let textSecondary = Color(hex: 0x636366)
  static let textTertiary = Color(hex: 0x8E8E93)
  static let textQuaternary = Color(hex: 0xC7C7CC)

  // MARK: - Status Colors
  static let success = ready
  static let warning = Color(hex: 0xFF9F0A)
  static let error = signalRed
  static let info = Color(hex: 0x007AFF)
  static let amber = copper

  // MARK: - Mac Window Button Colors
  static let windowButtonClose = Color(hex: 0xFF5F57)
  static let windowButtonMinimize = Color(hex: 0xFFBD2E)
  static let windowButtonMaximize = Color(hex: 0x28CA42)

  // MARK: - Speaker Colors (for transcript bubbles)
  static let speakerColors: [Color] = [
    Color(hex: 0x3A3A3C),
    Color(hex: 0x48484A),
    Color(hex: 0x636366),
    Color(hex: 0x6E6E73),
    Color(hex: 0x8E8E93),
    Color(hex: 0x007AFF),
  ]

  /// User bubble color: richer than the page chrome, softer than a flat primary fill.
  static let userBubble = copper

  // MARK: - Gradients
  static let purpleGradient = LinearGradient(
    colors: [Color(hex: 0x8E8E93), accent],
    startPoint: .topLeading,
    endPoint: .bottomTrailing
  )

  static let purpleLightGradient = LinearGradient(
    colors: [Color(hex: 0xFFFFFF), Color(hex: 0xF2F2F7)],
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
