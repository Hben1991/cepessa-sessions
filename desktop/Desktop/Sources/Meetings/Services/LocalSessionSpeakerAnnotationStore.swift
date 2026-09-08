import Darwin
import Foundation

enum LocalSessionSpeakerAnnotationStoreError: LocalizedError, Equatable {
  case unsafeLock(URL)
  case lockTimeout(URL)
  case unsafeAnnotationFile(URL)

  var errorDescription: String? {
    switch self {
    case .unsafeLock:
      return "The session lock is unavailable or unsafe."
    case .lockTimeout:
      return "Another process is updating this session. Try again."
    case .unsafeAnnotationFile:
      return "The speaker annotation history is unavailable or unsafe."
    }
  }
}

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
    try withSessionLock(for: sessionID) {
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
      try appendUnlocked(event)
      return event
    }
  }

  func loadEvents(sessionID: UUID) -> [LocalSessionSpeakerAnnotationEvent] {
    let url = fileLayout.speakerAnnotationsURL(for: sessionID)
    guard let data = stableAnnotationData(at: url), !data.isEmpty else {
      return []
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return data.split(separator: 0x0A).compactMap {
      try? decoder.decode(LocalSessionSpeakerAnnotationEvent.self, from: Data($0))
    }.filter { $0.sessionID == sessionID }
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
    guard let evidence = session.transcriptionEvidence else { return [:] }
    let runFileName = evidence.runFileName
    guard !runFileName.isEmpty,
      runFileName != ".",
      runFileName != "..",
      !runFileName.contains("/"),
      !runFileName.contains("\0"),
      URL(fileURLWithPath: runFileName).lastPathComponent == runFileName
    else { return [:] }

    let runsDirectory = fileLayout.transcriptionRunsDirectory(for: session.id)
    let url = runsDirectory.appendingPathComponent(runFileName, isDirectory: false)
    guard
      url.deletingLastPathComponent().standardizedFileURL == runsDirectory.standardizedFileURL,
      let data = stableAnnotationData(at: url)
    else { return [:] }

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    guard
      let envelope = try? decoder.decode(MeetingEvidenceEnvelopeV1.self, from: data),
      UUID(uuidString: envelope.session.id) == session.id,
      let canonicalContentHash = try? MeetingEvidenceCanonicalizer.contentHash(envelopeData: data),
      envelope.contentHash == canonicalContentHash,
      evidence.contentHash == canonicalContentHash
    else { return [:] }
    let speakerIDs = envelope.speakers.map(\.id)
    guard Set(speakerIDs).count == speakerIDs.count else { return [:] }
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
    try withSessionLock(for: event.sessionID) {
      try appendUnlocked(event)
    }
  }

  private func appendUnlocked(_ event: LocalSessionSpeakerAnnotationEvent) throws {
    let url = fileLayout.speakerAnnotationsURL(for: event.sessionID)
    guard hasSafeParentDirectories(for: url) else {
      throw LocalSessionSpeakerAnnotationStoreError.unsafeAnnotationFile(url)
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    var data = try encoder.encode(event)
    data.append(0x0A)

    let descriptor = try openAnnotationFileForAppend(at: url)
    defer { close(descriptor) }

    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
    try handle.write(contentsOf: data)
    try handle.synchronize()

    var openedStatus = stat()
    var pathStatus = stat()
    guard
      fstat(descriptor, &openedStatus) == 0,
      lstat(url.path, &pathStatus) == 0,
      isSafeRegularFile(openedStatus),
      isSafeRegularFile(pathStatus),
      sameFile(openedStatus, pathStatus),
      hasSafeParentDirectories(for: url)
    else {
      throw LocalSessionSpeakerAnnotationStoreError.unsafeAnnotationFile(url)
    }
  }

  private func withSessionLock<T>(
    for sessionID: UUID,
    _ body: () throws -> T
  ) throws -> T {
    let sessionDirectory = fileLayout.sessionDirectory(for: sessionID)
    try fileLayout.ensureDirectories(fileManager: fileManager, for: sessionID)

    let lockURL = sessionDirectory.appendingPathComponent(".session.lock", isDirectory: false)
    guard hasSafeParentDirectories(for: lockURL) else {
      throw LocalSessionSpeakerAnnotationStoreError.unsafeLock(lockURL)
    }
    let descriptor = try openSessionLock(at: lockURL)
    defer { close(descriptor) }

    let deadline = DispatchTime.now().uptimeNanoseconds + 1_000_000_000
    while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
      let errorNumber = errno
      guard errorNumber == EAGAIN || errorNumber == EWOULDBLOCK else {
        throw LocalSessionSpeakerAnnotationStoreError.unsafeLock(lockURL)
      }
      guard DispatchTime.now().uptimeNanoseconds < deadline else {
        throw LocalSessionSpeakerAnnotationStoreError.lockTimeout(lockURL)
      }
      usleep(10_000)
    }
    defer { _ = flock(descriptor, LOCK_UN) }

    var lockedStatus = stat()
    var lockedPathStatus = stat()
    guard
      fstat(descriptor, &lockedStatus) == 0,
      lstat(lockURL.path, &lockedPathStatus) == 0,
      isSafeRegularFile(lockedStatus),
      isSafeRegularFile(lockedPathStatus),
      sameFile(lockedStatus, lockedPathStatus),
      hasSafeParentDirectories(for: lockURL)
    else {
      throw LocalSessionSpeakerAnnotationStoreError.unsafeLock(lockURL)
    }
    return try body()
  }

  private func openSessionLock(at url: URL) throws -> Int32 {
    var pathStatus = stat()
    let pathExists = lstat(url.path, &pathStatus) == 0
    if pathExists {
      guard isSafeRegularFile(pathStatus) else {
        throw LocalSessionSpeakerAnnotationStoreError.unsafeLock(url)
      }
    } else if errno != ENOENT {
      throw LocalSessionSpeakerAnnotationStoreError.unsafeLock(url)
    }

    let descriptor = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
    guard descriptor >= 0 else {
      throw LocalSessionSpeakerAnnotationStoreError.unsafeLock(url)
    }

    var openedStatus = stat()
    var openedPathStatus = stat()
    guard
      fstat(descriptor, &openedStatus) == 0,
      lstat(url.path, &openedPathStatus) == 0,
      isSafeRegularFile(openedStatus),
      isSafeRegularFile(openedPathStatus),
      sameFile(openedStatus, openedPathStatus),
      !pathExists || sameFile(pathStatus, openedStatus)
    else {
      close(descriptor)
      throw LocalSessionSpeakerAnnotationStoreError.unsafeLock(url)
    }
    return descriptor
  }

  private func stableAnnotationData(at url: URL) -> Data? {
    for _ in 0..<3 {
      if let data = try? readStableAnnotationData(at: url) {
        return data
      }
    }
    return nil
  }

  private func readStableAnnotationData(at url: URL) throws -> Data? {
    guard hasSafeParentDirectories(for: url) else {
      throw LocalSessionSpeakerAnnotationStoreError.unsafeAnnotationFile(url)
    }
    var pathStatus = stat()
    guard lstat(url.path, &pathStatus) == 0 else {
      if errno == ENOENT { return nil }
      throw LocalSessionSpeakerAnnotationStoreError.unsafeAnnotationFile(url)
    }
    guard isSafeRegularFile(pathStatus) else {
      throw LocalSessionSpeakerAnnotationStoreError.unsafeAnnotationFile(url)
    }

    let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    guard descriptor >= 0 else {
      throw LocalSessionSpeakerAnnotationStoreError.unsafeAnnotationFile(url)
    }
    defer { close(descriptor) }

    var openedStatus = stat()
    guard
      fstat(descriptor, &openedStatus) == 0,
      isSafeRegularFile(openedStatus),
      sameFile(pathStatus, openedStatus),
      stableFileMetadata(pathStatus, openedStatus)
    else {
      throw LocalSessionSpeakerAnnotationStoreError.unsafeAnnotationFile(url)
    }

    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
    let data = try handle.readToEnd() ?? Data()

    var finishedStatus = stat()
    var finalPathStatus = stat()
    guard
      fstat(descriptor, &finishedStatus) == 0,
      lstat(url.path, &finalPathStatus) == 0,
      isSafeRegularFile(finishedStatus),
      isSafeRegularFile(finalPathStatus),
      sameFile(openedStatus, finishedStatus),
      sameFile(finishedStatus, finalPathStatus),
      stableFileMetadata(openedStatus, finishedStatus),
      stableFileMetadata(finishedStatus, finalPathStatus),
      finishedStatus.st_size == off_t(data.count),
      hasSafeParentDirectories(for: url)
    else {
      throw LocalSessionSpeakerAnnotationStoreError.unsafeAnnotationFile(url)
    }
    return data
  }

  private func openAnnotationFileForAppend(at url: URL) throws -> Int32 {
    for _ in 0..<3 {
      var pathStatus = stat()
      if lstat(url.path, &pathStatus) == 0 {
        guard isSafeRegularFile(pathStatus) else {
          throw LocalSessionSpeakerAnnotationStoreError.unsafeAnnotationFile(url)
        }

        let descriptor = open(url.path, O_WRONLY | O_APPEND | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
          throw LocalSessionSpeakerAnnotationStoreError.unsafeAnnotationFile(url)
        }

        var openedStatus = stat()
        guard
          fstat(descriptor, &openedStatus) == 0,
          isSafeRegularFile(openedStatus),
          sameFile(pathStatus, openedStatus),
          stableFileMetadata(pathStatus, openedStatus)
        else {
          close(descriptor)
          throw LocalSessionSpeakerAnnotationStoreError.unsafeAnnotationFile(url)
        }
        return descriptor
      }

      guard errno == ENOENT else {
        throw LocalSessionSpeakerAnnotationStoreError.unsafeAnnotationFile(url)
      }
      let descriptor = open(
        url.path,
        O_WRONLY | O_APPEND | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
        mode_t(0o600)
      )
      if descriptor >= 0 {
        var openedStatus = stat()
        var createdPathStatus = stat()
        guard
          fstat(descriptor, &openedStatus) == 0,
          lstat(url.path, &createdPathStatus) == 0,
          isSafeRegularFile(openedStatus),
          isSafeRegularFile(createdPathStatus),
          sameFile(openedStatus, createdPathStatus)
        else {
          close(descriptor)
          throw LocalSessionSpeakerAnnotationStoreError.unsafeAnnotationFile(url)
        }
        return descriptor
      }
      guard errno == EEXIST else {
        throw LocalSessionSpeakerAnnotationStoreError.unsafeAnnotationFile(url)
      }
    }
    throw LocalSessionSpeakerAnnotationStoreError.unsafeAnnotationFile(url)
  }

  private func isSafeRegularFile(_ status: stat) -> Bool {
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

  private func hasSafeParentDirectories(for url: URL) -> Bool {
    guard let checkedURL = LocalStoragePath.checkedFileURL(url) else { return false }
    let components = checkedURL.pathComponents
    guard components.first == "/" else { return false }

    var currentURL = URL(fileURLWithPath: "/", isDirectory: true)
    for component in components.dropFirst().dropLast() {
      currentURL.appendPathComponent(component, isDirectory: true)
      var status = stat()
      guard lstat(currentURL.path, &status) == 0, (status.st_mode & S_IFMT) == S_IFDIR else {
        return false
      }
    }
    return true
  }
}
