import Darwin
import Foundation
import XCTest

@testable import CepessaSessions

final class LocalSessionSpeakerAnnotationStoreSafetyTests: XCTestCase {
  private struct DirectorySnapshot: Equatable {
    let subpaths: [String]
    let fileBytes: [String: Data]
  }

  private var tempRoot: URL!
  private let fileManager = FileManager.default

  override func setUpWithError() throws {
    tempRoot = fileManager.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(
      "LocalSessionSpeakerAnnotationStoreSafetyTests-\(UUID().uuidString)",
      isDirectory: true
    )
    try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    if let tempRoot { try? fileManager.removeItem(at: tempRoot) }
  }

  func testAnnotationSymlinkIsRejectedWithoutChangingOutsideBytes() throws {
    let layout = LocalMeetingFileLayout(baseDirectory: tempRoot)
    let sessionID = UUID()
    try layout.ensureDirectories(fileManager: fileManager, for: sessionID)
    let annotationURL = layout.speakerAnnotationsURL(for: sessionID)
    let outsideURL = tempRoot.appendingPathComponent("outside-symlink.jsonl")
    let outsideBytes = Data("outside symlink bytes\n".utf8)
    try outsideBytes.write(to: outsideURL)
    try fileManager.createSymbolicLink(at: annotationURL, withDestinationURL: outsideURL)
    let store = makeStore(layout: layout)

    XCTAssertTrue(store.loadEvents(sessionID: sessionID).isEmpty)
    XCTAssertThrowsError(
      try store.appendRename(
        sessionID: sessionID,
        evidenceContentHash: "hash-a",
        speakerID: "speaker-a",
        displayName: "Maya"
      )
    ) { error in
      XCTAssertEqual(
        error as? LocalSessionSpeakerAnnotationStoreError,
        .unsafeAnnotationFile(annotationURL)
      )
    }
    XCTAssertEqual(try Data(contentsOf: outsideURL), outsideBytes)
  }

  func testAnnotationHardlinkIsRejectedWithoutChangingOutsideBytes() throws {
    let layout = LocalMeetingFileLayout(baseDirectory: tempRoot)
    let sessionID = UUID()
    try layout.ensureDirectories(fileManager: fileManager, for: sessionID)
    let annotationURL = layout.speakerAnnotationsURL(for: sessionID)
    let outsideURL = tempRoot.appendingPathComponent("outside-hardlink.jsonl")
    let outsideBytes = Data("outside hardlink bytes\n".utf8)
    try outsideBytes.write(to: outsideURL)
    XCTAssertEqual(Darwin.link(outsideURL.path, annotationURL.path), 0)
    let store = makeStore(layout: layout)

    XCTAssertTrue(store.loadEvents(sessionID: sessionID).isEmpty)
    XCTAssertThrowsError(
      try store.appendRename(
        sessionID: sessionID,
        evidenceContentHash: "hash-a",
        speakerID: "speaker-a",
        displayName: "Maya"
      )
    ) { error in
      XCTAssertEqual(
        error as? LocalSessionSpeakerAnnotationStoreError,
        .unsafeAnnotationFile(annotationURL)
      )
    }
    XCTAssertEqual(try Data(contentsOf: outsideURL), outsideBytes)
  }

  func testUnsafeSessionLockIsRejectedWithoutChangingOutsideBytes() throws {
    let layout = LocalMeetingFileLayout(baseDirectory: tempRoot)
    let sessionID = UUID()
    try layout.ensureDirectories(fileManager: fileManager, for: sessionID)
    let lockURL = layout.sessionDirectory(for: sessionID)
      .appendingPathComponent(".session.lock", isDirectory: false)
    let outsideURL = tempRoot.appendingPathComponent("outside-lock")
    let outsideBytes = Data("outside lock bytes".utf8)
    try outsideBytes.write(to: outsideURL)
    try fileManager.createSymbolicLink(at: lockURL, withDestinationURL: outsideURL)
    let store = makeStore(layout: layout)

    XCTAssertThrowsError(
      try store.appendRename(
        sessionID: sessionID,
        evidenceContentHash: "hash-a",
        speakerID: "speaker-a",
        displayName: "Maya"
      )
    ) { error in
      XCTAssertEqual(
        error as? LocalSessionSpeakerAnnotationStoreError,
        .unsafeLock(lockURL)
      )
    }
    XCTAssertEqual(try Data(contentsOf: outsideURL), outsideBytes)
    XCTAssertFalse(
      fileManager.fileExists(atPath: layout.speakerAnnotationsURL(for: sessionID).path))
  }

