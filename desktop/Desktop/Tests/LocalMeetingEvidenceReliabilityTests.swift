import Darwin
import Foundation
import XCTest

@testable import CepessaSessions

final class LocalMeetingEvidenceReliabilityTests: XCTestCase {
  private var tempRoot: URL!
  private let fileManager = FileManager.default

  override func setUpWithError() throws {
    tempRoot = fileManager.temporaryDirectory.appendingPathComponent(
      "LocalMeetingEvidenceReliabilityTests-\(UUID().uuidString)",
      isDirectory: true
    )
    try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    if let tempRoot { try? fileManager.removeItem(at: tempRoot) }
  }

  func testLegacyEvidenceSummaryDecodesWithoutQualityFields() throws {
    let data = Data(
      #"{"runID":"run","revision":1,"disposition":"ready","contentHash":"hash","parentContentHash":null,"runFileName":"run.json","outboxFileName":"event.json","issues":[]}"#
        .utf8
    )
    let summary = try JSONDecoder().decode(
      LocalSessionTranscriptionEvidenceSummary.self, from: data)
    XCTAssertNil(summary.isComplete)
    XCTAssertNil(summary.speechCoverage)
    XCTAssertNil(summary.hasVerifiableTimestamps)
  }

  func testOutOfDurationASRTimingIsExcludedAndCannotBecomeReady() async throws {
    let layout = LocalMeetingFileLayout(baseDirectory: tempRoot)
    let session = makeSession()
    let urls = try writePrimaryWaves(layout: layout, sessionID: session.id, duration: 60)
    let transcription = ReliabilityTranscriptionStub(
      results: [
        "mic.wav": result(text: "outside", start: 120, end: 121),
        "system.wav": result(text: "inside", start: 0, end: 1),
      ]
    )
    let coordinator = LocalSessionEvidenceTranscriptionCoordinator(
      transcriptionService: transcription,
      diarizer: ReliabilityDiarizerStub(speechEnd: 60),
      fileLayout: layout,
      fileManager: fileManager,
      now: fixedNow
    )

    let output = try await coordinator.transcribe(
      makeInput(session: session, urls: urls)
    )

    XCTAssertEqual(output.envelope.run.disposition, .degraded)
    XCTAssertFalse(output.envelope.quality.isComplete)
    XCTAssertEqual(output.envelope.segments.map(\.activeText), ["inside"])
    XCTAssertTrue(
      output.envelope.run.issues.contains { $0.contains("outside the audio source") }
    )
  }

  func testSpeechCoverageUsesVerifiedSpeechIntervalsInsteadOfElapsedAudio() async throws {
    let layout = LocalMeetingFileLayout(baseDirectory: tempRoot)
    let session = makeSession()
    let urls = try writePrimaryWaves(layout: layout, sessionID: session.id, duration: 60)
    let transcription = ReliabilityTranscriptionStub(
      results: [
        "mic.wav": result(text: "one second", start: 0, end: 1),
        "system.wav": result(text: "עוד שנייה", start: 0, end: 1),
      ]
    )

    let incomplete = try await LocalSessionEvidenceTranscriptionCoordinator(
      transcriptionService: transcription,
      diarizer: ReliabilityDiarizerStub(speechEnd: 60),
      fileLayout: layout,
      fileManager: fileManager,
      now: fixedNow
    ).transcribe(makeInput(session: session, urls: urls))
    XCTAssertEqual(incomplete.envelope.run.disposition, .degraded)
    XCTAssertEqual(
      incomplete.envelope.quality.speechCoverage ?? -1, 1.0 / 60.0, accuracy: 0.000_001)
    XCTAssertFalse(incomplete.envelope.quality.isComplete)

    let completeLayout = LocalMeetingFileLayout(
      baseDirectory: tempRoot.appendingPathComponent("complete", isDirectory: true)
    )
    let completeURLs = try writePrimaryWaves(
      layout: completeLayout,
      sessionID: session.id,
      duration: 60
    )
    let complete = try await LocalSessionEvidenceTranscriptionCoordinator(
      transcriptionService: transcription,
      diarizer: ReliabilityDiarizerStub(speechEnd: 1),
      fileLayout: completeLayout,
      fileManager: fileManager,
      now: fixedNow
    ).transcribe(makeInput(session: session, urls: completeURLs))
    XCTAssertEqual(complete.envelope.run.disposition, .ready)
    XCTAssertEqual(complete.envelope.quality.speechCoverage, 1)
    XCTAssertTrue(complete.envelope.quality.isComplete)
  }

