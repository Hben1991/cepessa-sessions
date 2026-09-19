import Foundation
import XCTest

@testable import CepessaSessions

@MainActor
final class LocalClipViewModelReliabilityTests: XCTestCase {
  func testSessionLeaseRejectsClipStartBeforeCaptureServicesRun() throws {
    let fixture = try ViewModelFixture()
    defer { fixture.remove() }
    let sessionLease = try fixture.lifecycle.beginCapture(.session)

    fixture.model.startClip()

    XCTAssertEqual(fixture.audioRecorder.startCount, 0)
    XCTAssertEqual(fixture.screenRecorder.startCount, 0)
    XCTAssertEqual(fixture.lifecycle.phase, .starting(sessionLease))
    XCTAssertTrue(fixture.model.statusMessage?.contains("active session capture") == true)
  }

  func testDuplicateStartBeforeAsyncAudioResumeStartsOnlyOneCapture() async throws {
    let audioRecorder = FakeClipAudioRecorder(suspendsStart: true)
    let fixture = try ViewModelFixture(audioRecorder: audioRecorder)
    defer { fixture.remove() }

    fixture.model.startClip()
    fixture.model.startClip()
    await waitUntil { audioRecorder.startCount == 1 }

    XCTAssertEqual(audioRecorder.startCount, 1)
    XCTAssertEqual(fixture.screenRecorder.startCount, 0)
    XCTAssertEqual(fixture.lifecycle.activeKind, .clip)
    audioRecorder.resumeStart()
    await waitUntil { fixture.model.isRecording }

    XCTAssertEqual(audioRecorder.startCount, 1)
    XCTAssertEqual(fixture.screenRecorder.startCount, 1)
    await fixture.model.finishCaptureForTermination()
    XCTAssertEqual(fixture.lifecycle.phase, .idle)
  }

  func testStartFailurePersistsFailureReleasesLeaseAndPreservesNewDrafts() async throws {
    let audioRecorder = FakeClipAudioRecorder(startError: MockCaptureError.audioStartFailed)
    let fixture = try ViewModelFixture(audioRecorder: audioRecorder)
    defer { fixture.remove() }
    fixture.model.newClipTitleDraft = "  Keep this draft title  "
    fixture.model.newClipIntentDraft = "  Keep this draft intent  "

    fixture.model.startClip()
    await waitUntil { fixture.model.clips.first?.status == .failed }

    let failedClip = try XCTUnwrap(fixture.model.clips.first)
    XCTAssertEqual(failedClip.title, "Keep this draft title")
    XCTAssertEqual(failedClip.intent, "Keep this draft intent")
    XCTAssertEqual(failedClip.errorMessage, MockCaptureError.audioStartFailed.localizedDescription)
    XCTAssertEqual(fixture.model.newClipTitleDraft, "  Keep this draft title  ")
    XCTAssertEqual(fixture.model.newClipIntentDraft, "  Keep this draft intent  ")
    XCTAssertEqual(fixture.lifecycle.phase, .idle)
    XCTAssertEqual(fixture.screenRecorder.startCount, 0)
    XCTAssertEqual(fixture.store.loadClips().first?.status, .failed)
    XCTAssertEqual(
      fixture.store.loadClips().first?.errorMessage,
      MockCaptureError.audioStartFailed.localizedDescription
    )
  }

  func testSelectedClipEditsPersistWithoutOverwritingNewClipDrafts() throws {
    let fixture = try ViewModelFixture()
    defer { fixture.remove() }
    let storedClip = makeClip(
      id: UUID(uuidString: "C11CE001-0001-4000-8000-000000000001")!,
      status: .failed,
      title: "Stored title",
      intent: "Stored intent",
      segments: []
    )
    try fixture.store.save(storedClip)
    fixture.model.loadClips()
    fixture.model.selectClip(storedClip.id)
    fixture.model.newClipTitleDraft = "Next capture title"
    fixture.model.newClipIntentDraft = "Next capture intent"
    fixture.model.selectedClipTitleDraft = "Edited stored title"
    fixture.model.selectedClipIntentDraft = "Edited stored intent"
    fixture.model.selectedClipPostNotesDraft = "Edited stored notes"

    fixture.model.saveSelectedNotes()

    XCTAssertEqual(fixture.model.newClipTitleDraft, "Next capture title")
    XCTAssertEqual(fixture.model.newClipIntentDraft, "Next capture intent")
    let persisted = try XCTUnwrap(fixture.store.loadClips().first)
    XCTAssertEqual(persisted.title, "Edited stored title")
    XCTAssertEqual(persisted.intent, "Edited stored intent")
    XCTAssertEqual(persisted.postNotes, "Edited stored notes")
  }

