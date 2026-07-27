import Combine
import Foundation
import SwiftUI

enum LocalSessionStorageRoot {
  static var productionBaseDirectory: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Cepessa", isDirectory: true)
  }

  static var defaultBaseDirectory: URL {
    #if DEBUG
      if let testRoot = ProcessInfo.processInfo.environment["CEPESSA_SESSIONS_TEST_ROOT"]?
        .trimmingCharacters(in: .whitespacesAndNewlines),
        !testRoot.isEmpty
      {
        return URL(fileURLWithPath: testRoot, isDirectory: true)
      }

      if ProcessInfo.processInfo.processName == "xctest" {
        return FileManager.default.temporaryDirectory.appendingPathComponent(
          "CepessaSessionsTests-\(ProcessInfo.processInfo.processIdentifier)",
          isDirectory: true
        )
      }
    #endif

    return productionBaseDirectory
  }
}

@MainActor
final class LocalSessionAppModel: ObservableObject {
  @Published var sessions: [LocalSession] {
    didSet {
      reconcileSelection()
      refreshRetranscriptionAvailabilityCache(for: sessions)
    }
  }
  @Published var selectedSessionID: LocalSession.ID?
  @Published private(set) var isRecording = false
  @Published private(set) var isTranscribing = false
  @Published private(set) var isGeneratingRecap = false
  @Published private(set) var isMicrophoneCaptureActive = false
  @Published private(set) var isMicrophoneMuted = false
  @Published private(set) var isSystemAudioCaptureActive = false
  @Published private(set) var micLevel: Double = 0
  @Published private(set) var systemLevel: Double = 0
  @Published private(set) var recordingDurationText = LocalMeetingRecordingTimer.shared
    .formattedDuration
  @Published private(set) var recorderErrorMessage: String?
  @Published private(set) var processingStatusTitle: String?
  @Published private(set) var processingStatusDetail: String?
  @Published private(set) var processingProgress: Double?
  @Published private(set) var processingSnapshots: [LocalSessionProcessingSnapshot] = []
  @Published private(set) var retranscribableSessionIDs: Set<LocalSession.ID> = []
  let speakerModelProvisioner: LocalSessionSpeakerModelProvisioner

  private let fileLayout: LocalSessionFileLayout
  private let store: LocalSessionStore?
  private let recorder: LocalMeetingRecorder
  private let transcriptionService: any LocalSessionTranscribing
  private let evidenceTranscriptionCoordinator: LocalSessionEvidenceTranscriptionCoordinator
  private let audioImportService: any LocalSessionAudioImporting
  private let fileManager: FileManager
  private var activeImportSessionIDs: Set<LocalSession.ID> = []
  private var activeTranscriptionSessionIDs: Set<LocalSession.ID> = []
  private var warmedTranscriptionModelPath: String?
  private var cancellables: Set<AnyCancellable> = []

  init(
    sessions: [LocalSession] = [],
    store: LocalSessionStore? = nil,
    fileLayout: LocalSessionFileLayout? = nil,
    transcriptionService: any LocalSessionTranscribing = LocalMeetingTranscriptionService(),
    audioImportService: any LocalSessionAudioImporting = LocalSessionAudioImportService(),
    speakerModelProvisioner: LocalSessionSpeakerModelProvisioner? = nil,
    fileManager: FileManager = .default
  ) {
    let resolvedFileLayout =
      fileLayout ?? LocalSessionFileLayout(baseDirectory: Self.defaultBaseDirectory)
    let resolvedStore = store ?? LocalSessionStore(fileLayout: resolvedFileLayout)
    self.sessions = sessions
    self.fileLayout = resolvedFileLayout
    self.store = resolvedStore
    let resolvedSpeakerModelProvisioner =
      speakerModelProvisioner
      ?? LocalSessionSpeakerModelProvisioner(
        fileLayout: resolvedFileLayout,
        fileManager: fileManager
      )
    self.speakerModelProvisioner = resolvedSpeakerModelProvisioner
    self.recorder = LocalMeetingRecorder(fileLayout: resolvedFileLayout)
    self.transcriptionService = transcriptionService
    self.evidenceTranscriptionCoordinator = LocalSessionEvidenceTranscriptionCoordinator(
      transcriptionService: transcriptionService,
      diarizer: LocalSessionSpeakerKitDiarizer(
        modelFolderURL: resolvedSpeakerModelProvisioner.activeRoot,
        fileManager: fileManager
      ),
      fileLayout: resolvedFileLayout,
      fileManager: fileManager
    )
    self.audioImportService = audioImportService
    self.fileManager = fileManager
    self.selectedSessionID = nil
    bindRecorder()
    loadStoredSessions()
  }

  var selectedSession: LocalSession? {
    guard let selectedSessionID else { return nil }
    return sessions.first { $0.id == selectedSessionID }
  }

  var isProcessingSession: Bool {
    isTranscribing
  }

  var processingQueue: [LocalSessionProcessingSnapshot] {
    processingSnapshots.sorted(by: processingSnapshotSort)
  }

  func processingSnapshot(for sessionID: LocalSession.ID) -> LocalSessionProcessingSnapshot? {
    processingSnapshots.first { $0.id == sessionID }
  }

  func isGeneratingRecap(for sessionID: LocalSession.ID) -> Bool {
    false
  }

  func canRetranscribe(_ session: LocalSession) -> Bool {
    guard processingSnapshot(for: session.id) == nil else { return false }
    return retranscribableSessionIDs.contains(session.id)
  }

  func loadEmptySessions() {
    retranscribableSessionIDs = []
    sessions = []
    selectedSessionID = nil
  }

  func loadSampleSessions() {
    retranscribableSessionIDs = []
    sessions = LocalSession.sampleSessions.sorted { $0.startedAt > $1.startedAt }
    selectedSessionID = sessions.first?.id
  }

  func loadStoredSessions() {
    guard let store else { return }

    let storedSessions = store.loadSessions()
    let normalizedSessions = storedSessions.map(normalizedStoredSession(_:))
    refreshRetranscriptionAvailabilityCache(for: normalizedSessions)

    for (storedSession, normalizedSession) in zip(storedSessions, normalizedSessions)
    where storedSession != normalizedSession {
      do {
        try store.save(normalizedSession)
      } catch {
        recorderErrorMessage =
          "Failed to recover an interrupted session. \(error.localizedDescription)"
      }
    }
    let annotationStore = LocalSessionSpeakerAnnotationStore(
      fileLayout: fileLayout,
      fileManager: fileManager
    )
    sessions = normalizedSessions.map(annotationStore.applyingAnnotations(to:))

    if selectedSessionID == nil {
      selectedSessionID = sessions.first?.id
    }

  }

  @discardableResult
  func renameSpeaker(
    speakerID: String,
    to displayName: String,
    in sessionID: LocalSession.ID? = nil
  ) -> Bool {
    let resolvedSessionID = sessionID ?? selectedSessionID
    guard let resolvedSessionID,
      let index = sessions.firstIndex(where: { $0.id == resolvedSessionID }),
      let contentHash = sessions[index].transcriptionEvidence?.contentHash
    else {
      return false
    }
    do {
      let annotationStore = LocalSessionSpeakerAnnotationStore(
        fileLayout: fileLayout,
        fileManager: fileManager
      )
      try annotationStore.appendRename(
        sessionID: resolvedSessionID,
        evidenceContentHash: contentHash,
        speakerID: speakerID,
        displayName: displayName
      )
      sessions[index] = annotationStore.applyingAnnotations(to: sessions[index])
      return true
    } catch {
      recorderErrorMessage = "Failed to save the speaker name. \(error.localizedDescription)"
      return false
    }
  }

  @discardableResult
  func undoLatestSpeakerRename(
    speakerID: String,
    in sessionID: LocalSession.ID? = nil
  ) -> Bool {
    let resolvedSessionID = sessionID ?? selectedSessionID
    guard let resolvedSessionID,
      let index = sessions.firstIndex(where: { $0.id == resolvedSessionID }),
      let contentHash = sessions[index].transcriptionEvidence?.contentHash
    else {
      return false
    }
    let annotationStore = LocalSessionSpeakerAnnotationStore(
      fileLayout: fileLayout,
      fileManager: fileManager
    )
    do {
      guard
        try annotationStore.appendUndo(
          sessionID: resolvedSessionID,
          evidenceContentHash: contentHash,
          speakerID: speakerID
        ) != nil
      else {
        return false
      }
      guard let rawSession = store?.loadSessions().first(where: { $0.id == resolvedSessionID })
      else { return false }
      sessions[index] = annotationStore.applyingAnnotations(
        to: normalizedStoredSession(rawSession)
      )
      return true
    } catch {
      recorderErrorMessage = "Failed to undo the speaker name. \(error.localizedDescription)"
      return false
    }
  }

