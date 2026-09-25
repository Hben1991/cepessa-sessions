import Foundation
import SessionsHandoff
import XCTest

final class SessionsOutboxReaderTests: XCTestCase {
  private var root: URL!
  private var outbox: URL!

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent("SessionsOutboxReaderTests-\(UUID().uuidString)", isDirectory: true)
    outbox = root.appendingPathComponent(SessionsHandoff.outboxDirectoryName, isDirectory: true)
    try FileManager.default.createDirectory(at: outbox, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    if let root { try? FileManager.default.removeItem(at: root) }
  }

  func testAMissingOutboxIsAnEmptySnapshotNotAnError() throws {
    let reader = SessionsOutboxReader(
      baseDirectory: root.appendingPathComponent("nothing-here", isDirectory: true))
    XCTAssertEqual(try reader.snapshot(), .init(evidence: [], rejected: []))
  }

  func testTheNewestVerifiedRevisionOfEachRecordingWins() throws {
    try write(envelope(evidenceID: "a", revision: 1, title: "First pass"), as: "a1.json")
    try write(envelope(evidenceID: "a", revision: 2, title: "Second pass"), as: "a2.json")
    try write(
      envelope(evidenceID: "b", revision: 1, title: "Other", startedAt: "2026-09-26T08:00:00Z"),
      as: "b1.json")

    let snapshot = try SessionsOutboxReader(baseDirectory: root).snapshot()

    XCTAssertEqual(snapshot.rejected, [])
    XCTAssertEqual(snapshot.evidence.map(\.session.title), ["Other", "Second pass"])
    XCTAssertEqual(snapshot.evidence.last?.revision, 2)
  }

  func testATamperedEnvelopeIsRejectedAndNamedNeverSilentlyDropped() throws {
    var tampered = envelope(evidenceID: "a", revision: 3, title: "Honest")
    tampered["session"] = [
      "id": "session-a", "title": "Edited after hashing", "startedAt": "2026-09-25T08:00:00Z",
      "status": "ready",
    ]
    try write(envelope(evidenceID: "a", revision: 1, title: "Honest"), as: "good.json")
    try write(tampered, as: "tampered.json", rehash: false)

    let snapshot = try SessionsOutboxReader(baseDirectory: root).snapshot()

    XCTAssertEqual(snapshot.evidence.map(\.revision), [1], "a forged newer revision must not win")
    XCTAssertEqual(
      snapshot.rejected, [.init(fileName: "tampered.json", reason: .contentHashMismatch)])
  }

  func testAnUnknownSchemaIsRejectedRatherThanMisread() throws {
    var future = envelope(evidenceID: "a", revision: 1, title: "Future")
    future["schemaVersion"] = "meeting-evidence/v9"
    try write(future, as: "future.json")

    let snapshot = try SessionsOutboxReader(baseDirectory: root).snapshot()
    XCTAssertEqual(snapshot.evidence, [])
    XCTAssertEqual(
      snapshot.rejected,
      [.init(fileName: "future.json", reason: .unsupportedSchema("meeting-evidence/v9"))])
  }

  func testLinksAreNotFollowed() throws {
    let elsewhere = root.appendingPathComponent("elsewhere.json")
    try JSONSerialization.data(withJSONObject: envelope(evidenceID: "a", revision: 1, title: "x"))
      .write(to: elsewhere)
    try FileManager.default.createSymbolicLink(
      at: outbox.appendingPathComponent("link.json"), withDestinationURL: elsewhere)

    let snapshot = try SessionsOutboxReader(baseDirectory: root).snapshot()
    XCTAssertEqual(snapshot.evidence, [])
    XCTAssertEqual(snapshot.rejected, [.init(fileName: "link.json", reason: .unsafeFile)])
  }

  func testCanonicalNumbersAreBoundedMicroUnits() throws {
    XCTAssertEqual(try SessionsEvidenceCanonicalizer.canonicalNumberString(1), "1")
    XCTAssertEqual(try SessionsEvidenceCanonicalizer.canonicalNumberString(0.1234565), "0.123457")
    XCTAssertThrowsError(try SessionsEvidenceCanonicalizer.canonicalNumberString(-1))
    XCTAssertThrowsError(try SessionsEvidenceCanonicalizer.canonicalNumberString(.nan))
  }

  // MARK: - Fixtures

  private func envelope(
    evidenceID: String, revision: Int, title: String,
    startedAt: String = "2026-09-25T08:00:00Z"
  ) -> [String: Any] {
    [
      "schemaVersion": SessionsHandoff.schemaVersion,
      "evidenceId": evidenceID,
      "sourceRef": "cepessa-sessions:\(evidenceID)",
      "revision": revision,
      "session": [
        "id": "session-\(evidenceID)", "title": title, "startedAt": startedAt, "status": "ready",
      ],
      "run": [
        "id": "run-\(evidenceID)-\(revision)",
        "createdAt": "2026-09-25T09:00:0\(revision)Z",
        "completedAt": "2026-09-25T09:00:0\(revision)Z",
        "disposition": "ready",
        "engine": "whisperCpp",
        "model": ["identifier": "hebrewTurbo", "modelBasename": "ggml-model.bin"],
        "requestedLanguage": "auto",
        "detectedLanguages": ["he"],
        "diarizationStatus": "available",
        "issues": [],
      ],
      "sources": [
        [
          "id": "mic", "kind": "microphone", "fileName": "mic.wav", "role": "primary",
          "integrity": "available", "durationSeconds": 12.5, "sha256": String(repeating: "a", count: 64),
          "issues": [],
        ]
      ],
      "speakers": [
        [
          "id": "s1", "label": "Ben", "kind": "person", "identityStatus": "confirmed",
          "confidence": 0.9,
        ]
      ],
      "segments": [
        [
          "id": "seg1", "sourceId": "mic", "speakerId": "s1", "rawASRText": "שלום",
          "activeText": "שלום", "startSeconds": 0, "endSeconds": 1.25,
          "timestampProvenance": "asr", "isTimed": true, "confidence": 0.8, "uncertainty": [],
          "language": "he",
        ]
      ],
      "transcript": [
        "renderedText": "Ben: שלום\n",
        "byteOffsets": [["segmentId": "seg1", "utf8Start": 5, "utf8Length": 8]],
      ],
      "quality": [
        "isComplete": true, "speechCoverage": 0.98, "hasVerifiableTimestamps": true,
        "sourceSeparationPreserved": true, "diarization": "available", "issues": [],
      ],
    ]
  }

  private func write(_ object: [String: Any], as name: String, rehash: Bool = true) throws {
    var object = object
    if rehash || object["contentHash"] == nil {
      object["contentHash"] = SessionsEvidenceCanonicalizer.contentHash(
        canonicalData: try SessionsEvidenceCanonicalizer.canonicalData(jsonValue: object))
    }
    if !rehash {
      // Keep the hash of the untampered original.
      var original = object
      original["session"] = [
        "id": "session-a", "title": "Honest", "startedAt": "2026-09-25T08:00:00Z",
        "status": "ready",
      ]
      original.removeValue(forKey: "contentHash")
      object["contentHash"] = SessionsEvidenceCanonicalizer.contentHash(
        canonicalData: try SessionsEvidenceCanonicalizer.canonicalData(jsonValue: original))
    }
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    try data.write(to: outbox.appendingPathComponent(name))
  }
}
