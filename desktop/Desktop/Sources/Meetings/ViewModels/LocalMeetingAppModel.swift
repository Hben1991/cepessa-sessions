import Combine
import Foundation
import SwiftUI

@MainActor
final class LocalSessionAppModel: ObservableObject {
  @Published var sessions: [LocalSession] {
    didSet {
      reconcileSelection()
    }
  }
  @Published var selectedSessionID: LocalSession.ID?
  @Published private(set) var isRecording = false
  @Published private(set) var isTranscribing = false
  @Published private(set) var isGeneratingRecap = false
  @Published private(set) var isMicrophoneCaptureActive = false
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

  private let fileLayout: LocalSessionFileLayout
  private let store: LocalSessionStore?
  private let recorder: LocalMeetingRecorder
  private let transcriptionService: any LocalSessionTranscribing
  private let recapGenerator: any LocalSessionRecapGenerating
  private let documentChatService: (any LocalSessionDocumentChatProviding)?
  private let audioImportService: any LocalSessionAudioImporting
  private let fileManager: FileManager
  private var activeImportSessionIDs: Set<LocalSession.ID> = []
  private var activeTranscriptionSessionIDs: Set<LocalSession.ID> = []
  private var activeRecapSessionIDs: Set<LocalSession.ID> = []
  private var warmedTranscriptionModelPath: String?
  private var cancellables: Set<AnyCancellable> = []

  init(
    sessions: [LocalSession] = [],
    store: LocalSessionStore? = nil,
    fileLayout: LocalSessionFileLayout? = nil,
    transcriptionService: any LocalSessionTranscribing = LocalMeetingTranscriptionService(),
    recapGenerator: any LocalSessionRecapGenerating = LocalSessionRecapGenerator(),
    documentChatService: (any LocalSessionDocumentChatProviding)? = LocalSessionDocumentChatClient(),
    audioImportService: any LocalSessionAudioImporting = LocalSessionAudioImportService(),
    fileManager: FileManager = .default
  ) {
    let resolvedFileLayout =
      fileLayout ?? LocalSessionFileLayout(baseDirectory: Self.defaultBaseDirectory)
    let resolvedStore = store ?? LocalSessionStore(fileLayout: resolvedFileLayout)
    self.sessions = sessions
    self.fileLayout = resolvedFileLayout
    self.store = resolvedStore
    self.recorder = LocalMeetingRecorder(fileLayout: resolvedFileLayout)
    self.transcriptionService = transcriptionService
    self.recapGenerator = recapGenerator
    self.documentChatService = documentChatService
    self.audioImportService = audioImportService
    self.fileManager = fileManager
    self.selectedSessionID = nil
    bindRecorder()
    loadStoredSessions()
    Task { [weak self] in
      await self?.warmUpTranscriptionModelIfNeeded()
    }
  }

  var selectedSession: LocalSession? {
    guard let selectedSessionID else { return nil }
    return sessions.first { $0.id == selectedSessionID }
  }

  var isProcessingSession: Bool {
    isTranscribing || isGeneratingRecap
  }

  var processingQueue: [LocalSessionProcessingSnapshot] {
    processingSnapshots.sorted(by: processingSnapshotSort)
  }

  func processingSnapshot(for sessionID: LocalSession.ID) -> LocalSessionProcessingSnapshot? {
    processingSnapshots.first { $0.id == sessionID }
  }

  func isGeneratingRecap(for sessionID: LocalSession.ID) -> Bool {
    activeRecapSessionIDs.contains(sessionID)
  }

  func canRetranscribe(_ session: LocalSession) -> Bool {
    guard processingSnapshot(for: session.id) == nil else { return false }
    return resolvedAudioURL(for: session) != nil
  }

  func loadEmptySessions() {
    sessions = []
    selectedSessionID = nil
  }

  func loadSampleSessions() {
    sessions = LocalSession.sampleSessions.sorted { $0.startedAt > $1.startedAt }
    selectedSessionID = sessions.first?.id
  }

  func loadStoredSessions() {
    guard let store else { return }

    let storedSessions = store.loadSessions()
    let normalizedSessions = storedSessions.map(normalizedStoredSession(_:))
    sessions = normalizedSessions

    for (storedSession, normalizedSession) in zip(storedSessions, normalizedSessions)
    where storedSession != normalizedSession {
      do {
        try store.save(normalizedSession)
      } catch {
        recorderErrorMessage =
          "Failed to recover an interrupted session. \(error.localizedDescription)"
      }
    }

    if selectedSessionID == nil {
      selectedSessionID = sessions.first?.id
    }
  }

  @discardableResult
  func upsertSession(_ session: LocalSession) -> LocalSession {
    let mergedSession = mergedSession(from: session)

    if let existingIndex = sessions.firstIndex(where: { $0.id == mergedSession.id }) {
      sessions[existingIndex] = mergedSession
    } else {
      sessions.append(mergedSession)
    }

    sessions.sort { $0.startedAt > $1.startedAt }

    do {
      try store?.save(mergedSession)
    } catch {
      recorderErrorMessage = "Failed to save this session locally. \(error.localizedDescription)"
    }

    return mergedSession
  }

