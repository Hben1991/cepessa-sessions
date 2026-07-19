import Foundation
import XCTest

@testable import CepessaSessions

@MainActor
final class ManualRegenerateLatestSessionDocumentsTests: XCTestCase {
  func testRegenerateDocumentsForApprovedLatestSessionSet() async throws {
    guard ProcessInfo.processInfo.environment["CEPESSA_RUN_MANUAL_DOCUMENT_REGEN_LATEST_15"] == "1"
    else {
      throw XCTSkip("Manual document regeneration test is disabled by default.")
    }

    let targetIDs = [
      "6E6ED9C6-E553-4D80-975B-BC57AB76AF7C",
      "DB984411-D860-4E21-B79B-137E755D32B6",
      "33FE32AB-BEFE-4EA3-99EF-C612356E3EF1",
      "8841B0FA-BCE4-4250-9115-4F72375A59F5",
      "09F963C9-C5DB-484C-BF5F-CCE7D6FF52FC",
      "E276FDB5-F3DE-4B5E-9A90-BFB5CF95AB6F",
      "D96BEFDF-1D42-4716-9ACF-361DF7C5481C",
      "5028DE1F-524E-4CA2-AC24-23169CE2113B",
      "DC31B582-DCE1-4EED-84C4-3BCDD721EBA8",
    ].compactMap(UUID.init(uuidString:))

    let deletedIDs = [
      "F6DE9AEA-86FF-4069-8BAD-37549BE40C94",
      "158FC816-97BB-4316-9A81-53C600ECBBDC",
      "1EFD603B-BCAE-4459-8484-AD5FC6621BEB",
      "878C4920-6B6D-4055-8256-D79F80BDAAC1",
      "9DEC46B4-DA1D-4587-8D23-8D15C890A4B6",
      "9565368D-4581-4FF8-B6B3-1990300C473E",
    ].compactMap(UUID.init(uuidString:))

    XCTAssertEqual(targetIDs.count, 9)
    XCTAssertEqual(deletedIDs.count, 6)

    let baseDirectory = FileManager.default.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    )[0].appendingPathComponent("Cepessa", isDirectory: true)
    let layout = LocalMeetingFileLayout(baseDirectory: baseDirectory)
    let store = LocalMeetingSessionStore(fileLayout: layout)

    let loadedIDs = Set(store.loadSessions().map(\.id))
    for deletedID in deletedIDs {
      XCTAssertFalse(loadedIDs.contains(deletedID), "Short deleted session is still loaded: \(deletedID)")
    }

    try await repairInterruptedTranscriptIfNeeded(
      sessionID: UUID(uuidString: "E276FDB5-F3DE-4B5E-9A90-BFB5CF95AB6F")!,
      store: store,
      layout: layout
    )

    let generator = LocalSessionRecapGenerator()

    for sessionID in targetIDs {
      var session = try XCTUnwrap(
        store.loadSessions().first { $0.id == sessionID },
        "Missing session for document regeneration: \(sessionID)"
      )
      XCTAssertFalse(session.transcriptSegments.isEmpty, "Missing transcript for \(sessionID)")

      session.status = .ready
      session.contentClassification = LocalSessionContentClassification(
        type: .meeting,
        confidence: 1,
        rationale: "Meeting document regeneration requested for the latest session maintenance pass."
      )
      session.documentMarkdown = nil
      session.recap = await generator.generateRecap(for: session)
      try store.save(session)

      let saved = try XCTUnwrap(
        store.loadSessions().first { $0.id == sessionID },
        "Missing saved session after document regeneration: \(sessionID)"
      )
      XCTAssertEqual(saved.status, .ready)
      XCTAssertEqual(saved.contentClassification?.type, .meeting)
      XCTAssertFalse(saved.transcriptSegments.isEmpty)
      XCTAssertTrue(saved.recap.hasContent)
      XCTAssertNil(saved.documentMarkdown)
      emit(
        "DOCUMENT_DONE\t\(sessionID.uuidString)\tsegments=\(saved.transcriptSegments.count)\trecapSections=\(saved.recap.sections.count)"
      )
    }
  }

  private func repairInterruptedTranscriptIfNeeded(
    sessionID: UUID,
    store: LocalMeetingSessionStore,
    layout: LocalMeetingFileLayout
  ) async throws {
    guard let stored = store.loadSessions().first(where: { $0.id == sessionID }) else { return }
    guard stored.status == .transcribing || stored.transcriptSegments.count < 100 else { return }

    emit("REPAIR_TRANSCRIPT_START\t\(sessionID.uuidString)\tsegments=\(stored.transcriptSegments.count)")
    let model = LocalMeetingAppModel(store: store, fileLayout: layout)
    guard let session = model.sessions.first(where: { $0.id == sessionID }) else {
      XCTFail("Missing interrupted session in app model: \(sessionID)")
      return
    }
    XCTAssertTrue(model.canRetranscribe(session), "Interrupted session is not repairable: \(sessionID)")

    model.retranscribeSession(id: sessionID)
    let deadline = Date().addingTimeInterval(90 * 60)
    var lastSegmentCount = -1
    var sawRepairStart = false

    while Date() < deadline {
      let current = model.sessions.first { $0.id == sessionID }
      let segmentCount = current?.transcriptSegments.count ?? 0
      if model.processingSnapshot(for: sessionID) != nil || current?.status == .transcribing {
        sawRepairStart = true
      }
      if segmentCount != lastSegmentCount {
        emit("REPAIR_TRANSCRIPT_PROGRESS\t\(sessionID.uuidString)\tsegments=\(segmentCount)")
        lastSegmentCount = segmentCount
      }

      if sawRepairStart,
        model.processingSnapshot(for: sessionID) == nil,
        model.isGeneratingRecap(for: sessionID) == false,
        current?.status != .transcribing,
        segmentCount >= 100
      {
        break
      }

      if sawRepairStart, current?.status == .failed, model.processingSnapshot(for: sessionID) == nil {
        XCTFail("Transcript repair failed for \(sessionID)")
        return
      }

      try await Task.sleep(nanoseconds: 2_000_000_000)
    }

    let repaired = try XCTUnwrap(store.loadSessions().first { $0.id == sessionID })
    XCTAssertEqual(repaired.status, .ready)
    XCTAssertGreaterThanOrEqual(repaired.transcriptSegments.count, 100)
    emit("REPAIR_TRANSCRIPT_DONE\t\(sessionID.uuidString)\tsegments=\(repaired.transcriptSegments.count)")
  }

  private func emit(_ message: String) {
    FileHandle.standardError.write((message + "\n").data(using: .utf8) ?? Data())
  }
}

private extension LocalSessionRecap {
  var hasContent: Bool {
    !overview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !sections.isEmpty
  }
}
