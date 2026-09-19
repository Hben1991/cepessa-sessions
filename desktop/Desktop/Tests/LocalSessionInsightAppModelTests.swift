import Foundation
import XCTest

@testable import CepessaSessions

@MainActor
final class LocalSessionInsightAppModelTests: XCTestCase {
  func testAnalyzeConfirmAndRevealPersistThroughReload() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "InsightAppModel-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let layout = LocalSessionFileLayout(baseDirectory: root)
    let store = LocalSessionStore(fileLayout: layout)
    let started = Date(timeIntervalSince1970: 1_742_000_000)
    var session = makeSession(
      startedAt: started,
      segments: [
        ("Maya", "סיכמנו שעולים בראשון"),
        ("Noam", "אני אשלח לך מחר"),
      ]
    )
    session = try store.save(session)

    let model = LocalSessionAppModel(
      store: store,
      fileLayout: layout,
      insightProvider: LocalSessionInsightFixtureProvider()
    )
    model.selectSession(id: session.id)
    model.requestInsightAnalysis(for: session.id)

    let deadline = Date().addingTimeInterval(3)
    while Date() < deadline {
      if let record = model.insightRecord(for: session.id),
        record.status == .complete || record.status == .partial
      {
        break
      }
      try await Task.sleep(nanoseconds: 20_000_000)
    }
    let record = try XCTUnwrap(model.insightRecord(for: session.id))
    XCTAssertFalse(record.items.isEmpty)
    let item = try XCTUnwrap(record.items.first)
    XCTAssertEqual(item.reviewState, .unreviewed)

    model.reviewInsight(item, state: .confirmed)
    model.revealInsightSource(item)
    XCTAssertEqual(model.insightReveal?.segmentID, item.evidence.segmentIDs.first)
    XCTAssertEqual(model.insightReveal?.sessionID, session.id)

    let reloaded = LocalSessionAppModel(store: store, fileLayout: layout)
    let persisted = try XCTUnwrap(reloaded.insightRecord(for: session.id))
    XCTAssertEqual(persisted.items.first?.reviewState, .confirmed)
    XCTAssertEqual(store.loadSession(id: session.id)?.id, session.id)
  }
}