  func testSelectionAndSavedContextClearStaleClipboardFeedback() throws {
    let fixture = try ViewModelFixture()
    defer { fixture.remove() }
    let firstClip = makeClip(
      id: UUID(uuidString: "C11CE003-0003-4000-8000-000000000003")!,
      status: .failed,
      title: "First failed clip",
      intent: nil,
      segments: []
    )
    let secondClip = makeClip(
      id: UUID(uuidString: "C11CE004-0004-4000-8000-000000000004")!,
      status: .failed,
      title: "Second failed clip",
      intent: nil,
      segments: []
    )
    try fixture.store.save(firstClip)
    try fixture.store.save(secondClip)
    fixture.model.loadClips()
    fixture.model.selectClip(firstClip.id)
    fixture.model.copyAgentPrompt(for: firstClip.id)
    XCTAssertNotNil(fixture.model.clipboardMessage)

    fixture.model.selectClip(secondClip.id)

    XCTAssertNil(fixture.model.clipboardMessage)
    fixture.model.copyAgentPrompt(for: secondClip.id)
    XCTAssertNotNil(fixture.model.clipboardMessage)
    fixture.model.selectedClipPostNotesDraft = "Changed prompt context"
    fixture.model.saveSelectedNotes()
    XCTAssertNil(fixture.model.clipboardMessage)
    XCTAssertEqual(
      fixture.model.selectedClipContextSaveFeedback,
      .success("Context saved.")
    )

    fixture.model.selectClip(firstClip.id)
    XCTAssertNil(fixture.model.selectedClipContextSaveFeedback)
    fixture.model.selectClip(secondClip.id)
    fixture.model.saveSelectedNotes()
    XCTAssertEqual(
      fixture.model.selectedClipContextSaveFeedback,
      .success("Context saved.")
    )
    fixture.model.selectedClipIntentDraft = "Unsaved focus change"
    XCTAssertNil(fixture.model.selectedClipContextSaveFeedback)
  }

  func testContextSaveFailurePublishesLocalErrorAndRetainsDraft() throws {
    let fixture = try ViewModelFixture()
    defer { fixture.remove() }
    let storedClip = makeClip(
      id: UUID(uuidString: "C11CE005-0005-4000-8000-000000000005")!,
      status: .failed,
      title: "Persisted title",
      intent: nil,
      segments: []
    )
    try fixture.store.save(storedClip)
    let savedManifest = try Data(contentsOf: fixture.clipLayout.manifestURL(for: storedClip.id))
    fixture.model.loadClips()
    fixture.model.selectClip(storedClip.id)
    let transcriptURL = fixture.clipLayout.transcriptURL(for: storedClip.id)
    try FileManager.default.removeItem(at: transcriptURL)
    try FileManager.default.createDirectory(
      at: transcriptURL,
      withIntermediateDirectories: false
    )
    fixture.model.selectedClipTitleDraft = "Retain this title after failure"

    fixture.model.saveSelectedNotes()

    XCTAssertEqual(
      fixture.model.selectedClipTitleDraft,
      "Retain this title after failure"
    )
    guard case .failure(let message) = fixture.model.selectedClipContextSaveFeedback else {
      return XCTFail("Expected a context-save failure beside the Notes controls")
    }
    XCTAssertTrue(message.contains("Failed to save CLIP"))
    XCTAssertEqual(
      try Data(contentsOf: fixture.clipLayout.manifestURL(for: storedClip.id)), savedManifest)
    XCTAssertTrue(fixture.store.loadClips().isEmpty)
    XCTAssertEqual(fixture.store.loadWarnings.count, 1)
  }

