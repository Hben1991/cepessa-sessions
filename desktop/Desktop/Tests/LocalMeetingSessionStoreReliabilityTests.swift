import Darwin
import Foundation
import XCTest

@testable import CepessaSessions

final class LocalMeetingSessionStoreReliabilityTests: XCTestCase {
  private var rootURL: URL!
  private let fileManager = FileManager.default

  override func setUpWithError() throws {
    rootURL = fileManager.temporaryDirectory
      .appendingPathComponent(
        "LocalMeetingSessionStoreReliability-\(UUID().uuidString)", isDirectory: true)
    try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    if let rootURL {
      try? fileManager.removeItem(at: rootURL)
    }
  }

  func testMergePreservesDifferentRemoteTopLevelChanges() throws {
    let layout = LocalSessionFileLayout(
      baseDirectory: rootURL.appendingPathComponent("Cepessa", isDirectory: true))
    let store = LocalMeetingSessionStore(fileLayout: layout)
    let base = makeSession()
    try store.save(base)

    var remote = base
    remote.title = "Remote title"
    _ = try store.save(remote)

    var local = base
    local.documentMarkdown = "Local document"
    let saved = try store.save(local, mergingChangesFrom: base)

    XCTAssertEqual(saved.title, "Remote title")
    XCTAssertEqual(saved.documentMarkdown, "Local document")
    XCTAssertEqual(store.loadSession(id: base.id)?.title, "Remote title")
  }

  func testMergeRaisesExplicitConflictForSameTopLevelField() throws {
    let layout = LocalSessionFileLayout(
      baseDirectory: rootURL.appendingPathComponent("Cepessa", isDirectory: true))
    let store = LocalMeetingSessionStore(fileLayout: layout)
    let base = makeSession()
    try store.save(base)

    var remote = base
    remote.title = "Remote title"
    _ = try store.save(remote)
    let packageURL = layout.promptPackageJSONURL(for: base.id)
    let packageBeforeConflict = try Data(contentsOf: packageURL)

    var local = base
    local.title = "Local title"
    XCTAssertThrowsError(try store.save(local, mergingChangesFrom: base)) { error in
      guard case LocalSessionStoreError.editConflict(let fields) = error else {
        return XCTFail("Expected an edit conflict, got \(error)")
      }
      XCTAssertTrue(fields.contains("title"))
    }
    XCTAssertEqual(store.loadSession(id: base.id)?.title, "Remote title")
    XCTAssertEqual(try Data(contentsOf: packageURL), packageBeforeConflict)
  }