  func testLinkedSessionDirectoryCannotExposeOrModifyOutsideAnnotationTree() throws {
    let layout = LocalMeetingFileLayout(baseDirectory: tempRoot)
    let sessionID = UUID()
    try layout.ensureDirectories(fileManager: fileManager)
    let outsideDirectory = tempRoot.appendingPathComponent("outside-session", isDirectory: true)
    try fileManager.createDirectory(at: outsideDirectory, withIntermediateDirectories: true)
    let event = makeEvent(sessionID: sessionID, speakerID: "speaker-a", displayName: "Outside")
    try annotationBytes(for: [event]).write(
      to: outsideDirectory.appendingPathComponent("speaker-annotations.jsonl"))
    try Data("sentinel".utf8).write(
      to: outsideDirectory.appendingPathComponent("sentinel.txt"))
    try fileManager.createSymbolicLink(
      at: layout.sessionDirectory(for: sessionID),
      withDestinationURL: outsideDirectory
    )
    let before = try snapshot(of: outsideDirectory)
    let store = makeStore(layout: layout)

    XCTAssertTrue(store.loadEvents(sessionID: sessionID).isEmpty)
    XCTAssertThrowsError(
      try store.appendRename(
        sessionID: sessionID,
        evidenceContentHash: "hash-a",
        speakerID: "speaker-a",
        displayName: "Maya"
      )
    )
    XCTAssertEqual(try snapshot(of: outsideDirectory), before)
  }

  func testLinkedRootAncestorCannotExposeOrModifyOutsideAnnotationTree() throws {
    let sessionID = UUID()
    let outsideRoot = tempRoot.appendingPathComponent("outside-root", isDirectory: true)
    let linkedRoot = tempRoot.appendingPathComponent("linked-root", isDirectory: true)
    let outsideBase = outsideRoot.appendingPathComponent("Cepessa", isDirectory: true)
    let layout = LocalMeetingFileLayout(
      baseDirectory: linkedRoot.appendingPathComponent("Cepessa", isDirectory: true)
    )
    let outsideSession = outsideBase.appendingPathComponent("Sessions", isDirectory: true)
      .appendingPathComponent(sessionID.uuidString, isDirectory: true)
    try fileManager.createDirectory(at: outsideSession, withIntermediateDirectories: true)
    let event = makeEvent(sessionID: sessionID, speakerID: "speaker-a", displayName: "Outside")
    try annotationBytes(for: [event]).write(
      to: outsideSession.appendingPathComponent("speaker-annotations.jsonl"))
    try Data("sentinel".utf8).write(to: outsideRoot.appendingPathComponent("sentinel.txt"))
    try fileManager.createSymbolicLink(at: linkedRoot, withDestinationURL: outsideRoot)
    let before = try snapshot(of: outsideRoot)
    let store = makeStore(layout: layout)

    XCTAssertTrue(store.loadEvents(sessionID: sessionID).isEmpty)
    XCTAssertThrowsError(
      try store.appendRename(
        sessionID: sessionID,
        evidenceContentHash: "hash-a",
        speakerID: "speaker-a",
        displayName: "Maya"
      )
    )
    XCTAssertEqual(try snapshot(of: outsideRoot), before)
  }

  func testEvidenceRunTraversalCannotProjectOutsideSpeakerMetadata() throws {
    let layout = LocalMeetingFileLayout(baseDirectory: tempRoot)
    let sessionID = UUID()
    try layout.ensureDirectories(fileManager: fileManager, for: sessionID)
    let evidence = try evidenceEnvelope(sessionID: sessionID, speakerLabel: "Outside Evidence")
    let outsideURL = tempRoot.appendingPathComponent("outside-evidence.json")
    try evidence.data.write(to: outsideURL)
    let outsideBytes = try Data(contentsOf: outsideURL)
    let session = try annotatedSession(
      layout: layout,
      sessionID: sessionID,
      runFileName: "../../../../outside-evidence.json",
      contentHash: evidence.contentHash
    )

    assertEvidenceMetadataWasNotProjected(session, layout: layout)
    XCTAssertEqual(try Data(contentsOf: outsideURL), outsideBytes)
  }

