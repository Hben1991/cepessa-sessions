import Foundation
import PDFKit
import XCTest

@testable import CepessaSessions

final class LocalSessionRecapExporterTests: XCTestCase {
  private var tempDirectory: URL!

  override func setUpWithError() throws {
    tempDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "LocalSessionRecapExporterTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    if let tempDirectory {
      try? FileManager.default.removeItem(at: tempDirectory)
    }
  }

  func testMarkdownExportWritesSelectedLanguages() throws {
    let exporter = LocalSessionRecapExporter()
    let urls = try exporter.export(
      session: makeSession(),
      format: .markdown,
      languages: .both,
      to: tempDirectory
    )

    XCTAssertEqual(urls.count, 2)
    XCTAssertTrue(urls.contains { $0.lastPathComponent.hasSuffix("-english.md") })
    XCTAssertTrue(urls.contains { $0.lastPathComponent.hasSuffix("-hebrew.md") })

    let englishURL = try XCTUnwrap(urls.first { $0.lastPathComponent.hasSuffix("-english.md") })
    let hebrewURL = try XCTUnwrap(urls.first { $0.lastPathComponent.hasSuffix("-hebrew.md") })
    let english = try String(contentsOf: englishURL, encoding: .utf8)
    let hebrew = try String(contentsOf: hebrewURL, encoding: .utf8)

    XCTAssertTrue(english.contains("# Export Review"))
    XCTAssertTrue(english.contains("## Overview"))
    XCTAssertFalse(english.contains("## Transcript"))
    XCTAssertFalse(english.contains("We agreed to export the recap."))
    XCTAssertTrue(hebrew.contains("## סקירה"))
    XCTAssertFalse(hebrew.contains("## תמלול"))
  }

  func testPDFExportWritesPDFFile() throws {
    let exporter = LocalSessionRecapExporter()
    let urls = try exporter.export(
      session: makeSession(),
      format: .pdf,
      languages: .english,
      to: tempDirectory
    )

    let url = try XCTUnwrap(urls.first)
    XCTAssertEqual(url.pathExtension, "pdf")

    let data = try Data(contentsOf: url)
    XCTAssertTrue(data.count > 100)
    XCTAssertEqual(String(data: data.prefix(4), encoding: .ascii), "%PDF")

    let document = try XCTUnwrap(PDFDocument(data: data))
    let text = document.string ?? ""
    XCTAssertTrue(text.contains("Export Review"))
    XCTAssertFalse(text.contains("# Export Review"))
    XCTAssertFalse(text.contains("## Overview"))
  }

  func testTranscriptMarkdownExportWritesFullTranscriptOnly() throws {
    let exporter = LocalSessionRecapExporter()
    let url = try exporter.exportTranscriptMarkdown(
      session: makeSession(),
      to: tempDirectory
    )

    XCTAssertEqual(url.pathExtension, "md")

    let markdown = try String(contentsOf: url, encoding: .utf8)
    XCTAssertTrue(markdown.contains("# Export Review Transcript"))
    XCTAssertTrue(markdown.contains("## Transcript"))
    XCTAssertTrue(markdown.contains("Dana"))
    XCTAssertTrue(markdown.contains("We agreed to export the recap."))
    XCTAssertFalse(markdown.contains("## Overview"))
    XCTAssertFalse(markdown.contains("The team reviewed export options."))
    XCTAssertFalse(markdown.contains("Add PDF and Markdown export options."))
  }

  private func makeSession() -> LocalMeetingSession {
    let startedAt = Date(timeIntervalSince1970: 2_000_000)
    var session = LocalMeetingSession(
      id: UUID(uuidString: "9B9282E1-412C-446C-BF92-4C8BC9CFA754")!,
      title: "Export Review",
      startedAt: startedAt,
      status: .ready,
      transcriptSegments: [
        .init(
          id: UUID(uuidString: "C6EE85FB-6845-4B2B-A80C-7969CE9E4943")!,
          speaker: "Dana",
          text: "We agreed to export the recap.",
          timestamp: startedAt.addingTimeInterval(12)
        )
      ],
      audioArtifacts: .empty
    )
    session.recap = LocalSessionRecap(
      overview: "The team reviewed export options.",
      generatedAt: startedAt,
      sections: [
        LocalSessionRecapSection(
          id: UUID(uuidString: "36AD327B-016B-408B-9C87-50D278D45702")!,
          kind: .actionItem,
          title: "Action items",
          summary: "Export follow-ups.",
          bullets: ["Add PDF and Markdown export options."],
          anchorTimestamp: nil,
          startOffset: nil,
          endOffset: nil
        )
      ]
    )
    return session
  }
}