  func testMergePreservesUnknownCurrentTopLevelFields() throws {
    let layout = LocalSessionFileLayout(
      baseDirectory: rootURL.appendingPathComponent("Cepessa", isDirectory: true))
    let store = LocalMeetingSessionStore(fileLayout: layout)
    let base = makeSession()
    try store.save(base)

    let metadataURL = layout.metadataURL(for: base.id)
    var object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: metadataURL)) as? [String: Any]
    )
    object["futureExtension"] = ["enabled": true, "payload": ["keep", 2]]
    try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
      .write(to: metadataURL, options: .atomic)

    var local = base
    local.documentMarkdown = "Local document"
    _ = try store.save(local, mergingChangesFrom: base)

    let mergedObject = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: metadataURL)) as? [String: Any]
    )
    XCTAssertEqual((mergedObject["futureExtension"] as? [String: Any])?["enabled"] as? Bool, true)
    let payload = try XCTUnwrap((mergedObject["futureExtension"] as? [String: Any])?["payload"])
    XCTAssertEqual(
      try JSONSerialization.data(
        withJSONObject: payload, options: [.sortedKeys, .fragmentsAllowed]),
      Data("[\"keep\",2]".utf8)
    )
  }

  func testLoadRepairsGeneratedPackagesFromLatestMetadata() throws {
    let layout = LocalSessionFileLayout(
      baseDirectory: rootURL.appendingPathComponent("Cepessa", isDirectory: true))
    let store = LocalMeetingSessionStore(fileLayout: layout)
    let base = makeSession()
    try store.save(base)

    let markdownURL = layout.promptPackageMarkdownURL(for: base.id)
    let jsonURL = layout.promptPackageJSONURL(for: base.id)
    try Data("stale markdown".utf8).write(to: markdownURL)
    try Data("stale json".utf8).write(to: jsonURL)

    var latest = base
    latest.title = "Latest metadata"
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(latest).write(to: layout.metadataURL(for: base.id), options: .atomic)

    let loaded = try XCTUnwrap(store.loadSessions().first { $0.id == base.id })
    XCTAssertEqual(loaded.title, "Latest metadata")
    let markdown = try String(contentsOf: markdownURL, encoding: .utf8)
    let packageJSON = try String(contentsOf: jsonURL, encoding: .utf8)
    XCTAssertTrue(markdown.contains("Latest metadata"))
    XCTAssertTrue(packageJSON.contains("Latest metadata"))
    XCTAssertFalse(markdown.contains("stale markdown"))
    XCTAssertFalse(packageJSON.contains("stale json"))
  }

  func testLoadKeepsSessionWhenGeneratedPackageRepairFails() throws {
    let layout = LocalSessionFileLayout(
      baseDirectory: rootURL.appendingPathComponent("Cepessa", isDirectory: true))
    let store = LocalMeetingSessionStore(fileLayout: layout)
    let base = makeSession()
    try store.save(base)

    let exportsDirectory = layout.exportsDirectory(for: base.id)
    try fileManager.removeItem(at: exportsDirectory)
    try Data("unavailable".utf8).write(to: exportsDirectory)

    let loaded = try XCTUnwrap(store.loadSessions().first { $0.id == base.id })
    XCTAssertEqual(loaded, base)
    XCTAssertTrue(
      store.loadWarnings.contains {
        $0.contains("generated package could not be refreshed")
      }
    )
  }

  func testBulkLoadSkipsUnsafeAndMismatchedEntriesWithoutTouchingHealthySibling() throws {
    let layout = LocalSessionFileLayout(
      baseDirectory: rootURL.appendingPathComponent("Cepessa", isDirectory: true))
    let store = LocalMeetingSessionStore(fileLayout: layout)
    let healthy = makeSession()
    try store.save(healthy)

    let sessionsDirectory = layout.sessionsDirectory
    let symlinkEntryID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    let symlinkTargetID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    let symlinkTargetDirectory = rootURL.appendingPathComponent(
      "outside-symlink", isDirectory: true)
    try fileManager.createDirectory(at: symlinkTargetDirectory, withIntermediateDirectories: true)
    let symlinkTargetMetadata = symlinkTargetDirectory.appendingPathComponent(
      "session.json", isDirectory: false)
    try encodedSessionData(makeSession(id: symlinkTargetID)).write(to: symlinkTargetMetadata)
    let symlinkEntry = sessionsDirectory.appendingPathComponent(
      symlinkEntryID.uuidString, isDirectory: true)
    try fileManager.createSymbolicLink(at: symlinkEntry, withDestinationURL: symlinkTargetDirectory)

    let hardlinkEntryID = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
    let hardlinkTargetID = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!
    let hardlinkTargetMetadata = rootURL.appendingPathComponent(
      "outside-hardlink.json", isDirectory: false)
    try encodedSessionData(makeSession(id: hardlinkTargetID)).write(to: hardlinkTargetMetadata)
    let hardlinkDirectory = sessionsDirectory.appendingPathComponent(
      hardlinkEntryID.uuidString, isDirectory: true)
    try fileManager.createDirectory(at: hardlinkDirectory, withIntermediateDirectories: true)
    let hardlinkEntryMetadata = hardlinkDirectory.appendingPathComponent(
      "session.json", isDirectory: false)
    XCTAssertEqual(Darwin.link(hardlinkTargetMetadata.path, hardlinkEntryMetadata.path), 0)

    let mismatchedEntryID = UUID(uuidString: "55555555-5555-4555-8555-555555555555")!
    let mismatchedPayloadID = UUID(uuidString: "66666666-6666-4666-8666-666666666666")!
    let mismatchedDirectory = sessionsDirectory.appendingPathComponent(
      mismatchedEntryID.uuidString, isDirectory: true)
    try fileManager.createDirectory(at: mismatchedDirectory, withIntermediateDirectories: true)
    let mismatchedMetadata = mismatchedDirectory.appendingPathComponent(
      "session.json", isDirectory: false)
    try encodedSessionData(makeSession(id: mismatchedPayloadID)).write(to: mismatchedMetadata)

    let manifestSymlinkEntryID = UUID(uuidString: "77777777-7777-4777-8777-777777777777")!
    let manifestSymlinkDirectory = sessionsDirectory.appendingPathComponent(
      manifestSymlinkEntryID.uuidString, isDirectory: true)
    try fileManager.createDirectory(at: manifestSymlinkDirectory, withIntermediateDirectories: true)
    let manifestSymlinkMetadata = manifestSymlinkDirectory.appendingPathComponent(
      "session.json", isDirectory: false)
    try fileManager.createSymbolicLink(
      at: manifestSymlinkMetadata, withDestinationURL: symlinkTargetMetadata)

    let symlinkTargetBefore = try Data(contentsOf: symlinkTargetMetadata)
    let hardlinkTargetBefore = try Data(contentsOf: hardlinkTargetMetadata)
    let mismatchedBefore = try Data(contentsOf: mismatchedMetadata)

    let loaded = store.loadSessions()

    XCTAssertEqual(loaded.map(\.id), [healthy.id])
    XCTAssertEqual(try Data(contentsOf: symlinkTargetMetadata), symlinkTargetBefore)
    XCTAssertEqual(try Data(contentsOf: hardlinkTargetMetadata), hardlinkTargetBefore)
    XCTAssertEqual(try Data(contentsOf: mismatchedMetadata), mismatchedBefore)
  }

  func testSaveAndSingleLoadRejectSymlinkedSessionWithoutTouchingOutsideTree() throws {
    let layout = LocalSessionFileLayout(
      baseDirectory: rootURL.appendingPathComponent("Cepessa", isDirectory: true))
    let store = LocalMeetingSessionStore(fileLayout: layout)
    try layout.ensureDirectories(fileManager: fileManager)

    let session = makeSession()
    let outsideDirectory = rootURL.appendingPathComponent("outside-session", isDirectory: true)
    try fileManager.createDirectory(at: outsideDirectory, withIntermediateDirectories: true)
    let outsideMetadata = outsideDirectory.appendingPathComponent(
      "session.json", isDirectory: false)
    try encodedSessionData(session).write(to: outsideMetadata)
    let outsideBefore = try Data(contentsOf: outsideMetadata)
    let sessionDirectory = layout.sessionDirectory(for: session.id)
    try fileManager.createSymbolicLink(at: sessionDirectory, withDestinationURL: outsideDirectory)

    XCTAssertThrowsError(try store.save(session))
    XCTAssertNil(store.loadSession(id: session.id))
    XCTAssertEqual(try Data(contentsOf: outsideMetadata), outsideBefore)
    XCTAssertFalse(
      fileManager.fileExists(
        atPath: outsideDirectory.appendingPathComponent("Attachments", isDirectory: true).path))
    XCTAssertFalse(
      fileManager.fileExists(
        atPath: outsideDirectory.appendingPathComponent("Exports", isDirectory: true).path))
    XCTAssertFalse(
      fileManager.fileExists(
        atPath: outsideDirectory.appendingPathComponent("TranscriptionEvidence", isDirectory: true)
          .path))
  }

  func testSaveRejectsSymlinkedSessionsRootWithoutTouchingOutsideTree() throws {
    let layout = LocalSessionFileLayout(
      baseDirectory: rootURL.appendingPathComponent("Cepessa", isDirectory: true))
    let store = LocalMeetingSessionStore(fileLayout: layout)
    try fileManager.createDirectory(at: layout.baseDirectory, withIntermediateDirectories: true)

    let session = makeSession()
    let outsideDirectory = rootURL.appendingPathComponent("outside-sessions", isDirectory: true)
    try fileManager.createDirectory(at: outsideDirectory, withIntermediateDirectories: true)
    let outsideSessionDirectory = outsideDirectory.appendingPathComponent(
      session.id.uuidString, isDirectory: true)
    try fileManager.createDirectory(at: outsideSessionDirectory, withIntermediateDirectories: true)
    try encodedSessionData(session).write(
      to: outsideSessionDirectory.appendingPathComponent("session.json", isDirectory: false))
    let marker = outsideDirectory.appendingPathComponent("marker.txt", isDirectory: false)
    try Data("outside".utf8).write(to: marker)
    let outsideBefore = try fileManager.subpathsOfDirectory(atPath: outsideDirectory.path)
    try fileManager.createSymbolicLink(
      at: layout.sessionsDirectory, withDestinationURL: outsideDirectory)

    XCTAssertThrowsError(try store.save(session))
    XCTAssertNil(store.loadSession(id: session.id))
    XCTAssertEqual(
      try fileManager.subpathsOfDirectory(atPath: outsideDirectory.path), outsideBefore)
    XCTAssertEqual(try Data(contentsOf: marker), Data("outside".utf8))
  }

  func testSaveRejectsSymlinkedManagedDirectoryBeforeDescendantWrites() throws {
    let layout = LocalSessionFileLayout(
      baseDirectory: rootURL.appendingPathComponent("Cepessa", isDirectory: true))
    let store = LocalMeetingSessionStore(fileLayout: layout)
    try layout.ensureDirectories(fileManager: fileManager)

    let sessionIDs = [
      UUID(uuidString: "77777777-7777-4777-8777-777777777777")!,
      UUID(uuidString: "88888888-8888-4888-8888-888888888888")!,
      UUID(uuidString: "99999999-9999-4999-8999-999999999999")!,
    ]
    let managedDirectories: [(UUID) -> URL] = [
      layout.attachmentsDirectory(for:),
      layout.exportsDirectory(for:),
      layout.transcriptionEvidenceDirectory(for:),
    ]

    for (index, sessionID) in sessionIDs.enumerated() {
      let sessionDirectory = layout.sessionDirectory(for: sessionID)
      try fileManager.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
      let outsideDirectory = rootURL.appendingPathComponent(
        "outside-managed-\(index)", isDirectory: true)
      try fileManager.createDirectory(at: outsideDirectory, withIntermediateDirectories: true)
      let marker = outsideDirectory.appendingPathComponent("marker.txt", isDirectory: false)
      try Data("outside".utf8).write(to: marker)
      let outsideBefore = try fileManager.subpathsOfDirectory(atPath: outsideDirectory.path)
      let managedDirectory = managedDirectories[index](sessionID)
      try fileManager.createSymbolicLink(at: managedDirectory, withDestinationURL: outsideDirectory)

      XCTAssertThrowsError(try store.save(makeSession(id: sessionID)))
      XCTAssertEqual(
        try fileManager.subpathsOfDirectory(atPath: outsideDirectory.path), outsideBefore)
      XCTAssertEqual(try Data(contentsOf: marker), Data("outside".utf8))
    }
  }

  func testValidatedAudioURLRejectsSymlinkAndHardlinkWithoutReadingOutside() throws {
    let layout = LocalSessionFileLayout(
      baseDirectory: rootURL.appendingPathComponent("Cepessa", isDirectory: true))
    let sessionID = UUID(uuidString: "A1B2C3D4-E5F6-4789-ABCD-001122334455")!
    try layout.ensureDirectories(fileManager: fileManager, for: sessionID)

    let outsideURL = rootURL.appendingPathComponent("outside-audio.wav", isDirectory: false)
    let outsideData = validWaveData()
    try outsideData.write(to: outsideURL)
    let importedURL = layout.importedAudioURL(for: sessionID)
    let artifacts = LocalSessionAudioArtifacts(
      micFileName: nil,
      systemFileName: nil,
      mixedFileName: nil,
      importedFileName: "imported.wav"
    )

    try fileManager.createSymbolicLink(at: importedURL, withDestinationURL: outsideURL)
    XCTAssertNil(layout.validatedAudioURL(for: importedURL, fileManager: fileManager))
    XCTAssertNil(
      layout.existingAudioURL(for: sessionID, artifacts: artifacts, fileManager: fileManager))
    XCTAssertEqual(try Data(contentsOf: outsideURL), outsideData)

    try fileManager.removeItem(at: importedURL)
    XCTAssertEqual(Darwin.link(outsideURL.path, importedURL.path), 0)
    XCTAssertNil(layout.validatedAudioURL(for: importedURL, fileManager: fileManager))
    XCTAssertNil(
      layout.existingAudioURL(for: sessionID, artifacts: artifacts, fileManager: fileManager))
    XCTAssertEqual(try Data(contentsOf: outsideURL), outsideData)

    let safeMalformedURL = layout.sessionDirectory(for: sessionID)
      .appendingPathComponent("malformed.wav", isDirectory: false)
    try Data("not a wave".utf8).write(to: safeMalformedURL)
    XCTAssertTrue(layout.isSafeDirectSessionAudioFile(safeMalformedURL, fileManager: fileManager))
    XCTAssertNil(layout.validatedAudioURL(for: safeMalformedURL, fileManager: fileManager))
  }

  func testValidatedAudioURLRejectsLinkedSessionAndSessionsRoot() throws {
    let layout = LocalSessionFileLayout(
      baseDirectory: rootURL.appendingPathComponent("SessionLink", isDirectory: true))
    let sessionID = UUID(uuidString: "B1C2D3E4-F5A6-4789-ABCD-001122334455")!
    try layout.ensureDirectories(fileManager: fileManager, for: sessionID)

    let outsideSessionDirectory = rootURL.appendingPathComponent(
      "outside-linked-session", isDirectory: true)
    try fileManager.createDirectory(at: outsideSessionDirectory, withIntermediateDirectories: true)
    let outsideAudioURL = outsideSessionDirectory.appendingPathComponent(
      "imported.wav", isDirectory: false)
    let outsideAudioData = validWaveData()
    try outsideAudioData.write(to: outsideAudioURL)
    let outsideBefore = try Data(contentsOf: outsideAudioURL)
    let sessionDirectory = layout.sessionDirectory(for: sessionID)
    let redirectURL = sessionDirectory.appendingPathComponent("redirect", isDirectory: true)
    try fileManager.createSymbolicLink(at: redirectURL, withDestinationURL: outsideSessionDirectory)
    let traversedURL =
      redirectURL
      .appendingPathComponent("..", isDirectory: true)
      .appendingPathComponent("imported.wav", isDirectory: false)
    XCTAssertNil(layout.validatedAudioURL(for: traversedURL, fileManager: fileManager))
    try fileManager.removeItem(at: redirectURL)
    try fileManager.removeItem(at: sessionDirectory)
    try fileManager.createSymbolicLink(
      at: sessionDirectory, withDestinationURL: outsideSessionDirectory)

    let linkedSessionAudioURL = layout.importedAudioURL(for: sessionID)
    XCTAssertNil(layout.validatedAudioURL(for: linkedSessionAudioURL, fileManager: fileManager))
    XCTAssertNil(
      layout.existingAudioURL(
        for: sessionID,
        artifacts: .init(
          micFileName: nil,
          systemFileName: nil,
          mixedFileName: nil,
          importedFileName: "imported.wav"
        ),
        fileManager: fileManager
      )
    )
    XCTAssertEqual(try Data(contentsOf: outsideAudioURL), outsideBefore)

    let rootLinkedLayout = LocalSessionFileLayout(
      baseDirectory: rootURL.appendingPathComponent("SessionsRootLink", isDirectory: true))
    try rootLinkedLayout.ensureDirectories(fileManager: fileManager)
    let outsideSessionsDirectory = rootURL.appendingPathComponent(
      "outside-linked-sessions", isDirectory: true)
    try fileManager.createDirectory(at: outsideSessionsDirectory, withIntermediateDirectories: true)
    let outsideRootSessionDirectory = outsideSessionsDirectory.appendingPathComponent(
      sessionID.uuidString, isDirectory: true)
    try fileManager.createDirectory(
      at: outsideRootSessionDirectory, withIntermediateDirectories: true)
    let outsideRootAudioURL = outsideRootSessionDirectory.appendingPathComponent(
      "imported.wav", isDirectory: false)
    try outsideAudioData.write(to: outsideRootAudioURL)
    let outsideRootBefore = try Data(contentsOf: outsideRootAudioURL)
    try fileManager.removeItem(at: rootLinkedLayout.sessionsDirectory)
    try fileManager.createSymbolicLink(
      at: rootLinkedLayout.sessionsDirectory, withDestinationURL: outsideSessionsDirectory)

    let linkedRootAudioURL = rootLinkedLayout.importedAudioURL(for: sessionID)
    XCTAssertNil(
      rootLinkedLayout.validatedAudioURL(for: linkedRootAudioURL, fileManager: fileManager))
    XCTAssertNil(
      rootLinkedLayout.existingAudioURL(
        for: sessionID,
        artifacts: .init(
          micFileName: nil,
          systemFileName: nil,
          mixedFileName: nil,
          importedFileName: "imported.wav"
        ),
        fileManager: fileManager
      )
    )
    XCTAssertEqual(try Data(contentsOf: outsideRootAudioURL), outsideRootBefore)
  }

  func testBaselineMergePromotesLegacySessionIntoCurrentSessions() throws {
    let layout = LocalSessionFileLayout(
      baseDirectory: rootURL.appendingPathComponent("Cepessa", isDirectory: true))
    let store = LocalMeetingSessionStore(fileLayout: layout)
    let base = makeSession()
    try store.save(base)

    let currentDirectory = layout.sessionDirectory(for: base.id)
    let legacyDirectory = layout.legacySessionDirectory(for: base.id)
    try fileManager.createDirectory(
      at: legacyDirectory.deletingLastPathComponent(), withIntermediateDirectories: true)
    try fileManager.moveItem(at: currentDirectory, to: legacyDirectory)

    var local = base
    local.documentMarkdown = "Promoted document"
    let saved = try store.save(local, mergingChangesFrom: base)

    XCTAssertEqual(saved.documentMarkdown, "Promoted document")
    XCTAssertTrue(fileManager.fileExists(atPath: layout.metadataURL(for: base.id).path))
    XCTAssertEqual(store.loadSession(id: base.id)?.documentMarkdown, "Promoted document")
  }

  func testSessionLockIsCreatedAndRejectsSymlinkAndHardlink() throws {
    let layout = LocalSessionFileLayout(
      baseDirectory: rootURL.appendingPathComponent("Cepessa", isDirectory: true))
    let store = LocalMeetingSessionStore(fileLayout: layout)
    let session = makeSession()
    try store.save(session)
    let lockURL = layout.sessionDirectory(for: session.id)
      .appendingPathComponent(".session.lock", isDirectory: false)
    XCTAssertTrue(fileManager.fileExists(atPath: lockURL.path))

    let outsideURL = rootURL.appendingPathComponent("outside-lock", isDirectory: false)
    try Data("outside".utf8).write(to: outsideURL)
    try fileManager.removeItem(at: lockURL)
    try fileManager.createSymbolicLink(at: lockURL, withDestinationURL: outsideURL)
    XCTAssertThrowsError(try store.save(session)) { error in
      guard case LocalSessionStoreError.unsafeLock = error else {
        return XCTFail("Expected unsafe symlink lock error, got \(error)")
      }
    }

    try fileManager.removeItem(at: lockURL)
    XCTAssertEqual(Darwin.link(outsideURL.path, lockURL.path), 0)
    XCTAssertThrowsError(try store.save(session)) { error in
      guard case LocalSessionStoreError.unsafeLock = error else {
        return XCTFail("Expected unsafe hardlink lock error, got \(error)")
      }
    }
  }

  private func makeSession(
    id: UUID = UUID(uuidString: "B0C1D2E3-F4A5-46B7-88C9-001122334455")!
  ) -> LocalSession {
    let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
    return LocalSession(
      id: id,
      title: "Base title",
      startedAt: startedAt,
      status: .ready,
      transcriptSegments: [
        .init(
          id: UUID(uuidString: "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE")!,
          speaker: "Speaker",
          text: "The baseline transcript",
          timestamp: startedAt.addingTimeInterval(1)
        )
      ],
      audioArtifacts: .empty
    )
  }

  private func encodedSessionData(_ session: LocalSession) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    return try encoder.encode(session)
  }

  private func validWaveData() -> Data {
    var data = Data("RIFF".utf8)
    appendLittleEndian(UInt32(40), to: &data)
    data.append(contentsOf: Data("WAVE".utf8))
    data.append(contentsOf: Data("fmt ".utf8))
    appendLittleEndian(UInt32(16), to: &data)
    appendLittleEndian(UInt16(1), to: &data)
    appendLittleEndian(UInt16(1), to: &data)
    appendLittleEndian(UInt32(16_000), to: &data)
    appendLittleEndian(UInt32(32_000), to: &data)
    appendLittleEndian(UInt16(2), to: &data)
    appendLittleEndian(UInt16(16), to: &data)
    data.append(contentsOf: Data("data".utf8))
    appendLittleEndian(UInt32(4), to: &data)
    data.append(contentsOf: [0, 0, 0, 0])
    return data
  }

  private func appendLittleEndian(_ value: UInt16, to data: inout Data) {
    data.append(UInt8(value & 0xFF))
    data.append(UInt8((value >> 8) & 0xFF))
  }

  private func appendLittleEndian(_ value: UInt32, to data: inout Data) {
    data.append(UInt8(value & 0xFF))
    data.append(UInt8((value >> 8) & 0xFF))
    data.append(UInt8((value >> 16) & 0xFF))
    data.append(UInt8((value >> 24) & 0xFF))
  }
}
