import Foundation
import XCTest

@testable import CepessaSessions

final class LocalMeetingEvidenceTranscriptionTests: XCTestCase {
  private var tempRoot: URL!
  private let fileManager = FileManager.default

  override func setUpWithError() throws {
    tempRoot = fileManager.temporaryDirectory.appendingPathComponent(
      "LocalMeetingEvidenceTranscriptionTests-\(UUID().uuidString)",
      isDirectory: true
    )
    try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    if let tempRoot { try? fileManager.removeItem(at: tempRoot) }
  }

  func testDeterministicIndependentSourcesProduceReadyImmutableEnvelope() async throws {
    let layout = LocalMeetingFileLayout(baseDirectory: tempRoot)
    let session = makeSession()
    try layout.ensureDirectories(fileManager: fileManager, for: session.id)
    let micURL = layout.micTranscriptAudioURL(for: session.id)
    let systemURL = layout.systemAudioURL(for: session.id)
    let mixedURL = layout.mixedAudioURL(for: session.id)
    try writeWave(to: micURL)
    try writeWave(to: systemURL)
    try writeWave(to: mixedURL)

    let transcription = EvidenceTranscriptionStub(
      results: [
        "mic-transcript.wav": result("I will ship it", language: "en"),
        "system.wav": result("אני מסכים", language: "he"),
        "mixed.wav": result("unused", language: "en"),
      ]
    )
    let diarizer = RecordingEvidenceDiarizerStub()
    let coordinator = LocalSessionEvidenceTranscriptionCoordinator(
      transcriptionService: transcription,
      diarizer: diarizer,
      fileLayout: layout,
      fileManager: fileManager,
      now: { Date(timeIntervalSince1970: 1_800_000_000) }
    )
    let output = try await coordinator.transcribe(
      .init(
        session: session,
        plan: makePlan(),
        microphoneURL: micURL,
        systemURL: systemURL,
        mixedURL: mixedURL,
        revision: 1,
        parentContentHash: nil
      )
    )

    XCTAssertEqual(output.envelope.run.disposition, .ready)
    XCTAssertEqual(output.envelope.session.status, .ready)
    XCTAssertTrue(output.envelope.quality.isComplete)
    XCTAssertEqual(Set(output.envelope.sources.map(\.kind)), [.microphone, .system])
    XCTAssertTrue(
      output.envelope.sources.allSatisfy { source in
        guard let sha256 = source.sha256 else { return false }
        return sha256.count == 64
          && sha256 == sha256.lowercased()
          && sha256.allSatisfy(\.isHexDigit)
      }
    )
    let calledFileNames = await transcription.calledFileNames()
    XCTAssertEqual(calledFileNames, ["mic-transcript.wav", "system.wav"])
    let diarizedSources = await diarizer.calledSources()
    XCTAssertEqual(Set(diarizedSources), [.microphone, .system])
    XCTAssertEqual(output.envelope.segments.count, 2)
    XCTAssertEqual(output.envelope.transcript.byteOffsets.count, 2)
    XCTAssertEqual(
      output.envelope.contentHash,
      try MeetingEvidenceCanonicalizer.contentHash(
        payload: MeetingEvidenceHashPayloadV1(envelope: output.envelope)
      )
    )

    let runURL = layout.transcriptionRunsDirectory(for: session.id)
      .appendingPathComponent(output.summary.runFileName)
    let outboxURL = layout.meetingEvidenceOutboxDirectory
      .appendingPathComponent(output.summary.outboxFileName)
    XCTAssertTrue(fileManager.fileExists(atPath: runURL.path))
    XCTAssertTrue(fileManager.fileExists(atPath: outboxURL.path))
    let outboxData = try Data(contentsOf: outboxURL)
    XCTAssertEqual(try Data(contentsOf: runURL), outboxData)
    let rawCanonicalHash = try MeetingEvidenceCanonicalizer.contentHash(envelopeData: outboxData)
    XCTAssertEqual(rawCanonicalHash, output.envelope.contentHash)

    let json = try XCTUnwrap(
      try JSONSerialization.jsonObject(with: outboxData) as? [String: Any]
    )
    XCTAssertNotNil(json["quality"])
    XCTAssertNotNil((json["session"] as? [String: Any])?["status"])
    XCTAssertNotNil(((json["sources"] as? [[String: Any]])?.first)?["role"])
    XCTAssertNotNil(((json["speakers"] as? [[String: Any]])?.first)?["kind"])
    XCTAssertTrue(
      (((json["segments"] as? [[String: Any]])?.first)?["uncertainty"] as? [String])?
        .contains("speaker-mapping-segment-level") == true
    )
    try assertTranscriptOffsetsReconstructActiveText(json)

    let tamperedHashes = try [
      tamperedHash(outboxData) { object in
        var speakers = object["speakers"] as! [[String: Any]]
        speakers[0]["label"] = "Tampered speaker"
        object["speakers"] = speakers
      },
      tamperedHash(outboxData) { object in
        var sources = object["sources"] as! [[String: Any]]
        sources[0]["integrity"] = "missing"
        object["sources"] = sources
      },
      tamperedHash(outboxData) { object in
        var segments = object["segments"] as! [[String: Any]]
        segments[0]["startSeconds"] = 0.25
        object["segments"] = segments
      },
      tamperedHash(outboxData) { object in
        var quality = object["quality"] as! [String: Any]
        quality["isComplete"] = false
        object["quality"] = quality
      },
    ]
    XCTAssertTrue(tamperedHashes.allSatisfy { $0 != output.envelope.contentHash })

    do {
      _ = try await coordinator.transcribe(
        .init(
          session: session,
          plan: makePlan(),
          microphoneURL: micURL,
          systemURL: systemURL,
          mixedURL: mixedURL,
          revision: 1,
          parentContentHash: nil
        )
      )
      XCTFail("An existing immutable run must never be overwritten.")
    } catch LocalSessionEvidenceCoordinatorError.immutableArtifactExists {
      // Expected.
    }
  }