  func testOutOfDurationDiarizationKeepsCoverageUnknownAndCannotBecomeReady() async throws {
    let layout = LocalMeetingFileLayout(baseDirectory: tempRoot)
    let session = makeSession()
    let urls = try writePrimaryWaves(layout: layout, sessionID: session.id, duration: 1)
    let output = try await LocalSessionEvidenceTranscriptionCoordinator(
      transcriptionService: standardTranscriptionStub(),
      diarizer: ReliabilityDiarizerStub(speechEnd: 2),
      fileLayout: layout,
      fileManager: fileManager,
      now: fixedNow
    ).transcribe(makeInput(session: session, urls: urls))

    XCTAssertEqual(output.envelope.run.disposition, .degraded)
    XCTAssertNil(output.envelope.quality.speechCoverage)
    XCTAssertFalse(output.envelope.quality.isComplete)
    XCTAssertFalse(output.envelope.quality.hasVerifiableTimestamps)
    XCTAssertTrue(
      output.envelope.run.issues.contains { $0.contains("diarization contained timestamps") }
    )
    XCTAssertTrue(
      output.envelope.run.issues.contains { $0.contains("Speech coverage is unknown") }
    )
  }

  func testWaveEvidenceInspectorRejectsSymlinkAndHardlinkSourcesWithoutReadingTargets() throws {
    let externalURL = tempRoot.appendingPathComponent("external-audio.wav")
    try writeWave(to: externalURL, duration: 1)
    let originalData = try Data(contentsOf: externalURL)

    for usesSymbolicLink in [true, false] {
      let kind = usesSymbolicLink ? "symlink" : "hardlink"
      let linkedURL = tempRoot.appendingPathComponent("linked-audio-\(kind).wav")
      try createUnsafeLink(
        at: linkedURL,
        to: externalURL,
        symbolic: usesSymbolicLink
      )

      let inspection = LocalSessionWaveEvidenceInspector.inspect(
        url: linkedURL,
        fileManager: fileManager
      )

      XCTAssertEqual(inspection.integrity, .invalid)
      XCTAssertNil(inspection.duration)
      XCTAssertNil(inspection.sha256)
      XCTAssertTrue(inspection.issues.contains { $0.contains("unsafe linked audio") })
      XCTAssertEqual(try Data(contentsOf: externalURL), originalData)
      XCTAssertTrue(unsafeLinkEntryExists(at: linkedURL))
      try fileManager.removeItem(at: linkedURL)
    }
  }

  func testLinkedImportedAudioCannotMintTranscriptEvidenceFromExternalBytes() async throws {
    for usesSymbolicLink in [true, false] {
      let kind = usesSymbolicLink ? "symlink" : "hardlink"
      let layout = LocalMeetingFileLayout(
        baseDirectory: tempRoot.appendingPathComponent("linked-import-\(kind)", isDirectory: true)
      )
      let session = makeSession(id: UUID())
      try layout.ensureDirectories(fileManager: fileManager, for: session.id)
      let externalURL = tempRoot.appendingPathComponent("external-import-\(kind).wav")
      try writeWave(to: externalURL, duration: 1)
      let externalData = try Data(contentsOf: externalURL)
      let importedURL = layout.importedAudioURL(for: session.id)
      try createUnsafeLink(
        at: importedURL,
        to: externalURL,
        symbolic: usesSymbolicLink
      )
      let transcription = ReliabilityTranscriptionStub(
        results: ["imported.wav": result(text: "external words", start: 0, end: 1)]
      )
      let output = try await LocalSessionEvidenceTranscriptionCoordinator(
        transcriptionService: transcription,
        diarizer: ReliabilityDiarizerStub(speechEnd: 1),
        fileLayout: layout,
        fileManager: fileManager,
        now: fixedNow
      ).transcribe(makeImportedInput(session: session, importedURL: importedURL))

      XCTAssertEqual(output.envelope.run.disposition, .failed)
      XCTAssertEqual(output.envelope.sources.map(\.integrity), [.invalid])
      XCTAssertNil(output.envelope.sources.first?.sha256)
      XCTAssertTrue(output.envelope.segments.isEmpty)
      let transcriptionCallCount = await transcription.callCount()
      XCTAssertEqual(transcriptionCallCount, 0)
      XCTAssertEqual(try Data(contentsOf: externalURL), externalData)
      XCTAssertTrue(unsafeLinkEntryExists(at: importedURL))
    }
  }