  @discardableResult
  func upsertSession(_ session: LocalSession) -> LocalSession {
    let annotationStore = LocalSessionSpeakerAnnotationStore(
      fileLayout: fileLayout,
      fileManager: fileManager
    )
    let mergedSession = mergedSession(from: session)
    let persistedBase = store?.loadSessions().first { $0.id == mergedSession.id }
    let persistedSession = annotationStore.removingAnnotationProjection(
      from: mergedSession,
      persistedBase: persistedBase
    )
    let displayedSession = annotationStore.applyingAnnotations(to: persistedSession)

    if let existingIndex = sessions.firstIndex(where: { $0.id == displayedSession.id }) {
      sessions[existingIndex] = displayedSession
    } else {
      sessions.append(displayedSession)
    }

    sessions.sort { $0.startedAt > $1.startedAt }

    do {
      try store?.save(persistedSession)
    } catch {
      recorderErrorMessage = "Failed to save this session locally. \(error.localizedDescription)"
    }

    return displayedSession
  }

  func selectSession(id: LocalSession.ID) {
    guard sessions.contains(where: { $0.id == id }) else {
      selectedSessionID = nil
      return
    }

    selectedSessionID = id
    syncProcessingSummary(preferredSessionID: id)
  }

  @discardableResult
  func updateSessionTitle(_ title: String, for sessionID: LocalSession.ID? = nil) -> Bool {
    let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let currentSession = sessions.first(where: { $0.id == (sessionID ?? selectedSessionID) })
    else {
      return false
    }
    guard currentSession.title != trimmedTitle else { return true }
    let updatedSession = mutateSession(id: sessionID) { session in
      session.title = trimmedTitle
    }
    guard updatedSession != nil else { return false }

    return true
  }

  func clearSelection() {
    selectedSessionID = nil
    syncProcessingSummary()
  }

  private func reconcileSelection() {
    guard let currentSelectionID = selectedSessionID else { return }
    if !sessions.contains(where: { $0.id == currentSelectionID }) {
      selectedSessionID = nil
    }
  }

  func toggleRecording() {
    #if DEBUG
      if ProcessInfo.processInfo.environment["CEPESSA_SESSIONS_DEBUG_PRESENTATION_ONLY"] == "1" {
        isRecording.toggle()
        isMicrophoneCaptureActive = isRecording
        isSystemAudioCaptureActive = isRecording
        isMicrophoneMuted = false
        micLevel = isRecording ? 0.24 : 0
        systemLevel = isRecording ? 0.36 : 0
        recordingDurationText = isRecording ? "00:42" : "00:00"
        recorderErrorMessage = nil
        return
      }
    #endif

    if isRecording {
      Task { await stopRecording() }
    } else {
      Task { await startRecording() }
    }
  }

  func toggleMicrophoneMute() {
    guard isRecording else { return }
    recorder.toggleMicrophoneMute()
  }

  func importExistingRecording(from sourceURL: URL, title: String? = nil) async {
    let sessionID = UUID()
    let startedAt = importedRecordingDate(for: sourceURL)
    let resolvedTitle = normalizedImportedTitle(title, sourceURL: sourceURL)
    var session = LocalSession(
      id: sessionID,
      title: resolvedTitle,
      startedAt: startedAt,
      status: .transcribing,
      transcriptSegments: [],
      recap: .empty,
      audioArtifacts: .init(
        micFileName: nil,
        systemFileName: nil,
        mixedFileName: "mixed.wav"
      )
    )

    session = upsertSession(session)
    selectedSessionID = session.id

    let destinationURL = fileLayout.mixedAudioURL(for: session.id)
    beginImport(for: session.id)
    setProcessingSnapshot(
      for: session.id,
      phase: .importingAudio,
      title: "Importing audio",
      detail: "Normalizing the selected recording into the local transcript pipeline.",
      progress: 0.02,
      logMessages: [
        "Source file: \(sourceURL.lastPathComponent)",
        "Destination file: \(destinationURL.lastPathComponent)",
      ]
    )

    do {
      try fileLayout.ensureDirectories(for: session.id)
      try await audioImportService.importAudio(from: sourceURL, to: destinationURL)
      recorderErrorMessage = nil
      endImport(for: session.id)
      await transcribe(session, audioURL: destinationURL)
    } catch {
      recorderErrorMessage = error.localizedDescription
      endImport(for: session.id, clearSnapshot: true)
      _ = mutateSession(id: session.id) { currentSession in
        currentSession.status = .failed
      }
    }
  }

  func retranscribeSession(id: LocalSession.ID) {
    Task { await retranscribeSession(id: id, shouldResetSelection: true) }
  }

  private func retranscribeSession(id: LocalSession.ID, shouldResetSelection: Bool) async {
    guard var session = sessions.first(where: { $0.id == id }) else { return }
    guard processingSnapshot(for: id) == nil else { return }
    guard let audioURL = resolvedAudioURL(for: session) else {
      recorderErrorMessage = "This session does not have a local audio file to transcribe."
      return
    }

    session.status = .transcribing
    session.transcriptSegments = []
    session.recap = .empty
    let preparedSession = upsertSession(session)

    if shouldResetSelection {
      selectedSessionID = preparedSession.id
    }

    recorderErrorMessage = nil
    await transcribe(preparedSession, audioURL: audioURL)
  }

  @discardableResult
  func addAttachment(
    _ attachment: LocalSessionAttachment,
    to sessionID: LocalSession.ID? = nil
  ) -> LocalSessionAttachment? {
    guard
      mutateSession(
        id: sessionID,
        { session in
          session.addAttachment(attachment)
        }) != nil
    else {
      return nil
    }

    return attachment
  }

  @discardableResult
  func addScreenshotAttachment(
    to sessionID: LocalSession.ID? = nil,
    title: String,
    timestamp: Date = Date(),
    sessionOffset: TimeInterval? = nil,
    fileName: String? = nil,
    mimeType: String = "image/png",
    urlString: String? = nil,
    note: String? = nil
  ) -> LocalSessionAttachment? {
    let attachment = LocalSessionAttachment(
      id: UUID(),
      kind: .image,
      source: .manual,
      title: title,
      timestamp: timestamp,
      sessionOffset: sessionOffset,
      fileName: fileName,
      mimeType: mimeType,
      urlString: urlString,
      note: note
    )

    return addAttachment(attachment, to: sessionID)
  }

  @discardableResult
  func addDocumentAttachment(
    to sessionID: LocalSession.ID? = nil,
    title: String,
    timestamp: Date = Date(),
    sessionOffset: TimeInterval? = nil,
    fileName: String? = nil,
    mimeType: String = "application/pdf",
    urlString: String? = nil,
    note: String? = nil
  ) -> LocalSessionAttachment? {
    let attachment = LocalSessionAttachment(
      id: UUID(),
      kind: .file,
      source: .manual,
      title: title,
      timestamp: timestamp,
      sessionOffset: sessionOffset,
      fileName: fileName,
      mimeType: mimeType,
      urlString: urlString,
      note: note
    )

    return addAttachment(attachment, to: sessionID)
  }

  @discardableResult
  func addCaptureArtifact(
    to sessionID: LocalSession.ID? = nil,
    title: String,
    capturedAt: Date = Date(),
    sessionOffset: TimeInterval? = nil,
    attachmentIDs: [UUID] = [],
    notes: String? = nil
  ) -> LocalSessionCaptureArtifact? {
    let captureArtifact = LocalSessionCaptureArtifact(
      id: UUID(),
      kind: .floatingBarCapture,
      title: title,
      capturedAt: capturedAt,
      sessionOffset: sessionOffset,
      attachmentIDs: attachmentIDs,
      notes: notes
    )

    guard
      mutateSession(
        id: sessionID,
        { session in
          session.captureArtifacts.append(captureArtifact)
        }) != nil
    else {
      return nil
    }

    return captureArtifact
  }

