import CryptoKit
import Darwin
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
  let importedURL: URL?
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
    onProgress: (@Sendable (LocalSessionTranscriptionProgress) async -> Void)? = nil,
    importedURL: URL? = nil
  ) {
    self.session = session
    self.plan = plan
    self.microphoneURL = microphoneURL
    self.systemURL = systemURL
    self.mixedURL = mixedURL
    self.importedURL = importedURL
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
  case invalidImmutableArtifact(String)

  var errorDescription: String? {
    switch self {
    case .invalidRevision:
      return "A transcript revision must be positive and revision 1 cannot have a parent hash."
    case .immutableArtifactExists(let name):
      return "Immutable transcription artifact already exists: \(name)"
    case .invalidImmutableArtifact(let message):
      return "Existing transcription evidence could not be recovered: \(message)"
    }
  }
}

private struct LocalSessionSpeechCoverageMeasurement: Sendable {
  let coveredDuration: TimeInterval
  let speechDuration: TimeInterval

  var ratio: Double {
    guard speechDuration > 0 else { return 0 }
    return min(1, max(0, coveredDuration / speechDuration))
  }
}

private enum LocalSessionEvidenceTimingValidator {
  static let timestampTolerance: TimeInterval = 0.25

  struct ResultValidation {
    let result: LocalSessionTranscriptionResult
    let hadInvalidTiming: Bool
  }

  struct DiarizationValidation {
    let result: LocalSessionDiarizationResult
    let hadInvalidTiming: Bool
  }

  static func validate(
    result: LocalSessionTranscriptionResult,
    duration: TimeInterval
  ) -> ResultValidation {
    var hadInvalidTiming = false
    let segments = result.segments.compactMap { segment -> LocalSessionTranscriptionSegment? in
      guard
        isValidInterval(
          start: segment.startTime,
          end: segment.endTime,
          duration: duration)
      else {
        hadInvalidTiming = true
        return nil
      }
      let words = segment.words.filter { word in
        let isValid = isValidInterval(
          start: word.startTime,
          end: word.endTime,
          duration: duration,
          allowsZeroLength: true
        )
        if !isValid { hadInvalidTiming = true }
        return isValid
      }
      return .init(
        startTime: segment.startTime,
        endTime: segment.endTime,
        text: segment.text,
        words: words
      )
    }
    let text = LocalSessionTranscriptionPostprocessor.transcriptText(
      from: segments,
      fallback: segments.map(\.text).joined(separator: " ")
    )
    return .init(
      result: .init(
        text: text,
        detectedLanguage: result.detectedLanguage,
        segments: segments,
        modelPath: result.modelPath,
        engine: result.engine,
        warnings: result.warnings
      ),
      hadInvalidTiming: hadInvalidTiming
    )
  }

  static func validate(
    diarization: LocalSessionDiarizationResult,
    duration: TimeInterval
  ) -> DiarizationValidation {
    guard diarization.status == .available else {
      return .init(result: diarization, hadInvalidTiming: false)
    }
    var hadInvalidTiming = false
    let clusters = diarization.clusters.filter { cluster in
      let isValid = isValidInterval(
        start: cluster.startSeconds,
        end: cluster.endSeconds,
        duration: duration)
      if !isValid { hadInvalidTiming = true }
      return isValid
    }
    var issues = diarization.issues
    if hadInvalidTiming {
      issues.append("Speaker diarization contained timestamps outside the audio source.")
    }
    guard !clusters.isEmpty else {
      issues.append("Speaker diarization contained no valid speech intervals.")
      return .init(
        result: .init(status: .failed, clusters: [], issues: Array(Set(issues)).sorted()),
        hadInvalidTiming: hadInvalidTiming
      )
    }
    return .init(
      result: .init(
        status: .available,
        clusters: clusters,
        issues: Array(Set(issues)).sorted()
      ),
      hadInvalidTiming: hadInvalidTiming
    )
  }

  static func speechCoverage(
    transcript: LocalSessionTranscriptionResult,
    diarization: LocalSessionDiarizationResult,
    duration: TimeInterval
  ) -> LocalSessionSpeechCoverageMeasurement? {
    guard diarization.status == .available else { return nil }
    let speechIntervals = mergedIntervals(
      diarization.clusters.map { ($0.startSeconds, $0.endSeconds) },
      duration: duration
    )
    let transcriptIntervals = mergedIntervals(
      transcript.segments.map { ($0.startTime, $0.endTime) },
      duration: duration
    )
    let speechDuration = speechIntervals.reduce(0) { $0 + ($1.1 - $1.0) }
    guard speechDuration > 0 else { return nil }
    let coveredDuration = speechIntervals.reduce(0) { total, speech in
      total
        + transcriptIntervals.reduce(0) { covered, transcript in
          covered + max(0, min(speech.1, transcript.1) - max(speech.0, transcript.0))
        }
    }
    return .init(coveredDuration: coveredDuration, speechDuration: speechDuration)
  }

  private static func isValidInterval(
    start: TimeInterval,
    end: TimeInterval,
    duration: TimeInterval,
    allowsZeroLength: Bool = false
  ) -> Bool {
    start.isFinite
      && end.isFinite
      && duration.isFinite
      && duration > 0
      && start >= 0
      && (allowsZeroLength ? end >= start : end > start)
      && end <= duration + timestampTolerance
  }