  func testUsablePrimaryIsPreservedWhenOtherPrimaryIsMissing() async throws {
    let layout = LocalMeetingFileLayout(baseDirectory: tempRoot)
    let session = makeSession()
    try layout.ensureDirectories(fileManager: fileManager, for: session.id)
    let micURL = layout.micTranscriptAudioURL(for: session.id)
    let mixedURL = layout.mixedAudioURL(for: session.id)
    try writeWave(to: micURL)
    try writeWave(to: mixedURL)
    let transcription = EvidenceTranscriptionStub(
      results: [
        "mic-transcript.wav": result("preserved microphone", language: "en"),
        "mixed.wav": result("degraded fallback", language: "en"),
      ]
    )
    let coordinator = LocalSessionEvidenceTranscriptionCoordinator(
      transcriptionService: transcription,
      diarizer: EvidenceDiarizerStub(),
      fileLayout: layout,
      fileManager: fileManager
    )

    let output = try await coordinator.transcribe(
      .init(
        session: session,
        plan: makePlan(),
        microphoneURL: micURL,
        systemURL: nil,
        mixedURL: mixedURL,
        revision: 1,
        parentContentHash: nil
      )
    )

    XCTAssertEqual(output.envelope.run.disposition, .degraded)
    XCTAssertEqual(output.envelope.session.status, .failed)
    XCTAssertFalse(output.envelope.quality.isComplete)
    XCTAssertEqual(output.envelope.segments.map(\.activeText), ["preserved microphone"])
    let calledFileNames = await transcription.calledFileNames()
    XCTAssertEqual(calledFileNames, ["mic-transcript.wav"])
  }

  func testLegacySessionWithoutEvidenceStillDecodes() throws {
    let session = makeSession()
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    var json = try XCTUnwrap(
      try JSONSerialization.jsonObject(with: encoder.encode(session)) as? [String: Any]
    )
    json.removeValue(forKey: "transcriptionEvidence")
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(
      LocalSession.self,
      from: JSONSerialization.data(withJSONObject: json)
    )
    XCTAssertNil(decoded.transcriptionEvidence)
  }