  func updateAttachmentAnchor(
    attachmentID: UUID,
    in sessionID: LocalSession.ID? = nil,
    timestamp: Date,
    sessionOffset: TimeInterval?
  ) -> Bool {
    let resolvedSessionID = sessionID ?? selectedSessionID
    guard let resolvedSessionID,
      let index = sessions.firstIndex(where: { $0.id == resolvedSessionID })
    else {
      return false
    }

    var session = sessions[index]
    guard let attachmentIndex = session.attachments.firstIndex(where: { $0.id == attachmentID })
    else {
      return false
    }

    session.attachments[attachmentIndex].timestamp = timestamp
    session.attachments[attachmentIndex].sessionOffset = sessionOffset
    upsertSession(session)
    return true
  }

  func sessionFolderURL(for sessionID: LocalSession.ID? = nil) -> URL? {
    let resolvedSessionID = sessionID ?? selectedSessionID
    guard let resolvedSessionID else { return nil }
    return fileLayout.sessionDirectory(for: resolvedSessionID)
  }

  func promptPackageMarkdownURL(for sessionID: LocalSession.ID? = nil) -> URL? {
    let resolvedSessionID = sessionID ?? selectedSessionID
    guard let resolvedSessionID else { return nil }
    return fileLayout.promptPackageMarkdownURL(for: resolvedSessionID)
  }

  func promptPackageJSONURL(for sessionID: LocalSession.ID? = nil) -> URL? {
    let resolvedSessionID = sessionID ?? selectedSessionID
    guard let resolvedSessionID else { return nil }
    return fileLayout.promptPackageJSONURL(for: resolvedSessionID)
  }

  func sendDocumentChatMessage(_ text: String, for sessionID: LocalSession.ID? = nil) {}

  func regenerateRecap(for sessionID: LocalSession.ID? = nil) {}

  func applyPendingDocumentChatProposal(for sessionID: LocalSession.ID? = nil) {}

  func undoLastDocumentChatEdit(for sessionID: LocalSession.ID? = nil) {}

  func discardPendingDocumentChatProposal(for sessionID: LocalSession.ID? = nil) {}

  private func startRecording() async {
    do {
      let session = try await recorder.startRecording()
      recorderErrorMessage = recorder.lastErrorMessage
      upsertSession(session)
      selectedSessionID = session.id
    } catch {
      recorderErrorMessage = error.localizedDescription
    }
  }

  private func stopRecording() async {
    if let session = await recorder.stopRecording() {
      let mergedSession = upsertSession(session)
      selectedSessionID = mergedSession.id
      await transcribe(mergedSession)
    }
  }