  func selectSession(id: LocalSession.ID) {
    guard sessions.contains(where: { $0.id == id }) else {
      selectedSessionID = nil
      return
    }

    selectedSessionID = id
    syncProcessingSummary(preferredSessionID: id)
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
    if isRecording {
      Task { await stopRecording() }
    } else {
      Task { await startRecording() }
    }
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
        "Destination file: \(destinationURL.lastPathComponent)"
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

  func sendDocumentChatMessage(_ text: String, for sessionID: LocalSession.ID? = nil) {
    let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !prompt.isEmpty else { return }

    let resolvedSessionID = sessionID ?? selectedSessionID
    guard let resolvedSessionID else { return }

    guard let documentChatService else {
      _ = mutateSession(id: resolvedSessionID) { session in
        session.documentChat.status = .failed
        session.documentChat.errorMessage = "Local model is unavailable."
        session.documentChat.updatedAt = Date()
      }
      return
    }

    let userMessage = LocalSessionDocumentChatMessage(
      id: UUID(),
      role: .user,
      text: prompt,
      createdAt: Date()
    )

    guard
      let preparedSession = mutateSession(id: resolvedSessionID, { session in
        if session.documentChat.createdAt == nil {
          session.documentChat.createdAt = Date()
        }
        session.documentChat.messages.append(userMessage)
        session.documentChat.status = .sending
        session.documentChat.errorMessage = nil
        session.documentChat.updatedAt = Date()
      })
    else {
      return
    }

    Task { [weak self] in
      guard let self else { return }
      do {
        let proposal = try await documentChatService.sendMessage(
          LocalSessionDocumentChatRequest(session: preparedSession, userMessage: prompt)
        )
        _ = self.mutateSession(id: resolvedSessionID) { session in
          session.documentChat.messages.append(
            LocalSessionDocumentChatMessage(
              id: UUID(),
              role: .assistant,
              text: proposal.assistantMessage,
              createdAt: Date()
            )
          )
          session.documentChat.pendingProposal = proposal.hasEdits ? proposal : nil
          session.documentChat.status = .idle
          session.documentChat.errorMessage = nil
          session.documentChat.updatedAt = Date()
        }
      } catch {
        _ = self.mutateSession(id: resolvedSessionID) { session in
          session.documentChat.status = .failed
          session.documentChat.errorMessage = "Local model is unavailable."
          session.documentChat.updatedAt = Date()
        }
      }
    }
  }

  func applyPendingDocumentChatProposal(for sessionID: LocalSession.ID? = nil) {
    let resolvedSessionID = sessionID ?? selectedSessionID
    guard let resolvedSessionID else { return }

    _ = mutateSession(id: resolvedSessionID) { session in
      guard let proposal = session.documentChat.pendingProposal else { return }
      apply(proposal, to: &session)
      session.documentChat.pendingProposal = nil
      session.documentChat.status = .idle
      session.documentChat.errorMessage = nil
      session.documentChat.updatedAt = Date()
    }
  }

  func discardPendingDocumentChatProposal(for sessionID: LocalSession.ID? = nil) {
    let resolvedSessionID = sessionID ?? selectedSessionID
    guard let resolvedSessionID else { return }

    _ = mutateSession(id: resolvedSessionID) { session in
      session.documentChat.pendingProposal = nil
      session.documentChat.status = .idle
      session.documentChat.errorMessage = nil
      session.documentChat.updatedAt = Date()
    }
  }

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
      .sink { [weak self] in self?.micLevel = $0 }
      .store(in: &cancellables)

    recorder.$isMicrophoneCaptureActive
      .receive(on: DispatchQueue.main)
      .sink { [weak self] in self?.isMicrophoneCaptureActive = $0 }
      .store(in: &cancellables)

    recorder.$isSystemAudioCaptureActive
      .receive(on: DispatchQueue.main)
      .sink { [weak self] in self?.isSystemAudioCaptureActive = $0 }
      .store(in: &cancellables)

    recorder.$systemLevel
      .receive(on: DispatchQueue.main)
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
        "Model file: \(transcriptionPlan.modelURL.lastPathComponent)"
      ]
    )

    do {
      let result = try await transcriptionService.transcribe(
        wavURL: resolvedAudioURL,
        modelURL: transcriptionPlan.modelURL,
        language: transcriptionPlan.language,
        prompt: transcriptionPlan.prompt,
        translateToEnglish: false,
        onProgress: { [weak self] update in
          guard let self else { return }
          await self.applyTranscriptionProgress(update, for: sessionID)
        }
      )

      updatedSession.status = .ready
      updatedSession.transcriptSegments = transcriptSegments(from: result, session: session)
      let transcriptReadySession = upsertSession(updatedSession)
      endTranscription(for: sessionID)
      beginRecapGeneration(for: transcriptReadySession)
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
          "Speech: \(speechMinutes)m, silence skipped: \(skippedMinutes)m"
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

  private func beginRecapGeneration(for session: LocalSession) {
    activeRecapSessionIDs.insert(session.id)
    syncActivityFlags()
    setProcessingSnapshot(
      for: session.id,
      phase: .generatingRecap,
      title: activeRecapSessionIDs.count > 1 ? "Generating recap" : "Generating recap",
      detail: "Running the local recap model over the transcript and captured context.",
      progress: nil,
      logMessages: [
        "Recap input: transcript + captured context"
      ]
    )

    Task { [weak self] in
      guard let self else { return }
      let recap = await self.recapGenerator.generateRecap(for: session)
      _ = self.mutateSession(id: session.id) { currentSession in
        currentSession.status = .ready
        currentSession.recap = recap
      }
      self.finishRecapGeneration(for: session.id)
    }
  }

  private func finishRecapGeneration(for sessionID: LocalSession.ID) {
    activeRecapSessionIDs.remove(sessionID)
    syncActivityFlags()
    removeProcessingSnapshot(for: sessionID)
  }

  private func transcriptSegments(
    from result: LocalSessionTranscriptionResult,
    session: LocalSession
  ) -> [LocalSessionTranscriptSegment] {
    if !result.segments.isEmpty {
      return result.segments.map { segment in
        LocalSessionTranscriptSegment(
          id: UUID(),
          speaker: "Transcript",
          text: segment.text,
          timestamp: session.startedAt.addingTimeInterval(segment.startTime)
        )
      }
    }

    let transcriptText = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !transcriptText.isEmpty else {
      return []
    }

    return [
      LocalSessionTranscriptSegment(
        id: UUID(),
        speaker: "Transcript",
        text: transcriptText,
        timestamp: session.startedAt
      )
    ]
  }

  private func transcriptSegments(
    from partialSegments: [LocalSessionTranscriptionSegment],
    sessionID: LocalSession.ID
  ) -> [LocalSessionTranscriptSegment] {
    guard let session = sessions.first(where: { $0.id == sessionID }) else { return [] }
    return partialSegments.map { segment in
      LocalSessionTranscriptSegment(
        id: UUID(),
        speaker: "Transcript",
        text: segment.text,
        timestamp: session.startedAt.addingTimeInterval(segment.startTime)
      )
    }
  }

  private func warmUpTranscriptionModelIfNeeded(plan: LocalSessionTranscriptionPlan? = nil) async {
    let resolvedPlan = plan ?? fileLayout.resolvedTranscriptionPlan(fileManager: fileManager)
    guard fileManager.fileExists(atPath: resolvedPlan.modelURL.path) else { return }
    guard warmedTranscriptionModelPath != resolvedPlan.modelURL.path else { return }
    warmedTranscriptionModelPath = resolvedPlan.modelURL.path
    await transcriptionService.warmUp(modelURL: resolvedPlan.modelURL)
  }

  private static var defaultBaseDirectory: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Cepessa", isDirectory: true)
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
      return incomingSession
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
      systemFileName: incomingSession.audioArtifacts.systemFileName
        ?? existingSession.audioArtifacts.systemFileName,
      mixedFileName: incomingSession.audioArtifacts.mixedFileName
        ?? existingSession.audioArtifacts.mixedFileName
    )
    mergedSession.documentChat =
      incomingSession.documentChat == .empty ? existingSession.documentChat : incomingSession.documentChat

    return mergedSession
  }

  private func apply(_ proposal: LocalSessionDocumentEditProposal, to session: inout LocalSession) {
    if let recapPatch = proposal.recapPatch {
      if let overview = recapPatch.overview?.trimmingCharacters(in: .whitespacesAndNewlines) {
        session.recap.overview = overview
      }

      for replacement in recapPatch.sections {
        let section = LocalSessionRecapSection(
          id: session.recap.section(kind: replacement.kind)?.id ?? UUID(),
          kind: replacement.kind,
          title: replacement.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? replacement.kind.displayTitle
            : replacement.title,
          summary: replacement.summary,
          bullets: replacement.bullets,
          anchorTimestamp: session.recap.section(kind: replacement.kind)?.anchorTimestamp,
          startOffset: session.recap.section(kind: replacement.kind)?.startOffset,
          endOffset: session.recap.section(kind: replacement.kind)?.endOffset
        )
        session.recap.upsertSection(section)
      }

      session.recap.generatedAt = Date()
    }

    for patch in proposal.transcriptPatches {
      guard
        let segmentIndex = session.transcriptSegments.firstIndex(where: { $0.id == patch.segmentID })
      else {
        continue
      }
      session.transcriptSegments[segmentIndex].text = patch.text
    }

    for rename in proposal.speakerRenames {
      for segmentIndex in session.transcriptSegments.indices
      where session.transcriptSegments[segmentIndex].speaker == rename.oldName {
        session.transcriptSegments[segmentIndex].speaker = rename.newName
      }
    }
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

    return normalizedSession
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
    isTranscribing = !activeImportSessionIDs.isEmpty || !activeTranscriptionSessionIDs.isEmpty
    isGeneratingRecap = !activeRecapSessionIDs.isEmpty
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

typealias LocalMeetingAppModel = LocalSessionAppModel