  func testUnavailableSpeakerKitDoesNotDownloadOrFakeAvailability() async {
    let diarizer = LocalSessionSpeakerKitDiarizer(
      modelFolderURL: tempRoot.appendingPathComponent("missing-speakerkit-models"),
      fileManager: fileManager
    )
    let result = await diarizer.diarize(
      wavURL: tempRoot.appendingPathComponent("missing.wav"),
      source: .system,
      sessionID: UUID()
    )
    XCTAssertEqual(result.status, .unavailable)
    XCTAssertTrue(result.clusters.isEmpty)
  }

  func testUnavailableDiarizationPreservesBothSeparatedPrimaryTranscripts() async throws {
    let layout = LocalMeetingFileLayout(baseDirectory: tempRoot)
    let session = makeSession()
    try layout.ensureDirectories(fileManager: fileManager, for: session.id)
    let micURL = layout.micTranscriptAudioURL(for: session.id)
    let systemURL = layout.systemAudioURL(for: session.id)
    let mixedURL = layout.mixedAudioURL(for: session.id)
    try writeWave(to: micURL)
    try writeWave(to: systemURL)
    try writeWave(to: mixedURL)
    let transcription = EvidenceTranscriptionStub(
      results: [
        "mic-transcript.wav": result("local words", language: "en"),
        "system.wav": result("remote words", language: "en"),
        "mixed.wav": result("must not be used", language: "en"),
      ]
    )
    let coordinator = LocalSessionEvidenceTranscriptionCoordinator(
      transcriptionService: transcription,
      diarizer: LocalSessionUnavailableDiarizer(reason: "models unavailable"),
      fileLayout: layout,
      fileManager: fileManager
    )

    let output = try await coordinator.transcribe(
      .init(
        session: session,
        plan: makePlan(),
        microphoneURL: micURL,
        systemURL: systemURL,
        mixedURL: mixedURL,
        revision: 1,
        parentContentHash: nil
      )
    )

    XCTAssertEqual(output.envelope.run.disposition, .degraded)
    XCTAssertEqual(Set(output.envelope.segments.map(\.activeText)), ["local words", "remote words"])
    let calledFileNames = await transcription.calledFileNames()
    XCTAssertEqual(calledFileNames, ["mic-transcript.wav", "system.wav"])
    XCTAssertTrue(output.envelope.quality.sourceSeparationPreserved)
    XCTAssertEqual(output.envelope.run.diarizationStatus, .unavailable)
    XCTAssertTrue(output.envelope.speakers.allSatisfy { $0.identityStatus == .unavailable })
    XCTAssertTrue(
      output.transcriptSegments
        .filter { $0.source == .microphone }
        .allSatisfy { $0.speaker == "Microphone speaker" && $0.identityStatus == .unavailable }
    )
  }

  func testEmptyAndTruncatedWavesAreNeverEligibleEvidence() throws {
    let emptyURL = tempRoot.appendingPathComponent("empty.wav")
    try writeWave(to: emptyURL, sampleData: Data())
    let empty = LocalSessionWaveEvidenceInspector.inspect(
      url: emptyURL,
      fileManager: fileManager
    )
    XCTAssertEqual(empty.integrity, .empty)

    let truncatedURL = tempRoot.appendingPathComponent("truncated.wav")
    try writeWave(to: truncatedURL)
    var truncatedData = try Data(contentsOf: truncatedURL)
    truncatedData.removeLast(100)
    try truncatedData.write(to: truncatedURL)
    let truncated = LocalSessionWaveEvidenceInspector.inspect(
      url: truncatedURL,
      fileManager: fileManager
    )
    XCTAssertEqual(truncated.integrity, .truncated)
  }