  private static func mergedIntervals(
    _ intervals: [(TimeInterval, TimeInterval)],
    duration: TimeInterval
  ) -> [(TimeInterval, TimeInterval)] {
    var sorted: [(TimeInterval, TimeInterval)] = []
    for interval in intervals {
      let boundedStart = max(0, min(interval.0, duration))
      let boundedEnd = max(0, min(interval.1, duration))
      if boundedEnd > boundedStart {
        sorted.append((boundedStart, boundedEnd))
      }
    }
    sorted.sort {
      $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 < $1.0
    }
    var merged: [(TimeInterval, TimeInterval)] = []
    for interval in sorted {
      guard let last = merged.last else {
        merged.append(interval)
        continue
      }
      if interval.0 <= last.1 {
        merged[merged.count - 1] = (last.0, max(last.1, interval.1))
      } else {
        merged.append(interval)
      }
    }
    return merged
  }
}

private actor LocalSessionEvidenceProgressAggregator {
  private let sourceCount: Int
  private let onProgress: (@Sendable (LocalSessionTranscriptionProgress) async -> Void)?
  private var percentBySource: [String: Int] = [:]
  private var partialSegmentsBySource: [String: [LocalSessionTranscriptionSegment]] = [:]
  private var analysisBySource: [String: (Int, TimeInterval, TimeInterval)] = [:]
  private var extractingSources: Set<String> = []
  private var highestPercent = 0
  private var highestMilestone = 0

  init(
    sourceCount: Int,
    onProgress: (@Sendable (LocalSessionTranscriptionProgress) async -> Void)?
  ) {
    self.sourceCount = max(1, sourceCount)
    self.onProgress = onProgress
  }

  func report(
    _ update: LocalSessionTranscriptionProgress,
    source: LocalSessionAudioSourceKind
  ) async {
    guard let onProgress else { return }
    let sourceKey = source.rawValue
    switch update.stage {
    case .decodingAudio:
      guard highestMilestone < 1 else { return }
      highestMilestone = 1
      await onProgress(update)
    case .loadingModel:
      guard highestMilestone < 2 else { return }
      highestMilestone = 2
      await onProgress(update)
    case .analyzingSpeech(let chunks, let speechDuration, let skippedSilenceDuration):
      highestMilestone = max(highestMilestone, 3)
      analysisBySource[sourceKey] = (chunks, speechDuration, skippedSilenceDuration)
      let aggregate = analysisBySource.values.reduce(into: (0, 0.0, 0.0)) {
        $0.0 += $1.0
        $0.1 += $1.1
        $0.2 += $1.2
      }
      await onProgress(
        .init(
          stage: .analyzingSpeech(
            chunks: aggregate.0,
            speechDuration: aggregate.1,
            skippedSilenceDuration: aggregate.2
          )))
    case .transcribing(let percent):
      highestMilestone = max(highestMilestone, 4)
      percentBySource[sourceKey] = max(0, min(percent, 100))
      let measured = percentBySource.values.reduce(0, +) / sourceCount
      let combined = max(highestPercent, measured)
      guard combined != highestPercent || highestPercent == 0 else { return }
      highestPercent = combined
      await onProgress(.init(stage: .transcribing(percent: combined)))
    case .partialSegments(let segments):
      partialSegmentsBySource[sourceKey] = segments
      var combined: [LocalSessionTranscriptionSegment] = []
      for sourceSegments in partialSegmentsBySource.values {
        combined.append(contentsOf: sourceSegments)
      }
      combined.sort {
        $0.startTime == $1.startTime ? $0.endTime < $1.endTime : $0.startTime < $1.startTime
      }
      if !combined.isEmpty {
        await onProgress(.init(stage: .partialSegments(combined)))
      }
    case .extractingSegments:
      extractingSources.insert(sourceKey)
      guard extractingSources.count >= sourceCount, highestMilestone < 5 else { return }
      highestMilestone = 5
      await onProgress(update)
    }
  }

  func finish(source: LocalSessionAudioSourceKind) async {
    guard let onProgress else { return }
    let sourceKey = source.rawValue
    if (percentBySource[sourceKey] ?? 0) < 100 {
      percentBySource[sourceKey] = 100
      let measured = percentBySource.values.reduce(0, +) / sourceCount
      let combined = max(highestPercent, measured)
      if combined != highestPercent {
        highestPercent = combined
        await onProgress(.init(stage: .transcribing(percent: combined)))
      }
    }
    extractingSources.insert(sourceKey)
    guard extractingSources.count >= sourceCount, highestMilestone < 5 else { return }
    highestMilestone = 5
    await onProgress(.init(stage: .extractingSegments))
  }
}

