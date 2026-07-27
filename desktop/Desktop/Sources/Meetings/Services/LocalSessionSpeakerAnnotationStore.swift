import Foundation

struct LocalSessionSpeakerAnnotationEvent: Codable, Equatable, Sendable {
  enum Action: String, Codable, Equatable, Sendable {
    case rename
    case undo
  }

  let id: UUID
  let createdAt: Date
  let sessionID: UUID
  let evidenceContentHash: String
  let speakerID: String
  let action: Action
  let displayName: String?
  let targetEventID: UUID?
}

struct LocalSessionSpeakerAnnotationStore {
  private let fileLayout: LocalSessionFileLayout
  private let fileManager: FileManager
  private let now: @Sendable () -> Date

  init(
    fileLayout: LocalSessionFileLayout,
    fileManager: FileManager = .default,
    now: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.fileLayout = fileLayout
    self.fileManager = fileManager
    self.now = now
  }

  @discardableResult
  func appendRename(
    sessionID: UUID,
    evidenceContentHash: String,
    speakerID: String,
    displayName: String
  ) throws -> LocalSessionSpeakerAnnotationEvent {
    let normalizedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedName.isEmpty else {
      throw CocoaError(.validationMissingMandatoryProperty)
    }
    let event = LocalSessionSpeakerAnnotationEvent(
      id: UUID(),
      createdAt: now(),
      sessionID: sessionID,
      evidenceContentHash: evidenceContentHash,
      speakerID: speakerID,
      action: .rename,
      displayName: normalizedName,
      targetEventID: nil
    )
    try append(event)
    return event
  }

  @discardableResult
  func appendUndo(
    sessionID: UUID,
    evidenceContentHash: String,
    speakerID: String
  ) throws -> LocalSessionSpeakerAnnotationEvent? {
    let events = loadEvents(sessionID: sessionID)
      .filter { $0.evidenceContentHash == evidenceContentHash }
    let undone = Set(events.compactMap { $0.action == .undo ? $0.targetEventID : nil })
    guard
      let target = events.last(where: {
        $0.action == .rename && $0.speakerID == speakerID && !undone.contains($0.id)
      })
    else {
      return nil
    }
    let event = LocalSessionSpeakerAnnotationEvent(
      id: UUID(),
      createdAt: now(),
      sessionID: sessionID,
      evidenceContentHash: evidenceContentHash,
      speakerID: speakerID,
      action: .undo,
      displayName: nil,
      targetEventID: target.id
    )
    try append(event)
    return event
  }

  func loadEvents(sessionID: UUID) -> [LocalSessionSpeakerAnnotationEvent] {
    let url = fileLayout.speakerAnnotationsURL(for: sessionID)
    guard let data = try? Data(contentsOf: url), !data.isEmpty else { return [] }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return data.split(separator: 0x0A).compactMap {
      try? decoder.decode(LocalSessionSpeakerAnnotationEvent.self, from: Data($0))
    }
  }

  func resolvedNames(
    sessionID: UUID,
    evidenceContentHash: String
  ) -> [String: String] {
    let matching = loadEvents(sessionID: sessionID).filter {
      $0.evidenceContentHash == evidenceContentHash
    }
    let undone = Set(matching.compactMap { $0.action == .undo ? $0.targetEventID : nil })
    var names: [String: String] = [:]
    for event in matching where event.action == .rename && !undone.contains(event.id) {
      if let displayName = event.displayName {
        names[event.speakerID] = displayName
      }
    }
    return names
  }

  func applyingAnnotations(to session: LocalSession) -> LocalSession {
    guard let contentHash = session.transcriptionEvidence?.contentHash else { return session }
    let names = resolvedNames(sessionID: session.id, evidenceContentHash: contentHash)
    guard !names.isEmpty else { return session }
    var updated = session
    for index in updated.transcriptSegments.indices {
      guard let speakerID = updated.transcriptSegments[index].speakerID,
        let name = names[speakerID]
      else { continue }
      updated.transcriptSegments[index].speaker = name
      updated.transcriptSegments[index].identityStatus = .confirmed
    }
    return updated
  }

  func removingAnnotationProjection(
    from session: LocalSession,
    persistedBase: LocalSession? = nil
  ) -> LocalSession {
    guard let contentHash = session.transcriptionEvidence?.contentHash else { return session }
    let annotatedSpeakerIDs = Set(
      resolvedNames(sessionID: session.id, evidenceContentHash: contentHash).keys
    )
    guard !annotatedSpeakerIDs.isEmpty else { return session }
    let evidenceSpeakers = evidenceSpeakerMetadata(for: session)
    let persistedSpeakers = (persistedBase?.transcriptSegments ?? []).reduce(
      into: [String: LocalSessionTranscriptSegment]()
    ) { speakers, segment in
      if let speakerID = segment.speakerID, speakers[speakerID] == nil {
        speakers[speakerID] = segment
      }
    }
    let fallbackLabels = fallbackSpeakerLabels(for: session)
    var base = session
    for index in base.transcriptSegments.indices {
      guard let speakerID = base.transcriptSegments[index].speakerID,
        annotatedSpeakerIDs.contains(speakerID)
      else { continue }
      if let evidence = evidenceSpeakers[speakerID] {
        base.transcriptSegments[index].speaker = evidence.label
        base.transcriptSegments[index].identityStatus = evidence.identityStatus
      } else if let persisted = persistedSpeakers[speakerID] {
        base.transcriptSegments[index].speaker = persisted.speaker
        base.transcriptSegments[index].identityStatus = persisted.identityStatus
      } else {
        base.transcriptSegments[index].speaker =
          fallbackLabels[speakerID] ?? "Speaker"
        base.transcriptSegments[index].identityStatus = .unavailable
      }
    }
    return base
  }

  private func evidenceSpeakerMetadata(
    for session: LocalSession
  ) -> [String: LocalSessionEvidenceSpeakerV1] {
    guard let runFileName = session.transcriptionEvidence?.runFileName else { return [:] }
    let url = fileLayout.transcriptionRunsDirectory(for: session.id)
      .appendingPathComponent(runFileName, isDirectory: false)
    guard let data = try? Data(contentsOf: url) else { return [:] }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    guard let envelope = try? decoder.decode(MeetingEvidenceEnvelopeV1.self, from: data) else {
      return [:]
    }
    return Dictionary(uniqueKeysWithValues: envelope.speakers.map { ($0.id, $0) })
  }

  private func fallbackSpeakerLabels(for session: LocalSession) -> [String: String] {
    var labels: [String: String] = [:]
    var remoteIndex = 0
    for segment in session.transcriptSegments {
      guard let speakerID = segment.speakerID, labels[speakerID] == nil else { continue }
      if segment.source == .microphone {
        labels[speakerID] = "Microphone speaker"
      } else {
        remoteIndex += 1
        labels[speakerID] = "Speaker \(remoteIndex)"
      }
    }
    return labels
  }

  private func append(_ event: LocalSessionSpeakerAnnotationEvent) throws {
    let url = fileLayout.speakerAnnotationsURL(for: event.sessionID)
    try fileManager.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    var data = try encoder.encode(event)
    data.append(0x0A)
    if !fileManager.fileExists(atPath: url.path) {
      try data.write(to: url, options: .withoutOverwriting)
      return
    }
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: data)
    try handle.synchronize()
  }
}
