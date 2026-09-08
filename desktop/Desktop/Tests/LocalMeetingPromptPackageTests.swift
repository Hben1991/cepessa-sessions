import Foundation
import XCTest

@testable import CepessaSessions

final class LocalMeetingPromptPackageTests: XCTestCase {
  private var tempRootURL: URL!
  private let fileManager = FileManager.default

  override func setUpWithError() throws {
    tempRootURL = fileManager.temporaryDirectory
      .appendingPathComponent(
        "LocalMeetingPromptPackageTests-\(UUID().uuidString)", isDirectory: true)
    try fileManager.createDirectory(at: tempRootURL, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    if let tempRootURL {
      try? fileManager.removeItem(at: tempRootURL)
    }
  }

  func testSavingSessionGeneratesMarkdownAndJSONPromptPackage() throws {
    let layout = LocalMeetingFileLayout(
      baseDirectory: tempRootURL.appendingPathComponent("Cepessa", isDirectory: true))
    let store = LocalMeetingSessionStore(fileLayout: layout)
    let sessionID = UUID(uuidString: "B0C1D2E3-F4A5-46B7-88C9-001122334455")!
    let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
    let session = LocalSession(
      id: sessionID,
      title: "Session Product Review",
      startedAt: startedAt,
      status: .ready,
      transcriptSegments: [
        .init(
          id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
          speaker: "Transcript",
          text: "We agreed to ship the export package next.",
          timestamp: startedAt.addingTimeInterval(45)
        )
      ],
      recap: LocalSessionRecap(
        overview: "A short decision-focused recap.",
        generatedAt: startedAt.addingTimeInterval(60),
        sections: [
          .init(
            id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            kind: .decisions,
            title: "Decisions",
            summary: "Ship the export package first.",
            bullets: ["Export transcript, recap, and attachments together."],
            anchorTimestamp: startedAt.addingTimeInterval(45),
            startOffset: 45,
            endOffset: 55
          )
        ]
      ),
      attachments: [
        .init(
          id: UUID(uuidString: "99999999-8888-7777-6666-555555555555")!,
          kind: .file,
          source: .imported,
          title: "PRD",
          timestamp: startedAt.addingTimeInterval(32),
          sessionOffset: 32,
          fileName: "prd.pdf",
          mimeType: "application/pdf",
          urlString: layout.attachmentsDirectory(for: sessionID).appendingPathComponent("prd.pdf")
            .path,
          note: "Imported during review."
        )
      ],
      captureArtifacts: [
        .init(
          id: UUID(uuidString: "12345678-90AB-CDEF-1234-567890ABCDEF")!,
          kind: .note,
          title: "PRD reference",
          capturedAt: startedAt.addingTimeInterval(32),
          sessionOffset: 32,
          attachmentIDs: [UUID(uuidString: "99999999-8888-7777-6666-555555555555")!],
          notes: "Discussed while deciding the rollout order."
        )
      ],
      audioArtifacts: .init(
        micFileName: "mic.wav",
        systemFileName: "system.wav",
        mixedFileName: "mixed.wav"
      )
    )

    try store.save(session)

    let markdownURL = layout.promptPackageMarkdownURL(for: sessionID)
    let jsonURL = layout.promptPackageJSONURL(for: sessionID)

    XCTAssertTrue(fileManager.fileExists(atPath: markdownURL.path))
    XCTAssertTrue(fileManager.fileExists(atPath: jsonURL.path))

    let markdown = try String(contentsOf: markdownURL, encoding: .utf8)
    XCTAssertTrue(markdown.contains("Reusable AI Prompt"))
    XCTAssertTrue(markdown.contains("Session Product Review"))
    XCTAssertTrue(markdown.contains("We agreed to ship the export package next."))
    XCTAssertTrue(markdown.contains("prd.pdf"))

    let jsonObject =
      try JSONSerialization.jsonObject(with: Data(contentsOf: jsonURL)) as? [String: Any]
    XCTAssertEqual(jsonObject?["title"] as? String, "Session Product Review")
    XCTAssertEqual((jsonObject?["attachments"] as? [[String: Any]])?.count, 1)
  }

  func testImportedPackageIncludesSourceAndEvidenceInBothFormats() throws {
    let layout = LocalSessionFileLayout(baseDirectory: tempRootURL)
    var session = packageSession()
    session.audioArtifacts = .init(importedFileName: "imported.wav")
    session.transcriptionEvidence = summary(ready: true, revision: 1)
    try LocalSessionPromptPackageBuilder(fileLayout: layout).writePackage(for: session)

    let markdown = try String(
      contentsOf: layout.promptPackageMarkdownURL(for: session.id), encoding: .utf8)
    let json = try packageJSON(layout, session.id)
    let files = try XCTUnwrap(json["audioFiles"] as? [[String: String]])
    XCTAssertEqual(files.count, 1)
    XCTAssertEqual(files.first?["fileName"], "imported.wav")
    XCTAssertEqual(files.first?["path"], layout.importedAudioURL(for: session.id).path)
    XCTAssertTrue(markdown.contains("Imported: imported.wav"))
    XCTAssertTrue(markdown.contains("Detected speech coverage: 99.00%"))
    XCTAssertTrue(
      markdown.contains("Timing and speech coverage checks do not verify every recognized word."))
    XCTAssertEqual(json["evidenceOrigin"] as? String, "transcription-run-reference")
    let evidence = try XCTUnwrap(json["transcriptionEvidence"] as? [String: Any])
    XCTAssertEqual(evidence["runID"] as? String, "run-1")
    XCTAssertEqual(evidence["contentHash"] as? String, "hash-1")
    XCTAssertEqual(evidence["isComplete"] as? Bool, true)
  }

  func testLegacyPackageKeepsCompletenessWarningEvenWhenStatusIsReady() throws {
    let layout = LocalSessionFileLayout(baseDirectory: tempRootURL)
    let session = packageSession()
    try LocalSessionPromptPackageBuilder(fileLayout: layout).writePackage(for: session)
    let markdown = try String(
      contentsOf: layout.promptPackageMarkdownURL(for: session.id), encoding: .utf8)
    let json = try packageJSON(layout, session.id)
    let notice = try XCTUnwrap(json["transcriptNotice"] as? [String: Any])
    XCTAssertEqual(json["status"] as? String, "ready")
    XCTAssertEqual(json["evidenceOrigin"] as? String, "legacy-session-json")
    XCTAssertNil(json["transcriptionEvidence"])
    XCTAssertEqual(notice["title"] as? String, "Saved transcript")
    XCTAssertTrue((notice["detail"] as? String)?.contains("no completeness check") == true)
    XCTAssertTrue(markdown.contains("no completeness check"))
  }

  func testFailedRetryPackageKeepsPriorWordsAndBothAttemptStates() throws {
    let layout = LocalSessionFileLayout(baseDirectory: tempRootURL)
    var session = packageSession()
    session.status = .failed
    session.transcriptionEvidence = summary(ready: true, revision: 1)
    session.latestTranscriptionAttempt = summary(ready: false, revision: 2)
    session.processingError = "Showing the previously saved transcript."
    try LocalSessionPromptPackageBuilder(fileLayout: layout).writePackage(for: session)
    let markdown = try String(
      contentsOf: layout.promptPackageMarkdownURL(for: session.id), encoding: .utf8)
    let json = try packageJSON(layout, session.id)
    XCTAssertTrue((json["transcriptText"] as? String)?.contains("Previously saved words") == true)
    XCTAssertEqual(
      (json["transcriptionEvidence"] as? [String: Any])?["disposition"] as? String, "ready")
    XCTAssertEqual(
      (json["latestTranscriptionAttempt"] as? [String: Any])?["disposition"] as? String, "failed")
    XCTAssertTrue(markdown.contains("Latest transcription attempt"))
    XCTAssertTrue(markdown.contains("The latest audio was incomplete."))
    XCTAssertTrue(markdown.contains("Showing the previously saved transcript."))
  }

  func testPackageRefusesLinkedCachesWithoutChangingOutsideBytes() throws {
    for hardLink in [false, true] {
      let layout = LocalSessionFileLayout(
        baseDirectory: tempRootURL.appendingPathComponent(UUID().uuidString))
      let session = packageSession()
      try layout.ensureDirectories(for: session.id)
      let outside = tempRootURL.appendingPathComponent("outside-\(UUID().uuidString).md")
      let original = Data("Unrelated file".utf8)
      try original.write(to: outside)
      let destination = layout.promptPackageMarkdownURL(for: session.id)
      if hardLink {
        try fileManager.linkItem(at: outside, to: destination)
      } else {
        try fileManager.createSymbolicLink(at: destination, withDestinationURL: outside)
      }
      XCTAssertThrowsError(
        try LocalSessionPromptPackageBuilder(fileLayout: layout).writePackage(for: session))
      XCTAssertEqual(try Data(contentsOf: outside), original)
      XCTAssertFalse(
        fileManager.fileExists(atPath: layout.promptPackageJSONURL(for: session.id).path))
    }
  }

  private func packageSession() -> LocalSession {
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    return .init(
      id: UUID(), title: "Package review", startedAt: date, status: .ready,
      transcriptSegments: [
        .init(id: UUID(), speaker: "Speaker 1", text: "Previously saved words", timestamp: date)
      ],
      recap: .empty, attachments: [], captureArtifacts: [], audioArtifacts: .empty)
  }

  private func summary(ready: Bool, revision: Int) -> LocalSessionTranscriptionEvidenceSummary {
    .init(
      runID: "run-\(revision)", revision: revision, disposition: ready ? .ready : .failed,
      contentHash: "hash-\(revision)", parentContentHash: nil, runFileName: "run-\(revision).json",
      outboxFileName: "outbox-\(revision).json",
      issues: ready ? [] : ["The latest audio was incomplete."],
      isComplete: ready, speechCoverage: ready ? 0.99 : 0.2, hasVerifiableTimestamps: true)
  }

  private func packageJSON(_ layout: LocalSessionFileLayout, _ sessionID: UUID) throws -> [String:
    Any]
  {
    try XCTUnwrap(
      JSONSerialization.jsonObject(
        with: Data(contentsOf: layout.promptPackageJSONURL(for: sessionID))) as? [String: Any])
  }
}