  func testEvidenceRunSymlinkCannotProjectOutsideSpeakerMetadata() throws {
    let layout = LocalMeetingFileLayout(baseDirectory: tempRoot)
    let sessionID = UUID()
    try layout.ensureDirectories(fileManager: fileManager, for: sessionID)
    let evidence = try evidenceEnvelope(sessionID: sessionID, speakerLabel: "Outside Evidence")
    let outsideURL = tempRoot.appendingPathComponent("outside-symlink-evidence.json")
    try evidence.data.write(to: outsideURL)
    let outsideBytes = try Data(contentsOf: outsideURL)
    let runFileName = "run-symlink.json"
    try fileManager.createSymbolicLink(
      at: layout.transcriptionRunsDirectory(for: sessionID)
        .appendingPathComponent(runFileName),
      withDestinationURL: outsideURL
    )
    let session = try annotatedSession(
      layout: layout,
      sessionID: sessionID,
      runFileName: runFileName,
      contentHash: evidence.contentHash
    )

    assertEvidenceMetadataWasNotProjected(session, layout: layout)
    XCTAssertEqual(try Data(contentsOf: outsideURL), outsideBytes)
  }

  func testEvidenceRunHardlinkCannotProjectOutsideSpeakerMetadata() throws {
    let layout = LocalMeetingFileLayout(baseDirectory: tempRoot)
    let sessionID = UUID()
    try layout.ensureDirectories(fileManager: fileManager, for: sessionID)
    let evidence = try evidenceEnvelope(sessionID: sessionID, speakerLabel: "Outside Evidence")
    let outsideURL = tempRoot.appendingPathComponent("outside-hardlink-evidence.json")
    try evidence.data.write(to: outsideURL)
    let outsideBytes = try Data(contentsOf: outsideURL)
    let runFileName = "run-hardlink.json"
    XCTAssertEqual(
      Darwin.link(
        outsideURL.path,
        layout.transcriptionRunsDirectory(for: sessionID)
          .appendingPathComponent(runFileName).path
      ),
      0
    )
    let session = try annotatedSession(
      layout: layout,
      sessionID: sessionID,
      runFileName: runFileName,
      contentHash: evidence.contentHash
    )

    assertEvidenceMetadataWasNotProjected(session, layout: layout)
    XCTAssertEqual(try Data(contentsOf: outsideURL), outsideBytes)
  }

  func testEvidenceRunForAnotherSessionCannotProjectSpeakerMetadata() throws {
    let layout = LocalMeetingFileLayout(baseDirectory: tempRoot)
    let sessionID = UUID()
    try layout.ensureDirectories(fileManager: fileManager, for: sessionID)
    let evidence = try evidenceEnvelope(sessionID: UUID(), speakerLabel: "Wrong Session")
    let runFileName = "wrong-session.json"
    try evidence.data.write(
      to: layout.transcriptionRunsDirectory(for: sessionID)
        .appendingPathComponent(runFileName)
    )
    let session = try annotatedSession(
      layout: layout,
      sessionID: sessionID,
      runFileName: runFileName,
      contentHash: evidence.contentHash
    )

    assertEvidenceMetadataWasNotProjected(session, layout: layout)
  }

  func testRehashedEvidenceRunCannotReplaceSummarySpeakerMetadata() throws {
    let layout = LocalMeetingFileLayout(baseDirectory: tempRoot)
    let sessionID = UUID()
    try layout.ensureDirectories(fileManager: fileManager, for: sessionID)
    let trusted = try evidenceEnvelope(sessionID: sessionID, speakerLabel: "Trusted Evidence")
    let replaced = try evidenceEnvelope(sessionID: sessionID, speakerLabel: "Rehashed Replacement")
    XCTAssertNotEqual(trusted.contentHash, replaced.contentHash)
    let runFileName = "rehashed-mismatch.json"
    try replaced.data.write(
      to: layout.transcriptionRunsDirectory(for: sessionID)
        .appendingPathComponent(runFileName)
    )
    let session = try annotatedSession(
      layout: layout,
      sessionID: sessionID,
      runFileName: runFileName,
      contentHash: trusted.contentHash
    )

    assertEvidenceMetadataWasNotProjected(session, layout: layout)
  }