  func testImportedPrimaryCanBeCompleteWithoutFabricatedCaptureSources() async throws {
    let layout = LocalMeetingFileLayout(baseDirectory: tempRoot)
    let session = makeSession()
    try layout.ensureDirectories(fileManager: fileManager, for: session.id)
    let importedURL = layout.importedAudioURL(for: session.id)
    try writeWave(to: importedURL, duration: 1)
    let transcription = ReliabilityTranscriptionStub(
      results: ["imported.wav": result(text: "imported", start: 0, end: 1)]
    )
    let coordinator = LocalSessionEvidenceTranscriptionCoordinator(
      transcriptionService: transcription,
      diarizer: ReliabilityDiarizerStub(speechEnd: 1),
      fileLayout: layout,
      fileManager: fileManager,
      now: fixedNow
    )
    let input = makeImportedInput(session: session, importedURL: importedURL)

    let output = try await coordinator.transcribe(input)

    XCTAssertEqual(output.envelope.run.disposition, .ready)
    XCTAssertTrue(output.envelope.quality.isComplete)
    XCTAssertEqual(output.envelope.quality.speechCoverage, 1)
    XCTAssertFalse(output.envelope.quality.sourceSeparationPreserved)
    XCTAssertEqual(output.envelope.sources.map(\.kind), [.imported])
    XCTAssertEqual(output.envelope.sources.map(\.role), ["primary"])
    XCTAssertFalse(output.envelope.run.issues.contains { $0.contains("microphone") })
    XCTAssertFalse(output.envelope.run.issues.contains { $0.contains("system") })

    let runURL = layout.transcriptionRunsDirectory(for: session.id)
      .appendingPathComponent(output.summary.runFileName)
    let outboxURL = layout.meetingEvidenceOutboxDirectory
      .appendingPathComponent(output.summary.outboxFileName)
    let originalAudio = try Data(contentsOf: importedURL)
    try fileManager.removeItem(at: outboxURL)
    var changedAudio = originalAudio
    changedAudio[changedAudio.count - 1] ^= 0x01
    try changedAudio.write(to: importedURL, options: .atomic)
    do {
      _ = try await coordinator.transcribe(input)
      XCTFail("Recovery must reject a changed imported source.")
    } catch {
      XCTAssertTrue(error.localizedDescription.contains("imported source no longer matches"))
    }
    XCTAssertTrue(fileManager.fileExists(atPath: runURL.path))
    XCTAssertFalse(fileManager.fileExists(atPath: outboxURL.path))

    try originalAudio.write(to: importedURL, options: .atomic)
    let recovered = try await coordinator.transcribe(input)
    let transcriptionCallCount = await transcription.callCount()
    XCTAssertEqual(recovered.envelope.contentHash, output.envelope.contentHash)
    XCTAssertEqual(recovered.summary, output.summary)
    XCTAssertEqual(transcriptionCallCount, 1)
    XCTAssertEqual(try Data(contentsOf: runURL), try Data(contentsOf: outboxURL))
  }

  func testImportedPrimaryWithPartialOrUnknownCoverageIsNotComplete() async throws {
    let session = makeSession()
    let partialLayout = LocalMeetingFileLayout(baseDirectory: tempRoot)
    try partialLayout.ensureDirectories(fileManager: fileManager, for: session.id)
    let partialURL = partialLayout.importedAudioURL(for: session.id)
    try writeWave(to: partialURL, duration: 60)
    let transcription = ReliabilityTranscriptionStub(
      results: ["imported.wav": result(text: "partial", start: 0, end: 1)]
    )
    let partial = try await LocalSessionEvidenceTranscriptionCoordinator(
      transcriptionService: transcription,
      diarizer: ReliabilityDiarizerStub(speechEnd: 60),
      fileLayout: partialLayout,
      fileManager: fileManager,
      now: fixedNow
    ).transcribe(makeImportedInput(session: session, importedURL: partialURL))
    XCTAssertEqual(partial.envelope.run.disposition, .degraded)
    XCTAssertEqual(partial.envelope.quality.speechCoverage ?? -1, 1.0 / 60.0, accuracy: 0.000_001)
    XCTAssertFalse(partial.envelope.quality.isComplete)

    let unknownSession = makeSession(id: UUID())
    let unknownLayout = LocalMeetingFileLayout(
      baseDirectory: tempRoot.appendingPathComponent("unknown", isDirectory: true)
    )
    try unknownLayout.ensureDirectories(fileManager: fileManager, for: unknownSession.id)
    let unknownURL = unknownLayout.importedAudioURL(for: unknownSession.id)
    try writeWave(to: unknownURL, duration: 1)
    let unknown = try await LocalSessionEvidenceTranscriptionCoordinator(
      transcriptionService: transcription,
      diarizer: ReliabilityUnavailableDiarizerStub(),
      fileLayout: unknownLayout,
      fileManager: fileManager,
      now: fixedNow
    ).transcribe(makeImportedInput(session: unknownSession, importedURL: unknownURL))
    XCTAssertEqual(unknown.envelope.run.disposition, .degraded)
    XCTAssertNil(unknown.envelope.quality.speechCoverage)
    XCTAssertFalse(unknown.envelope.quality.isComplete)
  }

