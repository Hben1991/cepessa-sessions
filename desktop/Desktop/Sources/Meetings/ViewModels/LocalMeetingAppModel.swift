import Combine
import Foundation
import SwiftUI

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

  private let fileLayout: LocalSessionFileLayout
  private let store: LocalSessionStore?
  private let recorder: LocalMeetingRecorder
  private let transcriptionService: any LocalSessionTranscribing
  private let recapGenerator: any LocalSessionRecapGenerating
  private let contentClassifier: any LocalSessionContentClassifying
  private let documentChatService: (any LocalSessionDocumentChatProviding)?
  private let audioImportService: any LocalSessionAudioImporting
  private let fileManager: FileManager
  private var activeImportSessionIDs: Set<LocalSession.ID> = []
  private var activeTranscriptionSessionIDs: Set<LocalSession.ID> = []
  private var activeContentClassificationSessionIDs: Set<LocalSession.ID> = []
  private var activeRecapSessionIDs: Set<LocalSession.ID> = []
  private var warmedTranscriptionModelPath: String?
  private var cancellables: Set<AnyCancellable> = []

  init(
    sessions: [LocalSession] = [],
    store: LocalSessionStore? = nil,
    fileLayout: LocalSessionFileLayout? = nil,
    transcriptionService: any LocalSessionTranscribing = LocalMeetingTranscriptionService(),
    recapGenerator: any LocalSessionRecapGenerating = LocalSessionRecapGenerator(),
    contentClassifier: any LocalSessionContentClassifying = LocalSessionContentClassifier(),
    documentChatService: (any LocalSessionDocumentChatProviding)? =
      LocalSessionDocumentChatClient(),
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
    self.contentClassifier = contentClassifier
    self.documentChatService = documentChatService
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
    isTranscribing || isGeneratingRecap || !activeContentClassificationSessionIDs.isEmpty
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

  func sendDocumentChatMessage(_ text: String, for sessionID: LocalSession.ID? = nil) {
    let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !prompt.isEmpty else { return }

    let resolvedSessionID = sessionID ?? selectedSessionID
    guard let resolvedSessionID else { return }

    guard let documentChatService else {
      _ = mutateSession(id: resolvedSessionID) { session in
        session.documentChat.status = .failed
        session.documentChat.errorMessage = "Session chat is not configured in this build."
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
      let preparedSession = mutateSession(
        id: resolvedSessionID,
        { session in
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
          if proposal.hasEdits {
            session.documentChat.pendingProposal = proposal
            session.documentChat.messages.append(
              LocalSessionDocumentChatMessage(
                id: UUID(),
                role: .assistant,
                text: self.previewReadyMessage(for: proposal),
                createdAt: Date(),
                sourceCitations: proposal.sourceCitations
              )
            )
          } else {
            session.documentChat.pendingProposal = nil
            session.documentChat.messages.append(
              LocalSessionDocumentChatMessage(
                id: UUID(),
                role: .assistant,
                text: self.assistantMessage(for: proposal),
                createdAt: Date(),
                sourceCitations: proposal.sourceCitations
              )
            )
          }
          session.documentChat.status = .idle
          session.documentChat.errorMessage = nil
          session.documentChat.updatedAt = Date()
        }
      } catch {
        _ = self.mutateSession(id: resolvedSessionID) { session in
          session.documentChat.status = .failed
          session.documentChat.errorMessage = "Session chat could not finish."
          session.documentChat.updatedAt = Date()
        }
      }
    }
  }

  func regenerateRecap(for sessionID: LocalSession.ID? = nil) {
    let resolvedSessionID = sessionID ?? selectedSessionID
    guard let resolvedSessionID,
      !activeContentClassificationSessionIDs.contains(resolvedSessionID),
      !activeRecapSessionIDs.contains(resolvedSessionID),
      let session = sessions.first(where: { $0.id == resolvedSessionID }),
      !session.transcriptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      return
    }

    beginContentClassification(for: session)
  }

  private func assistantMessage(
    for proposal: LocalSessionDocumentEditProposal,
    requestedEdit: Bool = false,
    didApplyEdits: Bool = false,
    userMessage: String = ""
  ) -> String {
    if requestedEdit, !didApplyEdits {
      return userMessage.containsHebrewScript || proposal.assistantMessage.containsHebrewScript
        ? "לא הצלחתי להחיל שינוי במסמך מהתגובה הזאת."
        : "I could not apply a document change from that response."
    }

    let trimmed = proposal.assistantMessage.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmed.isEmpty {
      return trimmed
    }

    return proposal.hasEdits
      ? "Applied the requested document edits." : "No document edit was needed."
  }

  private func previewReadyMessage(for proposal: LocalSessionDocumentEditProposal) -> String {
    let trimmed = proposal.assistantMessage.trimmingCharacters(in: .whitespacesAndNewlines)
    let summary = trimmed.isEmpty ? "Review the proposed document changes before applying them." : trimmed
    return "Preview ready: \(summary)"
  }

  func applyPendingDocumentChatProposal(for sessionID: LocalSession.ID? = nil) {
    let resolvedSessionID = sessionID ?? selectedSessionID
    guard let resolvedSessionID else { return }

    _ = mutateSession(id: resolvedSessionID) { session in
      guard let proposal = session.documentChat.pendingProposal else { return }
      let undoSnapshot = LocalSessionDocumentUndoSnapshot(
        title: session.title,
        documentMarkdown: session.documentMarkdown,
        recap: session.recap,
        transcriptSegments: session.transcriptSegments,
        createdAt: Date()
      )
      let didApplyEdits = apply(proposal, to: &session)
      session.documentChat.pendingProposal = nil
      session.documentChat.status = didApplyEdits ? .idle : .failed
      session.documentChat.errorMessage = didApplyEdits
        ? nil
        : "The proposed document edit could not be applied."
      if didApplyEdits {
        session.documentChat.undoSnapshot = undoSnapshot
      }
      session.documentChat.messages.append(
        LocalSessionDocumentChatMessage(
          id: UUID(),
          role: .assistant,
          text: didApplyEdits
            ? "Applied the previewed document changes."
            : "I could not apply a document change from that preview.",
          createdAt: Date(),
          sourceCitations: proposal.sourceCitations
        )
      )
      session.documentChat.updatedAt = Date()
    }
  }

  func undoLastDocumentChatEdit(for sessionID: LocalSession.ID? = nil) {
    let resolvedSessionID = sessionID ?? selectedSessionID
    guard let resolvedSessionID else { return }

    _ = mutateSession(id: resolvedSessionID) { session in
      guard let snapshot = session.documentChat.undoSnapshot else { return }
      session.title = snapshot.title
      session.documentMarkdown = snapshot.documentMarkdown
      session.recap = snapshot.recap
      session.transcriptSegments = snapshot.transcriptSegments
      session.documentChat.undoSnapshot = nil
      session.documentChat.pendingProposal = nil
      session.documentChat.status = .idle
      session.documentChat.errorMessage = nil
      session.documentChat.messages.append(
        LocalSessionDocumentChatMessage(
          id: UUID(),
          role: .assistant,
          text: "Undid the last document edit.",
          createdAt: Date()
        )
      )
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
      .removeDuplicates { abs($0 - $1) < 0.01 }
      .throttle(for: .milliseconds(80), scheduler: DispatchQueue.main, latest: true)
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
      beginContentClassification(for: transcriptReadySession)
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

  private func beginContentClassification(for session: LocalSession) {
    activeContentClassificationSessionIDs.insert(session.id)
    syncActivityFlags()
    setProcessingSnapshot(
      for: session.id,
      phase: .classifyingContent,
      title: "Understanding content",
      detail: "Detecting whether this transcript is a meeting, message, video commentary, or general transcript.",
      progress: nil,
      logMessages: [
        "Classification input: transcript + captured context"
      ]
    )

    Task { [weak self] in
      guard let self else { return }
      let classification = await self.contentClassifier.classifyContent(for: session)
      let classifiedSession = self.mutateSession(id: session.id) { currentSession in
        currentSession.contentClassification = classification
      }
      self.finishContentClassification(for: session.id)
      self.beginRecapGeneration(for: classifiedSession ?? session)
    }
  }

  private func finishContentClassification(for sessionID: LocalSession.ID) {
    activeContentClassificationSessionIDs.remove(sessionID)
    syncActivityFlags()
  }

  private func beginRecapGeneration(for session: LocalSession) {
    activeRecapSessionIDs.insert(session.id)
    syncActivityFlags()
    let contentTypeTitle = session.contentClassification?.type.displayTitle ?? "General transcript"
    setProcessingSnapshot(
      for: session.id,
      phase: .generatingRecap,
      title: "Generating \(contentTypeTitle.lowercased()) brief",
      detail: "Running the local recap model with \(contentTypeTitle.lowercased()) instructions.",
      progress: nil,
      logMessages: [
        "Detected content type: \(contentTypeTitle)",
        "Recap input: transcript + captured context",
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
          endTimestamp: session.startedAt.addingTimeInterval(max(segment.endTime, segment.startTime))
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
        speaker: "Speaker 1",
        text: transcriptText,
        timestamp: session.startedAt,
        endTimestamp: nil
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
        speaker: "Speaker 1",
        text: segment.text,
        timestamp: session.startedAt.addingTimeInterval(segment.startTime),
        endTimestamp: session.startedAt.addingTimeInterval(max(segment.endTime, segment.startTime))
      )
    }
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
      systemFileName: incomingSession.audioArtifacts.systemFileName
        ?? existingSession.audioArtifacts.systemFileName,
      mixedFileName: incomingSession.audioArtifacts.mixedFileName
        ?? existingSession.audioArtifacts.mixedFileName
    )
    mergedSession.contentClassification =
      incomingSession.contentClassification ?? existingSession.contentClassification
    mergedSession.documentChat =
      incomingSession.documentChat == .empty
      ? existingSession.documentChat : incomingSession.documentChat
    mergedSession.anchorTimelineContextToTranscriptSegments()

    return mergedSession
  }

  @discardableResult
  private func apply(
    _ proposal: LocalSessionDocumentEditProposal,
    to session: inout LocalSession
  ) -> Bool {
    var changed = false
    var recapChanged = false

    if proposal.operation == .delete {
      let replacement = proposal.documentMarkdown?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      if session.documentMarkdown != replacement {
        session.documentMarkdown = replacement
        changed = true
      }
    } else if let documentMarkdown = proposal.documentMarkdown {
      let replacement = documentMarkdown.trimmingCharacters(in: .whitespacesAndNewlines)
      if session.documentMarkdown != replacement {
        session.documentMarkdown = replacement
        changed = true
      }
    }

    if let title = proposal.sessionTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
      !title.isEmpty,
      session.title != title
    {
      session.title = title
      changed = true
    }

    if let recapPatch = proposal.recapPatch {
      if let overview = recapPatch.overview?.trimmingCharacters(in: .whitespacesAndNewlines) {
        if session.recap.overview != overview {
          session.recap.overview = overview
          changed = true
          recapChanged = true
        }
      }

      for replacement in recapPatch.sections {
        let existingSection = session.recap.section(kind: replacement.kind)
        let section = LocalSessionRecapSection(
          id: existingSection?.id ?? UUID(),
          kind: replacement.kind,
          title: replacement.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? replacement.kind.displayTitle
            : replacement.title,
          summary: replacement.summary,
          bullets: replacement.bullets,
          anchorTimestamp: existingSection?.anchorTimestamp,
          startOffset: existingSection?.startOffset,
          endOffset: existingSection?.endOffset
        )
        if existingSection?.title != section.title
          || existingSection?.summary != section.summary
          || existingSection?.bullets != section.bullets
        {
          session.recap.upsertSection(section)
          changed = true
          recapChanged = true
        }
      }

      if recapChanged {
        session.recap.generatedAt = Date()
      }
    }

    for patch in proposal.transcriptPatches {
      guard
        let segmentIndex = session.transcriptSegments.firstIndex(where: { $0.id == patch.segmentID }
        )
      else {
        continue
      }
      if session.transcriptSegments[segmentIndex].text != patch.text {
        session.transcriptSegments[segmentIndex].text = patch.text
        changed = true
      }
    }

    for rename in proposal.speakerRenames {
      for segmentIndex in session.transcriptSegments.indices
      where session.transcriptSegments[segmentIndex].speaker == rename.oldName {
        if session.transcriptSegments[segmentIndex].speaker != rename.newName {
          session.transcriptSegments[segmentIndex].speaker = rename.newName
          changed = true
        }
      }
    }

    return changed
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
    if normalizedSession.transcriptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      normalizedSession.recap.removeStaleGenericFallback()
    {
      normalizedSession.recap = .empty
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
      || !activeContentClassificationSessionIDs.isEmpty
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

private extension LocalSessionDocumentEditProposal {
  var isStaleAppendInstructionEcho: Bool {
    let generatedText = [
      sessionTitle,
      recapPatch?.overview,
    ].compactMap { $0 }
      + (recapPatch?.sections ?? []).flatMap { section in
        [section.title, section.summary] + section.bullets
      }

    return generatedText.contains { $0.looksLikeAppendInstructionEcho }
  }
}

private extension LocalSessionDocumentChatMessage {
  var isStaleLocalModelFailureMessage: Bool {
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

  var isStaleAppendInstructionPreviewMessage: Bool {
    guard role == .assistant else { return false }

    let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return normalized.contains("preview ready:")
      && (normalized.contains("הוספתי פסקת המשך בסוף המסמך")
        || normalized.contains("added a closing paragraph"))
  }
}

private extension LocalSessionRecap {
  mutating func removeStaleAppliedAppendInstructionSections() -> Bool {
    let countBefore = sections.count
    sections.removeAll { $0.looksLikeAppliedAppendInstructionEcho }
    return sections.count != countBefore
  }

  mutating func removeStaleTitleUpdateNote() -> String? {
    guard let index = sections.firstIndex(where: { section in
      section.kind == .notes && section.title.contains("כותרת")
    }) else {
      return nil
    }

    let title = sections[index].title.cleanedTitleUpdateRequest
    guard let title else { return nil }

    sections.remove(at: index)
    return title
  }

  mutating func normalizeStaleHebrewVideoTemplateTitles() -> Bool {
    let corpus =
      ([overview] + sections.flatMap { [$0.title, $0.summary] + $0.bullets })
      .joined(separator: " ")
      .lowercased()
    guard corpus.containsHebrewScript else { return false }
    guard ["סרטון", "יוטיוב", "לייב", "ערוץ", "מורה מבוכים"].contains(where: {
      corpus.contains($0)
    }) else {
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

  mutating func removeStaleGenericFallback() -> Bool {
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
}

private extension LocalSessionRecapSection {
  var looksLikeAppliedAppendInstructionEcho: Bool {
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

private extension String {
  var containsHebrewScript: Bool {
    unicodeScalars.contains { scalar in
      (0x0590...0x05FF).contains(Int(scalar.value))
    }
  }

  var looksLikeAppendInstructionEcho: Bool {
    let normalized = trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !normalized.isEmpty else { return false }

    return [
      "תוסיף", "הוסף", "להוסיף", "תרשום", "תכתוב", "כתוב",
      "add", "append", "write this", "write it",
    ].contains { normalized.contains($0) }
  }

  var cleanedTitleUpdateRequest: String? {
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