  func testRehashedEvidenceRunWithDuplicateSpeakerIDsCannotCrashOrProjectMetadata() throws {
    let layout = LocalMeetingFileLayout(baseDirectory: tempRoot)
    let sessionID = UUID()
    try layout.ensureDirectories(fileManager: fileManager, for: sessionID)
    let evidence = try evidenceEnvelope(
      sessionID: sessionID,
      speakerLabels: ["First Duplicate", "Second Duplicate"]
    )
    let runFileName = "duplicate-speakers.json"
    try evidence.data.write(
      to: layout.transcriptionRunsDirectory(for: sessionID)
        .appendingPathComponent(runFileName)
    )
    let session = try annotatedSession(
      layout: layout,
      sessionID: sessionID,
      runFileName: runFileName,
      contentHash: evidence.contentHash
    )

    assertEvidenceMetadataWasNotProjected(session, layout: layout)
  }

  func testValidEvidenceRunRestoresItsSpeakerMetadata() throws {
    let layout = LocalMeetingFileLayout(baseDirectory: tempRoot)
    let sessionID = UUID()
    try layout.ensureDirectories(fileManager: fileManager, for: sessionID)
    let evidence = try evidenceEnvelope(sessionID: sessionID, speakerLabel: "Evidence Speaker")
    let runFileName = "valid-run.json"
    try evidence.data.write(
      to: layout.transcriptionRunsDirectory(for: sessionID)
        .appendingPathComponent(runFileName)
    )
    let session = try annotatedSession(
      layout: layout,
      sessionID: sessionID,
      runFileName: runFileName,
      contentHash: evidence.contentHash
    )

    let base = makeStore(layout: layout).removingAnnotationProjection(from: session)
    XCTAssertEqual(base.transcriptSegments.first?.speaker, "Evidence Speaker")
    XCTAssertEqual(base.transcriptSegments.first?.identityStatus, .anonymous)
  }