  func testRecoveredReadyEvidenceRejectsRehashedSemanticContradictionsBeforeOutboxRepair()
    async throws
  {
    typealias Mutation = (inout [String: Any]) -> Void
    let mutations: [(name: String, apply: Mutation)] = [
      (
        "incomplete quality",
        { object in
          var quality = object["quality"] as! [String: Any]
          quality["isComplete"] = false
          object["quality"] = quality
        }
      ),
      (
        "fallback imported role",
        { object in
          var sources = object["sources"] as! [[String: Any]]
          sources[0]["role"] = "fallback"
          object["sources"] = sources
        }
      ),
      (
        "insufficient coverage",
        { object in
          var quality = object["quality"] as! [String: Any]
          quality["speechCoverage"] = 0.5
          object["quality"] = quality
        }
      ),
      (
        "unavailable diarization",
        { object in
          var run = object["run"] as! [String: Any]
          run["diarizationStatus"] = "unavailable"
          object["run"] = run
          var quality = object["quality"] as! [String: Any]
          quality["diarization"] = "unavailable"
          object["quality"] = quality
        }
      ),
      (
        "empty transcript",
        { object in
          object["segments"] = [[String: Any]]()
          object["speakers"] = [[String: Any]]()
          object["transcript"] = [
            "renderedText": "",
            "byteOffsets": [[String: Any]](),
          ]
        }
      ),
      (
        "out-of-bounds segment",
        { object in
          var segments = object["segments"] as! [[String: Any]]
          segments[0]["endSeconds"] = 99.0
          object["segments"] = segments
        }
      ),
    ]

    for (index, mutation) in mutations.enumerated() {
      let caseRoot = tempRoot.appendingPathComponent("semantic-\(index)", isDirectory: true)
      let layout = LocalMeetingFileLayout(baseDirectory: caseRoot)
      let session = makeSession(id: UUID())
      try layout.ensureDirectories(fileManager: fileManager, for: session.id)
      let importedURL = layout.importedAudioURL(for: session.id)
      try writeWave(to: importedURL, duration: 1)
      let transcription = ReliabilityTranscriptionStub(
        results: ["imported.wav": result(text: "imported", start: 0, end: 1)]
      )
      let coordinator = LocalSessionEvidenceTranscriptionCoordinator(
        transcriptionService: transcription,
        diarizer: ReliabilityDiarizerStub(speechEnd: 1),
        fileLayout: layout,
        fileManager: fileManager,
        now: fixedNow
      )
      let input = makeImportedInput(session: session, importedURL: importedURL)
      let output = try await coordinator.transcribe(input)
      let runURL = layout.transcriptionRunsDirectory(for: session.id)
        .appendingPathComponent(output.summary.runFileName)
      let outboxURL = layout.meetingEvidenceOutboxDirectory
        .appendingPathComponent(output.summary.outboxFileName)
      let rehashedData = try rehashedEnvelopeData(
        try Data(contentsOf: runURL),
        mutation: mutation.apply
      )
      try fileManager.removeItem(at: outboxURL)
      try rehashedData.write(to: runURL, options: .atomic)

      do {
        _ = try await coordinator.transcribe(input)
        XCTFail("Recovery accepted \(mutation.name).")
      } catch {
        XCTAssertTrue(
          error.localizedDescription.contains("inconsistent transcript evidence"),
          "Unexpected error for \(mutation.name): \(error)"
        )
      }
      let outboxFiles = try fileManager.contentsOfDirectory(
        at: layout.meetingEvidenceOutboxDirectory,
        includingPropertiesForKeys: nil
      )
      XCTAssertTrue(outboxFiles.isEmpty, "Recovery repaired outbox for \(mutation.name).")
      XCTAssertFalse(fileManager.fileExists(atPath: runURL.path))
      let preservedFiles = try fileManager.contentsOfDirectory(
        at: layout.transcriptionRunsDirectory(for: session.id),
        includingPropertiesForKeys: nil
      ).filter { $0.pathExtension == "artifact" }
      XCTAssertEqual(preservedFiles.count, 1)
      XCTAssertEqual(try Data(contentsOf: XCTUnwrap(preservedFiles.first)), rehashedData)
    }
  }

  func testRecoveredDegradedAndFailedImportedEvidenceRemainIdempotent() async throws {
    let cases:
      [(name: String, text: String, transcriptEnd: TimeInterval, speechEnd: TimeInterval)] = [
        ("degraded", "partial", 1, 60),
        ("failed", "   ", 1, 1),
      ]

    for (index, testCase) in cases.enumerated() {
      let caseRoot = tempRoot.appendingPathComponent("nonready-\(index)", isDirectory: true)
      let layout = LocalMeetingFileLayout(baseDirectory: caseRoot)
      let session = makeSession(id: UUID())
      try layout.ensureDirectories(fileManager: fileManager, for: session.id)
      let importedURL = layout.importedAudioURL(for: session.id)
      try writeWave(to: importedURL, duration: 60)
      let transcription = ReliabilityTranscriptionStub(
        results: [
          "imported.wav": result(
            text: testCase.text,
            start: 0,
            end: testCase.transcriptEnd
          )
        ]
      )
      let coordinator = LocalSessionEvidenceTranscriptionCoordinator(
        transcriptionService: transcription,
        diarizer: ReliabilityDiarizerStub(speechEnd: testCase.speechEnd),
        fileLayout: layout,
        fileManager: fileManager,
        now: fixedNow
      )
      let input = makeImportedInput(session: session, importedURL: importedURL)
      let output = try await coordinator.transcribe(input)
      XCTAssertEqual(output.envelope.run.disposition.rawValue, testCase.name)
      XCTAssertFalse(output.envelope.quality.isComplete)

      let runURL = layout.transcriptionRunsDirectory(for: session.id)
        .appendingPathComponent(output.summary.runFileName)
      let outboxURL = layout.meetingEvidenceOutboxDirectory
        .appendingPathComponent(output.summary.outboxFileName)
      let runData = try Data(contentsOf: runURL)
      try fileManager.removeItem(at: outboxURL)

      let recovered = try await coordinator.transcribe(input)
      let transcriptionCallCount = await transcription.callCount()
      XCTAssertEqual(recovered.envelope.contentHash, output.envelope.contentHash)
      XCTAssertEqual(transcriptionCallCount, 1)
      XCTAssertEqual(try Data(contentsOf: runURL), runData)
      XCTAssertEqual(try Data(contentsOf: outboxURL), runData)
    }
  }