  private func bindRecorder() {
    recorder.$isRecording
      .receive(on: DispatchQueue.main)
      .sink { [weak self] in self?.isRecording = $0 }
      .store(in: &cancellables)

    recorder.$micLevel
      .receive(on: DispatchQueue.main)
      .removeDuplicates { abs($0 - $1) < 0.01 }
      .throttle(for: .milliseconds(80), scheduler: DispatchQueue.main, latest: true)
      .sink { [weak self] in self?.micLevel = $0 }
      .store(in: &cancellables)

    recorder.$isMicrophoneCaptureActive
      .receive(on: DispatchQueue.main)
      .sink { [weak self] in self?.isMicrophoneCaptureActive = $0 }
      .store(in: &cancellables)

    recorder.$isMicrophoneMuted
      .receive(on: DispatchQueue.main)
      .sink { [weak self] in self?.isMicrophoneMuted = $0 }
      .store(in: &cancellables)

    recorder.$isSystemAudioCaptureActive
      .receive(on: DispatchQueue.main)
      .sink { [weak self] in self?.isSystemAudioCaptureActive = $0 }
      .store(in: &cancellables)

    recorder.$systemLevel
      .receive(on: DispatchQueue.main)
      .removeDuplicates { abs($0 - $1) < 0.01 }
      .throttle(for: .milliseconds(80), scheduler: DispatchQueue.main, latest: true)
      .sink { [weak self] in self?.systemLevel = $0 }
      .store(in: &cancellables)

    recorder.$lastErrorMessage
      .receive(on: DispatchQueue.main)
      .sink { [weak self] in self?.recorderErrorMessage = $0 }
      .store(in: &cancellables)

    LocalMeetingRecordingTimer.shared.$duration
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in
        self?.recordingDurationText = LocalMeetingRecordingTimer.shared.formattedDuration
      }
      .store(in: &cancellables)
  }

  private func transcribe(_ session: LocalSession, audioURL: URL? = nil) async {
    var updatedSession = session
    let sessionID = session.id
    let transcriptionSettings = LocalSessionTranscriptionSettings.current()
    let transcriptionPlan = fileLayout.resolvedTranscriptionPlan(
      settings: transcriptionSettings,
      fileManager: fileManager
    )
    let resolvedAudioURL = audioURL ?? fileLayout.mixedAudioURL(for: sessionID)

    beginTranscription(for: sessionID)
    await warmUpTranscriptionModelIfNeeded(plan: transcriptionPlan)
    setProcessingSnapshot(
      for: sessionID,
      phase: .transcribing,
      title: "Preparing audio",
      detail: "\(transcriptionPlan.speedMode.rawValue) mode is preparing the local mixed master.",
      progress: 0.03,
      logMessages: [
        "Audio file: \(resolvedAudioURL.lastPathComponent)",
        "Model file: \(transcriptionPlan.modelURL.lastPathComponent)",
      ]
    )

    do {
      let microphoneURL =
        audioURL == nil
        ? sourceAudioURL(
          fileName: session.audioArtifacts.micTranscriptFileName,
          sessionID: sessionID,
          defaultFileName: "mic-transcript.wav"
        )
        : nil
      let systemURL =
        audioURL == nil
        ? sourceAudioURL(
          fileName: session.audioArtifacts.systemFileName,
          sessionID: sessionID,
          defaultFileName: "system.wav"
        )
        : nil
      let priorEvidence = session.transcriptionEvidence
      let result = try await evidenceTranscriptionCoordinator.transcribe(
        .init(
          session: session,
          plan: transcriptionPlan,
          microphoneURL: microphoneURL,
          systemURL: systemURL,
          mixedURL: resolvedAudioURL,
          revision: (priorEvidence?.revision ?? 0) + 1,
          parentContentHash: priorEvidence?.contentHash,
          onProgress: { [weak self] update in
            guard let self else { return }
            await self.applyTranscriptionProgress(update, for: sessionID)
          }
        )
      )

      updatedSession.status = result.envelope.run.disposition == .ready ? .ready : .failed
      updatedSession.transcriptSegments = result.transcriptSegments
      updatedSession.transcriptionEvidence = result.summary
      updatedSession.title = inferredSessionTitle(for: updatedSession)
      upsertSession(updatedSession)
      if result.envelope.run.disposition != .ready {
        recorderErrorMessage =
          result.summary.issues.first
          ?? "The transcript was saved as non-ready because its evidence was incomplete."
      }
      endTranscription(for: sessionID)
      return
    } catch {
      updatedSession.status = .failed
      upsertSession(updatedSession)
      recorderErrorMessage = error.localizedDescription
    }

    endTranscription(for: sessionID, clearSnapshot: true)
  }

  private func applyTranscriptionProgress(
    _ update: LocalSessionTranscriptionProgress,
    for sessionID: LocalSession.ID
  ) {
    switch update.stage {
    case .decodingAudio:
      setProcessingSnapshot(
        for: sessionID,
        phase: .transcribing,
        title: "Preparing audio",
        detail: "Decoding the local WAV file before transcription starts.",
        progress: 0.05,
        logMessages: [
          "Decoding \(resolvedAudioFileName(for: sessionID))"
        ]
      )
    case .loadingModel:
      setProcessingSnapshot(
        for: sessionID,
        phase: .transcribing,
        title: "Loading model",
        detail: "Warming up the on-device speech model in memory.",
        progress: 0.12,
        logMessages: [
          "Loading on-device speech model"
        ]
      )
    case .analyzingSpeech(let chunks, let speechDuration, let skippedSilenceDuration):
      let speechMinutes = max(1, Int((speechDuration / 60).rounded(.up)))
      let skippedMinutes = Int((skippedSilenceDuration / 60).rounded())
      setProcessingSnapshot(
        for: sessionID,
        phase: .transcribing,
        title: "Speech mapped",
        detail:
          "Processing \(speechMinutes)m of speech in \(chunks) optimized chunk\(chunks == 1 ? "" : "s"); skipped about \(skippedMinutes)m of silence.",
        progress: 0.16,
        logMessages: [
          "Mapped \(chunks) optimized chunk\(chunks == 1 ? "" : "s")",
          "Speech: \(speechMinutes)m, silence skipped: \(skippedMinutes)m",
        ]
      )
    case .transcribing(let percent):
      let normalizedProgress = 0.12 + (Double(percent) / 100.0 * 0.72)
      setProcessingSnapshot(
        for: sessionID,
        phase: .transcribing,
        title: "Transcribing \(percent)%",
        detail: "Writing a local transcript as each speech chunk finishes.",
        progress: normalizedProgress
      )
    case .partialSegments(let partialSegments):
      let mappedSegments = transcriptSegments(from: partialSegments, sessionID: sessionID)
      guard !mappedSegments.isEmpty else { return }
      _ = mutateSession(id: sessionID) { currentSession in
        currentSession.status = .transcribing
        currentSession.transcriptSegments = mappedSegments
      }
      setProcessingSnapshot(
        for: sessionID,
        phase: .transcribing,
        title: "Draft transcript available",
        detail: "Showing the transcript already captured while the rest keeps processing.",
        progress: nil,
        logMessages: [
          "Draft transcript segments available: \(mappedSegments.count)"
        ]
      )
    case .extractingSegments:
      setProcessingSnapshot(
        for: sessionID,
        phase: .transcribing,
        title: "Finalizing transcript",
        detail: "Turning decoded speech into timestamped transcript segments.",
        progress: 0.86,
        logMessages: [
          "Extracting timestamped transcript segments"
        ]
      )
    }
  }

  private func beginImport(for sessionID: LocalSession.ID) {
    activeImportSessionIDs.insert(sessionID)
    syncActivityFlags()
  }

  private func endImport(for sessionID: LocalSession.ID, clearSnapshot: Bool = false) {
    activeImportSessionIDs.remove(sessionID)
    syncActivityFlags()
    if clearSnapshot {
      removeProcessingSnapshot(for: sessionID)
    } else {
      syncProcessingSummary(preferredSessionID: sessionID)
    }
  }

  private func beginTranscription(for sessionID: LocalSession.ID) {
    activeImportSessionIDs.remove(sessionID)
    activeTranscriptionSessionIDs.insert(sessionID)
    syncActivityFlags()
  }

  private func endTranscription(for sessionID: LocalSession.ID, clearSnapshot: Bool = false) {
    activeTranscriptionSessionIDs.remove(sessionID)
    syncActivityFlags()
    if clearSnapshot {
      removeProcessingSnapshot(for: sessionID)
    } else {
      syncProcessingSummary(preferredSessionID: sessionID)
    }
  }

  private func transcriptSegments(
    from result: LocalSessionTranscriptionResult,
    session: LocalSession
  ) -> [LocalSessionTranscriptSegment] {
    let sourceAttributor = sourceAttributor(for: session)

    if !result.segments.isEmpty {
      return result.segments.map { segment in
        LocalSessionTranscriptSegment(
          id: UUID(),
          speaker: sourceAttributor?.speaker(
            startTime: segment.startTime,
            endTime: segment.endTime
          ) ?? "Speaker 1",
          text: segment.text,
          timestamp: session.startedAt.addingTimeInterval(segment.startTime),
          endTimestamp: session.startedAt.addingTimeInterval(
            max(segment.endTime, segment.startTime))
        )
      }.removingRepeatedShortGlitches()
    }

    let transcriptText = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !transcriptText.isEmpty else {
      return []
    }

    return [
      LocalSessionTranscriptSegment(
        id: UUID(),
        speaker: "Speaker 1",
        text: transcriptText,
        timestamp: session.startedAt,
        endTimestamp: nil
      )
    ].removingRepeatedShortGlitches()
  }

  private func transcriptSegments(
    from partialSegments: [LocalSessionTranscriptionSegment],
    sessionID: LocalSession.ID
  ) -> [LocalSessionTranscriptSegment] {
    guard let session = sessions.first(where: { $0.id == sessionID }) else { return [] }
    return partialSegments.map { segment in
      LocalSessionTranscriptSegment(
        id: UUID(),
        speaker: "Speaker 1",
        text: segment.text,
        timestamp: session.startedAt.addingTimeInterval(segment.startTime),
        endTimestamp: session.startedAt.addingTimeInterval(max(segment.endTime, segment.startTime))
      )
    }.removingRepeatedShortGlitches()
  }

  private func sourceAttributor(for session: LocalSession) -> LocalSessionSourceAttributor? {
    guard
      let micURL = sourceAudioURL(
        fileName: session.audioArtifacts.micFileName,
        sessionID: session.id,
        defaultFileName: "mic.wav"
      ),
      let systemURL = sourceAudioURL(
        fileName: session.audioArtifacts.systemFileName,
        sessionID: session.id,
        defaultFileName: "system.wav"
      )
    else {
      return nil
    }

    return LocalSessionSourceAttributor(
      micURL: micURL,
      systemURL: systemURL,
      fileManager: fileManager
    )
  }

  private func sourceAudioURL(
    fileName: String?,
    sessionID: LocalSession.ID,
    defaultFileName: String
  ) -> URL? {
    let roots = [
      fileLayout.sessionDirectory(for: sessionID),
      fileLayout.legacySessionDirectory(for: sessionID),
    ]
    let orderedFileNames = [fileName, defaultFileName].compactMap { $0 }
    var seenFileNames: Set<String> = []
    let candidateFileNames = orderedFileNames.filter { seenFileNames.insert($0).inserted }

    for root in roots {
      for candidateFileName in candidateFileNames {
        let candidateURL = root.appendingPathComponent(candidateFileName, isDirectory: false)
        if fileManager.fileExists(atPath: candidateURL.path) {
          return candidateURL
        }
      }
    }

    return nil
  }

  private func warmUpTranscriptionModelIfNeeded(plan: LocalSessionTranscriptionPlan? = nil) async {
    let resolvedPlan = plan ?? fileLayout.resolvedTranscriptionPlan(fileManager: fileManager)
    guard fileManager.fileExists(atPath: resolvedPlan.modelURL.path) else { return }
    guard warmedTranscriptionModelPath != resolvedPlan.modelURL.path else { return }
    warmedTranscriptionModelPath = resolvedPlan.modelURL.path
    await transcriptionService.warmUp(modelURL: resolvedPlan.modelURL)
  }

  private static var defaultBaseDirectory: URL {
    LocalSessionStorageRoot.defaultBaseDirectory
  }

  private func normalizedImportedTitle(_ title: String?, sourceURL: URL) -> String {
    if let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
      return title
    }

    return sourceURL.deletingPathExtension().lastPathComponent.replacingOccurrences(
      of: "_", with: " ")
  }

  private func importedRecordingDate(for sourceURL: URL) -> Date {
    let values = try? sourceURL.resourceValues(forKeys: [
      .contentModificationDateKey, .creationDateKey,
    ])
    return values?.contentModificationDate ?? values?.creationDate ?? Date()
  }

  private func inferredSessionTitle(for session: LocalSession) -> String {
    let transcript = session.transcriptText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !transcript.isEmpty else { return session.title }

    let candidates =
      transcript
      .components(separatedBy: CharacterSet(charactersIn: ".!?\n"))
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { $0.count >= 12 }

    let source = candidates.first ?? transcript
    let compact =
      source
      .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .truncated(maxLength: 64)

    guard !compact.isEmpty else { return session.title }
    return compact
  }

  @discardableResult
  private func mutateSession(
    id sessionID: LocalSession.ID? = nil,
    _ mutate: (inout LocalSession) -> Void
  ) -> LocalSession? {
    let resolvedSessionID = sessionID ?? selectedSessionID
    guard let resolvedSessionID,
      let index = sessions.firstIndex(where: { $0.id == resolvedSessionID })
    else {
      return nil
    }

    var session = sessions[index]
    mutate(&session)
    upsertSession(session)
    return session
  }

  private func mergedSession(from incomingSession: LocalSession) -> LocalSession {
    guard let existingSession = sessions.first(where: { $0.id == incomingSession.id }) else {
      var anchoredSession = incomingSession
      anchoredSession.anchorTimelineContextToTranscriptSegments()
      return anchoredSession
    }

    var mergedSession = incomingSession
    mergedSession.title =
      incomingSession.title.isEmpty ? existingSession.title : incomingSession.title
    mergedSession.transcriptSegments =
      incomingSession.transcriptSegments.isEmpty
      ? existingSession.transcriptSegments
      : incomingSession.transcriptSegments
    mergedSession.recap =
      incomingSession.recap == .empty ? existingSession.recap : incomingSession.recap
    mergedSession.attachments = mergeAttachments(
      existingSession.attachments, incomingSession.attachments)
    mergedSession.captureArtifacts = mergeCaptureArtifacts(
      existingSession.captureArtifacts,
      incomingSession.captureArtifacts
    )
    mergedSession.audioArtifacts = LocalSessionAudioArtifacts(
      micFileName: incomingSession.audioArtifacts.micFileName
        ?? existingSession.audioArtifacts.micFileName,
      micTranscriptFileName: incomingSession.audioArtifacts.micTranscriptFileName
        ?? existingSession.audioArtifacts.micTranscriptFileName,
      systemFileName: incomingSession.audioArtifacts.systemFileName
        ?? existingSession.audioArtifacts.systemFileName,
      mixedFileName: incomingSession.audioArtifacts.mixedFileName
        ?? existingSession.audioArtifacts.mixedFileName
    )
    mergedSession.contentClassification =
      incomingSession.contentClassification ?? existingSession.contentClassification
    mergedSession.transcriptionEvidence =
      incomingSession.transcriptionEvidence ?? existingSession.transcriptionEvidence
    mergedSession.documentChat =
      incomingSession.documentChat == .empty
      ? existingSession.documentChat : incomingSession.documentChat
    mergedSession.anchorTimelineContextToTranscriptSegments()

    return mergedSession
  }

  private func mergeAttachments(
    _ existing: [LocalSessionAttachment],
    _ incoming: [LocalSessionAttachment]
  ) -> [LocalSessionAttachment] {
    guard !existing.isEmpty else { return incoming }
    guard !incoming.isEmpty else { return existing }

    var attachmentsByID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
    for attachment in incoming {
      attachmentsByID[attachment.id] = attachment
    }

    return existing.compactMap { attachmentsByID[$0.id] }
      + incoming.filter { attachment in
        !existing.contains(where: { $0.id == attachment.id })
      }
  }

  private func mergeCaptureArtifacts(
    _ existing: [LocalSessionCaptureArtifact],
    _ incoming: [LocalSessionCaptureArtifact]
  ) -> [LocalSessionCaptureArtifact] {
    guard !existing.isEmpty else { return incoming }
    guard !incoming.isEmpty else { return existing }

    var artifactsByID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
    for artifact in incoming {
      artifactsByID[artifact.id] = artifact
    }

    return existing.compactMap { artifactsByID[$0.id] }
      + incoming.filter { artifact in
        !existing.contains(where: { $0.id == artifact.id })
      }
  }

  private func normalizedStoredSession(_ session: LocalSession) -> LocalSession {
    var normalizedSession = session

    switch normalizedSession.status {
    case .recording, .transcribing:
      normalizedSession.status = .failed
    case .ready, .failed:
      break
    }

    if normalizedSession.documentChat.errorMessage == "Local model is unavailable." {
      normalizedSession.documentChat.status = .idle
      normalizedSession.documentChat.errorMessage = nil
      normalizedSession.documentChat.updatedAt = Date()
    }
    let cleanedMessages = normalizedSession.documentChat.messages.filter {
      !$0.isStaleLocalModelFailureMessage
    }
    if cleanedMessages.count != normalizedSession.documentChat.messages.count {
      normalizedSession.documentChat.messages = cleanedMessages
      normalizedSession.documentChat.status = .idle
      normalizedSession.documentChat.errorMessage = nil
      normalizedSession.documentChat.updatedAt = Date()
    }
    if normalizedSession.documentChat.pendingProposal?.isStaleAppendInstructionEcho == true {
      normalizedSession.documentChat.pendingProposal = nil
      normalizedSession.documentChat.messages.removeAll {
        $0.isStaleAppendInstructionPreviewMessage
      }
      normalizedSession.documentChat.status = .idle
      normalizedSession.documentChat.errorMessage = nil
      normalizedSession.documentChat.updatedAt = Date()
    }
    if normalizedSession.recap.removeStaleAppliedAppendInstructionSections() {
      normalizedSession.documentChat.messages.removeAll {
        $0.isStaleAppendInstructionPreviewMessage
      }
      normalizedSession.documentChat.status = .idle
      normalizedSession.documentChat.errorMessage = nil
      normalizedSession.documentChat.updatedAt = Date()
    }
    if let migratedTitle = normalizedSession.recap.removeStaleTitleUpdateNote(),
      normalizedSession.title != migratedTitle
    {
      normalizedSession.title = migratedTitle
    }
    if normalizedSession.recap.normalizeStaleHebrewVideoTemplateTitles() {
      normalizedSession.recap.generatedAt = normalizedSession.recap.generatedAt ?? Date()
    }
    normalizedSession.transcriptSegments =
      normalizedSession.transcriptSegments.removingRepeatedShortGlitches()
    if normalizedSession.recap.isStaleHebrewTranscriptCopyFallback(
      forTranscript: normalizedSession.transcriptText
    )
      || normalizedSession.recap.isGenericHebrewTranscriptPlaceholderFallback(
        forTranscript: normalizedSession.transcriptText
      ) || normalizedSession.recap.isSchemaPlaceholderFallback()
    {
      normalizedSession.recap = .empty
    }
    if normalizedSession.transcriptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      normalizedSession.recap.removeStaleGenericFallback()
    {
      normalizedSession.recap = .empty
    }
    if normalizedSession.recap.isUnsupportedWebsiteThemeFallback(
      forTranscript: normalizedSession.transcriptText)
    {
      normalizedSession.recap = .empty
    }
    if normalizedSession.recap.isStaleHebrewMeetingBoilerplate(
      forTranscript: normalizedSession.transcriptText)
    {
      normalizedSession.recap = .empty
      normalizedSession.documentChat.pendingProposal = nil
      normalizedSession.documentChat.status = .idle
      normalizedSession.documentChat.errorMessage = nil
      normalizedSession.documentChat.updatedAt = Date()
    }
    if LocalSessionRecapMarkdownDocument.preferredLanguage(for: normalizedSession) == .hebrew,
      normalizedSession.documentChat.localizeSavedEnglishStatusMessagesForHebrew()
    {
      normalizedSession.documentChat.updatedAt = Date()
    }

    return normalizedSession
  }

  private func refreshRetranscriptionAvailabilityCache(for sessions: [LocalSession]) {
    let availableSessionIDs = Set(
      sessions.compactMap { session in
        resolvedAudioURL(for: session) == nil ? nil : session.id
      }
    )

    if availableSessionIDs != retranscribableSessionIDs {
      retranscribableSessionIDs = availableSessionIDs
    }
  }

  private func resolvedAudioURL(for session: LocalSession) -> URL? {
    fileLayout.existingAudioURL(
      for: session.id, artifacts: session.audioArtifacts, fileManager: fileManager)
  }

  private func resolvedAudioFileName(for sessionID: LocalSession.ID) -> String {
    guard let session = sessions.first(where: { $0.id == sessionID }) else {
      return "mixed.wav"
    }

    return resolvedAudioURL(for: session)?.lastPathComponent
      ?? session.audioArtifacts.mixedFileName
      ?? session.audioArtifacts.micFileName
      ?? session.audioArtifacts.systemFileName
      ?? "mixed.wav"
  }

  private func setProcessingSnapshot(
    for sessionID: LocalSession.ID,
    phase: LocalSessionProcessingPhase,
    title: String,
    detail: String,
    progress: Double?,
    logMessages: [String] = []
  ) {
    let now = Date()
    let existingLogEntries = processingSnapshot(for: sessionID)?.logEntries ?? []
    let newLogEntries = logMessages.map {
      LocalSessionProcessingLogEntry(timestamp: now, message: $0)
    }
    let mergedLogEntries = Array((existingLogEntries + newLogEntries).suffix(12))
    for entry in newLogEntries {
      localMeetingLog("[\(sessionID.uuidString.prefix(8))] \(entry.message)")
    }
    let snapshot = LocalSessionProcessingSnapshot(
      id: sessionID,
      phase: phase,
      title: title,
      detail: detail,
      progress: progress,
      logEntries: mergedLogEntries,
      updatedAt: now
    )

    if let existingIndex = processingSnapshots.firstIndex(where: { $0.id == sessionID }) {
      processingSnapshots[existingIndex] = snapshot
    } else {
      processingSnapshots.append(snapshot)
    }

    syncProcessingSummary(preferredSessionID: sessionID)
  }

  private func removeProcessingSnapshot(for sessionID: LocalSession.ID) {
    processingSnapshots.removeAll { $0.id == sessionID }
    syncProcessingSummary()
  }

  private func syncActivityFlags() {
    isTranscribing =
      !activeImportSessionIDs.isEmpty || !activeTranscriptionSessionIDs.isEmpty
  }

  private func syncProcessingSummary(preferredSessionID: LocalSession.ID? = nil) {
    let snapshot =
      preferredSessionID.flatMap { processingSnapshot(for: $0) }
      ?? selectedSessionID.flatMap { processingSnapshot(for: $0) }
      ?? processingQueue.first

    processingStatusTitle = snapshot?.title
    processingStatusDetail = snapshot?.detail
    processingProgress = snapshot?.progress
  }

  private func processingSnapshotSort(
    lhs: LocalSessionProcessingSnapshot,
    rhs: LocalSessionProcessingSnapshot
  ) -> Bool {
    if lhs.updatedAt != rhs.updatedAt {
      return lhs.updatedAt > rhs.updatedAt
    }

    if lhs.phase.rank != rhs.phase.rank {
      return lhs.phase.rank < rhs.phase.rank
    }

    return lhs.id.uuidString < rhs.id.uuidString
  }
}