  func testLoadEventsRejectsEventsForAnotherSession() throws {
    let layout = LocalMeetingFileLayout(baseDirectory: tempRoot)
    let sessionID = UUID()
    let otherSessionID = UUID()
    try layout.ensureDirectories(fileManager: fileManager, for: sessionID)
    let expected = makeEvent(sessionID: sessionID, speakerID: "speaker-a", displayName: "Maya")
    let unexpected = makeEvent(
      sessionID: otherSessionID,
      speakerID: "speaker-b",
      displayName: "Outside"
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    var bytes = try encoder.encode(expected)
    bytes.append(0x0A)
    bytes.append(try encoder.encode(unexpected))
    bytes.append(0x0A)
    try bytes.write(to: layout.speakerAnnotationsURL(for: sessionID))
    let store = makeStore(layout: layout)

    XCTAssertEqual(store.loadEvents(sessionID: sessionID), [expected])
    XCTAssertEqual(
      store.resolvedNames(sessionID: sessionID, evidenceContentHash: "hash-a"),
      ["speaker-a": "Maya"]
    )
  }

  private func makeStore(
    layout: LocalMeetingFileLayout
  ) -> LocalSessionSpeakerAnnotationStore {
    LocalSessionSpeakerAnnotationStore(
      fileLayout: layout,
      fileManager: fileManager,
      now: { Date(timeIntervalSince1970: 1_800_000_000) }
    )
  }

  private func annotatedSession(
    layout: LocalMeetingFileLayout,
    sessionID: UUID,
    runFileName: String,
    contentHash: String
  ) throws -> LocalSession {
    let store = makeStore(layout: layout)
    try store.appendRename(
      sessionID: sessionID,
      evidenceContentHash: contentHash,
      speakerID: "speaker-a",
      displayName: "Maya"
    )
    return LocalSession(
      id: sessionID,
      title: "Evidence safety",
      startedAt: Date(timeIntervalSince1970: 1_800_000_000),
      status: .ready,
      transcriptSegments: [
        .init(
          id: UUID(),
          speaker: "Maya",
          text: "Recorded words",
          timestamp: Date(timeIntervalSince1970: 1_800_000_001),
          speakerID: "speaker-a",
          source: .system,
          identityStatus: .confirmed
        )
      ],
      audioArtifacts: .empty,
      transcriptionEvidence: .init(
        runID: "run-1",
        revision: 1,
        disposition: .ready,
        contentHash: contentHash,
        parentContentHash: nil,
        runFileName: runFileName,
        outboxFileName: "outbox.json",
        issues: []
      )
    )
  }

  private func assertEvidenceMetadataWasNotProjected(
    _ session: LocalSession,
    layout: LocalMeetingFileLayout,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    let base = makeStore(layout: layout).removingAnnotationProjection(from: session)
    XCTAssertEqual(base.transcriptSegments.first?.speaker, "Speaker 1", file: file, line: line)
    XCTAssertEqual(
      base.transcriptSegments.first?.identityStatus, .unavailable, file: file, line: line)
  }

  private func evidenceEnvelope(
    sessionID: UUID,
    speakerLabel: String
  ) throws -> (data: Data, contentHash: String) {
    try evidenceEnvelope(sessionID: sessionID, speakerLabels: [speakerLabel])
  }

  private func evidenceEnvelope(
    sessionID: UUID,
    speakerLabels: [String]
  ) throws -> (data: Data, contentHash: String) {
    let timestamp = Date(timeIntervalSince1970: 1_800_000_000)
    let evidenceSession = MeetingEvidenceSessionV1(
      id: sessionID.uuidString.lowercased(),
      title: "Evidence safety",
      startedAt: timestamp,
      status: .ready
    )
    let run = LocalSessionEvidenceRunV1(
      id: "run-1",
      createdAt: timestamp,
      completedAt: timestamp,
      disposition: .ready,
      engine: .whisperKit,
      model: .init(identifier: "test-model", modelBasename: nil),
      requestedLanguage: "en",
      detectedLanguages: ["en"],
      diarizationStatus: .available,
      issues: []
    )
    let speakers = speakerLabels.map { speakerLabel in
      LocalSessionEvidenceSpeakerV1(
        id: "speaker-a",
        label: speakerLabel,
        kind: "remote",
        identityStatus: .anonymous,
        confidence: 0.9
      )
    }
    let transcript = MeetingEvidenceTranscriptV1(renderedText: "", byteOffsets: [])
    let quality = MeetingEvidenceQualityV1(
      isComplete: true,
      speechCoverage: 1,
      hasVerifiableTimestamps: true,
      sourceSeparationPreserved: true,
      diarization: LocalSessionDiarizationStatus.available.rawValue,
      issues: []
    )
    let payload = MeetingEvidenceHashPayloadV1(
      schemaVersion: "meeting-evidence/v1",
      evidenceID: "meeting:\(sessionID.uuidString.lowercased()):run:run-1",
      sourceRef: "cepessa-session://\(sessionID.uuidString.lowercased())/transcript",
      revision: 1,
      parentContentHash: nil,
      session: evidenceSession,
      run: run,
      sources: [],
      speakers: speakers,
      segments: [],
      transcript: transcript,
      quality: quality
    )
    let contentHash = try MeetingEvidenceCanonicalizer.contentHash(payload: payload)
    let envelope = MeetingEvidenceEnvelopeV1(
      schemaVersion: payload.schemaVersion,
      evidenceID: payload.evidenceID,
      sourceRef: payload.sourceRef,
      revision: payload.revision,
      parentContentHash: payload.parentContentHash,
      contentHash: contentHash,
      session: evidenceSession,
      run: run,
      sources: [],
      speakers: speakers,
      segments: [],
      transcript: transcript,
      quality: quality
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    return (try encoder.encode(envelope), contentHash)
  }

  private func makeEvent(
    sessionID: UUID,
    speakerID: String,
    displayName: String
  ) -> LocalSessionSpeakerAnnotationEvent {
    LocalSessionSpeakerAnnotationEvent(
      id: UUID(),
      createdAt: Date(timeIntervalSince1970: 1_800_000_000),
      sessionID: sessionID,
      evidenceContentHash: "hash-a",
      speakerID: speakerID,
      action: .rename,
      displayName: displayName,
      targetEventID: nil
    )
  }

  private func annotationBytes(
    for events: [LocalSessionSpeakerAnnotationEvent]
  ) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    var data = Data()
    for event in events {
      data.append(try encoder.encode(event))
      data.append(0x0A)
    }
    return data
  }

  private func snapshot(of directory: URL) throws -> DirectorySnapshot {
    let subpaths = try fileManager.subpathsOfDirectory(atPath: directory.path).sorted()
    var fileBytes: [String: Data] = [:]
    for subpath in subpaths {
      let url = directory.appendingPathComponent(subpath)
      var isDirectory: ObjCBool = false
      guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
        !isDirectory.boolValue
      else { continue }
      fileBytes[subpath] = try Data(contentsOf: url)
    }
    return DirectorySnapshot(subpaths: subpaths, fileBytes: fileBytes)
  }
}