  func testUntimedPrimaryOutputFallsBackAndRemainsNonReady() async throws {
    let layout = LocalMeetingFileLayout(baseDirectory: tempRoot)
    let session = makeSession()
    try layout.ensureDirectories(fileManager: fileManager, for: session.id)
    let micURL = layout.micTranscriptAudioURL(for: session.id)
    let systemURL = layout.systemAudioURL(for: session.id)
    let mixedURL = layout.mixedAudioURL(for: session.id)
    try writeWave(to: micURL)
    try writeWave(to: systemURL)
    try writeWave(to: mixedURL)
    let untimed = LocalSessionTranscriptionResult(
      text: "untimed",
      detectedLanguage: "en",
      segments: [.init(startTime: 0, endTime: 0, text: "untimed")],
      modelPath: "/private/model/path",
      engine: .whisperKit
    )
    let transcription = EvidenceTranscriptionStub(
      results: [
        "mic-transcript.wav": untimed,
        "system.wav": result("timed system", language: "en"),
        "mixed.wav": result("fallback only", language: "en"),
      ]
    )
    let coordinator = LocalSessionEvidenceTranscriptionCoordinator(
      transcriptionService: transcription,
      diarizer: EvidenceDiarizerStub(),
      fileLayout: layout,
      fileManager: fileManager
    )

    let output = try await coordinator.transcribe(
      .init(
        session: session,
        plan: makePlan(),
        microphoneURL: micURL,
        systemURL: systemURL,
        mixedURL: mixedURL,
        revision: 1,
        parentContentHash: nil
      )
    )

    XCTAssertEqual(output.envelope.run.disposition, .degraded)
    XCTAssertEqual(output.envelope.segments.map(\.activeText), ["timed system"])
    XCTAssertFalse(output.envelope.quality.isComplete)
  }

  func testWordReconcilerSplitsAtSpeakerChangesAndPreservesWordOrder() {
    let segment = LocalSessionTranscriptionSegment(
      startTime: 0,
      endTime: 2,
      text: "Hello world",
      words: [
        .init(startTime: 0, endTime: 0.8, text: "Hello", confidence: 0.95),
        .init(startTime: 1.1, endTime: 2, text: " world", confidence: 0.9),
      ]
    )
    let slices = LocalSessionSpeakerReconciler.reconcile(
      segment: segment,
      clusters: [
        .init(stableID: "speaker-a", startSeconds: 0, endSeconds: 1, confidence: 0.8),
        .init(stableID: "speaker-b", startSeconds: 1, endSeconds: 2, confidence: 0.85),
      ]
    )

    XCTAssertEqual(slices.map(\.speakerID), ["speaker-a", "speaker-b"])
    XCTAssertEqual(slices.map(\.text).joined(), "Hello world")
    XCTAssertEqual(slices.map(\.startTime), [0, 1.1])
  }

  func testWordReconcilerMarksTiedSpeakerAssignmentAmbiguous() {
    let segment = LocalSessionTranscriptionSegment(
      startTime: 0,
      endTime: 1,
      text: "word",
      words: [.init(startTime: 0, endTime: 1, text: "word")]
    )
    let slices = LocalSessionSpeakerReconciler.reconcile(
      segment: segment,
      clusters: [
        .init(stableID: "speaker-a", startSeconds: 0, endSeconds: 1, confidence: 0.9),
        .init(stableID: "speaker-b", startSeconds: 0, endSeconds: 1, confidence: 0.9),
      ]
    )

    XCTAssertNil(slices.first?.speakerID)
    XCTAssertEqual(slices.first?.uncertainty, ["speaker-assignment-ambiguous"])
  }

