import CryptoKit
import Foundation
import SpeakerKit
@preconcurrency import WhisperKit

struct LocalSessionDiarizationCluster: Equatable, Sendable {
  let stableID: String
  let startSeconds: TimeInterval
  let endSeconds: TimeInterval
  let confidence: Double?
}

struct LocalSessionDiarizationResult: Equatable, Sendable {
  let status: LocalSessionDiarizationStatus
  let clusters: [LocalSessionDiarizationCluster]
  let issues: [String]
}

protocol LocalSessionDiarizing: Sendable {
  func diarize(
    wavURL: URL,
    source: LocalSessionAudioSourceKind,
    sessionID: UUID
  ) async -> LocalSessionDiarizationResult
}

struct LocalSessionUnavailableDiarizer: LocalSessionDiarizing {
  let reason: String

  func diarize(
    wavURL: URL,
    source: LocalSessionAudioSourceKind,
    sessionID: UUID
  ) async -> LocalSessionDiarizationResult {
    .init(status: .unavailable, clusters: [], issues: [reason])
  }
}

actor LocalSessionSpeakerKitDiarizer: LocalSessionDiarizing {
  private let modelFolderURL: URL?
  private let fileManager: FileManager
  private let validator: LocalSessionSpeakerModelValidator
  private var runtime: SpeakerKit?

  init(
    modelFolderURL: URL?,
    fileManager: FileManager = .default,
    validator: LocalSessionSpeakerModelValidator? = nil
  ) {
    self.modelFolderURL = modelFolderURL
    self.fileManager = fileManager
    self.validator = validator ?? LocalSessionSpeakerModelValidator(fileManager: fileManager)
  }

  func diarize(
    wavURL: URL,
    source: LocalSessionAudioSourceKind,
    sessionID: UUID
  ) async -> LocalSessionDiarizationResult {
    guard let modelFolderURL, fileManager.fileExists(atPath: modelFolderURL.path) else {
      return .init(
        status: .unavailable,
        clusters: [],
        issues: ["Local SpeakerKit models are not installed."]
      )
    }
    do {
      try validator.validateActiveRoot(modelFolderURL)
    } catch {
      return .init(
        status: .unavailable,
        clusters: [],
        issues: ["Local SpeakerKit models are not verified: \(error.localizedDescription)"]
      )
    }

    do {
      let samples = try AudioProcessor.loadAudioAsFloatArray(fromPath: wavURL.path)
      let runtime = try await runtime(modelFolderURL: modelFolderURL)
      let result = try await runtime.diarize(audioArray: samples)
      var segmentsByRawSpeakerID: [Int: [SpeakerSegment]] = [:]
      for segment in result.segments {
        guard let rawSpeakerID = segment.speaker.speakerId else { continue }
        segmentsByRawSpeakerID[rawSpeakerID, default: []].append(segment)
      }
      let orderedRawSpeakerIDs = segmentsByRawSpeakerID.keys.sorted { lhs, rhs in
        let lhsStart = segmentsByRawSpeakerID[lhs]?.map(\.startTime).min() ?? 0
        let rhsStart = segmentsByRawSpeakerID[rhs]?.map(\.startTime).min() ?? 0
        return lhsStart < rhsStart
      }
      var clusters: [LocalSessionDiarizationCluster] = []
      for (index, rawSpeakerID) in orderedRawSpeakerIDs.enumerated() {
        let stableID = LocalSessionStableID.string(
          namespace: "speaker-cluster",
          components: [
            sessionID.uuidString.lowercased(),
            source.rawValue,
            String(index + 1),
          ]
        )
        for segment in segmentsByRawSpeakerID[rawSpeakerID] ?? [] {
          clusters.append(
            LocalSessionDiarizationCluster(
              stableID: stableID,
              startSeconds: TimeInterval(segment.startTime),
              endSeconds: TimeInterval(segment.endTime),
              confidence: nil
            )
          )
        }
      }
      guard !clusters.isEmpty else {
        return .init(
          status: .failed,
          clusters: [],
          issues: ["SpeakerKit returned no speaker clusters."]
        )
      }
      return .init(status: .available, clusters: clusters, issues: [])
    } catch {
      return .init(
        status: .failed,
        clusters: [],
        issues: ["SpeakerKit diarization failed: \(error.localizedDescription)"]
      )
    }
  }

  private func runtime(modelFolderURL: URL) async throws -> SpeakerKit {
    if let runtime { return runtime }
    let runtime = try await SpeakerKit(
      PyannoteConfig(
        modelFolder: modelFolderURL.path,
        download: false,
        load: true,
        verbose: false
      )
    )
    self.runtime = runtime
    return runtime
  }
}