  func testStoredReadyClipMissingVideoStartsCheckingThenBecomesFailed() async throws {
    let fixture = try ViewModelFixture()
    defer { fixture.remove() }
    let clip = makeClip(
      id: UUID(uuidString: "C11CE002-0002-4000-8000-000000000002")!,
      status: .ready,
      title: "Stored ready fixture",
      intent: nil,
      segments: [
        LocalClipTranscriptSegment(
          id: UUID(uuidString: "C11CE102-0102-4000-8000-000000000102")!,
          startOffset: 0.1,
          endOffset: 0.8,
          text: "Synthetic narration"
        )
      ]
    )
    try fixture.store.save(clip)
    let writer = try LocalMeetingWaveFileWriter(
      fileURL: fixture.clipLayout.audioURL(for: clip.id)
    )
    try writer.append(samples: [Int16](repeating: 12, count: 16_000))
    try writer.close()

    fixture.model.loadClips()

    XCTAssertTrue(fixture.model.isValidating(clip.id))
    XCTAssertFalse(fixture.model.isReadyForDisplay(clip.id))
    XCTAssertFalse(fixture.model.canCopyAgentPrompt(for: clip.id))
    await waitUntil { fixture.model.clips.first(where: { $0.id == clip.id })?.status == .failed }
    XCTAssertFalse(fixture.model.isValidating(clip.id))
    XCTAssertFalse(fixture.model.isReadyForDisplay(clip.id))
    XCTAssertFalse(fixture.model.canCopyAgentPrompt(for: clip.id))
    XCTAssertTrue(
      fixture.model.clips.first(where: { $0.id == clip.id })?.errorMessage?
        .contains("saved video file is missing") == true
    )
    XCTAssertEqual(
      fixture.store.loadClips().first(where: { $0.id == clip.id })?.status,
      .failed
    )
  }

  func testNormalizedDraftsPersistWhileRecordingAndStopFailurePersistsFailed() async throws {
    let screenRecorder = FakeClipScreenRecorder(
      stopResult: .init(outcome: .forcedTermination, terminationStatus: 15)
    )
    let fixture = try ViewModelFixture(screenRecorder: screenRecorder)
    defer { fixture.remove() }
    fixture.model.newClipTitleDraft = "  Normalized title  "
    fixture.model.newClipIntentDraft = "  Normalized intent  "

    fixture.model.startClip()
    await waitUntil { fixture.model.isRecording }

    let recordingClip = try XCTUnwrap(fixture.store.loadClips().first)
    XCTAssertEqual(recordingClip.status, .recording)
    XCTAssertEqual(recordingClip.title, "Normalized title")
    XCTAssertEqual(recordingClip.intent, "Normalized intent")
    XCTAssertEqual(fixture.model.activeClipID, recordingClip.id)
    XCTAssertEqual(fixture.model.selectedClipID, recordingClip.id)
    XCTAssertEqual(fixture.model.newClipTitleDraft, "")
    XCTAssertEqual(fixture.model.newClipIntentDraft, "")

    fixture.model.stopClip()
    await waitUntil { fixture.model.clips.first?.status == .failed }

    let failedClip = try XCTUnwrap(fixture.store.loadClips().first)
    XCTAssertEqual(failedClip.status, .failed)
    XCTAssertTrue(failedClip.errorMessage?.contains("forced it to stop") == true)
    XCTAssertNil(fixture.model.activeClipID)
    XCTAssertEqual(fixture.model.selectedClipID, failedClip.id)
    XCTAssertEqual(fixture.lifecycle.phase, .idle)
    XCTAssertEqual(screenRecorder.stopCount, 1)
  }

  private func waitUntil(
    attempts: Int = 200,
    _ condition: @MainActor () -> Bool
  ) async {
    for _ in 0..<attempts {
      if condition() { return }
      try? await Task.sleep(nanoseconds: 5_000_000)
    }
    XCTFail("Timed out waiting for CLIP model state")
  }
}

@MainActor
private final class ViewModelFixture {
  let directoryURL: URL
  let clipLayout: LocalClipFileLayout
  let sessionLayout: LocalSessionFileLayout
  let store: LocalClipStore
  let lifecycle: LocalCaptureLifecycle
  let audioRecorder: FakeClipAudioRecorder
  let screenRecorder: FakeClipScreenRecorder
  let model: LocalClipViewModel

  init(
    audioRecorder: FakeClipAudioRecorder? = nil,
    screenRecorder: FakeClipScreenRecorder? = nil
  ) throws {
    let resolvedAudioRecorder = audioRecorder ?? FakeClipAudioRecorder()
    let resolvedScreenRecorder = screenRecorder ?? FakeClipScreenRecorder()
    directoryURL = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let clipRoot = directoryURL.appendingPathComponent("Clips", isDirectory: true)
    let sessionRoot = directoryURL.appendingPathComponent("Sessions", isDirectory: true)
    clipLayout = LocalClipFileLayout(baseDirectory: clipRoot)
    sessionLayout = LocalSessionFileLayout(baseDirectory: sessionRoot)
    store = LocalClipStore(fileLayout: clipLayout)
    lifecycle = LocalCaptureLifecycle()
    self.audioRecorder = resolvedAudioRecorder
    self.screenRecorder = resolvedScreenRecorder
    try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    model = LocalClipViewModel(
      store: store,
      clipFileLayout: clipLayout,
      sessionFileLayout: sessionLayout,
      transcriptionService: NeverClipTranscriber(),
      captureLifecycle: lifecycle,
      audioRecorder: resolvedAudioRecorder,
      screenRecorder: resolvedScreenRecorder
    )
  }

