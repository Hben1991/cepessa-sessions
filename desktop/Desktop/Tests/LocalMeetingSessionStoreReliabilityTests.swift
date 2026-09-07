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

  private func makeSession() -> LocalSession {
    let id = UUID(uuidString: "B0C1D2E3-F4A5-46B7-88C9-001122334455")!
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
}