struct LocalSessionEvidenceTranscriptionInput: Sendable {
  let session: LocalSession
  let plan: LocalSessionTranscriptionPlan
  let microphoneURL: URL?
  let systemURL: URL?
  let mixedURL: URL?
  let revision: Int
  let parentContentHash: String?
  let onProgress: (@Sendable (LocalSessionTranscriptionProgress) async -> Void)?

  init(
    session: LocalSession,
    plan: LocalSessionTranscriptionPlan,
    microphoneURL: URL?,
    systemURL: URL?,
    mixedURL: URL?,
    revision: Int,
    parentContentHash: String?,
    onProgress: (@Sendable (LocalSessionTranscriptionProgress) async -> Void)? = nil
  ) {
    self.session = session
    self.plan = plan
    self.microphoneURL = microphoneURL
    self.systemURL = systemURL
    self.mixedURL = mixedURL
    self.revision = revision
    self.parentContentHash = parentContentHash
    self.onProgress = onProgress
  }
}

struct LocalSessionEvidenceTranscriptionOutput: Sendable {
  let envelope: MeetingEvidenceEnvelopeV1
  let summary: LocalSessionTranscriptionEvidenceSummary
  let transcriptSegments: [LocalSessionTranscriptSegment]
}

struct LocalSessionSpeakerReconciler {
  struct Slice: Equatable, Sendable {
    let speakerID: String?
    let text: String
    let startTime: TimeInterval
    let endTime: TimeInterval
    let confidence: Double?
    let uncertainty: [String]
  }

  static func reconcile(
    segment: LocalSessionTranscriptionSegment,
    clusters: [LocalSessionDiarizationCluster]
  ) -> [Slice] {
    guard !segment.words.isEmpty else {
      let assignment = assignment(
        startTime: segment.startTime,
        endTime: segment.endTime,
        clusters: clusters
      )
      return [
        Slice(
          speakerID: assignment.speakerID,
          text: segment.text,
          startTime: segment.startTime,
          endTime: segment.endTime,
          confidence: assignment.confidence,
          uncertainty: ["speaker-mapping-segment-level"] + assignment.uncertainty
        )
      ]
    }

    var slices: [Slice] = []
    for word in segment.words {
      guard word.startTime.isFinite, word.endTime.isFinite, word.endTime >= word.startTime else {
        continue
      }
      let assignment = assignment(
        startTime: word.startTime,
        endTime: word.endTime,
        clusters: clusters
      )
      let uncertainty =
        (word.timestampProvenance == .asr ? [] : ["word-timestamp-unavailable"])
        + assignment.uncertainty
      if let last = slices.last, last.speakerID == assignment.speakerID,
        last.uncertainty == uncertainty
      {
        slices[slices.count - 1] = Slice(
          speakerID: last.speakerID,
          text: last.text + word.text,
          startTime: last.startTime,
          endTime: max(last.endTime, word.endTime),
          confidence: minimumConfidence(last.confidence, word.confidence, assignment.confidence),
          uncertainty: uncertainty
        )
      } else {
        slices.append(
          Slice(
            speakerID: assignment.speakerID,
            text: word.text,
            startTime: word.startTime,
            endTime: word.endTime,
            confidence: minimumConfidence(word.confidence, assignment.confidence),
            uncertainty: uncertainty
          )
        )
      }
    }

    if slices.isEmpty {
      return [
        Slice(
          speakerID: nil,
          text: segment.text,
          startTime: segment.startTime,
          endTime: segment.endTime,
          confidence: nil,
          uncertainty: ["word-timestamps-invalid", "speaker-assignment-ambiguous"]
        )
      ]
    }
    return slices
  }