private struct LocalSessionSourceAttributor {
  private let micWave: LocalSessionPCM16Wave
  private let systemWave: LocalSessionPCM16Wave
  private let dominanceRatio = 1.35
  private let silenceFloor = 40.0

  init?(micURL: URL, systemURL: URL, fileManager: FileManager) {
    guard fileManager.fileExists(atPath: micURL.path),
      fileManager.fileExists(atPath: systemURL.path),
      let micWave = try? LocalSessionPCM16Wave(url: micURL),
      let systemWave = try? LocalSessionPCM16Wave(url: systemURL)
    else {
      return nil
    }

    self.micWave = micWave
    self.systemWave = systemWave
  }

  func speaker(startTime: TimeInterval, endTime: TimeInterval) -> String {
    let resolvedEndTime = max(endTime, startTime + 0.1)
    let micEnergy = micWave.averageAbsoluteAmplitude(startTime: startTime, endTime: resolvedEndTime)
    let systemEnergy = systemWave.averageAbsoluteAmplitude(
      startTime: startTime,
      endTime: resolvedEndTime
    )

    guard max(micEnergy, systemEnergy) > silenceFloor else {
      return "Speaker 1"
    }

    if micEnergy >= systemEnergy * dominanceRatio {
      return "You"
    }

    if systemEnergy >= micEnergy * dominanceRatio {
      return "Remote speaker"
    }

    return "Speaker 1"
  }
}

