import Darwin
import Foundation
import XCTest
@testable import CepessaSessions

final class LocalMeetingSessionStoreReliabilityTests: XCTestCase {
  private var rootURL: URL!
  private let fileManager = FileManager.default

  override func setUpWithError() throws {
    rootURL = fileManager.temporaryDirectory
      .appendingPathComponent("LocalMeetingSessionStoreReliability-\(UUID().uuidString)", isDirectory: true)
    try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    if let rootURL {
      try? fileManager.removeItem(at: rootURL)
    }
  }

  func testMergePreservesDifferentRemoteTopLevelChanges() throws {
    let layout = LocalSessionFileLayout(baseDirectory: rootURL.appendingPathComponent("Cepessa", isDirectory: true))
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
    let layout = LocalSessionFileLayout(baseDirectory: rootURL.appendingPathComponent("Cepessa", isDirectory: true))
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
    let layout = LocalSessionFileLayout(baseDirectory: rootURL.appendingPathComponent("Cepessa", isDirectory: true))
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
      try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .fragmentsAllowed]),
      Data("[\"keep\",2]".utf8)
    )
  }

  func testLoadRepairsGeneratedPackagesFromLatestMetadata() throws {
    let layout = LocalSessionFileLayout(baseDirectory: rootURL.appendingPathComponent("Cepessa", isDirectory: true))
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
    let layout = LocalSessionFileLayout(baseDirectory: rootURL.appendingPathComponent("Cepessa", isDirectory: true))
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
    let layout = LocalSessionFileLayout(baseDirectory: rootURL.appendingPathComponent("Cepessa", isDirectory: true))
    let store = LocalMeetingSessionStore(fileLayout: layout)
    let healthy = makeSession()
    try store.save(healthy)

    let sessionsDirectory = layout.sessionsDirectory
    let symlinkEntryID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    let symlinkTargetID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    let symlinkTargetDirectory = rootURL.appendingPathComponent("outside-symlink", isDirectory: true)
    try fileManager.createDirectory(at: symlinkTargetDirectory, withIntermediateDirectories: true)
    let symlinkTargetMetadata = symlinkTargetDirectory.appendingPathComponent("session.json", isDirectory: false)
    try encodedSessionData(makeSession(id: symlinkTargetID)).write(to: symlinkTargetMetadata)
    let symlinkEntry = sessionsDirectory.appendingPathComponent(symlinkEntryID.uuidString, isDirectory: true)
    try fileManager.createSymbolicLink(at: symlinkEntry, withDestinationURL: symlinkTargetDirectory)

    let hardlinkEntryID = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
    let hardlinkTargetID = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!
    let hardlinkTargetMetadata = rootURL.appendingPathComponent("outside-hardlink.json", isDirectory: false)
    try encodedSessionData(makeSession(id: hardlinkTargetID)).write(to: hardlinkTargetMetadata)
    let hardlinkDirectory = sessionsDirectory.appendingPathComponent(hardlinkEntryID.uuidString, isDirectory: true)
    try fileManager.createDirectory(at: hardlinkDirectory, withIntermediateDirectories: true)
    let hardlinkEntryMetadata = hardlinkDirectory.appendingPathComponent("session.json", isDirectory: false)
    XCTAssertEqual(Darwin.link(hardlinkTargetMetadata.path, hardlinkEntryMetadata.path), 0)

    let mismatchedEntryID = UUID(uuidString: "55555555-5555-4555-8555-555555555555")!
    let mismatchedPayloadID = UUID(uuidString: "66666666-6666-4666-8666-666666666666")!
    let mismatchedDirectory = sessionsDirectory.appendingPathComponent(mismatchedEntryID.uuidString, isDirectory: true)
    try fileManager.createDirectory(at: mismatchedDirectory, withIntermediateDirectories: true)
    let mismatchedMetadata = mismatchedDirectory.appendingPathComponent("session.json", isDirectory: false)
    try encodedSessionData(makeSession(id: mismatchedPayloadID)).write(to: mismatchedMetadata)

    let symlinkTargetBefore = try Data(contentsOf: symlinkTargetMetadata)
    let hardlinkTargetBefore = try Data(contentsOf: hardlinkTargetMetadata)
    let mismatchedBefore = try Data(contentsOf: mismatchedMetadata)

    let loaded = store.loadSessions()

    XCTAssertEqual(loaded.map(\.id), [healthy.id])
    XCTAssertEqual(try Data(contentsOf: symlinkTargetMetadata), symlinkTargetBefore)
    XCTAssertEqual(try Data(contentsOf: hardlinkTargetMetadata), hardlinkTargetBefore)
    XCTAssertEqual(try Data(contentsOf: mismatchedMetadata), mismatchedBefore)
  }

  func testBaselineMergePromotesLegacySessionIntoCurrentSessions() throws {
    let layout = LocalSessionFileLayout(baseDirectory: rootURL.appendingPathComponent("Cepessa", isDirectory: true))
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
    let layout = LocalSessionFileLayout(baseDirectory: rootURL.appendingPathComponent("Cepessa", isDirectory: true))
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
}
