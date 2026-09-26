import AppKit
import CoreText
import SwiftUI
import XCTest

@testable import CepessaSessions

@MainActor
final class SessionsTypeTests: XCTestCase {
  func testTheBundledFacesAreFoundInTheBuiltBundle() {
    let names = SessionsType.bundledFontURLs().map(\.lastPathComponent).sorted()
    XCTAssertEqual(
      names,
      ["CalSans-SemiBold.otf", "Geist-Medium.otf", "Geist-Regular.otf", "Geist-SemiBold.otf"])
  }

  /// Hebrew falls through Cal Sans and Geist to SF Hebrew at every weight the
  /// app uses, never to the last-resort Lucida Grande.
  func testHebrewCascadesToSFHebrew() {
    SessionsType.registerBundledFonts()
    for (name, weight, rounded) in [
      (SessionsType.displayFaceName, Font.Weight.semibold, true),
      ("Geist-Regular", .regular, false), ("Geist-Medium", .medium, false),
      ("Geist-SemiBold", .semibold, false),
    ] {
      let fonts = runFonts(of: "Plan שלום לכולם", face: name, weight: weight, rounded: rounded)
      XCTAssertTrue(fonts.contains(where: { $0.hasPrefix(name) }), "\(name): \(fonts)")
      XCTAssertTrue(
        fonts.contains(where: { $0.localizedCaseInsensitiveContains("Hebrew") }),
        "\(name): \(fonts)")
      XCTAssertFalse(
        fonts.contains(where: { $0.localizedCaseInsensitiveContains("Lucida") }),
        "\(name): \(fonts)")
    }
  }

  private func runFonts(
    of text: String, face: String, weight: Font.Weight, rounded: Bool
  ) -> [String] {
    let font = SessionsType.cachedFont(name: face, size: 15, weight: weight, rounded: rounded)
    let line = CTLineCreateWithAttributedString(
      NSAttributedString(string: text, attributes: [.font: font]))
    let runs = CTLineGetGlyphRuns(line) as? [CTRun] ?? []
    return runs.compactMap { run in
      let attributes = CTRunGetAttributes(run) as NSDictionary
      guard let runFont = attributes[kCTFontAttributeName] else { return nil }
      return CTFontCopyPostScriptName(runFont as! CTFont) as String
    }
  }
}