private struct LocalSessionPCM16Wave {
  private let sampleRate: Int
  private let channelCount: Int
  private let pcmData: Data

  init(url: URL) throws {
    let data = try Data(contentsOf: url)
    guard data.count >= 44,
      String(data: data.prefix(4), encoding: .ascii) == "RIFF",
      String(data: data[8..<12], encoding: .ascii) == "WAVE"
    else {
      throw LocalSessionPCM16WaveError.unsupportedFormat
    }

    var offset = 12
    var audioFormat: UInt16?
    var channelCount: UInt16?
    var sampleRate: UInt32?
    var bitsPerSample: UInt16?
    var pcmData: Data?

    while offset + 8 <= data.count {
      let chunkID = String(data: data[offset..<(offset + 4)], encoding: .ascii) ?? ""
      let chunkSize = Int(Self.readUInt32LE(from: data, at: offset + 4))
      let chunkStart = offset + 8
      let chunkEnd = chunkStart + chunkSize

      guard chunkEnd <= data.count else {
        throw LocalSessionPCM16WaveError.unsupportedFormat
      }

      switch chunkID {
      case "fmt ":
        audioFormat = Self.readUInt16LE(from: data, at: chunkStart)
        channelCount = Self.readUInt16LE(from: data, at: chunkStart + 2)
        sampleRate = Self.readUInt32LE(from: data, at: chunkStart + 4)
        bitsPerSample = Self.readUInt16LE(from: data, at: chunkStart + 14)
      case "data":
        pcmData = Data(data[chunkStart..<chunkEnd])
      default:
        break
      }

      offset = chunkEnd + (chunkSize % 2)
    }

    guard audioFormat == 1,
      let channelCount,
      channelCount > 0,
      let sampleRate,
      sampleRate > 0,
      bitsPerSample == 16,
      let pcmData
    else {
      throw LocalSessionPCM16WaveError.unsupportedFormat
    }

    self.sampleRate = Int(sampleRate)
    self.channelCount = Int(channelCount)
    self.pcmData = pcmData
  }

  func averageAbsoluteAmplitude(startTime: TimeInterval, endTime: TimeInterval) -> Double {
    let bytesPerFrame = channelCount * MemoryLayout<Int16>.size
    let frameCount = pcmData.count / bytesPerFrame
    guard frameCount > 0 else { return 0 }

    let startFrame = max(
      0,
      min(frameCount, Int((startTime * Double(sampleRate)).rounded(.down)))
    )
    let endFrame = max(
      startFrame,
      min(frameCount, Int((endTime * Double(sampleRate)).rounded(.up)))
    )
    guard endFrame > startFrame else { return 0 }

    return pcmData.withUnsafeBytes { rawBuffer in
      let bytes = rawBuffer.bindMemory(to: UInt8.self)
      var total = 0.0
      var count = 0

      for frame in startFrame..<endFrame {
        for channel in 0..<channelCount {
          let sampleOffset = (frame * channelCount + channel) * MemoryLayout<Int16>.size
          guard sampleOffset + 1 < bytes.count else { continue }
          let rawValue = UInt16(bytes[sampleOffset]) | (UInt16(bytes[sampleOffset + 1]) << 8)
          let sample = Int16(bitPattern: rawValue)
          total += abs(Double(sample))
          count += 1
        }
      }

      guard count > 0 else { return 0 }
      return total / Double(count)
    }
  }

  private static func readUInt16LE(from data: Data, at offset: Int) -> UInt16 {
    data.withUnsafeBytes { rawBuffer in
      let bytes = rawBuffer.bindMemory(to: UInt8.self)
      return UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }
  }

  private static func readUInt32LE(from data: Data, at offset: Int) -> UInt32 {
    data.withUnsafeBytes { rawBuffer in
      let bytes = rawBuffer.bindMemory(to: UInt8.self)
      return UInt32(bytes[offset])
        | (UInt32(bytes[offset + 1]) << 8)
        | (UInt32(bytes[offset + 2]) << 16)
        | (UInt32(bytes[offset + 3]) << 24)
    }
  }
}

private enum LocalSessionPCM16WaveError: Error {
  case unsupportedFormat
}

extension Array where Element == LocalSessionTranscriptSegment {
  fileprivate func removingRepeatedShortGlitches() -> [LocalSessionTranscriptSegment] {
    var cleaned: [LocalSessionTranscriptSegment] = []
    var activeKey: String?
    var activeStart: Date?
    var activeCount = 0

    for segment in self {
      let key = segment.text.shortTranscriptGlitchKey
      let isSameCluster =
        key != nil
        && key == activeKey
        && activeStart.map { segment.timestamp.timeIntervalSince($0) <= 12 } == true

      if isSameCluster {
        activeCount += 1
      } else {
        activeKey = key
        activeStart = key == nil ? nil : segment.timestamp
        activeCount = key == nil ? 0 : 1
      }

      if key != nil, activeCount > 3 {
        continue
      }

      cleaned.append(segment)
    }

    return cleaned
  }
}

