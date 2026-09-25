// Renders the Sessions app icon: the recorder's orb rising over a night sky.
// Usage: swift Branding/render-app-icon.swift Branding/AppIcon-1024.png
import AppKit
import SwiftUI

struct SessionsAppIcon: View {
  let side: CGFloat = 1024

  var body: some View {
    let tile = RoundedRectangle(cornerRadius: side * 0.2237, style: .continuous)
    ZStack {
      Color.clear
      ZStack {
        // Night sky.
        LinearGradient(
          colors: [Color(hex: 0x1B3550), Color(hex: 0x0B1829), Color(hex: 0x06101F)],
          startPoint: .top, endPoint: .bottom)
        // First light along the bottom edge: the day about to start.
        RadialGradient(
          colors: [
            Color(red: 1.0, green: 0.61, blue: 0.18).opacity(0.55),
            Color(red: 0.965, green: 0.414, blue: 0.416).opacity(0.28),
            .clear,
          ],
          center: UnitPoint(x: 0.5, y: 1.08), startRadius: 0, endRadius: side * 0.62)
        // Horizon: a line of first light.
        Capsule()
          .fill(
            LinearGradient(
              colors: [
                .clear, Color(red: 1.0, green: 0.61, blue: 0.18).opacity(0.9),
                Color(red: 1.0, green: 0.965, blue: 0.9), Color(red: 1.0, green: 0.61, blue: 0.18).opacity(0.9),
                .clear,
              ],
              startPoint: .leading, endPoint: .trailing)
          )
          .frame(width: side * 0.62, height: side * 0.008)
          .shadow(color: Color(red: 1.0, green: 0.61, blue: 0.18).opacity(0.9), radius: side * 0.02)
          .offset(y: side * 0.2)
        // Halo.
        Circle()
          .fill(
            RadialGradient(
              colors: [
                Color(red: 1.0, green: 0.78, blue: 0.45).opacity(0.6),
                Color(red: 0.965, green: 0.414, blue: 0.416).opacity(0.16),
                .clear,
              ],
              center: .center, startRadius: side * 0.08, endRadius: side * 0.34))
          .frame(width: side * 0.68, height: side * 0.68)
          .offset(y: -side * 0.03)
          .blendMode(.plusLighter)
        // A lit arc: the record mark, caught by the light from above.
        Circle()
          .strokeBorder(
            AngularGradient(
              colors: [
                Color(red: 0.945, green: 0.933, blue: 0.91).opacity(0.95),
                Color(red: 0.945, green: 0.933, blue: 0.91).opacity(0.15),
                Color(red: 0.945, green: 0.933, blue: 0.91).opacity(0.0),
                Color(red: 0.945, green: 0.933, blue: 0.91).opacity(0.15),
                Color(red: 0.945, green: 0.933, blue: 0.91).opacity(0.95),
              ],
              center: .center, startAngle: .degrees(-90), endAngle: .degrees(270)),
            lineWidth: side * 0.012)
          .frame(width: side * 0.5, height: side * 0.5)
          .offset(y: -side * 0.03)
        // The ember, rising.
        Circle()
          .fill(
            RadialGradient(
              colors: [
                Color(red: 1.0, green: 0.965, blue: 0.9),
                Color(red: 1.0, green: 0.78, blue: 0.42),
                Color(red: 1.0, green: 0.61, blue: 0.18),
                Color(red: 0.965, green: 0.414, blue: 0.416),
              ],
              center: UnitPoint(x: 0.42, y: 0.32), startRadius: 0, endRadius: side * 0.19))
          .frame(width: side * 0.28, height: side * 0.28)
          .shadow(color: Color(red: 1.0, green: 0.61, blue: 0.18).opacity(0.7), radius: side * 0.05)
          .offset(y: -side * 0.03)
        // Glass edge.
        tile.strokeBorder(
          LinearGradient(
            colors: [.white.opacity(0.28), .white.opacity(0.04), .white.opacity(0.1)],
            startPoint: .top, endPoint: .bottom),
          lineWidth: side * 0.006)
      }
      .clipShape(tile)
      .frame(width: side * 0.805, height: side * 0.805)
      .shadow(color: .black.opacity(0.35), radius: side * 0.018, y: side * 0.012)
    }
    .frame(width: side, height: side)
  }
}

extension Color {
  init(hex: UInt) {
    self.init(
      .sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
      blue: Double(hex & 0xFF) / 255, opacity: 1)
  }
}

@MainActor func render() {
  let output = CommandLine.arguments.dropFirst().first ?? "AppIcon-1024.png"
  let renderer = ImageRenderer(content: SessionsAppIcon())
  renderer.scale = 1
  guard let image = renderer.nsImage,
    let tiff = image.tiffRepresentation,
    let bitmap = NSBitmapImageRep(data: tiff),
    let png = bitmap.representation(using: .png, properties: [:])
  else {
    fatalError("render failed")
  }
  try! png.write(to: URL(fileURLWithPath: output))
  print("wrote \(output)")
}

MainActor.assumeIsolated { render() }
