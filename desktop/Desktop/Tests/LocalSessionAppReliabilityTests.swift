import Foundation
import XCTest

@testable import CepessaSessions

@MainActor
final class LocalSessionAppReliabilityTests: XCTestCase {
  private var root: URL!

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "SessionAppReliability-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    if let root { try? FileManager.default.removeItem(at: root) }
  }

  func testCompletedRetryReleasesItsStateAndRetainsBothSourceChannels() async throws {
    let (layout, store, session) = try fixture(separated: true)
    let service = AppReliabilityTranscriber()
    let model = LocalMeetingAppModel(
      store: store, fileLayout: layout, transcriptionService: service)

    model.retranscribeSession(id: session.id)
    await eventually { service.receivedURLs.count == 2 && !model.isTranscribing }
    XCTAssertEqual(
      Set(service.receivedURLs.map(\.lastPathComponent)), ["mic-transcript.wav", "system.wav"])
    XCTAssertTrue(model.processingSnapshots.isEmpty)
    XCTAssertTrue(model.canRetranscribe(try XCTUnwrap(model.selectedSession)))

    model.retranscribeSession(id: session.id)
    await eventually { service.receivedURLs.count == 4 && !model.isTranscribing }
    XCTAssertEqual(model.selectedSession?.transcriptionEvidence?.revision, 2)
    XCTAssertTrue(model.processingSnapshots.isEmpty)
  }

  func testRetryKeepsSavedTranscriptAndProtectsTitleEditedDuringProcessing() async throws {
    let (layout, store, session) = try fixture(separated: false)
    let service = AppReliabilityTranscriber(blocks: true)
    let model = LocalMeetingAppModel(
      store: store, fileLayout: layout, transcriptionService: service)

    model.retranscribeSession(id: session.id)
    await eventually { service.waiting }
    XCTAssertEqual(store.loadSession(id: session.id)?.transcriptText, "Original saved words")
    XCTAssertEqual(model.selectedSession?.transcriptText, "Original saved words")
    XCTAssertTrue(model.updateSessionTitle("My chosen title", for: session.id))
    service.finish()
    await eventually { !model.isTranscribing }

    XCTAssertEqual(model.selectedSession?.title, "My chosen title")
    XCTAssertEqual(store.loadSession(id: session.id)?.title, "My chosen title")
    XCTAssertEqual(model.selectedSession?.titleOrigin, .user)
    XCTAssertEqual(model.selectedSession?.transcriptText, "Replacement words")
  }

  func testExportUsesChosenFilenameAndPreservesUnselectedNeighbor() throws {
    let (_, _, session) = try fixture(separated: false)
    let chosen = root.appendingPathComponent("Exactly my filename.md")
    let neighbor = root.appendingPathComponent("Original title Transcript.md")
    let sentinel = Data("Unrelated existing document".utf8)
    try sentinel.write(to: neighbor)

    let returned = try LocalSessionRecapExporter().exportTranscriptMarkdown(
      session: session, toFile: chosen)
    XCTAssertEqual(returned, chosen)
    XCTAssertTrue(try String(contentsOf: chosen, encoding: .utf8).contains("Original saved words"))
    XCTAssertEqual(try Data(contentsOf: neighbor), sentinel)
  }

  func testImportedAudioRetainsItsExplicitSourceWhenTranscribedAgain() async throws {
    let (layout, store, sourceSession) = try fixture(separated: false)
    let source = layout.mixedAudioURL(for: sourceSession.id)
    let service = AppReliabilityTranscriber()
    let model = LocalMeetingAppModel(
      store: store, fileLayout: layout, transcriptionService: service)

    await model.importExistingRecording(from: source, title: "Imported interview")
    let imported = try XCTUnwrap(model.selectedSession)
    XCTAssertNotEqual(imported.id, sourceSession.id)
    XCTAssertEqual(imported.audioArtifacts.importedFileName, "imported.wav")
    XCTAssertNil(imported.audioArtifacts.mixedFileName)
    XCTAssertEqual(imported.transcriptSegments.first?.source, .imported)
    XCTAssertEqual(imported.titleOrigin, .imported)
    XCTAssertEqual(service.receivedURLs.map(\.lastPathComponent), ["imported.wav"])

    model.retranscribeSession(id: imported.id)
    await eventually { service.receivedURLs.count == 2 && !model.isTranscribing }
    XCTAssertEqual(model.selectedSession?.transcriptSegments.first?.source, .imported)
    XCTAssertEqual(
      store.loadSession(id: imported.id)?.audioArtifacts.importedFileName, "imported.wav")
    XCTAssertEqual(service.receivedURLs.map(\.lastPathComponent), ["imported.wav", "imported.wav"])
  }

  func testConflictingTitleCannotPublishRejectedValueOrReportFalseSuccess() throws {
    let (layout, store, session) = try fixture(separated: false)
    let model = LocalMeetingAppModel(store: store, fileLayout: layout)
    var external = session
    external.title = "Changed elsewhere"
    try store.save(external)

    XCTAssertFalse(model.updateSessionTitle("My edit", for: session.id))
    XCTAssertEqual(model.selectedSession?.title, "Changed elsewhere")
    XCTAssertEqual(store.loadSession(id: session.id)?.title, "Changed elsewhere")
    XCTAssertNotNil(model.sessionSaveErrors[session.id])

    XCTAssertTrue(model.updateSessionTitle("My edit", for: session.id))
    XCTAssertEqual(store.loadSession(id: session.id)?.title, "My edit")
    XCTAssertNil(model.sessionSaveErrors[session.id])
  }

  func testDegradedRetryRetainsPreviousReadyTranscriptAndAdvancesAttemptRevision() async throws {
    let (layout, store, original) = try fixture(separated: false)
    var ready = original
    ready.status = .ready
    try store.save(ready)
    let service = AppReliabilityTranscriber()
    let model = LocalMeetingAppModel(
      store: store, fileLayout: layout, transcriptionService: service)

    model.retranscribeSession(id: ready.id)
    await eventually { service.receivedURLs.count == 1 && !model.isTranscribing }
    XCTAssertEqual(model.selectedSession?.status, .failed)
    XCTAssertEqual(model.selectedSession?.transcriptText, "Original saved words")
    XCTAssertEqual(model.selectedSession?.latestTranscriptionAttempt?.revision, 1)
    XCTAssertTrue(
      model.selectedSession?.processingError?.contains("previously saved transcript") == true)
    XCTAssertEqual(store.loadSession(id: ready.id)?.transcriptText, "Original saved words")

    model.retranscribeSession(id: ready.id)
    await eventually { service.receivedURLs.count == 2 && !model.isTranscribing }
    XCTAssertEqual(model.selectedSession?.latestTranscriptionAttempt?.revision, 2)
    XCTAssertEqual(model.selectedSession?.transcriptText, "Original saved words")
  }

  func testFailedTranscriptAndUnverifiedLegacyEvidenceCannotClaimComplete() throws {
    let (_, _, saved) = try fixture(separated: false)
    var session = saved
    session.processingError = "Speech near the end could not be recovered."
    let notice = LocalSessionReadingNotice.resolve(session)
    XCTAssertTrue(notice.needsReview)
    XCTAssertEqual(notice.detail, session.processingError)
    let output = try LocalSessionRecapExporter().exportTranscriptMarkdown(
      session: session, toFile: root.appendingPathComponent("partial.md"))
    XCTAssertTrue(try String(contentsOf: output, encoding: .utf8).contains("Speech near the end"))

    session.status = .ready
    session.processingError = nil
    session.transcriptionEvidence = .init(
      runID: "legacy", revision: 1, disposition: .ready,
      contentHash: "hash", parentContentHash: nil, runFileName: "run.json",
      outboxFileName: "event.json", issues: [])
    XCTAssertEqual(LocalSessionReadingNotice.resolve(session).title, "Saved transcript")
  }

  func testLoadingLibraryDoesNotRewriteUnchangedPromptPackages() throws {
    let (layout, store, session) = try fixture(separated: false)
    let path = layout.promptPackageMarkdownURL(for: session.id)
    let before = try Data(contentsOf: path)
    let sentinelDate = Date(timeIntervalSince1970: 1_700_000_000)
    try FileManager.default.setAttributes(
      [.modificationDate: sentinelDate], ofItemAtPath: path.path)
    _ = store.loadSessions()
    _ = store.loadSession(id: session.id)
    let after =
      try FileManager.default.attributesOfItem(atPath: path.path)[.modificationDate] as? Date
    XCTAssertEqual(after, sentinelDate)
    XCTAssertEqual(try Data(contentsOf: path), before)
  }

  func testSpeakerRenameAndUndoRefreshBothHandoffsWithoutChangingSourceEvidence() throws {
    let (layout, store, session) = try speakerFixture()
    let model = LocalMeetingAppModel(store: store, fileLayout: layout)
    let metadataBefore = try Data(contentsOf: layout.metadataURL(for: session.id))
    let audioBefore = try Data(contentsOf: layout.mixedAudioURL(for: session.id))
    let markdownURL = layout.promptPackageMarkdownURL(for: session.id)
    let jsonURL = layout.promptPackageJSONURL(for: session.id)

    XCTAssertTrue(model.renameSpeaker(speakerID: "speaker-a", to: "Maya", in: session.id))
    XCTAssertEqual(model.selectedSession?.transcriptSegments.first?.speaker, "Maya")
    XCTAssertTrue(
      try String(contentsOf: markdownURL, encoding: .utf8).contains("Maya: Original saved words"))
    let renamedPackage =
      try JSONSerialization.jsonObject(with: Data(contentsOf: jsonURL)) as? [String: Any]
    let renamedSegments = try XCTUnwrap(renamedPackage?["transcriptSegments"] as? [[String: Any]])
    XCTAssertEqual(renamedSegments.first?["speaker"] as? String, "Maya")
    XCTAssertEqual(renamedSegments.first?["identityStatus"] as? String, "confirmed")

    // A later library refresh must not replace the annotated handoff with raw labels.
    _ = store.loadSessions()
    XCTAssertTrue(
      try String(contentsOf: markdownURL, encoding: .utf8).contains("Maya: Original saved words"))
    XCTAssertTrue(model.undoLatestSpeakerRename(speakerID: "speaker-a", in: session.id))
    XCTAssertEqual(model.selectedSession?.transcriptSegments.first?.speaker, "Speaker 1")
    let undoneMarkdown = try String(contentsOf: markdownURL, encoding: .utf8)
    XCTAssertTrue(undoneMarkdown.contains("Speaker 1: Original saved words"))
    XCTAssertFalse(undoneMarkdown.contains("Maya: Original saved words"))
    let undonePackage =
      try JSONSerialization.jsonObject(with: Data(contentsOf: jsonURL)) as? [String: Any]
    let undoneSegments = try XCTUnwrap(undonePackage?["transcriptSegments"] as? [[String: Any]])
    XCTAssertEqual(undoneSegments.first?["speaker"] as? String, "Speaker 1")
    XCTAssertNotEqual(undoneSegments.first?["identityStatus"] as? String, "confirmed")
    XCTAssertEqual(try Data(contentsOf: layout.metadataURL(for: session.id)), metadataBefore)
    XCTAssertEqual(try Data(contentsOf: layout.mixedAudioURL(for: session.id)), audioBefore)
  }

  func testHandoffRefreshFailurePreservesSpeakerEditsAndReportsPartialSuccess() throws {
    let (layout, store, session) = try speakerFixture()
    let model = LocalMeetingAppModel(store: store, fileLayout: layout)
    let metadataBefore = try Data(contentsOf: layout.metadataURL(for: session.id))
    let markdownURL = layout.promptPackageMarkdownURL(for: session.id)
    try FileManager.default.removeItem(at: markdownURL)
    try FileManager.default.createDirectory(at: markdownURL, withIntermediateDirectories: false)
    let annotations = LocalSessionSpeakerAnnotationStore(fileLayout: layout)

    XCTAssertFalse(model.renameSpeaker(speakerID: "speaker-a", to: "Maya", in: session.id))
    XCTAssertEqual(model.selectedSession?.transcriptSegments.first?.speaker, "Maya")
    XCTAssertEqual(
      annotations.resolvedNames(sessionID: session.id, evidenceContentHash: "hash-a")["speaker-a"],
      "Maya")
    XCTAssertTrue(
      model.recorderErrorMessage?.contains("speaker name was saved, but the handoff package")
        == true)

    XCTAssertFalse(model.undoLatestSpeakerRename(speakerID: "speaker-a", in: session.id))
    XCTAssertEqual(model.selectedSession?.transcriptSegments.first?.speaker, "Speaker 1")
    XCTAssertTrue(
      annotations.resolvedNames(sessionID: session.id, evidenceContentHash: "hash-a").isEmpty)
    XCTAssertTrue(
      model.recorderErrorMessage?.contains("speaker correction was undone, but the handoff package")
        == true)
    XCTAssertEqual(try Data(contentsOf: layout.metadataURL(for: session.id)), metadataBefore)

    try FileManager.default.removeItem(at: markdownURL)
    XCTAssertTrue(model.renameSpeaker(speakerID: "speaker-a", to: "Dana", in: session.id))
    XCTAssertNil(model.recorderErrorMessage)
    XCTAssertTrue(
      try String(contentsOf: markdownURL, encoding: .utf8).contains("Dana: Original saved words"))
  }

  private func speakerFixture() throws -> (LocalSessionFileLayout, LocalSessionStore, LocalSession)
  {
    let (layout, store, original) = try fixture(separated: false)
    var session = original
    session.transcriptSegments[0].speakerID = "speaker-a"
    session.transcriptionEvidence = .init(
      runID: "annotation-test", revision: 1, disposition: .degraded,
      contentHash: "hash-a", parentContentHash: nil, runFileName: "run.json",
      outboxFileName: "event.json", issues: [])
    try store.save(session)
    return (layout, store, session)
  }

  private func fixture(separated: Bool) throws -> (
    LocalSessionFileLayout, LocalSessionStore, LocalSession
  ) {
    let layout = LocalSessionFileLayout(baseDirectory: root)
    let store = LocalSessionStore(fileLayout: layout)
    let started = Date(timeIntervalSince1970: 1_700_000_000)
    let session = LocalSession(
      id: UUID(), title: "Original title", startedAt: started,
      status: .failed,
      transcriptSegments: [
        .init(id: UUID(), speaker: "Speaker 1", text: "Original saved words", timestamp: started)
      ],
      audioArtifacts: .init(
        micFileName: separated ? "mic.wav" : nil,
        micTranscriptFileName: separated ? "mic-transcript.wav" : nil,
        systemFileName: separated ? "system.wav" : nil, mixedFileName: "mixed.wav"))
    try store.save(session)
    let names =
      separated ? ["mixed.wav", "mic.wav", "mic-transcript.wav", "system.wav"] : ["mixed.wav"]
    for (index, name) in names.enumerated() {
      let writer = try LocalMeetingWaveFileWriter(
        fileURL: layout.sessionDirectory(for: session.id).appendingPathComponent(name))
      try writer.append(samples: [Int16](repeating: Int16(1000 + index * 100), count: 16_000))
      try writer.close()
    }
    return (layout, store, session)
  }

  private func eventually(
    file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool
  ) async {
    for _ in 0..<500 {
      if condition() { return }
      try? await Task.sleep(for: .milliseconds(10))
    }
    XCTFail("Timed out waiting for controlled transcription", file: file, line: line)
  }
}

@MainActor
private final class AppReliabilityTranscriber: @unchecked Sendable, LocalSessionTranscribing {
  let blocks: Bool
  private(set) var receivedURLs: [URL] = []
  private var continuation: CheckedContinuation<Void, Never>?
  var waiting: Bool { continuation != nil }

  init(blocks: Bool = false) { self.blocks = blocks }
  func warmUp(modelURL: URL) async {}

  func transcribe(
    wavURL: URL, modelURL: URL, language: String, prompt: String?,
    translateToEnglish: Bool,
    onProgress: (@Sendable (LocalSessionTranscriptionProgress) async -> Void)?
  ) async throws -> LocalSessionTranscriptionResult {
    receivedURLs.append(wavURL)
    await onProgress?(
      .init(stage: .partialSegments([.init(startTime: 0, endTime: 0.4, text: "Temporary draft")])))
    if blocks { await withCheckedContinuation { continuation = $0 } }
    return .init(
      text: "Replacement words", detectedLanguage: "en",
      segments: [.init(startTime: 0, endTime: 0.8, text: "Replacement words")],
      modelPath: modelURL.path)
  }

  func finish() {
    continuation?.resume()
    continuation = nil
  }
}