extension String {
  fileprivate var shortTranscriptGlitchKey: String? {
    let normalized = trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: "\u{200f}", with: "")
      .replacingOccurrences(of: "\u{200e}", with: "")
      .replacingOccurrences(of: "\n", with: " ")
      .lowercased()
    let collapsed =
      normalized
      .split(whereSeparator: { $0.isWhitespace })
      .joined(separator: " ")
    guard !collapsed.isEmpty else { return nil }
    guard collapsed.count <= 18 else { return nil }
    let lettersAndDigits = collapsed.unicodeScalars.filter {
      CharacterSet.letters.union(.decimalDigits).contains($0)
    }
    guard lettersAndDigits.count <= 12 else { return nil }
    return String(String.UnicodeScalarView(lettersAndDigits))
  }
}

extension LocalSessionDocumentEditProposal {
  fileprivate var isStaleAppendInstructionEcho: Bool {
    let generatedText =
      [
        sessionTitle,
        recapPatch?.overview,
      ].compactMap { $0 }
      + (recapPatch?.sections ?? []).flatMap { section in
        [section.title, section.summary] + section.bullets
      }

    return generatedText.contains { $0.looksLikeAppendInstructionEcho }
  }
}

extension LocalSessionDocumentChatMessage {
  fileprivate var isStaleLocalModelFailureMessage: Bool {
    guard role == .assistant else { return false }

    let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return normalized.contains("could not produce a clean document edit")
      || normalized.contains("couldn't produce a clean document edit")
      || normalized.contains("the local model couldn't produce a clean document edit")
      || normalized.contains("could not run the local model")
      || normalized.contains("לא הצלחתי להפעיל את המודל המקומי")
      || normalized.contains("המסמך עוסק בועכשיו אני למשל לוקח סרטון")
      || (normalized.contains("המסמך עוסק ב")
        && normalized.contains("ההיסטוריה שראיתי ביוטיוב"))
  }

  fileprivate var isStaleAppendInstructionPreviewMessage: Bool {
    guard role == .assistant else { return false }

    let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return normalized.contains("preview ready:")
      && (normalized.contains("הוספתי פסקת המשך בסוף המסמך")
        || normalized.contains("added a closing paragraph"))
  }
}

extension LocalSessionRecap {
  fileprivate mutating func removeStaleAppliedAppendInstructionSections() -> Bool {
    let countBefore = sections.count
    sections.removeAll { $0.looksLikeAppliedAppendInstructionEcho }
    return sections.count != countBefore
  }

  fileprivate mutating func removeStaleTitleUpdateNote() -> String? {
    guard
      let index = sections.firstIndex(where: { section in
        section.kind == .notes && section.title.contains("כותרת")
      })
    else {
      return nil
    }

    let title = sections[index].title.cleanedTitleUpdateRequest
    guard let title else { return nil }

    sections.remove(at: index)
    return title
  }

  fileprivate mutating func normalizeStaleHebrewVideoTemplateTitles() -> Bool {
    let corpus =
      ([overview] + sections.flatMap { [$0.title, $0.summary] + $0.bullets })
      .joined(separator: " ")
      .lowercased()
    guard corpus.containsHebrewScript else { return false }
    guard
      ["סרטון", "יוטיוב", "לייב", "ערוץ", "מורה מבוכים"].contains(where: {
        corpus.contains($0)
      })
    else {
      return false
    }

    var changed = false
    for index in sections.indices {
      let normalizedTitle = sections[index].title.trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
      let replacementTitle: String?
      let replacementSummary: String?
      switch sections[index].kind {
      case .overview:
        replacementTitle = normalizedTitle == "overview" ? "על מה המסמך" : nil
        replacementSummary = nil
      case .keyPoints:
        replacementTitle =
          ["commentary highlights", "key details", "key points", "נקודות מרכזיות"].contains(
            normalizedTitle)
          ? "מה מופיע בסרטון" : nil
        replacementSummary =
          sections[index].summary.containsHebrewScript
          ? nil : "הרגעים והפרטים המרכזיים מתוך הסרטון."
      case .decisions:
        replacementTitle =
          ["observed conclusions", "explicit conclusions", "decisions", "החלטות"].contains(
            normalizedTitle)
          ? "מה אפשר להסיק" : nil
        replacementSummary =
          sections[index].summary.containsHebrewScript
          ? nil : "מסקנות שאפשר לזהות מתוך התוכן שנקלט."
      case .actionItem:
        replacementTitle =
          [
            "follow-up from commentary", "tasks or follow-up", "action items",
            "משימות לביצוע", "משימות המשך",
          ].contains(normalizedTitle)
          ? "מה כדאי לעשות עם זה" : nil
        replacementSummary =
          sections[index].summary.containsHebrewScript
          ? nil : "פעולות המשך אפשריות לפי מטרת המסמך."
      case .openQuestions:
        replacementTitle =
          ["open questions", "שאלות פתוחות"].contains(normalizedTitle)
          ? "מה עדיין לא ברור" : nil
        replacementSummary =
          sections[index].summary.containsHebrewScript
          ? nil : "נקודות שעדיין צריך להבהיר לגבי השימוש במסמך."
      case .nextSteps:
        replacementTitle =
          ["professional recommendation", "next steps", "המלצה מקצועית"].contains(normalizedTitle)
          ? "המשך מומלץ" : nil
        replacementSummary =
          sections[index].summary.containsHebrewScript
          ? nil : "דרך פעולה מומלצת לאחר קריאת המסמך."
      case .notes:
        replacementTitle = nil
        replacementSummary = nil
      }

      if let replacementTitle {
        sections[index].title = replacementTitle
        changed = true
      }
      if let replacementSummary {
        sections[index].summary = replacementSummary
        changed = true
      }
    }

    let countBeforePruning = sections.count
    sections.removeAll { section in
      guard [.decisions, .actionItem, .openQuestions, .nextSteps].contains(section.kind) else {
        return false
      }

      let sectionText = ([section.title, section.summary] + section.bullets)
        .joined(separator: " ")
        .lowercased()
      let staleBoilerplate = [
        "לא זוהתה החלטה תפעולית",
        "אם מטרת המסמך היא",
        "האם צריך לסכם את תוכן הסרטון",
        "להשתמש בתקציר כנושא המסמך",
        "no final decision was explicit",
        "follow-up work created by the observed video",
      ]
      return staleBoilerplate.contains { sectionText.contains($0) }
    }
    if sections.count != countBeforePruning {
      changed = true
    }

    return changed
  }