  private static func assignment(
    startTime: TimeInterval,
    endTime: TimeInterval,
    clusters: [LocalSessionDiarizationCluster]
  ) -> (speakerID: String?, confidence: Double?, uncertainty: [String]) {
    guard !clusters.isEmpty else {
      return (nil, nil, ["speaker-diarization-unavailable"])
    }
    let overlaps = clusters.map { cluster in
      (
        cluster,
        max(0, min(cluster.endSeconds, endTime) - max(cluster.startSeconds, startTime))
      )
    }
    let bestOverlap = overlaps.map(\.1).max() ?? 0
    if bestOverlap > 0 {
      let winners = overlaps.filter { abs($0.1 - bestOverlap) < 0.000_001 }
      let speakerIDs = Set(winners.map(\.0.stableID))
      guard speakerIDs.count == 1, let winner = winners.first else {
        return (nil, nil, ["speaker-assignment-ambiguous"])
      }
      return (winner.0.stableID, winner.0.confidence, [])
    }

    let midpoint = startTime + max(0, endTime - startTime) / 2
    let midpointMatches = clusters.filter {
      $0.startSeconds <= midpoint && midpoint <= $0.endSeconds
    }
    let speakerIDs = Set(midpointMatches.map(\.stableID))
    guard speakerIDs.count == 1, let winner = midpointMatches.first else {
      return (nil, nil, ["speaker-assignment-ambiguous"])
    }
    return (winner.stableID, winner.confidence, ["speaker-assignment-midpoint"])
  }

  private static func minimumConfidence(_ values: Double?...) -> Double? {
    values.compactMap { $0 }.min()
  }
}

enum LocalSessionEvidenceCoordinatorError: LocalizedError {
  case invalidRevision
  case immutableArtifactExists(String)

  var errorDescription: String? {
    switch self {
    case .invalidRevision:
      return "A transcript revision must be positive and revision 1 cannot have a parent hash."
    case .immutableArtifactExists(let name):
      return "Immutable transcription artifact already exists: \(name)"
    }
  }
}