actor LocalSessionEvidenceTranscriptionCoordinator {
  private struct ImmutableArtifactSnapshot {
    let data: Data
    let status: stat
  }

  private struct SourceWork: Sendable {
    let evidence: LocalSessionEvidenceSourceV1
    let result: LocalSessionTranscriptionResult?
    let diarization: LocalSessionDiarizationResult?
    let hadInvalidTiming: Bool
    let speechCoverage: LocalSessionSpeechCoverageMeasurement?

    init(
      evidence: LocalSessionEvidenceSourceV1,
      result: LocalSessionTranscriptionResult? = nil,
      diarization: LocalSessionDiarizationResult? = nil,
      hadInvalidTiming: Bool = false,
      speechCoverage: LocalSessionSpeechCoverageMeasurement? = nil
    ) {
      self.evidence = evidence
      self.result = result
      self.diarization = diarization
      self.hadInvalidTiming = hadInvalidTiming
      self.speechCoverage = speechCoverage
    }
  }

  private static let minimumCompleteSpeechCoverage = 0.9

  private let transcriptionService: any LocalSessionTranscribing
  private let diarizer: any LocalSessionDiarizing
  private let fileLayout: LocalSessionFileLayout
  private let fileManager: FileManager
  private let now: @Sendable () -> Date
  private let beforeOutboxWrite: @Sendable () throws -> Void

  init(
    transcriptionService: any LocalSessionTranscribing,
    diarizer: any LocalSessionDiarizing,
    fileLayout: LocalSessionFileLayout,
    fileManager: FileManager = .default,
    now: @escaping @Sendable () -> Date = { Date() },
    beforeOutboxWrite: @escaping @Sendable () throws -> Void = {}
  ) {
    self.transcriptionService = transcriptionService
    self.diarizer = diarizer
    self.fileLayout = fileLayout
    self.fileManager = fileManager
    self.now = now
    self.beforeOutboxWrite = beforeOutboxWrite
  }

  func transcribe(_ input: LocalSessionEvidenceTranscriptionInput) async throws
    -> LocalSessionEvidenceTranscriptionOutput
  {
    guard input.revision > 0,
      (input.revision == 1) == (input.parentContentHash == nil)
    else {
      throw LocalSessionEvidenceCoordinatorError.invalidRevision
    }

    let runID = makeRunID(for: input)
    if let recovered = try recoverExistingRun(for: input, runID: runID) {
      return recovered
    }

    let startedAt = now()
    let activeSources: [SourceWork]
    let allSourceEvidence: [LocalSessionEvidenceSourceV1]
    let sourceSeparationPreserved: Bool
    var disposition: LocalSessionEvidenceDisposition
    if let importedURL = input.importedURL {
      let importedProgress = LocalSessionEvidenceProgressAggregator(
        sourceCount: 1,
        onProgress: input.onProgress
      )
      let imported = await processPrimary(
        url: importedURL,
        kind: .imported,
        input: input,
        progressAggregator: importedProgress
      )
      activeSources = [imported]
      allSourceEvidence = [imported.evidence]
      sourceSeparationPreserved = false
      let isUsable =
        imported.evidence.integrity == .available && isTimedNonempty(imported.result)
      let isComplete =
        isUsable
        && imported.diarization?.status == .available
        && !imported.hadInvalidTiming
        && (imported.speechCoverage?.ratio ?? 0) >= Self.minimumCompleteSpeechCoverage
      disposition = isComplete ? .ready : isUsable ? .degraded : .failed
    } else {
      let primaryProgress = LocalSessionEvidenceProgressAggregator(
        sourceCount: [input.microphoneURL, input.systemURL].compactMap { $0 }.count,
        onProgress: input.onProgress
      )
      async let microphone = processPrimary(
        url: input.microphoneURL,
        kind: .microphone,
        input: input,
        progressAggregator: primaryProgress
      )
      async let system = processPrimary(
        url: input.systemURL,
        kind: .system,
        input: input,
        progressAggregator: primaryProgress
      )
      let primary = await [microphone, system]
      let usablePrimary = primary.filter {
        $0.evidence.integrity == .available && isTimedNonempty($0.result)
      }
      let independentSourcesAreReady =
        usablePrimary.count == primary.count
        && usablePrimary.allSatisfy {
          $0.diarization?.status == .available
            && !$0.hadInvalidTiming
            && ($0.speechCoverage?.ratio ?? 0) >= Self.minimumCompleteSpeechCoverage
        }

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
      allSourceEvidence =
        primary.map(\.evidence)
        + activeSources.filter { $0.evidence.kind == .mixed }.map(\.evidence)
      sourceSeparationPreserved =
        usablePrimary.count == primary.count
        && !activeSources.contains { $0.evidence.kind == .mixed }
    }

    let mapped = mapSegments(activeSources, session: input.session)
    let merged = deduplicated(mapped.segments)
    if merged.isEmpty {
      disposition = .failed
    }
    let coverageMeasurements = activeSources.compactMap(\.speechCoverage)
    let measuredSpeechDuration = coverageMeasurements.reduce(0) { $0 + $1.speechDuration }
    let speechCoverage: Double? =
      measuredSpeechDuration > 0
      ? coverageMeasurements.reduce(0) { $0 + $1.coveredDuration } / measuredSpeechDuration
      : nil
    var qualityIssues: [String] = []
    if !merged.isEmpty, speechCoverage == nil {
      qualityIssues.append(
        "Speech coverage is unknown because no verified diarization speech intervals were available."
      )
    } else if let speechCoverage,
      speechCoverage < Self.minimumCompleteSpeechCoverage
    {
      let percent = Int((speechCoverage * 100).rounded())
      qualityIssues.append(
        "ASR timestamps cover about \(percent)% of verified speech intervals; the transcript may be incomplete."
      )
    }
    if activeSources.contains(where: \.hadInvalidTiming) {
      qualityIssues.append(
        "Timestamp evidence outside an audio source was excluded from the transcript."
      )
    }
    if disposition == .ready,
      speechCoverage == nil || (speechCoverage ?? 0) < Self.minimumCompleteSpeechCoverage
    {
      disposition = .degraded
    }
    let degradedContextIssue: String? =
      disposition == .degraded
      ? activeSources.contains { $0.evidence.kind == .imported }
        ? "Imported audio produced a usable transcript, but verified speech coverage, timestamps, or diarization were incomplete."
        : activeSources.contains { $0.evidence.kind == .mixed }
          ? "No usable microphone/system transcript existed; mixed audio was used as a degraded fallback."
          : "Usable separated-source ASR was preserved, but speaker diarization or a primary source was incomplete."
      : nil
    let issues = Array(
      Set(
        allSourceEvidence.flatMap(\.issues)
          + activeSources.compactMap(\.diarization).flatMap(\.issues)
          + qualityIssues
          + [degradedContextIssue].compactMap { $0 }
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
      speechCoverage: speechCoverage,
      hasVerifiableTimestamps: !merged.isEmpty
        && !activeSources.contains(where: \.hadInvalidTiming)
        && merged.allSatisfy { $0.isTimed && $0.endSeconds >= $0.startSeconds },
      sourceSeparationPreserved: sourceSeparationPreserved,
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
    return makeOutput(envelope: envelope, artifactNames: artifactNames)
  }

  private func processPrimary(
    url: URL?,
    kind: LocalSessionAudioSourceKind,
    input: LocalSessionEvidenceTranscriptionInput,
    progressAggregator: LocalSessionEvidenceProgressAggregator
  ) async -> SourceWork {
    let work = await process(
      url: url,
      kind: kind,
      input: input,
      onProgress: { update in
        await progressAggregator.report(update, source: kind)
      }
    )
    if url != nil {
      await progressAggregator.finish(source: kind)
    }
    return work
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

    guard fileLayout.isSafeDirectSessionAudioFile(url, fileManager: fileManager) else {
      return SourceWork(
        evidence: .init(
          id: sourceID,
          kind: kind,
          fileName: url.lastPathComponent,
          role: kind == .mixed ? "fallback" : "primary",
          integrity: .invalid,
          durationSeconds: nil,
          sha256: nil,
          issues: ["\(kind.rawValue) source is unavailable or unsafe."]
        )
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
      let rawResult = try await transcriptionService.transcribe(
        wavURL: url,
        modelURL: input.plan.modelURL,
        language: input.plan.language,
        prompt: input.plan.prompt,
        translateToEnglish: false,
        onProgress: onProgress
      )
      let diarization: LocalSessionDiarizationResult
      let rawDiarization = await diarizer.diarize(
        wavURL: url,
        source: kind,
        sessionID: input.session.id
      )
      guard let duration = inspection.duration else {
        return SourceWork(
          evidence: .init(
            id: sourceID,
            kind: kind,
            fileName: url.lastPathComponent,
            role: kind == .mixed ? "fallback" : "primary",
            integrity: .invalid,
            durationSeconds: nil,
            sha256: inspection.sha256,
            issues: inspection.issues + ["Audio duration could not be verified."]
          )
        )
      }
      let resultValidation = LocalSessionEvidenceTimingValidator.validate(
        result: rawResult,
        duration: duration
      )
      let diarizationValidation = LocalSessionEvidenceTimingValidator.validate(
        diarization: rawDiarization,
        duration: duration
      )
      let result = resultValidation.result
      diarization = diarizationValidation.result
      let hadInvalidTiming =
        resultValidation.hadInvalidTiming || diarizationValidation.hadInvalidTiming
      var issues = inspection.issues + result.warnings
      if resultValidation.hadInvalidTiming {
        issues.append("ASR output contained timestamps outside the audio source.")
      }
      if !isTimedNonempty(result) {
        issues.append("\(kind.rawValue) ASR output was empty or lacked valid timestamps.")
      }
      let speechCoverage = LocalSessionEvidenceTimingValidator.speechCoverage(
        transcript: result,
        diarization: diarization,
        duration: duration
      )
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
        diarization: diarization,
        hadInvalidTiming: hadInvalidTiming,
        speechCoverage: speechCoverage
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

  private func makeRunID(for input: LocalSessionEvidenceTranscriptionInput) -> String {
    var components = [
      input.session.id.uuidString.lowercased(),
      String(input.revision),
      input.plan.engine.rawValue,
      input.plan.modelURL.lastPathComponent,
      input.plan.modelFlavor.rawValue,
      input.plan.language,
      input.plan.prompt ?? "",
      input.plan.speedMode.rawValue,
    ]
    if input.importedURL != nil {
      components.append("imported-primary")
    }
    return LocalSessionStableID.string(
      namespace: "transcription-run",
      components: components
    )
  }

  private func recoverExistingRun(
    for input: LocalSessionEvidenceTranscriptionInput,
    runID: String
  ) throws -> LocalSessionEvidenceTranscriptionOutput? {
    let runFileName = "\(runID).json"
    let runURL = fileLayout.transcriptionRunsDirectory(for: input.session.id)
      .appendingPathComponent(runFileName)
    guard let runSnapshot = try readImmutableArtifactSnapshot(at: runURL) else { return nil }
    let data = runSnapshot.data

    let envelope: MeetingEvidenceEnvelopeV1
    do {
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .iso8601
      envelope = try decoder.decode(MeetingEvidenceEnvelopeV1.self, from: data)
    } catch {
      try preserveCorruptRunAndThrow(
        runSnapshot,
        at: runURL,
        reason: "is malformed"
      )
    }

    let canonicalContentHash: String
    do {
      canonicalContentHash = try MeetingEvidenceCanonicalizer.contentHash(envelopeData: data)
    } catch {
      try preserveCorruptRunAndThrow(
        runSnapshot,
        at: runURL,
        reason: "cannot be canonicalized"
      )
    }
    guard envelope.contentHash == canonicalContentHash else {
      try preserveCorruptRunAndThrow(
        runSnapshot,
        at: runURL,
        reason: "does not match its content hash"
      )
    }
    try validateRecoveredEnvelope(envelope, for: input, expectedRunID: runID)
    if let semanticIssue = recoveredSemanticValidationIssue(envelope, for: input) {
      try preserveCorruptRunAndThrow(
        runSnapshot,
        at: runURL,
        reason: "has inconsistent transcript evidence: \(semanticIssue)"
      )
    }

    let outboxFileName = makeOutboxFileName(for: envelope)
    let outboxURL = fileLayout.meetingEvidenceOutboxDirectory
      .appendingPathComponent(outboxFileName)
    try fileManager.createDirectory(
      at: fileLayout.meetingEvidenceOutboxDirectory,
      withIntermediateDirectories: true
    )
    if let outboxSnapshot = try readImmutableArtifactSnapshot(at: outboxURL) {
      guard outboxSnapshot.data == data else {
        throw LocalSessionEvidenceCoordinatorError.invalidImmutableArtifact(
          "\(outboxFileName) differs from the recovered run artifact."
        )
      }
    } else {
      try publishImmutableArtifact(
        data,
        to: outboxURL,
        beforePublish: beforeOutboxWrite
      )
    }
    return makeOutput(
      envelope: envelope,
      artifactNames: (run: runFileName, outbox: outboxFileName)
    )
  }

  private func validateRecoveredEnvelope(
    _ envelope: MeetingEvidenceEnvelopeV1,
    for input: LocalSessionEvidenceTranscriptionInput,
    expectedRunID: String
  ) throws {
    guard
      envelope.schemaVersion == "meeting-evidence/v1",
      envelope.run.id == expectedRunID,
      envelope.session.id == input.session.id.uuidString.lowercased(),
      abs(envelope.session.startedAt.timeIntervalSince(input.session.startedAt)) < 1,
      envelope.revision == input.revision,
      envelope.parentContentHash == input.parentContentHash,
      envelope.run.engine == input.plan.engine,
      envelope.run.model.identifier == input.plan.modelFlavor.rawValue,
      envelope.run.model.modelBasename == input.plan.modelURL.lastPathComponent,
      envelope.run.requestedLanguage == input.plan.language
    else {
      throw LocalSessionEvidenceCoordinatorError.invalidImmutableArtifact(
        "\(expectedRunID).json belongs to different transcription inputs."
      )
    }

    let sourceKinds = envelope.sources.map(\.kind)
    if input.importedURL != nil {
      guard sourceKinds == [.imported] else {
        throw LocalSessionEvidenceCoordinatorError.invalidImmutableArtifact(
          "\(expectedRunID).json does not contain exactly one imported primary source."
        )
      }
    } else if sourceKinds.contains(.imported) {
      throw LocalSessionEvidenceCoordinatorError.invalidImmutableArtifact(
        "\(expectedRunID).json belongs to an imported transcription."
      )
    }

    let URLsByKind: [LocalSessionAudioSourceKind: URL?] = [
      .microphone: input.microphoneURL,
      .system: input.systemURL,
      .mixed: input.mixedURL,
      .imported: input.importedURL,
    ]
    for source in envelope.sources {
      guard let optionalURL = URLsByKind[source.kind] else {
        throw LocalSessionEvidenceCoordinatorError.invalidImmutableArtifact(
          "\(expectedRunID).json contains an unknown audio source."
        )
      }
      guard let url = optionalURL else {
        guard source.integrity == .missing, source.sha256 == nil else {
          throw LocalSessionEvidenceCoordinatorError.invalidImmutableArtifact(
            "The \(source.kind.rawValue) source no longer matches the recovered run."
          )
        }
        continue
      }
      guard fileLayout.isSafeDirectSessionAudioFile(url, fileManager: fileManager) else {
        throw LocalSessionEvidenceCoordinatorError.invalidImmutableArtifact(
          "The \(source.kind.rawValue) source is unavailable or unsafe."
        )
      }
      let inspection = LocalSessionWaveEvidenceInspector.inspect(
        url: url,
        fileManager: fileManager
      )
      let durationMatches: Bool
      switch (source.durationSeconds, inspection.duration) {
      case (nil, nil):
        durationMatches = true
      case (.some(let expected), .some(let actual)):
        durationMatches = abs(expected - actual) < 0.000_001
      default:
        durationMatches = false
      }
      guard
        source.fileName == url.lastPathComponent,
        source.integrity == inspection.integrity,
        source.sha256 == inspection.sha256,
        durationMatches
      else {
        throw LocalSessionEvidenceCoordinatorError.invalidImmutableArtifact(
          "The \(source.kind.rawValue) source no longer matches the recovered run."
        )
      }
    }
  }

  private func recoveredSemanticValidationIssue(
    _ envelope: MeetingEvidenceEnvelopeV1,
    for input: LocalSessionEvidenceTranscriptionInput
  ) -> String? {
    let expectedSessionID = input.session.id.uuidString.lowercased()
    guard
      envelope.evidenceID == "meeting:\(expectedSessionID):run:\(envelope.run.id)",
      envelope.sourceRef == "cepessa-session://\(expectedSessionID)/transcript"
    else {
      return "the evidence identity does not match the session and run"
    }
    guard
      envelope.run.createdAt <= envelope.run.completedAt,
      envelope.run.issues == envelope.quality.issues,
      envelope.quality.diarization == envelope.run.diarizationStatus.rawValue
    else {
      return "run and quality metadata disagree"
    }

    let shouldBeReady = envelope.run.disposition == .ready
    guard
      envelope.session.status == (shouldBeReady ? .ready : .failed),
      envelope.quality.isComplete == shouldBeReady
    else {
      return "run disposition, session status, and completeness disagree"
    }
    if let coverage = envelope.quality.speechCoverage,
      !coverage.isFinite || coverage < 0 || coverage > 1
    {
      return "speech coverage is outside the valid range"
    }

    let sourceIDs = envelope.sources.map(\.id)
    guard Set(sourceIDs).count == sourceIDs.count else {
      return "audio source identifiers are not unique"
    }
    for source in envelope.sources {
      let expectedSourceID = LocalSessionStableID.string(
        namespace: "audio-source",
        components: [expectedSessionID, source.kind.rawValue]
      )
      guard source.id == expectedSourceID else {
        return "the \(source.kind.rawValue) source identifier is invalid"
      }
      guard source.role == (source.kind == .mixed ? "fallback" : "primary") else {
        return "the \(source.kind.rawValue) source role is invalid"
      }
      if source.integrity == .available {
        guard
          let duration = source.durationSeconds,
          duration.isFinite,
          duration > 0,
          let sha256 = source.sha256,
          isLowercaseSHA256(sha256)
        else {
          return "the \(source.kind.rawValue) source lacks valid available-file evidence"
        }
      }
    }

    let sourceKinds = envelope.sources.map(\.kind)
    if input.importedURL != nil {
      guard
        sourceKinds == [.imported],
        envelope.sources[0].role == "primary",
        !envelope.quality.sourceSeparationPreserved
      else {
        return "imported evidence does not contain one non-separated primary source"
      }
    } else {
      let hasCaptureSources =
        sourceKinds == [.microphone, .system]
        || sourceKinds == [.microphone, .system, .mixed]
      guard hasCaptureSources else {
        return "capture evidence has an invalid source layout"
      }
      if sourceKinds.contains(.mixed), envelope.quality.sourceSeparationPreserved {
        return "mixed fallback evidence claims preserved source separation"
      }
    }

    let speakerIDs = envelope.speakers.map(\.id)
    guard Set(speakerIDs).count == speakerIDs.count else {
      return "speaker identifiers are not unique"
    }
    for speaker in envelope.speakers {
      if let confidence = speaker.confidence,
        !confidence.isFinite || confidence < 0 || confidence > 1
      {
        return "speaker confidence is outside the valid range"
      }
    }

    let sourcesByID = Dictionary(uniqueKeysWithValues: envelope.sources.map { ($0.id, $0) })
    let knownSpeakerIDs = Set(speakerIDs)
    let segmentIDs = envelope.segments.map(\.id)
    guard Set(segmentIDs).count == segmentIDs.count else {
      return "transcript segment identifiers are not unique"
    }
    for segment in envelope.segments {
      guard
        let source = sourcesByID[segment.sourceID],
        source.integrity == .available,
        let sourceDuration = source.durationSeconds,
        knownSpeakerIDs.contains(segment.speakerID),
        !segment.rawASRText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        segment.activeText == segment.rawASRText,
        segment.timestampProvenance == .asr,
        segment.isTimed,
        segment.startSeconds.isFinite,
        segment.endSeconds.isFinite,
        segment.startSeconds >= 0,
        segment.endSeconds > segment.startSeconds,
        segment.endSeconds <= sourceDuration
          + LocalSessionEvidenceTimingValidator.timestampTolerance
      else {
        return "a transcript segment has invalid source, speaker, text, or timing evidence"
      }
      if let confidence = segment.confidence,
        !confidence.isFinite || confidence < 0 || confidence > 1
      {
        return "segment confidence is outside the valid range"
      }
    }
    guard envelope.segments.elementsEqual(envelope.segments.sorted(by: segmentSort)) else {
      return "transcript segments are not in deterministic order"
    }
    guard
      envelope.transcript
        == MeetingEvidenceTranscriptRenderer.render(
          segments: envelope.segments,
          speakers: envelope.speakers
        )
    else {
      return "the rendered transcript does not match its segments"
    }

    switch envelope.run.disposition {
    case .ready:
      guard
        !envelope.segments.isEmpty,
        envelope.quality.hasVerifiableTimestamps,
        envelope.run.diarizationStatus == .available,
        (envelope.quality.speechCoverage ?? 0) >= Self.minimumCompleteSpeechCoverage,
        envelope.sources.allSatisfy({ $0.integrity == .available })
      else {
        return "ready evidence lacks complete sources, timing, diarization, or speech coverage"
      }
      if input.importedURL == nil {
        guard
          sourceKinds == [.microphone, .system],
          envelope.quality.sourceSeparationPreserved
        else {
          return "ready capture evidence does not contain two separated primary sources"
        }
      }
    case .degraded:
      guard !envelope.segments.isEmpty else {
        return "degraded evidence has no usable transcript segments"
      }
    case .failed:
      guard
        envelope.segments.isEmpty,
        envelope.speakers.isEmpty,
        !envelope.quality.hasVerifiableTimestamps
      else {
        return "failed evidence contains usable transcript claims"
      }
    }
    return nil
  }

  private func isLowercaseSHA256(_ value: String) -> Bool {
    value.count == 64
      && value == value.lowercased()
      && value.unicodeScalars.allSatisfy(
        CharacterSet(charactersIn: "0123456789abcdef").contains
      )
  }

  private func makeOutput(
    envelope: MeetingEvidenceEnvelopeV1,
    artifactNames: (run: String, outbox: String)
  ) -> LocalSessionEvidenceTranscriptionOutput {
    let summary = LocalSessionTranscriptionEvidenceSummary(
      runID: envelope.run.id,
      revision: envelope.revision,
      disposition: envelope.run.disposition,
      contentHash: envelope.contentHash,
      parentContentHash: envelope.parentContentHash,
      runFileName: artifactNames.run,
      outboxFileName: artifactNames.outbox,
      issues: envelope.run.issues,
      isComplete: envelope.quality.isComplete,
      speechCoverage: envelope.quality.speechCoverage,
      hasVerifiableTimestamps: envelope.quality.hasVerifiableTimestamps
    )
    let speakerLabels = Dictionary(
      uniqueKeysWithValues: envelope.speakers.map { ($0.id, $0.label) }
    )
    let transcriptSegments = envelope.segments.map { segment in
      LocalSessionTranscriptSegment(
        id: UUID(uuidString: segment.id)
          ?? LocalSessionStableID.uuid(namespace: "segment-uuid", components: [segment.id]),
        speaker: speakerLabels[segment.speakerID] ?? "Speaker",
        text: segment.activeText,
        timestamp: envelope.session.startedAt.addingTimeInterval(segment.startSeconds),
        endTimestamp: envelope.session.startedAt.addingTimeInterval(segment.endSeconds),
        speakerID: segment.speakerID,
        source: envelope.sources.first { $0.id == segment.sourceID }?.kind,
        identityStatus: envelope.speakers.first { $0.id == segment.speakerID }?.identityStatus,
        uncertainty: segment.uncertainty
      )
    }
    return .init(
      envelope: envelope,
      summary: summary,
      transcriptSegments: transcriptSegments
    )
  }

  private func preserveCorruptRunAndThrow(
    _ snapshot: ImmutableArtifactSnapshot,
    at runURL: URL,
    reason: String
  ) throws -> Never {
    let data = snapshot.data
    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    let preservedFileName =
      "\(runURL.deletingPathExtension().lastPathComponent).invalid-\(digest.prefix(12)).artifact"
    let preservedURL = runURL.deletingLastPathComponent().appendingPathComponent(
      preservedFileName,
      isDirectory: false
    )
    if let preservedSnapshot = try readImmutableArtifactSnapshot(at: preservedURL) {
      guard preservedSnapshot.data == data else {
        throw LocalSessionEvidenceCoordinatorError.invalidImmutableArtifact(
          "\(runURL.lastPathComponent) \(reason), and its preservation path is occupied."
        )
      }
    } else {
      try publishImmutableArtifact(data, to: preservedURL)
    }
    try removeImmutableArtifact(at: runURL, matching: snapshot)
    throw LocalSessionEvidenceCoordinatorError.invalidImmutableArtifact(
      "\(runURL.lastPathComponent) \(reason). Its exact bytes were preserved as \(preservedFileName). Retry transcription to create a fresh run artifact."
    )
  }

  private func readImmutableArtifactSnapshot(
    at url: URL
  ) throws -> ImmutableArtifactSnapshot? {
    var pathStatus = stat()
    guard lstat(url.path, &pathStatus) == 0 else {
      let errorCode = errno
      if errorCode == ENOENT { return nil }
      throw unsafeImmutableArtifactError(url)
    }
    guard isSafeImmutableFile(pathStatus) else {
      throw unsafeImmutableArtifactError(url)
    }

    let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    guard descriptor >= 0 else {
      throw unsafeImmutableArtifactError(url)
    }
    defer { close(descriptor) }

    var openedStatus = stat()
    guard
      fstat(descriptor, &openedStatus) == 0,
      isSafeImmutableFile(openedStatus),
      sameFile(pathStatus, openedStatus)
    else {
      throw unsafeImmutableArtifactError(url)
    }

    let data: Data
    do {
      let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
      data = try handle.readToEnd() ?? Data()
    } catch {
      throw LocalSessionEvidenceCoordinatorError.invalidImmutableArtifact(
        "\(url.lastPathComponent) could not be read safely."
      )
    }

    var finishedStatus = stat()
    var finalPathStatus = stat()
    guard
      fstat(descriptor, &finishedStatus) == 0,
      lstat(url.path, &finalPathStatus) == 0,
      isSafeImmutableFile(finishedStatus),
      isSafeImmutableFile(finalPathStatus),
      sameFile(openedStatus, finishedStatus),
      sameFile(finishedStatus, finalPathStatus),
      stableFileMetadata(openedStatus, finishedStatus),
      stableFileMetadata(finishedStatus, finalPathStatus),
      finishedStatus.st_size == off_t(data.count)
    else {
      throw unsafeImmutableArtifactError(url)
    }
    return .init(
      data: data,
      status: finishedStatus
    )
  }

  private func removeImmutableArtifact(
    at url: URL,
    matching snapshot: ImmutableArtifactSnapshot
  ) throws {
    var status = stat()
    guard
      lstat(url.path, &status) == 0,
      isSafeImmutableFile(status),
      sameFile(status, snapshot.status),
      stableFileMetadata(status, snapshot.status),
      unlink(url.path) == 0
    else {
      throw LocalSessionEvidenceCoordinatorError.invalidImmutableArtifact(
        "\(url.lastPathComponent) changed after it was read. Its copied evidence was preserved, but the unsafe entry was left untouched."
      )
    }
  }

  private func isSafeImmutableFile(_ status: stat) -> Bool {
    (status.st_mode & S_IFMT) == S_IFREG && status.st_nlink == 1 && status.st_size >= 0
  }

  private func sameFile(_ lhs: stat, _ rhs: stat) -> Bool {
    lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino
  }

  private func stableFileMetadata(_ lhs: stat, _ rhs: stat) -> Bool {
    lhs.st_size == rhs.st_size
      && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
      && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
      && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
      && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
  }

  private func unsafeImmutableArtifactError(
    _ url: URL
  ) -> LocalSessionEvidenceCoordinatorError {
    .invalidImmutableArtifact(
      "\(url.lastPathComponent) is not a stable, regular, single-link file. The unsafe entry was left untouched; remove it before retrying."
    )
  }

  private func makeOutboxFileName(for envelope: MeetingEvidenceEnvelopeV1) -> String {
    let eventID = LocalSessionStableID.string(
      namespace: "meeting-evidence-outbox",
      components: [envelope.evidenceID, envelope.contentHash]
    )
    return "\(eventID).json"
  }

  private func writeImmutableArtifacts(
    envelope: MeetingEvidenceEnvelopeV1
  ) throws -> (run: String, outbox: String) {
    let runDirectory = fileLayout.transcriptionRunsDirectory(for: envelope.sessionID)
    let outboxDirectory = fileLayout.meetingEvidenceOutboxDirectory
    try fileManager.createDirectory(at: runDirectory, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: outboxDirectory, withIntermediateDirectories: true)

    let runFileName = "\(envelope.run.id).json"
    let outboxFileName = makeOutboxFileName(for: envelope)
    let runURL = runDirectory.appendingPathComponent(runFileName)
    let outboxURL = outboxDirectory.appendingPathComponent(outboxFileName)

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    let envelopeData = try encoder.encode(envelope)
    try publishImmutableArtifact(envelopeData, to: runURL)
    try publishImmutableArtifact(
      envelopeData,
      to: outboxURL,
      beforePublish: beforeOutboxWrite
    )
    return (runFileName, outboxFileName)
  }

  private func publishImmutableArtifact(
    _ data: Data,
    to destinationURL: URL,
    beforePublish: @Sendable () throws -> Void = {}
  ) throws {
    let temporaryURL = destinationURL.deletingLastPathComponent().appendingPathComponent(
      ".\(destinationURL.lastPathComponent).\(UUID().uuidString).tmp",
      isDirectory: false
    )
    defer { try? fileManager.removeItem(at: temporaryURL) }

    try data.write(to: temporaryURL, options: .withoutOverwriting)
    let handle = try FileHandle(forWritingTo: temporaryURL)
    do {
      try handle.synchronize()
      try handle.close()
    } catch {
      try? handle.close()
      throw error
    }
    try beforePublish()

    let linkResult = temporaryURL.path.withCString { temporaryPath in
      destinationURL.path.withCString { destinationPath in
        Darwin.link(temporaryPath, destinationPath)
      }
    }
    guard linkResult == 0 else {
      let errorCode = errno
      if errorCode == EEXIST {
        throw LocalSessionEvidenceCoordinatorError.immutableArtifactExists(
          destinationURL.lastPathComponent
        )
      }
      throw NSError(
        domain: NSPOSIXErrorDomain,
        code: Int(errorCode),
        userInfo: [NSFilePathErrorKey: destinationURL.path]
      )
    }
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

  static func inspect(url: URL, fileManager _: FileManager) -> Result {
    var pathStatus = stat()
    guard lstat(url.path, &pathStatus) == 0 else {
      if errno != ENOENT {
        return .init(
          integrity: .invalid, duration: nil, sha256: nil,
          issues: ["Audio file metadata could not be read safely."])
      }
      return .init(
        integrity: .missing, duration: nil, sha256: nil, issues: ["Audio file is missing."])
    }
    guard isSafeFile(pathStatus) else {
      return .init(
        integrity: .invalid, duration: nil, sha256: nil,
        issues: ["Audio file is an unsafe linked audio entry."])
    }

    let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    guard descriptor >= 0 else {
      return .init(
        integrity: .invalid, duration: nil, sha256: nil,
        issues: ["Audio file could not be opened safely."])
    }
    defer { close(descriptor) }

    var openedStatus = stat()
    guard
      fstat(descriptor, &openedStatus) == 0,
      isSafeFile(openedStatus),
      sameFile(pathStatus, openedStatus)
    else {
      return .init(
        integrity: .invalid, duration: nil, sha256: nil,
        issues: ["Audio file changed before it could be read safely."])
    }

    let data: Data
    do {
      let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
      data = try handle.readToEnd() ?? Data()
    } catch {
      return .init(
        integrity: .invalid, duration: nil, sha256: nil,
        issues: ["Audio file is unreadable."])
    }

    var finishedStatus = stat()
    var finalPathStatus = stat()
    guard
      fstat(descriptor, &finishedStatus) == 0,
      lstat(url.path, &finalPathStatus) == 0,
      isSafeFile(finishedStatus),
      isSafeFile(finalPathStatus),
      sameFile(openedStatus, finishedStatus),
      sameFile(finishedStatus, finalPathStatus),
      stableMetadata(openedStatus, finishedStatus),
      stableMetadata(finishedStatus, finalPathStatus),
      finishedStatus.st_size == off_t(data.count)
    else {
      return .init(
        integrity: .invalid, duration: nil, sha256: nil,
        issues: ["Audio file changed while it was being read."])
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

  private static func isSafeFile(_ status: stat) -> Bool {
    (status.st_mode & S_IFMT) == S_IFREG && status.st_nlink == 1 && status.st_size >= 0
  }

  private static func sameFile(_ lhs: stat, _ rhs: stat) -> Bool {
    lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino
  }

  private static func stableMetadata(_ lhs: stat, _ rhs: stat) -> Bool {
    lhs.st_size == rhs.st_size
      && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
      && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
      && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
      && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
  }

  private static func readUInt32(_ data: Data, offset: Int) -> UInt32 {
    guard offset + 4 <= data.count else { return 0 }
    return data[offset..<(offset + 4)].enumerated().reduce(0) {
      $0 | (UInt32($1.element) << UInt32($1.offset * 8))
    }
  }
}