  fileprivate mutating func removeStaleGenericFallback() -> Bool {
    let text =
      ([overview] + sections.flatMap { [$0.title, $0.summary] + $0.bullets })
      .joined(separator: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
    guard !text.isEmpty else { return false }

    let stalePhrases = [
      "source material captured the main areas that need follow-up",
      "video commentary captured the main areas that need follow-up",
      "reviewed the transcript and captured the main discussion areas",
      "generated brief is based on the meeting content rather than a verbatim transcript",
      "generated brief is based on the source content rather than raw conversation flow",
      "brief focuses on the work, context, and follow-up supported by the source material",
      "a video commentary on a project or product",
      "important moments and observations from the commentary",
      "follow-up work created by the observed video or screen context",
      "no final decision was explicit enough to treat as closed",
    ]

    guard stalePhrases.contains(where: { text.contains($0) }) else { return false }
    self = .empty
    return true
  }

  fileprivate func isUnsupportedWebsiteThemeFallback(forTranscript transcript: String) -> Bool {
    let recapText =
      ([overview] + sections.flatMap { [$0.title, $0.summary] + $0.bullets })
      .joined(separator: " ")
      .lowercased()
    guard !recapText.isEmpty else { return false }
    let staleWebsiteThemePhrases = [
      "site performance and scrolling behavior",
      "clearer calls to action",
      "interview simulation area",
      "hr and tech paths",
      "lighter visual",
      "section-jump behavior",
    ]
    guard staleWebsiteThemePhrases.contains(where: { recapText.contains($0) }) else {
      return false
    }

    let transcriptText = transcript.lowercased()
    guard transcriptText.containsHebrewScript else { return false }
    let hasStrongWebsiteContext = [
      "גלילה", "לגלול", "scroll", "section", "עמוד", "page", "landing", "ux", "webflow",
      "באתר", "האתר", "קריאה לפעולה", "cta",
    ].contains { transcriptText.contains($0) }
    if !hasStrongWebsiteContext,
      staleWebsiteThemePhrases.contains(where: { recapText.contains($0) })
    {
      return true
    }
    let claimGroups: [(recapPatterns: [String], sourcePatterns: [String])] = [
      (
        ["scrolling", "hard to scroll", "section-jump", "section navigation"],
        ["גלילה", "scroll", "ניווט באתר", "section"]
      ),
      (
        ["calls to action", "call to action", "cta", "user promise", "explicit next step"],
        ["קריאה לפעולה", "cta", "להירשם", "הרשמה", "next step"]
      ),
      (
        ["interview simulation", "hr and tech", "hr path", "tech path", "coming-soon"],
        ["סימולציה", "סימולציות", "ראיון", "ראיונות", "hr", "tech"]
      ),
      (
        [
          "visual tone", "visual direction", "lighter visual", "lighter background",
          "brand direction",
        ],
        ["עיצוב", "ויזואל", "צבע", "צבעוניות", "רקע", "design", "visual", "brand"]
      ),
    ]
    let unsupportedClaimGroupCount = claimGroups.filter { group in
      group.recapPatterns.contains { recapText.contains($0) }
        && !group.sourcePatterns.contains { transcriptText.contains($0) }
    }.count
    return unsupportedClaimGroupCount >= 2
  }

  fileprivate func isStaleHebrewTranscriptCopyFallback(forTranscript transcript: String) -> Bool {
    guard transcript.containsHebrewScript else { return false }

    let recapText =
      ([overview] + sections.flatMap { [$0.title, $0.summary] + $0.bullets })
      .joined(separator: "\n")
    let normalizedRecap =
      recapText
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
    guard normalizedRecap.contains("המסמך עוסק ב") else { return false }
    let staleSectionSignals = [
      "נקודות חשובות", "מה הובן מהמקור", "המשך טיפול", "שאלות פתוחות", "המשך מומלץ",
    ]
    guard staleSectionSignals.contains(where: { normalizedRecap.contains($0.lowercased()) }) else {
      return false
    }

    let transcriptSentences =
      transcript
      .components(separatedBy: .newlines)
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { $0.count >= 12 }
    guard !transcriptSentences.isEmpty else { return false }

    let rawSentenceMatches = transcriptSentences.prefix(6).filter { sentence in
      normalizedRecap.contains(sentence.lowercased())
    }.count
    return rawSentenceMatches >= 2
  }

  fileprivate func isGenericHebrewTranscriptPlaceholderFallback(forTranscript transcript: String)
    -> Bool
  {
    guard transcript.containsHebrewScript else { return false }

    let recapText =
      ([overview] + sections.flatMap { [$0.title, $0.summary] + $0.bullets })
      .joined(separator: "\n")
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
    guard !recapText.isEmpty else { return false }

    let overviewSignals = [
      "המסמך מבוסס על תמלול בעברית",
      "המסמך לא אמור לשחזר את המשפטים עצמם",
      "לזקק מתוכו נושאים, כוונות ופעולות המשך",
    ]
    guard overviewSignals.filter({ recapText.contains($0.lowercased()) }).count >= 2 else {
      return false
    }

    let placeholderSectionSignals = [
      "על מה המסמך",
      "נקודות חשובות",
      "מה הובן מהמקור",
      "המשך טיפול",
      "שאלות פתוחות",
      "המשך מומלץ",
      "לבנות מהמקור מסמך קצר, נקי ומעשי שמדבר על התוכן ולא מעתיק את התמלול עצמו",
    ]
    let matchedSignals = placeholderSectionSignals.filter { recapText.contains($0.lowercased()) }
    return matchedSignals.count >= 4
  }

  fileprivate func isSchemaPlaceholderFallback() -> Bool {
    let recapText =
      ([overview] + sections.flatMap { [$0.title, $0.summary] + $0.bullets })
      .joined(separator: "\n")
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
    guard !recapText.isEmpty else { return false }

    let placeholderSignals = [
      "concise paragraph with purpose and current state",
      "owner/person/team",
      "urgent fixes and next-iteration tasks",
      "short professional recommendation",
      "professional recommendation",
    ]
    return placeholderSignals.filter { recapText.contains($0) }.count >= 3
  }

  fileprivate func isStaleHebrewMeetingBoilerplate(forTranscript transcript: String) -> Bool {
    guard transcript.containsHebrewScript else { return false }

    let recapText =
      ([overview] + sections.flatMap { [$0.title, $0.summary] + $0.bullets })
      .joined(separator: "\n")
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
    guard !recapText.isEmpty else { return false }

    let staleSignals = [
      "עלה צורך לחדד",
      "פעולות המשך שנובעות מהמסמך",
      "פעולות המשך אפשריות לפי מטרת המסמך",
      "שאלות שנותרו לבדיקה",
      "נקודות שעדיין צריך להבהיר לגבי השימוש במסמך",
      "המשך פעולה מומלץ",
      "המשך מומלץ",
      "להפוך את נושאי הפגישה לרשימת החלטות ומשימות",
    ]
    return staleSignals.contains { recapText.contains($0.lowercased()) }
  }
}

extension LocalSessionRecapSection {
  fileprivate var looksLikeAppliedAppendInstructionEcho: Bool {
    guard kind == .notes else { return false }
    guard !title.contains("כותרת") else { return false }

    let normalized = ([title, summary] + bullets)
      .joined(separator: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
    guard !normalized.isEmpty else { return false }

    let appendTerms = [
      "תוסיף", "להוסיף", "הוסף", "תרשום", "תכתוב", "כתוב",
      "add", "append", "write this", "write it",
    ]
    let documentTerms = [
      "מסמך", "המסמך", "תמלול", "התמלול", "בסוף", "סיפור",
      "document", "transcript", "end of the document", "story",
    ]

    return appendTerms.contains { normalized.contains($0) }
      && documentTerms.contains { normalized.contains($0) }
  }
}

extension LocalSessionDocumentChat {
  fileprivate mutating func localizeSavedEnglishStatusMessagesForHebrew() -> Bool {
    var changed = false
    for index in messages.indices {
      let text = messages[index].text.trimmingCharacters(in: .whitespacesAndNewlines)
      if text.hasPrefix("Preview ready:") {
        let suffix = text.dropFirst("Preview ready:".count).trimmingCharacters(
          in: .whitespacesAndNewlines)
        messages[index].text = suffix.isEmpty ? "טיוטה מוכנה." : "טיוטה מוכנה: \(suffix)"
        changed = true
      } else if text == "No document edit was needed." {
        messages[index].text = "לא נדרש שינוי במסמך."
        changed = true
      } else if text == "Applied the previewed document changes." {
        messages[index].text = "החלתי את שינויי המסמך מהטיוטה."
        changed = true
      } else if text == "Undid the last document edit." {
        messages[index].text = "ביטלתי את שינוי המסמך האחרון."
        changed = true
      }
    }

    return changed
  }
}

extension String {
  fileprivate func truncated(maxLength: Int) -> String {
    guard count > maxLength else { return self }
    let endIndex = index(startIndex, offsetBy: max(0, maxLength - 1))
    return String(self[..<endIndex]).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
  }

  fileprivate var containsHebrewScript: Bool {
    unicodeScalars.contains { scalar in
      (0x0590...0x05FF).contains(Int(scalar.value))
    }
  }

  fileprivate var looksLikeAppendInstructionEcho: Bool {
    let normalized = trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !normalized.isEmpty else { return false }

    return [
      "תוסיף", "הוסף", "להוסיף", "תרשום", "תכתוב", "כתוב",
      "add", "append", "write this", "write it",
    ].contains { normalized.contains($0) }
  }

  fileprivate var cleanedTitleUpdateRequest: String? {
    var title = trimmingCharacters(in: .whitespacesAndNewlines)
    let removablePhrases = [
      "תעדכן את הכותרת ל", "תעדכן את הכותרת", "עדכן את הכותרת ל",
      "עדכן את הכותרת", "שנה את הכותרת ל", "שנה את הכותרת", "כותרת:",
      "כותרת -", "כותרת",
    ]
    for phrase in removablePhrases {
      title = title.replacingOccurrences(of: phrase, with: "", options: [.caseInsensitive])
    }
    title = title.trimmingCharacters(
      in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
    return title.isEmpty ? nil : title
  }
}

typealias LocalMeetingAppModel = LocalSessionAppModel