actor LocalSessionEvidenceTranscriptionCoordinator {
  private struct SourceWork: Sendable {
    let evidence: LocalSessionEvidenceSourceV1
    let result: LocalSessionTranscriptionResult?
    let diarization: LocalSessionDiarizationResult?
  }

  private let transcriptionService: any LocalSessionTranscribing
  private let diarizer: any LocalSessionDiarizing
  private let fileLayout: LocalSessionFileLayout
  private let fileManager: FileManager
  private let now: @Sendable () -> Date

  init(
    transcriptionService: any LocalSessionTranscribing,
    diarizer: any LocalSessionDiarizing,
    fileLayout: LocalSessionFileLayout,
    fileManager: FileManager = .default,
    now: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.transcriptionService = transcriptionService
    self.diarizer = diarizer
    self.fileLayout = fileLayout
    self.fileManager = fileManager
    self.now = now
  }

  func transcribe(_ input: LocalSessionEvidenceTranscriptionInput) async throws
    -> LocalSessionEvidenceTranscriptionOutput
  {
    guard input.revision > 0,
      (input.revision == 1) == (input.parentContentHash == nil)
    else {
      throw LocalSessionEvidenceCoordinatorError.invalidRevision
    }

    let startedAt = now()
    async let microphone = processPrimary(
      url: input.microphoneURL,
      kind: .microphone,
      input: input
    )
    async let system = processPrimary(
      url: input.systemURL,
      kind: .system,
      input: input
    )
    let primary = await [microphone, system]
    let usablePrimary = primary.filter {
      $0.evidence.integrity == .available && isTimedNonempty($0.result)
    }
    let independentSourcesAreReady =
      usablePrimary.count == primary.count
      && usablePrimary.allSatisfy { $0.diarization?.status == .available }

    let activeSources: [SourceWork]
    var disposition: LocalSessionEvidenceDisposition
    if independentSourcesAreReady {
      activeSources = primary
      disposition = .ready
    } else if !usablePrimary.isEmpty {
      activeSources = usablePrimary
      disposition = .degraded
    } else {
      let fallback = await processFallback(url: input.mixedURL, input: input)
      activeSources = [fallback]
      disposition =
        fallback.evidence.integrity == .available && isTimedNonempty(fallback.result)
        ? .degraded : .failed
    }

    let allSourceEvidence =
      primary.map(\.evidence)
      + activeSources.filter { $0.evidence.kind == .mixed }.map(\.evidence)
    let mapped = mapSegments(activeSources, session: input.session)
    let merged = deduplicated(mapped.segments)
    if merged.isEmpty {
      disposition = .failed
    }
    let issues = Array(
      Set(
        allSourceEvidence.flatMap(\.issues)
          + activeSources.compactMap(\.diarization).flatMap(\.issues)
          + (disposition == .degraded
            ? [
              activeSources.contains { $0.evidence.kind == .mixed }
                ? "No usable microphone/system transcript existed; mixed audio was used as a degraded fallback."
                : "Usable separated-source ASR was preserved, but speaker diarization or a primary source was incomplete."
            ]
            : [])
      )
    ).sorted()
    let detectedLanguages = Array(
      Set(activeSources.compactMap(\.result?.detectedLanguage).filter { !$0.isEmpty })
    ).sorted()
    let diarizationStatus =
      activeSources.allSatisfy { $0.diarization?.status == .available }
      ? LocalSessionDiarizationStatus.available
      : activeSources.contains { $0.diarization?.status == .failed }
        ? .failed : .unavailable
    let completedAt = now()
    let runID = LocalSessionStableID.string(
      namespace: "transcription-run",
      components: [
        input.session.id.uuidString.lowercased(),
        String(input.revision),
        input.plan.engine.rawValue,
        input.plan.modelURL.lastPathComponent,
      ]
    )
    let transcript = MeetingEvidenceTranscriptRenderer.render(
      segments: merged,
      speakers: mapped.speakers
    )
    let sourceRef =
      "cepessa-session://\(input.session.id.uuidString.lowercased())/transcript"
    let evidenceID = "meeting:\(input.session.id.uuidString.lowercased()):run:\(runID)"
    let run = LocalSessionEvidenceRunV1(
      id: runID,
      createdAt: startedAt,
      completedAt: completedAt,
      disposition: disposition,
      engine: input.plan.engine,
      model: .init(
        identifier: input.plan.modelFlavor.rawValue,
        modelBasename: input.plan.modelURL.lastPathComponent
      ),
      requestedLanguage: input.plan.language,
      detectedLanguages: detectedLanguages,
      diarizationStatus: diarizationStatus,
      issues: issues
    )
    let evidenceSession = MeetingEvidenceSessionV1(
      id: input.session.id.uuidString.lowercased(),
      title: input.session.title,
      startedAt: input.session.startedAt,
      status: disposition == .ready ? .ready : .failed
    )
    let quality = MeetingEvidenceQualityV1(
      isComplete: disposition == .ready,
      speechCoverage: nil,
      hasVerifiableTimestamps: !merged.isEmpty
        && merged.allSatisfy { $0.isTimed && $0.endSeconds >= $0.startSeconds },
      sourceSeparationPreserved:
        usablePrimary.count == primary.count
        && !activeSources.contains { $0.evidence.kind == .mixed },
      diarization: diarizationStatus.rawValue,
      issues: issues
    )
    let hashPayload = MeetingEvidenceHashPayloadV1(
      schemaVersion: "meeting-evidence/v1",
      evidenceID: evidenceID,
      sourceRef: sourceRef,
      revision: input.revision,
      parentContentHash: input.parentContentHash,
      session: evidenceSession,
      run: run,
      sources: allSourceEvidence,
      speakers: mapped.speakers,
      segments: merged,
      transcript: transcript,
      quality: quality
    )
    let contentHash = try MeetingEvidenceCanonicalizer.contentHash(payload: hashPayload)
    let envelope = MeetingEvidenceEnvelopeV1(
      schemaVersion: hashPayload.schemaVersion,
      evidenceID: evidenceID,
      sourceRef: sourceRef,
      revision: input.revision,
      parentContentHash: input.parentContentHash,
      contentHash: contentHash,
      session: evidenceSession,
      run: run,
      sources: allSourceEvidence,
      speakers: mapped.speakers,
      segments: merged,
      transcript: transcript,
      quality: quality
    )
    let artifactNames = try writeImmutableArtifacts(envelope: envelope)
    let summary = LocalSessionTranscriptionEvidenceSummary(
      runID: runID,
      revision: input.revision,
      disposition: disposition,
      contentHash: contentHash,
      parentContentHash: input.parentContentHash,
      runFileName: artifactNames.run,
      outboxFileName: artifactNames.outbox,
      issues: issues
    )
    let speakerLabels = Dictionary(uniqueKeysWithValues: mapped.speakers.map { ($0.id, $0.label) })
    let transcriptSegments = merged.compactMap { segment -> LocalSessionTranscriptSegment? in
      return .init(
        id: UUID(uuidString: segment.id)
          ?? LocalSessionStableID.uuid(namespace: "segment-uuid", components: [segment.id]),
        speaker: speakerLabels[segment.speakerID] ?? "Speaker",
        text: segment.activeText,
        timestamp: input.session.startedAt.addingTimeInterval(segment.startSeconds),
        endTimestamp: input.session.startedAt.addingTimeInterval(segment.endSeconds),
        speakerID: segment.speakerID,
        source: allSourceEvidence.first { $0.id == segment.sourceID }?.kind,
        identityStatus: mapped.speakers.first { $0.id == segment.speakerID }?.identityStatus,
        uncertainty: segment.uncertainty
      )
    }
    return .init(
      envelope: envelope,
      summary: summary,
      transcriptSegments: transcriptSegments
    )
  }

  private func processPrimary(
    url: URL?,
    kind: LocalSessionAudioSourceKind,
    input: LocalSessionEvidenceTranscriptionInput
  ) async -> SourceWork {
    await process(url: url, kind: kind, input: input, onProgress: nil)
  }

  private func processFallback(
    url: URL?,
    input: LocalSessionEvidenceTranscriptionInput
  ) async -> SourceWork {
    await process(url: url, kind: .mixed, input: input, onProgress: input.onProgress)
  }

  private func process(
    url: URL?,
    kind: LocalSessionAudioSourceKind,
    input: LocalSessionEvidenceTranscriptionInput,
    onProgress: (@Sendable (LocalSessionTranscriptionProgress) async -> Void)?
  ) async -> SourceWork {
    let sourceID = LocalSessionStableID.string(
      namespace: "audio-source",
      components: [input.session.id.uuidString.lowercased(), kind.rawValue]
    )
    guard let url else {
      return SourceWork(
        evidence: .init(
          id: sourceID, kind: kind, fileName: "\(kind.rawValue).wav",
          role: kind == .mixed ? "fallback" : "primary", integrity: .missing,
          durationSeconds: nil, sha256: nil, issues: ["\(kind.rawValue) source is missing."]
        ),
        result: nil,
        diarization: nil
      )
    }

    let inspection = LocalSessionWaveEvidenceInspector.inspect(url: url, fileManager: fileManager)
    guard inspection.integrity == .available else {
      return SourceWork(
        evidence: .init(
          id: sourceID,
          kind: kind,
          fileName: url.lastPathComponent,
          role: kind == .mixed ? "fallback" : "primary",
          integrity: inspection.integrity,
          durationSeconds: inspection.duration,
          sha256: inspection.sha256,
          issues: inspection.issues
        ),
        result: nil,
        diarization: nil
      )
    }

    do {
      let result = try await transcriptionService.transcribe(
        wavURL: url,
        modelURL: input.plan.modelURL,
        language: input.plan.language,
        prompt: input.plan.prompt,
        translateToEnglish: false,
        onProgress: onProgress
      )
      let diarization: LocalSessionDiarizationResult
      diarization = await diarizer.diarize(
        wavURL: url,
        source: kind,
        sessionID: input.session.id
      )
      var issues = inspection.issues + result.warnings
      if !isTimedNonempty(result) {
        issues.append("\(kind.rawValue) ASR output was empty or lacked valid timestamps.")
      }
      return SourceWork(
        evidence: .init(
          id: sourceID,
          kind: kind,
          fileName: url.lastPathComponent,
          role: kind == .mixed ? "fallback" : "primary",
          integrity: .available,
          durationSeconds: inspection.duration,
          sha256: inspection.sha256,
          issues: issues
        ),
        result: result,
        diarization: diarization
      )
    } catch {
      return SourceWork(
        evidence: .init(
          id: sourceID,
          kind: kind,
          fileName: url.lastPathComponent,
          role: kind == .mixed ? "fallback" : "primary",
          integrity: .available,
          durationSeconds: inspection.duration,
          sha256: inspection.sha256,
          issues: ["\(kind.rawValue) transcription failed: \(error.localizedDescription)"]
        ),
        result: nil,
        diarization: nil
      )
    }
  }

  private func isTimedNonempty(_ result: LocalSessionTranscriptionResult?) -> Bool {
    guard let result, !result.segments.isEmpty else { return false }
    return result.segments.allSatisfy(isValidTimedSegment)
  }

  private func isValidTimedSegment(_ segment: LocalSessionTranscriptionSegment) -> Bool {
    !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && segment.startTime.isFinite
      && segment.endTime.isFinite
      && segment.startTime >= 0
      && segment.endTime > segment.startTime
  }

  private func mapSegments(
    _ sources: [SourceWork],
    session: LocalSession
  ) -> (segments: [LocalSessionEvidenceSegmentV1], speakers: [LocalSessionEvidenceSpeakerV1]) {
    var segments: [LocalSessionEvidenceSegmentV1] = []
    var speakersByID: [String: LocalSessionEvidenceSpeakerV1] = [:]

    for source in sources {
      guard let result = source.result else { continue }
      let clusters = source.diarization?.clusters ?? []
      for resultSegment in result.segments {
        // Failed ASR output remains diagnostic source/run evidence. It must not
        // become an invalid transcript segment in the append-only outbox.
        guard isValidTimedSegment(resultSegment) else { continue }
        let slices = LocalSessionSpeakerReconciler.reconcile(
          segment: resultSegment,
          clusters: clusters
        )
        for slice in slices {
          let speakerID =
            slice.speakerID
            ?? LocalSessionStableID.string(
              namespace: "anonymous-speaker",
              components: [session.id.uuidString.lowercased(), source.evidence.kind.rawValue, "1"]
            )
          let label: String
          if source.evidence.kind == .microphone {
            label = "Microphone speaker"
          } else {
            let clusterIDs = clusters.reduce(into: [String]()) { ids, cluster in
              if !ids.contains(cluster.stableID) { ids.append(cluster.stableID) }
            }
            let index = clusterIDs.firstIndex(of: speakerID) ?? 0
            label = "Speaker \(index + 1)"
          }
          speakersByID[speakerID] = .init(
            id: speakerID,
            label: label,
            kind: "anonymous",
            identityStatus:
              source.diarization?.status == .available ? .anonymous : .unavailable,
            confidence: slice.confidence
          )
          let text = slice.text.trimmingCharacters(in: .whitespacesAndNewlines)
          guard !text.isEmpty else { continue }
          let segmentID = LocalSessionStableID.string(
            namespace: "transcript-segment",
            components: [
              session.id.uuidString.lowercased(),
              source.evidence.id,
              String(Int((slice.startTime * 1_000).rounded())),
              String(Int((slice.endTime * 1_000).rounded())),
              normalized(text),
            ]
          )
          segments.append(
            .init(
              id: segmentID,
              sourceID: source.evidence.id,
              speakerID: speakerID,
              rawASRText: text,
              activeText: text,
              startSeconds: slice.startTime,
              endSeconds: slice.endTime,
              timestampProvenance: .asr,
              isTimed: true,
              confidence: slice.confidence,
              uncertainty: slice.uncertainty,
              language: result.detectedLanguage
            )
          )
        }
      }
    }

    return (
      segments.sorted(by: segmentSort),
      speakersByID.values.sorted { $0.id < $1.id }
    )
  }

  private func deduplicated(
    _ segments: [LocalSessionEvidenceSegmentV1]
  ) -> [LocalSessionEvidenceSegmentV1] {
    var accepted: [LocalSessionEvidenceSegmentV1] = []
    for candidate in segments.sorted(by: segmentSort) {
      if let index = accepted.firstIndex(where: { isDuplicate($0, candidate) }) {
        if candidate.sourceID < accepted[index].sourceID {
          accepted[index] = candidate
        }
      } else {
        accepted.append(candidate)
      }
    }
    return accepted.sorted(by: segmentSort)
  }

  private func isDuplicate(
    _ lhs: LocalSessionEvidenceSegmentV1,
    _ rhs: LocalSessionEvidenceSegmentV1
  ) -> Bool {
    let temporalOverlap = max(
      0,
      min(lhs.endSeconds, rhs.endSeconds) - max(lhs.startSeconds, rhs.startSeconds)
    )
    guard temporalOverlap > 0 else { return false }
    let lhsTokens = Set(normalized(lhs.activeText).split(separator: " ").map(String.init))
    let rhsTokens = Set(normalized(rhs.activeText).split(separator: " ").map(String.init))
    guard !lhsTokens.isEmpty, !rhsTokens.isEmpty else { return false }
    return Double(lhsTokens.intersection(rhsTokens).count)
      / Double(lhsTokens.union(rhsTokens).count) >= 0.85
  }

  private func segmentSort(
    _ lhs: LocalSessionEvidenceSegmentV1,
    _ rhs: LocalSessionEvidenceSegmentV1
  ) -> Bool {
    if lhs.startSeconds != rhs.startSeconds { return lhs.startSeconds < rhs.startSeconds }
    if lhs.endSeconds != rhs.endSeconds { return lhs.endSeconds < rhs.endSeconds }
    return lhs.id < rhs.id
  }

  private func normalized(_ text: String) -> String {
    text.lowercased()
      .unicodeScalars
      .map { CharacterSet.alphanumerics.contains($0) ? String($0) : " " }
      .joined()
      .split(whereSeparator: \.isWhitespace)
      .joined(separator: " ")
  }

  private func writeImmutableArtifacts(
    envelope: MeetingEvidenceEnvelopeV1
  ) throws -> (run: String, outbox: String) {
    let runDirectory = fileLayout.transcriptionRunsDirectory(for: envelope.sessionID)
    let outboxDirectory = fileLayout.meetingEvidenceOutboxDirectory
    try fileManager.createDirectory(at: runDirectory, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: outboxDirectory, withIntermediateDirectories: true)

    let runFileName = "\(envelope.run.id).json"
    let eventID = LocalSessionStableID.string(
      namespace: "meeting-evidence-outbox",
      components: [envelope.evidenceID, envelope.contentHash]
    )
    let outboxFileName = "\(eventID).json"
    let runURL = runDirectory.appendingPathComponent(runFileName)
    let outboxURL = outboxDirectory.appendingPathComponent(outboxFileName)
    guard !fileManager.fileExists(atPath: runURL.path) else {
      throw LocalSessionEvidenceCoordinatorError.immutableArtifactExists(runFileName)
    }
    guard !fileManager.fileExists(atPath: outboxURL.path) else {
      throw LocalSessionEvidenceCoordinatorError.immutableArtifactExists(outboxFileName)
    }

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    let envelopeData = try encoder.encode(envelope)
    try envelopeData.write(to: runURL, options: .withoutOverwriting)
    try envelopeData.write(to: outboxURL, options: .withoutOverwriting)
    return (runFileName, outboxFileName)
  }
}