  func remove() {
    try? FileManager.default.removeItem(at: directoryURL)
  }
}

@MainActor
private final class FakeClipAudioRecorder: LocalClipAudioRecording {
  private let startError: Error?
  private let suspendsStart: Bool
  private var startContinuation: CheckedContinuation<LocalSession, Error>?
  private(set) var startCount = 0
  private(set) var stopCount = 0
  private var session: LocalSession?

  init(startError: Error? = nil, suspendsStart: Bool = false) {
    self.startError = startError
    self.suspendsStart = suspendsStart
  }

  func startRecording(title: String?) async throws -> LocalSession {
    startCount += 1
    if let startError { throw startError }
    if suspendsStart {
      return try await withCheckedThrowingContinuation { continuation in
        startContinuation = continuation
      }
    }
    let session = makeAudioSession(title: title)
    self.session = session
    return session
  }

  func resumeStart() {
    guard let continuation = startContinuation else { return }
    startContinuation = nil
    let session = makeAudioSession(title: "Suspended CLIP audio")
    self.session = session
    continuation.resume(returning: session)
  }

  func stopRecording() async -> LocalSession? {
    stopCount += 1
    defer { session = nil }
    return session
  }

  private func makeAudioSession(title: String?) -> LocalSession {
    LocalSession(
      id: UUID(),
      title: title ?? "Synthetic CLIP audio",
      startedAt: Date(),
      status: .recording,
      transcriptSegments: [],
      audioArtifacts: .init(
        micFileName: "mic.wav",
        micTranscriptFileName: "mic-transcript.wav",
        systemFileName: "system.wav",
        mixedFileName: "mixed.wav"
      )
    )
  }
}

@MainActor
private final class FakeClipScreenRecorder: LocalClipScreenRecording {
  private let stopResult: LocalClipScreenCaptureStopResult
  private(set) var startCount = 0
  private(set) var stopCount = 0

  init(
    stopResult: LocalClipScreenCaptureStopResult = .init(
      outcome: .stopped,
      terminationStatus: 0
    )
  ) {
    self.stopResult = stopResult
  }

  func startRecording(
    to videoURL: URL,
    onUnexpectedExit: @escaping @MainActor (String) -> Void
  ) throws {
    startCount += 1
  }

  func stopRecording() async -> LocalClipScreenCaptureStopResult {
    stopCount += 1
    return stopResult
  }
}

private struct NeverClipTranscriber: LocalSessionTranscribing {
  func warmUp(modelURL: URL) async {}

  func transcribe(
    wavURL: URL,
    modelURL: URL,
    language: String,
    prompt: String?,
    translateToEnglish: Bool,
    onProgress: (@Sendable (LocalSessionTranscriptionProgress) async -> Void)?
  ) async throws -> LocalSessionTranscriptionResult {
    throw MockCaptureError.transcriptionShouldNotRun
  }
}

private enum MockCaptureError: LocalizedError {
  case audioStartFailed
  case transcriptionShouldNotRun

  var errorDescription: String? {
    switch self {
    case .audioStartFailed:
      return "Synthetic audio start failed."
    case .transcriptionShouldNotRun:
      return "Synthetic transcription should not run."
    }
  }
}

private func makeClip(
  id: UUID,
  status: LocalClipStatus,
  title: String,
  intent: String?,
  segments: [LocalClipTranscriptSegment]
) -> LocalClipManifest {
  LocalClipManifest(
    id: id,
    title: title,
    startedAt: Date(timeIntervalSince1970: 1_700_000_000),
    endedAt: Date(timeIntervalSince1970: 1_700_000_001),
    status: status,
    intent: intent,
    videoFileName: "clip-video.mov",
    audioFileName: "clip-audio.wav",
    transcriptFileName: "transcript.json",
    notesFileName: "notes.md",
    transcriptSegments: segments,
    postNotes: "Stored notes",
    errorMessage: status == .failed ? "Stored failure" : nil
  )
}