  func testRecoveryRejectsSymlinkAndHardlinkRunEntriesWithoutFollowingTargets() async throws {
    for usesSymbolicLink in [true, false] {
      let kind = usesSymbolicLink ? "symlink" : "hardlink"
      let layout = LocalMeetingFileLayout(
        baseDirectory: tempRoot.appendingPathComponent("unsafe-run-\(kind)", isDirectory: true)
      )
      let session = makeSession(id: UUID())
      try layout.ensureDirectories(fileManager: fileManager, for: session.id)
      let importedURL = layout.importedAudioURL(for: session.id)
      try writeWave(to: importedURL, duration: 1)
      let transcription = ReliabilityTranscriptionStub(
        results: ["imported.wav": result(text: "imported", start: 0, end: 1)]
      )
      let coordinator = LocalSessionEvidenceTranscriptionCoordinator(
        transcriptionService: transcription,
        diarizer: ReliabilityDiarizerStub(speechEnd: 1),
        fileLayout: layout,
        fileManager: fileManager,
        now: fixedNow
      )
      let input = makeImportedInput(session: session, importedURL: importedURL)
      let output = try await coordinator.transcribe(input)
      let runURL = layout.transcriptionRunsDirectory(for: session.id)
        .appendingPathComponent(output.summary.runFileName)
      let outboxURL = layout.meetingEvidenceOutboxDirectory
        .appendingPathComponent(output.summary.outboxFileName)
      let externalURL = tempRoot.appendingPathComponent("external-run-\(kind).json")
      let originalData = try Data(contentsOf: runURL)
      try originalData.write(to: externalURL)
      try fileManager.removeItem(at: runURL)
      try fileManager.removeItem(at: outboxURL)
      try createUnsafeLink(
        at: runURL,
        to: externalURL,
        symbolic: usesSymbolicLink
      )

      for _ in 0..<2 {
        do {
          _ = try await coordinator.transcribe(input)
          XCTFail("Recovery followed an unsafe \(kind) run entry.")
        } catch {
          XCTAssertTrue(error.localizedDescription.contains("single-link file"))
        }
      }

      XCTAssertEqual(try Data(contentsOf: externalURL), originalData)
      XCTAssertTrue(unsafeLinkEntryExists(at: runURL))
      XCTAssertTrue(
        try fileManager.contentsOfDirectory(
          at: layout.meetingEvidenceOutboxDirectory,
          includingPropertiesForKeys: nil
        ).isEmpty
      )
      let transcriptionCallCount = await transcription.callCount()
      XCTAssertEqual(transcriptionCallCount, 1)
    }
  }

  func testRecoveryRejectsSymlinkAndHardlinkOutboxEntriesWithoutFollowingTargets() async throws {
    for usesSymbolicLink in [true, false] {
      let kind = usesSymbolicLink ? "symlink" : "hardlink"
      let layout = LocalMeetingFileLayout(
        baseDirectory: tempRoot.appendingPathComponent("unsafe-outbox-\(kind)", isDirectory: true)
      )
      let session = makeSession(id: UUID())
      try layout.ensureDirectories(fileManager: fileManager, for: session.id)
      let importedURL = layout.importedAudioURL(for: session.id)
      try writeWave(to: importedURL, duration: 1)
      let transcription = ReliabilityTranscriptionStub(
        results: ["imported.wav": result(text: "imported", start: 0, end: 1)]
      )
      let coordinator = LocalSessionEvidenceTranscriptionCoordinator(
        transcriptionService: transcription,
        diarizer: ReliabilityDiarizerStub(speechEnd: 1),
        fileLayout: layout,
        fileManager: fileManager,
        now: fixedNow
      )
      let input = makeImportedInput(session: session, importedURL: importedURL)
      let output = try await coordinator.transcribe(input)
      let outboxURL = layout.meetingEvidenceOutboxDirectory
        .appendingPathComponent(output.summary.outboxFileName)
      let externalURL = tempRoot.appendingPathComponent("external-outbox-\(kind).json")
      let originalData = try Data(contentsOf: outboxURL)
      try originalData.write(to: externalURL)
      try fileManager.removeItem(at: outboxURL)
      try createUnsafeLink(
        at: outboxURL,
        to: externalURL,
        symbolic: usesSymbolicLink
      )

      for _ in 0..<2 {
        do {
          _ = try await coordinator.transcribe(input)
          XCTFail("Recovery followed an unsafe \(kind) outbox entry.")
        } catch {
          XCTAssertTrue(error.localizedDescription.contains("single-link file"))
        }
      }

      XCTAssertEqual(try Data(contentsOf: externalURL), originalData)
      XCTAssertTrue(unsafeLinkEntryExists(at: outboxURL))
      let transcriptionCallCount = await transcription.callCount()
      XCTAssertEqual(transcriptionCallCount, 1)
    }
  }