  func testSpeakerAnnotationsAreAppendOnlyContentHashScopedAndUndoable() throws {
    let layout = LocalMeetingFileLayout(baseDirectory: tempRoot)
    let sessionID = UUID()
    let store = LocalSessionSpeakerAnnotationStore(
      fileLayout: layout,
      fileManager: fileManager,
      now: { Date(timeIntervalSince1970: 1_800_000_000) }
    )

    try store.appendRename(
      sessionID: sessionID,
      evidenceContentHash: "hash-a",
      speakerID: "speaker-a",
      displayName: "Maya"
    )
    try store.appendRename(
      sessionID: sessionID,
      evidenceContentHash: "hash-a",
      speakerID: "speaker-a",
      displayName: "Maya Cohen"
    )
    XCTAssertEqual(
      store.resolvedNames(sessionID: sessionID, evidenceContentHash: "hash-a")["speaker-a"],
      "Maya Cohen"
    )
    XCTAssertTrue(
      store.resolvedNames(sessionID: sessionID, evidenceContentHash: "hash-b").isEmpty
    )

    XCTAssertNotNil(
      try store.appendUndo(
        sessionID: sessionID,
        evidenceContentHash: "hash-a",
        speakerID: "speaker-a"
      )
    )
    XCTAssertEqual(
      store.resolvedNames(sessionID: sessionID, evidenceContentHash: "hash-a")["speaker-a"],
      "Maya"
    )
    XCTAssertEqual(store.loadEvents(sessionID: sessionID).count, 3)
  }

  func testFailedUntimedEvidenceOmitsInvalidSegmentsAndDoesNotBlockLaterReadyEvidence()
    async throws
  {
    let layout = LocalMeetingFileLayout(baseDirectory: tempRoot)
    let failedSession = makeSession(
      id: UUID(uuidString: "10000000-0000-4000-8000-000000000001")!,
      title: "Failed untimed capture"
    )
    let readySession = makeSession(
      id: UUID(uuidString: "20000000-0000-4000-8000-000000000002")!,
      title: "Later ready capture"
    )
    try layout.ensureDirectories(fileManager: fileManager, for: failedSession.id)
    try layout.ensureDirectories(fileManager: fileManager, for: readySession.id)

    let failedMixedURL = layout.mixedAudioURL(for: failedSession.id)
    let readyMicURL = layout.micTranscriptAudioURL(for: readySession.id)
    let readySystemURL = layout.systemAudioURL(for: readySession.id)
    try writeWave(to: failedMixedURL)
    try writeWave(to: readyMicURL)
    try writeWave(to: readySystemURL)

    let untimed = LocalSessionTranscriptionResult(
      text: "diagnostic words only",
      detectedLanguage: "en",
      segments: [.init(startTime: 0, endTime: 0, text: "diagnostic words only")],
      modelPath: "/private/model/path",
      engine: .whisperKit
    )
    let transcription = EvidenceTranscriptionStub(
      results: [
        "mixed.wav": untimed,
        "mic-transcript.wav": result("valid local words", language: "en"),
        "system.wav": result("מילים תקינות", language: "he"),
      ]
    )
    let coordinator = LocalSessionEvidenceTranscriptionCoordinator(
      transcriptionService: transcription,
      diarizer: EvidenceDiarizerStub(),
      fileLayout: layout,
      fileManager: fileManager,
      now: { Date(timeIntervalSince1970: 1_800_000_000) }
    )

    let failed = try await coordinator.transcribe(
      .init(
        session: failedSession,
        plan: makePlan(),
        microphoneURL: nil,
        systemURL: nil,
        mixedURL: failedMixedURL,
        revision: 1,
        parentContentHash: nil
      )
    )
    XCTAssertEqual(failed.envelope.run.disposition, .failed)
    XCTAssertEqual(failed.envelope.session.status, .failed)
    XCTAssertTrue(failed.envelope.segments.isEmpty)
    XCTAssertTrue(failed.envelope.speakers.isEmpty)
    XCTAssertEqual(failed.envelope.transcript.renderedText, "")
    XCTAssertTrue(failed.envelope.transcript.byteOffsets.isEmpty)
    XCTAssertFalse(failed.envelope.quality.hasVerifiableTimestamps)
    XCTAssertTrue(
      failed.envelope.run.issues.contains {
        $0.contains("ASR output was empty or lacked valid timestamps")
      }
    )

    let ready = try await coordinator.transcribe(
      .init(
        session: readySession,
        plan: makePlan(),
        microphoneURL: readyMicURL,
        systemURL: readySystemURL,
        mixedURL: nil,
        revision: 1,
        parentContentHash: nil
      )
    )
    XCTAssertEqual(ready.envelope.run.disposition, .ready)
    XCTAssertEqual(ready.envelope.segments.count, 2)
    XCTAssertEqual(
      ready.envelope.contentHash,
      try MeetingEvidenceCanonicalizer.contentHash(
        payload: MeetingEvidenceHashPayloadV1(envelope: ready.envelope)
      )
    )
    XCTAssertEqual(
      try fileManager.contentsOfDirectory(
        at: layout.meetingEvidenceOutboxDirectory,
        includingPropertiesForKeys: nil
      ).filter { $0.pathExtension == "json" }.count,
      2
    )
  }

