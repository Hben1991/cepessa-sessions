import Foundation
import XCTest

@testable import CepessaSessions

final class LocalMeetingTranscriptionArchitectureTests: XCTestCase {
  private var tempRootURL: URL!
  private let fileManager = FileManager.default

  override func setUpWithError() throws {
    tempRootURL = fileManager.temporaryDirectory
      .appendingPathComponent(
        "LocalMeetingTranscriptionArchitectureTests-\(UUID().uuidString)",
        isDirectory: true
      )
    try fileManager.createDirectory(at: tempRootURL, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    if let tempRootURL {
      try? fileManager.removeItem(at: tempRootURL)
    }
  }

  func testTranscriptionResultPersistsLocalEngineAndModelMetadata() throws {
    let result = LocalSessionTranscriptionResult(
      text: "Local transcript",
      detectedLanguage: "he",
      segments: [
        .init(startTime: 1.25, endTime: 3.5, text: "Local transcript")
      ],
      modelPath: "/models/whisperkit/large-v3-turbo",
      engine: .whisperKit,
      warnings: ["low confidence"]
    )

    let encoded = try JSONEncoder().encode(result)
    let decoded = try JSONDecoder().decode(LocalSessionTranscriptionResult.self, from: encoded)

    XCTAssertEqual(decoded.detectedLanguage, "he")
    XCTAssertEqual(decoded.modelPath, "/models/whisperkit/large-v3-turbo")
    XCTAssertEqual(decoded.engine, .whisperKit)
    XCTAssertEqual(decoded.segments.first?.startTime, 1.25)
    XCTAssertEqual(decoded.segments.first?.endTime, 3.5)
    XCTAssertEqual(decoded.segments.first?.words, [])
    XCTAssertEqual(decoded.warnings, ["low confidence"])
  }

  func testLegacyTranscriptionSegmentWithoutWordsStillDecodes() throws {
    let data = Data(#"{"startTime":0,"endTime":1,"text":"legacy"}"#.utf8)
    let decoded = try JSONDecoder().decode(LocalSessionTranscriptionSegment.self, from: data)
    XCTAssertEqual(decoded.words, [])
  }

  @MainActor
  func testDraftTranscriptProgressRemainsDistinctFromFinalTranscript() async throws {
    let layout = LocalMeetingFileLayout(
      baseDirectory: tempRootURL.appendingPathComponent("Meetings", isDirectory: true))
    let store = LocalMeetingSessionStore(fileLayout: layout)
    let sourceURL = tempRootURL.appendingPathComponent("recording.wav", isDirectory: false)
    try Data("audio".utf8).write(to: sourceURL)

    let transcriptionService = BlockingLocalTranscriptionService()
    let model = LocalMeetingAppModel(
      store: store,
      fileLayout: layout,
      transcriptionService: transcriptionService,
      audioImportService: PassthroughLocalAudioImportService()
    )

    let importTask = Task {
      await model.importExistingRecording(from: sourceURL, title: "Local ASR")
    }

    await waitForArchitectureCondition("draft transcript progress") {
      model.selectedSession?.transcriptText == "Draft ASR text" && model.isTranscribing
    }

    XCTAssertEqual(model.selectedSession?.status, .transcribing)
    XCTAssertEqual(model.processingQueue.first?.phase, .transcribing)
    XCTAssertEqual(model.processingQueue.first?.title, "Draft transcript available")

    transcriptionService.finish(
      with: LocalSessionTranscriptionResult(
        text: "Final ASR text",
        detectedLanguage: "en",
        segments: [
          .init(startTime: 0, endTime: 2, text: "Final ASR text")
        ],
        modelPath: "/models/whisperkit/base"
      )
    )

    await importTask.value

    await waitForArchitectureCondition("final transcript is persisted") {
      model.selectedSession?.transcriptText == "Final ASR text"
        && !model.isTranscribing
    }

    XCTAssertFalse(model.isTranscribing)
    XCTAssertEqual(model.selectedSession?.status, .failed)
    XCTAssertEqual(model.selectedSession?.transcriptionEvidence?.disposition, .degraded)
  }
}

@MainActor
private final class BlockingLocalTranscriptionService: @unchecked Sendable, LocalSessionTranscribing
{
  private var continuation: CheckedContinuation<LocalSessionTranscriptionResult, Never>?
  private var pendingResult: LocalSessionTranscriptionResult?

  func warmUp(modelURL: URL) async {}

  func transcribe(
    wavURL: URL,
    modelURL: URL,
    language: String,
    prompt: String?,
    translateToEnglish: Bool,
    onProgress: (@Sendable (LocalSessionTranscriptionProgress) async -> Void)?
  ) async throws -> LocalSessionTranscriptionResult {
    await onProgress?(
      .init(stage: .partialSegments([.init(startTime: 0, endTime: 1, text: "Draft ASR text")])))

    if let pendingResult {
      self.pendingResult = nil
      return pendingResult
    }

    return await withCheckedContinuation { continuation in
      self.continuation = continuation
    }
  }

  func finish(with result: LocalSessionTranscriptionResult) {
    if let continuation {
      self.continuation = nil
      continuation.resume(returning: result)
    } else {
      pendingResult = result
    }
  }
}

private struct PassthroughLocalAudioImportService: LocalSessionAudioImporting {
  func importAudio(from sourceURL: URL, to destinationWavURL: URL) async throws {
    try FileManager.default.createDirectory(
      at: destinationWavURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    var data = Data()
    let sampleData = Data(repeating: 0, count: 3_200)
    data.append("RIFF".data(using: .ascii)!)
    appendUInt32(UInt32(36 + sampleData.count), to: &data)
    data.append("WAVEfmt ".data(using: .ascii)!)
    appendUInt32(16, to: &data)
    appendUInt16(1, to: &data)
    appendUInt16(1, to: &data)
    appendUInt32(16_000, to: &data)
    appendUInt32(32_000, to: &data)
    appendUInt16(2, to: &data)
    appendUInt16(16, to: &data)
    data.append("data".data(using: .ascii)!)
    appendUInt32(UInt32(sampleData.count), to: &data)
    data.append(sampleData)
    try data.write(to: destinationWavURL)
  }

  private func appendUInt16(_ value: UInt16, to data: inout Data) {
    var value = value.littleEndian
    withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
  }

  private func appendUInt32(_ value: UInt32, to data: inout Data) {
    var value = value.littleEndian
    withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
  }
}

@MainActor
private func waitForArchitectureCondition(
  _ description: String,
  timeoutNanoseconds: UInt64 = 1_000_000_000,
  condition: @escaping @MainActor () -> Bool
) async {
  let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
  while !condition() {
    if DispatchTime.now().uptimeNanoseconds >= deadline {
      XCTFail("Timed out waiting for \(description)")
      return
    }
    await Task.yield()
  }
}