  func testPrimaryProgressCombinesBothSourcesAndNeverMovesBackward() async throws {
    let layout = LocalMeetingFileLayout(baseDirectory: tempRoot)
    let session = makeSession()
    let urls = try writePrimaryWaves(layout: layout, sessionID: session.id, duration: 1)
    let recorder = ReliabilityProgressRecorder()
    let transcription = ReliabilityTranscriptionStub(
      results: [
        "mic.wav": result(text: "microphone", start: 0, end: 1),
        "system.wav": result(text: "system", start: 0, end: 1),
      ],
      emitsProgress: true
    )
    let input = LocalSessionEvidenceTranscriptionInput(
      session: session,
      plan: makePlan(),
      microphoneURL: urls.microphone,
      systemURL: urls.system,
      mixedURL: nil,
      revision: 1,
      parentContentHash: nil,
      onProgress: { update in await recorder.record(update) }
    )

    _ = try await LocalSessionEvidenceTranscriptionCoordinator(
      transcriptionService: transcription,
      diarizer: ReliabilityDiarizerStub(speechEnd: 1),
      fileLayout: layout,
      fileManager: fileManager,
      now: fixedNow
    ).transcribe(input)

    let updates = await recorder.updates()
    let percents = updates.compactMap { update -> Int? in
      guard case .transcribing(let percent) = update.stage else { return nil }
      return percent
    }
    XCTAssertFalse(percents.isEmpty)
    XCTAssertEqual(percents, percents.sorted())
    XCTAssertEqual(percents.last, 100)
    let largestDraft = updates.compactMap { update -> Int? in
      guard case .partialSegments(let segments) = update.stage else { return nil }
      return segments.count
    }.max()
    XCTAssertEqual(largestDraft, 2)
  }

  func testRetryRepairsMissingOutboxFromExactImmutableRunWithoutRetranscribing() async throws {
    let session = makeSession()
    let targetLayout = LocalMeetingFileLayout(baseDirectory: tempRoot)
    let targetURLs = try writePrimaryWaves(
      layout: targetLayout,
      sessionID: session.id,
      duration: 1
    )
    let transcription = standardTranscriptionStub()
    let failOnce = ReliabilityFailOnce()
    let coordinator = LocalSessionEvidenceTranscriptionCoordinator(
      transcriptionService: transcription,
      diarizer: ReliabilityDiarizerStub(speechEnd: 1),
      fileLayout: targetLayout,
      fileManager: fileManager,
      now: fixedNow,
      beforeOutboxWrite: { try failOnce.run() }
    )

    do {
      _ = try await coordinator.transcribe(makeInput(session: session, urls: targetURLs))
      XCTFail("The injected outbox failure should interrupt the first commit.")
    } catch {
      let runFiles = try fileManager.contentsOfDirectory(
        at: targetLayout.transcriptionRunsDirectory(for: session.id),
        includingPropertiesForKeys: nil
      ).filter { $0.pathExtension == "json" }
      XCTAssertEqual(runFiles.count, 1)
      let unpublishedOutboxFiles = try fileManager.contentsOfDirectory(
        at: targetLayout.meetingEvidenceOutboxDirectory,
        includingPropertiesForKeys: nil
      )
      XCTAssertTrue(unpublishedOutboxFiles.isEmpty)
    }

    var renamedSession = session
    renamedSession.title = "Renamed after failed commit"
    let recovered = try await coordinator.transcribe(
      makeInput(session: renamedSession, urls: targetURLs)
    )
    let transcriptionCallCount = await transcription.callCount()
    XCTAssertEqual(transcriptionCallCount, 2)
    XCTAssertEqual(recovered.envelope.session.title, session.title)
    let runData = try Data(
      contentsOf: targetLayout.transcriptionRunsDirectory(for: session.id)
        .appendingPathComponent(recovered.summary.runFileName)
    )
    let outboxData = try Data(
      contentsOf: targetLayout.meetingEvidenceOutboxDirectory
        .appendingPathComponent(recovered.summary.outboxFileName)
    )
    XCTAssertEqual(runData, outboxData)
  }