  func testCanonicalMicroUnitQuantizationHasExactCrossLanguageBoundaries() throws {
    let halfMicroUnit = 0.000_000_5

    XCTAssertEqual(
      try MeetingEvidenceCanonicalizer.canonicalNumberString(halfMicroUnit.nextDown),
      "0"
    )
    XCTAssertEqual(
      try MeetingEvidenceCanonicalizer.canonicalNumberString(halfMicroUnit),
      "0.000001"
    )
    XCTAssertEqual(
      try MeetingEvidenceCanonicalizer.canonicalNumberString(halfMicroUnit.nextUp),
      "0.000001"
    )
    XCTAssertEqual(
      try MeetingEvidenceCanonicalizer.canonicalNumberString(0.123_456_4),
      "0.123456"
    )
    XCTAssertEqual(
      try MeetingEvidenceCanonicalizer.canonicalNumberString(0.123_456_5),
      "0.123457"
    )
  }

  func testCanonicalMicroUnitQuantizationValidatesBoundsBeforeHashing() throws {
    XCTAssertEqual(
      try MeetingEvidenceCanonicalizer.canonicalNumberString(1),
      "1",
      "One is the maximum valid confidence."
    )
    XCTAssertEqual(
      try MeetingEvidenceCanonicalizer.canonicalNumberString(
        MeetingEvidenceCanonicalizer.maximumCanonicalNumber
      ),
      "1000000000",
      "The maximum allowed evidence duration remains exactly representable."
    )
    XCTAssertThrowsError(
      try MeetingEvidenceCanonicalizer.canonicalNumberString(-Double.leastNonzeroMagnitude)
    )
    XCTAssertThrowsError(
      try MeetingEvidenceCanonicalizer.canonicalNumberString(
        MeetingEvidenceCanonicalizer.maximumCanonicalNumber.nextUp
      )
    )
    XCTAssertThrowsError(
      try MeetingEvidenceCanonicalizer.canonicalNumberString(.infinity)
    )
    XCTAssertThrowsError(
      try MeetingEvidenceCanonicalizer.canonicalNumberString(.nan)
    )
  }