extension MeetingEvidenceEnvelopeV1 {
  fileprivate var sessionID: UUID {
    UUID(uuidString: session.id)!
  }
}

enum LocalSessionWaveEvidenceInspector {
  struct Result {
    let integrity: LocalSessionSourceIntegrity
    let duration: TimeInterval?
    let sha256: String?
    let issues: [String]
  }

  static func inspect(url: URL, fileManager: FileManager) -> Result {
    guard fileManager.fileExists(atPath: url.path) else {
      return .init(
        integrity: .missing, duration: nil, sha256: nil, issues: ["Audio file is missing."])
    }
    guard let data = try? Data(contentsOf: url) else {
      return .init(
        integrity: .invalid, duration: nil, sha256: nil, issues: ["Audio file is unreadable."])
    }
    let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    guard data.count >= 44, String(data: data[0..<4], encoding: .ascii) == "RIFF",
      String(data: data[8..<12], encoding: .ascii) == "WAVE"
    else {
      return .init(
        integrity: .invalid, duration: nil, sha256: hash,
        issues: ["Audio file is not a valid WAV container."])
    }
    let declaredSize = Int(readUInt32(data, offset: 4)) + 8
    if declaredSize > data.count {
      return .init(
        integrity: .truncated, duration: nil, sha256: hash, issues: ["WAV container is truncated."])
    }
    guard let dataChunk = findDataChunk(data) else {
      return .init(
        integrity: .invalid, duration: nil, sha256: hash, issues: ["WAV data chunk is missing."])
    }
    if dataChunk.length == 0 {
      return .init(
        integrity: .empty, duration: 0, sha256: hash, issues: ["WAV data chunk is empty."])
    }
    if dataChunk.offset + dataChunk.length > data.count {
      return .init(
        integrity: .truncated, duration: nil, sha256: hash, issues: ["WAV data chunk is truncated."]
      )
    }
    let byteRate = data.count >= 32 ? Int(readUInt32(data, offset: 28)) : 0
    guard byteRate > 0 else {
      return .init(
        integrity: .invalid, duration: nil, sha256: hash, issues: ["WAV byte rate is invalid."])
    }
    return .init(
      integrity: .available,
      duration: Double(dataChunk.length) / Double(byteRate),
      sha256: hash,
      issues: []
    )
  }

  private static func findDataChunk(_ data: Data) -> (offset: Int, length: Int)? {
    var offset = 12
    while offset + 8 <= data.count {
      let name = String(data: data[offset..<(offset + 4)], encoding: .ascii)
      let length = Int(readUInt32(data, offset: offset + 4))
      if name == "data" { return (offset + 8, length) }
      offset += 8 + length + (length % 2)
    }
    return nil
  }

  private static func readUInt32(_ data: Data, offset: Int) -> UInt32 {
    guard offset + 4 <= data.count else { return 0 }
    return data[offset..<(offset + 4)].enumerated().reduce(0) {
      $0 | (UInt32($1.element) << UInt32($1.offset * 8))
    }
  }
}