  func testRetryPreservesCorruptImmutableRunBeforeAllowingFreshTranscription() async throws {
    let session = makeSession()
    let layout = LocalMeetingFileLayout(baseDirectory: tempRoot)
    let urls = try writePrimaryWaves(layout: layout, sessionID: session.id, duration: 1)
    let transcription = standardTranscriptionStub()
    let coordinator = LocalSessionEvidenceTranscriptionCoordinator(
      transcriptionService: transcription,
      diarizer: ReliabilityDiarizerStub(speechEnd: 1),
      fileLayout: layout,
      fileManager: fileManager,
      now: fixedNow
    )
    let first = try await coordinator.transcribe(makeInput(session: session, urls: urls))
    let runURL = layout.transcriptionRunsDirectory(for: session.id)
      .appendingPathComponent(first.summary.runFileName)
    let outboxURL = layout.meetingEvidenceOutboxDirectory
      .appendingPathComponent(first.summary.outboxFileName)
    try fileManager.removeItem(at: outboxURL)
    var object = try XCTUnwrap(
      try JSONSerialization.jsonObject(with: Data(contentsOf: runURL)) as? [String: Any]
    )
    object["contentHash"] = String(repeating: "0", count: 64)
    let corruptData = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    try corruptData.write(to: runURL, options: .atomic)
    var corruptStatus = stat()
    XCTAssertEqual(lstat(runURL.path, &corruptStatus), 0)

    do {
      _ = try await coordinator.transcribe(makeInput(session: session, urls: urls))
      XCTFail("A mismatched immutable hash must be rejected.")
    } catch {
      XCTAssertTrue(error.localizedDescription.contains("exact bytes were preserved"))
    }
    XCTAssertFalse(fileManager.fileExists(atPath: runURL.path))
    XCTAssertFalse(fileManager.fileExists(atPath: outboxURL.path))
    let preservedFiles = try fileManager.contentsOfDirectory(
      at: layout.transcriptionRunsDirectory(for: session.id),
      includingPropertiesForKeys: nil
    ).filter { $0.pathExtension == "artifact" }
    XCTAssertEqual(preservedFiles.count, 1)
    let preservedURL = try XCTUnwrap(preservedFiles.first)
    XCTAssertEqual(try Data(contentsOf: preservedURL), corruptData)
    var preservedStatus = stat()
    XCTAssertEqual(lstat(preservedURL.path, &preservedStatus), 0)
    XCTAssertNotEqual(preservedStatus.st_ino, corruptStatus.st_ino)
    XCTAssertEqual(preservedStatus.st_nlink, 1)

    let fresh = try await coordinator.transcribe(makeInput(session: session, urls: urls))
    let freshTranscriptionCallCount = await transcription.callCount()
    XCTAssertEqual(freshTranscriptionCallCount, 4)
    XCTAssertEqual(fresh.envelope.contentHash, first.envelope.contentHash)
    XCTAssertTrue(fileManager.fileExists(atPath: runURL.path))
    XCTAssertTrue(fileManager.fileExists(atPath: outboxURL.path))
  }

  private func standardTranscriptionStub() -> ReliabilityTranscriptionStub {
    ReliabilityTranscriptionStub(
      results: [
        "mic.wav": result(text: "microphone", start: 0, end: 1),
        "system.wav": result(text: "system", start: 0, end: 1),
      ]
    )
  }