  private func makeSession(
    id: UUID = UUID(uuidString: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")!,
    title: String = "Bilingual planning"
  ) -> LocalSession {
    LocalSession(
      id: id,
      title: title,
      startedAt: Date(timeIntervalSince1970: 1_700_000_000),
      status: .transcribing,
      transcriptSegments: [],
      audioArtifacts: .init(
        micFileName: "mic.wav",
        micTranscriptFileName: "mic-transcript.wav",
        systemFileName: "system.wav",
        mixedFileName: "mixed.wav"
      )
    )
  }

  private func makePlan() -> LocalSessionTranscriptionPlan {
    .init(
      engine: .whisperKit,
      modelURL: tempRoot.appendingPathComponent("small-bilingual-v1"),
      language: "auto",
      prompt: nil,
      modelFlavor: .whisperKitMultilingualTurbo,
      speedMode: .balanced
    )
  }

  private func result(_ text: String, language: String) -> LocalSessionTranscriptionResult {
    .init(
      text: text,
      detectedLanguage: language,
      segments: [.init(startTime: 0, endTime: 1, text: text)],
      modelPath: "/private/model/path",
      engine: .whisperKit
    )
  }

  private func writeWave(to url: URL, sampleData: Data = Data(repeating: 0, count: 3_200)) throws {
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

  private func tamperedHash(
    _ envelopeData: Data,
    mutate: (inout [String: Any]) -> Void
  ) throws -> String {
    var object = try XCTUnwrap(
      try JSONSerialization.jsonObject(with: envelopeData) as? [String: Any]
    )
    mutate(&object)
    let data = try JSONSerialization.data(
      withJSONObject: object,
      options: [.sortedKeys, .withoutEscapingSlashes]
    )
    return try MeetingEvidenceCanonicalizer.contentHash(envelopeData: data)
  }

  private func assertTranscriptOffsetsReconstructActiveText(_ json: [String: Any]) throws {
    let transcript = try XCTUnwrap(json["transcript"] as? [String: Any])
    let renderedText = try XCTUnwrap(transcript["renderedText"] as? String)
    let offsets = try XCTUnwrap(transcript["byteOffsets"] as? [[String: Any]])
    let segments = try XCTUnwrap(json["segments"] as? [[String: Any]])
    let activeTextByID = Dictionary(
      uniqueKeysWithValues: try segments.map { segment in
        (try XCTUnwrap(segment["id"] as? String), try XCTUnwrap(segment["activeText"] as? String))
      }
    )
    let renderedData = Data(renderedText.utf8)
    for offset in offsets {
      let segmentID = try XCTUnwrap(offset["segmentId"] as? String)
      let start = try XCTUnwrap(offset["utf8Start"] as? Int)
      let length = try XCTUnwrap(offset["utf8Length"] as? Int)
      let reconstructed = String(
        data: renderedData.subdata(in: start..<(start + length)),
        encoding: .utf8
      )
      XCTAssertEqual(reconstructed, activeTextByID[segmentID])
    }
  }
}

private actor EvidenceTranscriptionStub: LocalSessionTranscribing {
  private let results: [String: LocalSessionTranscriptionResult]
  private var calls: [String] = []

  init(results: [String: LocalSessionTranscriptionResult]) {
    self.results = results
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
    calls.append(wavURL.lastPathComponent)
    guard let result = results[wavURL.lastPathComponent] else {
      throw LocalSessionTranscriptionServiceError.transcriptionFailed("Unexpected source.")
    }
    return result
  }

  func calledFileNames() -> [String] {
    calls.sorted()
  }
}

private struct EvidenceDiarizerStub: LocalSessionDiarizing {
  func diarize(
    wavURL: URL,
    source: LocalSessionAudioSourceKind,
    sessionID: UUID
  ) async -> LocalSessionDiarizationResult {
    .init(
      status: .available,
      clusters: [
        .init(
          stableID: LocalSessionStableID.string(
            namespace: "test-speaker",
            components: [sessionID.uuidString.lowercased(), source.rawValue]
          ),
          startSeconds: 0,
          endSeconds: 1,
          confidence: 0.9
        )
      ],
      issues: []
    )
  }
}

private actor RecordingEvidenceDiarizerStub: LocalSessionDiarizing {
  private var sources: [LocalSessionAudioSourceKind] = []

  func diarize(
    wavURL: URL,
    source: LocalSessionAudioSourceKind,
    sessionID: UUID
  ) async -> LocalSessionDiarizationResult {
    sources.append(source)
    return .init(
      status: .available,
      clusters: [
        .init(
          stableID: LocalSessionStableID.string(
            namespace: "test-speaker",
            components: [sessionID.uuidString.lowercased(), source.rawValue]
          ),
          startSeconds: 0,
          endSeconds: 1,
          confidence: 0.9
        )
      ],
      issues: []
    )
  }

  func calledSources() -> [LocalSessionAudioSourceKind] {
    sources
  }
}