  private func makeSession(
    id: UUID = UUID(uuidString: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")!
  ) -> LocalSession {
    LocalSession(
      id: id,
      title: "Reliability",
      startedAt: Date(timeIntervalSince1970: 1_700_000_000.456),
      status: .transcribing,
      transcriptSegments: [],
      audioArtifacts: .init(
        micFileName: "mic.wav",
        micTranscriptFileName: nil,
        systemFileName: "system.wav",
        mixedFileName: nil
      )
    )
  }

  private func makePlan() -> LocalSessionTranscriptionPlan {
    .init(
      engine: .whisperKit,
      modelURL: URL(fileURLWithPath: "/models/reliability-test"),
      language: "auto",
      prompt: nil,
      modelFlavor: .whisperKitMultilingualTurbo,
      speedMode: .balanced
    )
  }

  private func makeInput(
    session: LocalSession,
    urls: (microphone: URL, system: URL)
  ) -> LocalSessionEvidenceTranscriptionInput {
    .init(
      session: session,
      plan: makePlan(),
      microphoneURL: urls.microphone,
      systemURL: urls.system,
      mixedURL: nil,
      revision: 1,
      parentContentHash: nil
    )
  }

  private func makeImportedInput(
    session: LocalSession,
    importedURL: URL
  ) -> LocalSessionEvidenceTranscriptionInput {
    .init(
      session: session,
      plan: makePlan(),
      microphoneURL: nil,
      systemURL: nil,
      mixedURL: nil,
      revision: 1,
      parentContentHash: nil,
      importedURL: importedURL
    )
  }

  private func result(
    text: String,
    start: TimeInterval,
    end: TimeInterval
  ) -> LocalSessionTranscriptionResult {
    .init(
      text: text,
      detectedLanguage: "en",
      segments: [.init(startTime: start, endTime: end, text: text)],
      modelPath: "/models/reliability-test",
      engine: .whisperKit
    )
  }

  private func rehashedEnvelopeData(
    _ data: Data,
    mutation: (inout [String: Any]) -> Void
  ) throws -> Data {
    var object = try XCTUnwrap(
      try JSONSerialization.jsonObject(with: data) as? [String: Any]
    )
    mutation(&object)
    object["contentHash"] = String(repeating: "0", count: 64)
    let placeholderData = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    object["contentHash"] = try MeetingEvidenceCanonicalizer.contentHash(
      envelopeData: placeholderData
    )
    return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
  }

  private func createUnsafeLink(
    at linkURL: URL,
    to targetURL: URL,
    symbolic: Bool
  ) throws {
    if symbolic {
      try fileManager.createSymbolicLink(at: linkURL, withDestinationURL: targetURL)
    } else {
      try fileManager.linkItem(at: targetURL, to: linkURL)
    }
  }

  private func unsafeLinkEntryExists(at url: URL) -> Bool {
    var status = stat()
    return lstat(url.path, &status) == 0
  }

  private func writePrimaryWaves(
    layout: LocalMeetingFileLayout,
    sessionID: UUID,
    duration: TimeInterval
  ) throws -> (microphone: URL, system: URL) {
    try layout.ensureDirectories(fileManager: fileManager, for: sessionID)
    let microphone = layout.micAudioURL(for: sessionID)
    let system = layout.systemAudioURL(for: sessionID)
    try writeWave(to: microphone, duration: duration)
    try writeWave(to: system, duration: duration)
    return (microphone, system)
  }

  private func writeWave(to url: URL, duration: TimeInterval) throws {
    let sampleData = Data(repeating: 0, count: Int(duration * 32_000))
    var data = Data()
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
    try data.write(to: url)
  }

  private func appendUInt16(_ value: UInt16, to data: inout Data) {
    var littleEndian = value.littleEndian
    withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
  }

  private func appendUInt32(_ value: UInt32, to data: inout Data) {
    var littleEndian = value.littleEndian
    withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
  }

  private var fixedNow: @Sendable () -> Date {
    { Date(timeIntervalSince1970: 1_800_000_000) }
  }
}

private actor ReliabilityTranscriptionStub: LocalSessionTranscribing {
  private let results: [String: LocalSessionTranscriptionResult]
  private let emitsProgress: Bool
  private var calls = 0

  init(results: [String: LocalSessionTranscriptionResult], emitsProgress: Bool = false) {
    self.results = results
    self.emitsProgress = emitsProgress
  }

  func warmUp(modelURL: URL) async {}

  func transcribe(
    wavURL: URL,
    modelURL: URL,
    language: String,
    prompt: String?,
    translateToEnglish: Bool,
    onProgress: (@Sendable (LocalSessionTranscriptionProgress) async -> Void)?
  ) async throws -> LocalSessionTranscriptionResult {
    calls += 1
    guard let result = results[wavURL.lastPathComponent] else {
      throw LocalSessionTranscriptionServiceError.transcriptionFailed("Missing stub result.")
    }
    if emitsProgress, let onProgress {
      await onProgress(.init(stage: .decodingAudio))
      await onProgress(.init(stage: .loadingModel))
      await onProgress(
        .init(stage: .analyzingSpeech(chunks: 1, speechDuration: 1, skippedSilenceDuration: 0))
      )
      await onProgress(.init(stage: .transcribing(percent: 50)))
      await onProgress(.init(stage: .partialSegments(result.segments)))
      await onProgress(.init(stage: .transcribing(percent: 100)))
      await onProgress(.init(stage: .extractingSegments))
    }
    return result
  }

  func callCount() -> Int { calls }
}

private struct ReliabilityDiarizerStub: LocalSessionDiarizing {
  let speechEnd: TimeInterval

  func diarize(
    wavURL: URL,
    source: LocalSessionAudioSourceKind,
    sessionID: UUID
  ) async -> LocalSessionDiarizationResult {
    .init(
      status: .available,
      clusters: [
        .init(
          stableID: "speaker-\(source.rawValue)",
          startSeconds: 0,
          endSeconds: speechEnd,
          confidence: 0.9
        )
      ],
      issues: []
    )
  }
}

private struct ReliabilityUnavailableDiarizerStub: LocalSessionDiarizing {
  func diarize(
    wavURL: URL,
    source: LocalSessionAudioSourceKind,
    sessionID: UUID
  ) async -> LocalSessionDiarizationResult {
    .init(status: .unavailable, clusters: [], issues: ["Diarization unavailable."])
  }
}

private actor ReliabilityProgressRecorder {
  private var recorded: [LocalSessionTranscriptionProgress] = []

  func record(_ update: LocalSessionTranscriptionProgress) {
    recorded.append(update)
  }

  func updates() -> [LocalSessionTranscriptionProgress] { recorded }
}

private final class ReliabilityFailOnce: @unchecked Sendable {
  private let lock = NSLock()
  private var shouldFail = true

  func run() throws {
    lock.lock()
    defer { lock.unlock() }
    guard shouldFail else { return }
    shouldFail = false
    throw NSError(
      domain: "LocalMeetingEvidenceReliabilityTests",
      code: 1,
      userInfo: [NSLocalizedDescriptionKey: "Injected outbox write failure"]
    )
  }
}
