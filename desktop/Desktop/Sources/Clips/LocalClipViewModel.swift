import AppKit
import Combine
import Foundation
import SwiftUI

enum LocalClipContextSaveFeedback: Equatable {
  case success(String)
  case failure(String)
}

@MainActor
final class LocalClipViewModel: ObservableObject {
  @Published private(set) var clips: [LocalClipManifest] = []
  @Published var selectedClipID: LocalClipManifest.ID?
  @Published private(set) var activeClipID: LocalClipManifest.ID?
  @Published private(set) var isRecording = false
  @Published private(set) var statusMessage: String?
  @Published private(set) var clipboardMessage: String?
  @Published private(set) var selectedClipContextSaveFeedback: LocalClipContextSaveFeedback?
  @Published private(set) var recordingDurationText = "00:00"
  @Published private(set) var isCaptureTransitioning = false
  @Published var newClipTitleDraft = ""
  @Published var newClipIntentDraft = ""
  @Published var selectedClipTitleDraft = "" {
    didSet { clearSelectedClipContextSaveFeedback() }
  }
  @Published var selectedClipIntentDraft = "" {
    didSet { clearSelectedClipContextSaveFeedback() }
  }
  @Published var selectedClipPostNotesDraft = "" {
    didSet { clearSelectedClipContextSaveFeedback() }
  }

  private let store: LocalClipStore
  private let clipFileLayout: LocalClipFileLayout
  private let sessionFileLayout: LocalSessionFileLayout
  private let audioRecorder: any LocalClipAudioRecording
  private let transcriptionService: any LocalSessionTranscribing
  private let fileManager: FileManager
  let captureLifecycle: LocalCaptureLifecycle
  private let screenRecorder: any LocalClipScreenRecording
  private var timer: Timer?
  private var audioSession: LocalSession?
  private var captureLease: LocalCaptureLifecycle.Lease?
  private var captureTask: Task<Void, Never>?
  private var automaticTitles: [LocalClipManifest.ID: String] = [:]
  @Published private var validatedReadyClipIDs: Set<LocalClipManifest.ID> = []
  @Published private var validatingClipIDs: Set<LocalClipManifest.ID> = []
  private var processingClipIDs: Set<LocalClipManifest.ID> = []
  private var cancellables: Set<AnyCancellable> = []

  init(
    store: LocalClipStore? = nil,
    clipFileLayout: LocalClipFileLayout = LocalClipFileLayout(),
    sessionFileLayout: LocalSessionFileLayout = LocalSessionFileLayout(
      baseDirectory: LocalSessionStorageRoot.defaultBaseDirectory),
    transcriptionService: any LocalSessionTranscribing = LocalMeetingTranscriptionService(),
    fileManager: FileManager = .default,
    captureLifecycle: LocalCaptureLifecycle? = nil,
    audioRecorder: (any LocalClipAudioRecording)? = nil,
    screenRecorder: (any LocalClipScreenRecording)? = nil
  ) {
    self.clipFileLayout = clipFileLayout
    self.store = store ?? LocalClipStore(fileLayout: clipFileLayout, fileManager: fileManager)
    self.sessionFileLayout = sessionFileLayout
    self.audioRecorder = audioRecorder ?? LocalMeetingRecorder(fileLayout: sessionFileLayout)
    self.transcriptionService = transcriptionService
    self.fileManager = fileManager
    self.captureLifecycle = captureLifecycle ?? LocalCaptureLifecycle()
    self.screenRecorder = screenRecorder ?? LocalClipScreenCaptureProcess()
    loadClips()
  }

  var selectedClip: LocalClipManifest? {
    guard let selectedClipID else { return nil }
    return clips.first { $0.id == selectedClipID }
  }

  var activeClip: LocalClipManifest? {
    guard let activeClipID else { return nil }
    return clips.first { $0.id == activeClipID }
  }

  var isProcessing: Bool {
    !processingClipIDs.isEmpty || clips.contains { $0.status == .processing }
  }

  func isValidating(_ clipID: LocalClipManifest.ID) -> Bool {
    validatingClipIDs.contains(clipID)
  }

  func isReadyForDisplay(_ clipID: LocalClipManifest.ID) -> Bool {
    clip(for: clipID)?.status == .ready && validatedReadyClipIDs.contains(clipID)
  }

  func videoPlaybackURL(for clipID: LocalClipManifest.ID? = nil) -> URL? {
    guard let clipID = clipID ?? selectedClipID else { return nil }
    let url = clipFileLayout.videoURL(for: clipID)
    return fileManager.fileExists(atPath: url.path) ? url : nil
  }

  func audioPlaybackURL(for clipID: LocalClipManifest.ID? = nil) -> URL? {
    guard let clipID = clipID ?? selectedClipID else { return nil }
    let url = clipFileLayout.audioURL(for: clipID)
    return fileManager.fileExists(atPath: url.path) ? url : nil
  }

  func loadClips() {
    validatedReadyClipIDs = []
    validatingClipIDs = []
    clips = store.loadClips().map { storedClip in
      guard storedClip.status == .recording || storedClip.status == .processing else {
        return storedClip
      }

      var recovered = storedClip
      recovered.status = .failed
      recovered.endedAt = recovered.endedAt ?? Date()
      recovered.errorMessage =
        "This clip was interrupted before capture and transcription completed."
      try? store.save(recovered)
      return recovered
    }
    if selectedClipID == nil {
      selectedClipID = clips.first?.id
    }
    syncSelectedClipDrafts()
    validateStoredReadyClips()
  }

  private func validateStoredReadyClips() {
    let readyClips = clips.filter { $0.status == .ready }
    guard !readyClips.isEmpty else { return }
    validatingClipIDs = Set(readyClips.map(\.id))

    Task { [weak self, readyClips] in
      guard let self else { return }
      for clip in readyClips {
        await self.validateStoredReadyClip(clip)
      }
    }
  }

  private func validateStoredReadyClip(_ clip: LocalClipManifest) async {
    defer { validatingClipIDs.remove(clip.id) }
    guard self.clip(for: clip.id)?.status == .ready else { return }
    let audioURL = clipFileLayout.audioURL(for: clip.id)
    if let audioFailure = LocalClipAudioValidator.failureReason(
      for: audioURL,
      fileManager: fileManager
    ) {
      failClip(clip.id, message: audioFailure)
      return
    }
    guard
      let audioDuration = LocalClipAudioValidator.duration(
        for: audioURL,
        fileManager: fileManager
      ),
      LocalClipTranscriptValidator.hasUsableSegments(
        clip.transcriptSegments,
        audioDuration: audioDuration
      )
    else {
      failClip(
        clip.id,
        message:
          "CLIP video and audio were saved, but no usable speech was transcribed. Check the microphone and record again."
      )
      return
    }
    let videoURL = clipFileLayout.videoURL(for: clip.id)
    guard fileManager.fileExists(atPath: videoURL.path) else {
      failClip(
        clip.id,
        message:
          "This CLIP's saved video file is missing. Record a new CLIP or restore the original file."
      )
      return
    }
    if let videoFailure = await LocalClipVideoValidator.failureReason(
      for: videoURL,
      fileManager: fileManager
    ) {
      failClip(clip.id, message: videoFailure)
      return
    }
    guard self.clip(for: clip.id)?.status == .ready else { return }
    validatedReadyClipIDs.insert(clip.id)
  }

  func selectClip(_ clipID: LocalClipManifest.ID) {
    guard clips.contains(where: { $0.id == clipID }) else { return }
    if selectedClipID != clipID {
      clipboardMessage = nil
      selectedClipContextSaveFeedback = nil
    }
    selectedClipID = clipID
    syncSelectedClipDrafts()
  }

  func startClip() {
    guard captureLease == nil else { return }
    do {
      let lease = try captureLifecycle.beginCapture(.clip)
      captureLease = lease
      isCaptureTransitioning = true
      statusMessage = "Starting CLIP capture."
      let titleDraft = newClipTitleDraft
      let intentDraft = newClipIntentDraft
      captureTask = Task { [weak self] in
        await self?.startClipRecording(
          lease: lease,
          titleDraft: titleDraft,
          intentDraft: intentDraft
        )
      }
    } catch {
      statusMessage = error.localizedDescription
    }
  }

  func stopClip() {
    guard let lease = captureLease, captureLifecycle.beginStopping(lease) else { return }
    isCaptureTransitioning = true
    statusMessage = "Stopping CLIP capture."
    let precedingTask = captureTask
    captureTask = Task { [weak self] in
      await precedingTask?.value
      guard let self, self.captureLease == lease else { return }
      await self.stopClipRecording(lease: lease)
    }
  }

  func saveSelectedNotes() {
    guard let selectedClipID else { return }
    let didSave = mutateClip(id: selectedClipID) { clip in
      clip.title = normalizedTitle(selectedClipTitleDraft, fallback: clip.title)
      clip.intent =
        selectedClipIntentDraft.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
      clip.postNotes = selectedClipPostNotesDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    if didSave {
      clipboardMessage = nil
      selectedClipContextSaveFeedback = .success("Context saved.")
    } else {
      selectedClipContextSaveFeedback = .failure(
        statusMessage ?? "Could not save this CLIP's context."
      )
    }
  }

  func canRetryTranscription(for clipID: LocalClipManifest.ID) -> Bool {
    guard let clip = clip(for: clipID), clip.status == .failed else { return false }
    return fileManager.fileExists(atPath: clipFileLayout.videoURL(for: clipID).path)
      && fileManager.fileExists(atPath: clipFileLayout.audioURL(for: clipID).path)
      && !processingClipIDs.contains(clipID)
  }

  func retryTranscription(for clipID: LocalClipManifest.ID? = nil) {
    guard let clipID = clipID ?? selectedClipID, canRetryTranscription(for: clipID) else { return }
    processingClipIDs.insert(clipID)
    guard
      mutateClip(
        id: clipID,
        { clip in
          clip.status = .processing
          clip.errorMessage = nil
        })
    else { return }
    statusMessage = "Retrying CLIP transcript."
    Task { [weak self] in
      await self?.validateAndTranscribeClip(clipID: clipID)
    }
  }

  func canCopyAgentPrompt(for clipID: LocalClipManifest.ID) -> Bool {
    guard let clip = clip(for: clipID) else { return false }
    return isReadyForDisplay(clipID)
      && LocalClipAudioValidator.duration(
        for: clipFileLayout.audioURL(for: clipID),
        fileManager: fileManager
      ).map {
        LocalClipTranscriptValidator.hasUsableSegments(
          clip.transcriptSegments,
          audioDuration: $0
        )
      } == true
  }

  func clipDirectoryURL(for clipID: LocalClipManifest.ID? = nil) -> URL? {
    let id = clipID ?? selectedClipID
    guard let id else { return nil }
    return store.clipDirectory(for: id)
  }

  func copyAgentPrompt(for clipID: LocalClipManifest.ID? = nil) {
    guard let clip = clip(for: clipID ?? selectedClipID) else { return }
    guard canCopyAgentPrompt(for: clip.id) else {
      clipboardMessage =
        "This CLIP needs a playable video, usable audio, and a transcript before it can be shared."
      return
    }
    let prompt = agentPrompt(for: clip)
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(prompt, forType: .string)
    clipboardMessage = "Agent prompt copied."
  }

  private func startClipRecording(
    lease: LocalCaptureLifecycle.Lease,
    titleDraft: String,
    intentDraft: String
  ) async {
    let clipID = UUID()
    let title = normalizedTitle(titleDraft, fallback: Self.defaultClipTitle())
    let intent = intentDraft.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    let usesAutomaticTitle = titleDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    var clip = LocalClipManifest(
      id: clipID,
      title: title,
      startedAt: Date(),
      endedAt: nil,
      status: .recording,
      intent: intent,
      videoFileName: "clip-video.mov",
      audioFileName: "clip-audio.wav",
      transcriptFileName: "transcript.json",
      notesFileName: "notes.md",
      transcriptSegments: [],
      postNotes: "",
      errorMessage: nil
    )

    do {
      try clipFileLayout.ensureDirectories(fileManager: fileManager, for: clip.id)
      audioSession = try await audioRecorder.startRecording(title: "CLIP audio - \(title)")
      guard captureLease == lease else { throw CancellationError() }
      try screenRecorder.startRecording(
        to: clipFileLayout.videoURL(for: clip.id),
        onUnexpectedExit: { [weak self] message in
          self?.screenCaptureExitedUnexpectedly(
            message,
            clipID: clipID,
            lease: lease
          )
        }
      )
      upsertClip(clip)
      activeClipID = clip.id
      selectClip(clip.id)
      if usesAutomaticTitle {
        automaticTitles[clip.id] = title
      }
      newClipTitleDraft = ""
      newClipIntentDraft = ""
      guard captureLifecycle.markRecording(lease) else {
        return
      }
      isRecording = true
      isCaptureTransitioning = false
      statusMessage = "Recording CLIP. Speak while the screen is captured."
      startTimer(startedAt: clip.startedAt)
    } catch {
      stopTimer()
      _ = await screenRecorder.stopRecording()
      var stoppedAudioSession: LocalSession?
      if audioSession != nil {
        stoppedAudioSession = await audioRecorder.stopRecording()
      }
      if let stoppedAudioSession {
        _ = copyAudioIfAvailable(from: stoppedAudioSession, to: clipID)
      }
      clip.status = .failed
      clip.endedAt = Date()
      clip.errorMessage = error.localizedDescription
      upsertClip(clip)
      statusMessage = error.localizedDescription
      activeClipID = nil
      isRecording = false
      isCaptureTransitioning = false
      audioSession = nil
      finishCaptureLease(lease)
    }
  }

  private func stopClipRecording(
    lease: LocalCaptureLifecycle.Lease,
    captureFailure: String? = nil,
    shouldTranscribe: Bool = true
  ) async {
    guard let clipID = activeClipID else {
      finishCaptureLease(lease)
      return
    }
    stopTimer()
    let screenStopResult = await screenRecorder.stopRecording()
    let stoppedAudioSession = await audioRecorder.stopRecording()
    let endedAt = Date()
    isRecording = false
    isCaptureTransitioning = false
    activeClipID = nil
    audioSession = nil

    mutateClip(id: clipID) { clip in
      clip.status = .processing
      clip.endedAt = endedAt
    }

    var artifactFailure = captureFailure ?? screenStopResult.failureMessage
    if let stoppedAudioSession {
      artifactFailure =
        artifactFailure ?? copyAudioIfAvailable(from: stoppedAudioSession, to: clipID)
    } else {
      artifactFailure =
        artifactFailure ?? "CLIP video was saved, but no audio recording was finalized."
    }

    finishCaptureLease(lease)

    if let artifactFailure {
      failClip(clipID, message: artifactFailure)
      return
    }

    guard shouldTranscribe else {
      failClip(
        clipID,
        message:
          "CLIP capture was finalized before Sessions quit. Retry transcription after reopening the app."
      )
      return
    }

    statusMessage = "Processing CLIP transcript."
    processingClipIDs.insert(clipID)
    Task { [weak self] in
      await self?.validateAndTranscribeClip(clipID: clipID)
    }
  }

  private func screenCaptureExitedUnexpectedly(
    _ message: String,
    clipID: LocalClipManifest.ID,
    lease: LocalCaptureLifecycle.Lease
  ) {
    guard activeClipID == clipID, captureLease == lease else { return }
    guard captureLifecycle.beginStopping(lease) else { return }
    isCaptureTransitioning = true
    statusMessage = message
    let precedingTask = captureTask
    captureTask = Task { [weak self] in
      await precedingTask?.value
      guard let self, self.captureLease == lease else { return }
      await self.stopClipRecording(
        lease: lease,
        captureFailure: message,
        shouldTranscribe: false
      )
    }
  }

  /// Finalize active capture artifacts before normal application termination.
  func finishCaptureForTermination() async {
    guard let lease = captureLease else { return }
    _ = captureLifecycle.beginStopping(lease)
    isCaptureTransitioning = true
    await captureTask?.value
    guard captureLease == lease else { return }
    await stopClipRecording(lease: lease, shouldTranscribe: false)
  }

  private func copyAudioIfAvailable(from session: LocalSession, to clipID: UUID) -> String? {
    guard
      let sourceURL = sessionFileLayout.existingAudioURL(
        for: session.id, artifacts: session.audioArtifacts, fileManager: fileManager)
    else {
      return "CLIP video was saved, but no recorded audio artifact was available."
    }
    let destinationURL = clipFileLayout.audioURL(for: clipID)
    do {
      if fileManager.fileExists(atPath: destinationURL.path) {
        try fileManager.removeItem(at: destinationURL)
      }
      try fileManager.copyItem(at: sourceURL, to: destinationURL)
      return LocalClipAudioValidator.failureReason(for: destinationURL, fileManager: fileManager)
    } catch {
      return "Could not copy CLIP audio. \(error.localizedDescription)"
    }
  }

  private func finishCaptureLease(_ lease: LocalCaptureLifecycle.Lease) {
    _ = captureLifecycle.finishCapture(lease)
    if captureLease == lease {
      captureLease = nil
      captureTask = nil
    }
  }

  private func failClip(_ clipID: LocalClipManifest.ID, message: String) {
    validatedReadyClipIDs.remove(clipID)
    processingClipIDs.remove(clipID)
    mutateClip(id: clipID) { clip in
      clip.status = .failed
      clip.errorMessage = message
    }
    statusMessage = message
  }

  private func validateAndTranscribeClip(clipID: UUID) async {
    defer { processingClipIDs.remove(clipID) }
    let videoURL = clipFileLayout.videoURL(for: clipID)
    if let videoFailure = await LocalClipVideoValidator.failureReason(
      for: videoURL,
      fileManager: fileManager
    ) {
      failClip(clipID, message: videoFailure)
      return
    }

    let audioURL = clipFileLayout.audioURL(for: clipID)
    if let audioFailure = LocalClipAudioValidator.failureReason(
      for: audioURL,
      fileManager: fileManager
    ) {
      failClip(clipID, message: audioFailure)
      return
    }
    guard
      let audioDuration = LocalClipAudioValidator.duration(
        for: audioURL,
        fileManager: fileManager
      )
    else {
      failClip(clipID, message: "CLIP audio duration could not be validated.")
      return
    }

    let settings = LocalSessionTranscriptionSettings.current()
    let plan = sessionFileLayout.resolvedTranscriptionPlan(
      settings: settings, fileManager: fileManager)
    await transcriptionService.warmUp(modelURL: plan.modelURL)

    do {
      let result = try await transcriptionService.transcribe(
        wavURL: audioURL,
        modelURL: plan.modelURL,
        language: plan.language,
        prompt: plan.prompt,
        translateToEnglish: false,
        onProgress: nil
      )
      let transcriptSegments = LocalClipTranscriptValidator.usableSegments(
        from: result.segments,
        audioDuration: audioDuration
      )
      guard !transcriptSegments.isEmpty else {
        failClip(
          clipID,
          message:
            "CLIP video and audio were saved, but no usable speech was transcribed. Check the microphone and record again."
        )
        return
      }
      let automaticTitle = automaticTitles[clipID]
      let didPersist = mutateClip(id: clipID) { clip in
        clip.status = .ready
        clip.transcriptSegments = transcriptSegments
        if let automaticTitle, clip.title == automaticTitle {
          clip.title = inferredClipTitle(for: clip)
        }
        clip.errorMessage = result.warnings.isEmpty ? nil : result.warnings.joined(separator: "\n")
      }
      guard didPersist else { return }
      automaticTitles.removeValue(forKey: clipID)
      validatedReadyClipIDs.insert(clipID)
      if selectedClipID == clipID {
        statusMessage = "CLIP ready. Copy the agent prompt or connect through MCP."
      }
    } catch {
      failClip(
        clipID,
        message:
          "CLIP video and audio were saved, but transcription failed. \(error.localizedDescription)"
      )
    }
  }

  private func startTimer(startedAt: Date) {
    stopTimer()
    timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
      Task { @MainActor in
        self?.recordingDurationText = Self.durationText(Date().timeIntervalSince(startedAt))
      }
    }
  }

  private func stopTimer() {
    timer?.invalidate()
    timer = nil
  }

  @discardableResult
  private func mutateClip(id: UUID, _ mutation: (inout LocalClipManifest) -> Void) -> Bool {
    guard let index = clips.firstIndex(where: { $0.id == id }) else { return false }
    var clip = clips[index]
    mutation(&clip)
    return persistAndPublish(clip)
  }

  private func clip(for clipID: UUID?) -> LocalClipManifest? {
    guard let clipID else { return nil }
    return clips.first { $0.id == clipID }
  }

  private func agentPrompt(for clip: LocalClipManifest) -> String {
    let directory = store.clipDirectory(for: clip.id).path
    let transcript = clip.transcriptText.trimmingCharacters(in: .whitespacesAndNewlines)
    let notes = clip.postNotes.trimmingCharacters(in: .whitespacesAndNewlines)
    return """
      I recorded a Cepessa CLIP for you.

      Connect to the Cepessa Sessions MCP server and call get_local_clip with this clip_id:
      \(clip.id.uuidString)

      Use the returned paths to inspect:
      - clip-video.mov for the screen recording
      - transcript.json / transcript_segments for what I said
      - notes.md / post_notes for extra context I added after recording

      Local folder:
      \(directory)

      Title:
      \(clip.title)

      Intent:
      \(clip.intent ?? "No explicit intent was written.")

      Post notes:
      \(notes.isEmpty ? "No post notes yet." : notes)

      Transcript preview:
      \(transcript.isEmpty ? "Transcript is not available yet." : transcript.truncated(maxLength: 1200))

      Please use both the video and transcript before deciding what I want changed.
      """
  }

  private func inferredClipTitle(for clip: LocalClipManifest) -> String {
    let transcript = clip.transcriptText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !transcript.isEmpty else { return clip.title }
    let source =
      transcript
      .components(separatedBy: CharacterSet(charactersIn: ".!?\n"))
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .first { $0.count >= 12 } ?? transcript
    let compact =
      source
      .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .truncated(maxLength: 64)
    return compact.isEmpty ? clip.title : compact
  }

  @discardableResult
  func persistAndPublish(_ clip: LocalClipManifest) -> Bool {
    do {
      try store.save(clip)
      publish(clip)
      return true
    } catch {
      let message = "Failed to save CLIP. \(error.localizedDescription)"
      var visibleFailure = clip
      visibleFailure.status = .failed
      visibleFailure.errorMessage = message
      validatedReadyClipIDs.remove(clip.id)
      processingClipIDs.remove(clip.id)
      publish(visibleFailure)
      statusMessage = message
      return false
    }
  }

  private func upsertClip(_ clip: LocalClipManifest) {
    _ = persistAndPublish(clip)
  }

  private func publish(_ clip: LocalClipManifest) {
    if let index = clips.firstIndex(where: { $0.id == clip.id }) {
      clips[index] = clip
    } else {
      clips.append(clip)
    }
    clips.sort { $0.startedAt > $1.startedAt }
  }

  private func syncSelectedClipDrafts() {
    guard let selectedClip else {
      selectedClipTitleDraft = ""
      selectedClipIntentDraft = ""
      selectedClipPostNotesDraft = ""
      return
    }
    selectedClipTitleDraft = selectedClip.title
    selectedClipIntentDraft = selectedClip.intent ?? ""
    selectedClipPostNotesDraft = selectedClip.postNotes
  }

  private func clearSelectedClipContextSaveFeedback() {
    guard selectedClipContextSaveFeedback != nil else { return }
    selectedClipContextSaveFeedback = nil
  }

  private func normalizedTitle(_ title: String, fallback: String) -> String {
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? fallback : trimmed
  }

  private static func defaultClipTitle() -> String {
    "CLIP \(Date().formatted(date: .abbreviated, time: .shortened))"
  }

  private static func durationText(_ duration: TimeInterval) -> String {
    let totalSeconds = max(0, Int(duration.rounded()))
    return String(format: "%02d:%02d", totalSeconds / 60, totalSeconds % 60)
  }
}

extension String {
  fileprivate var nilIfEmpty: String? {
    isEmpty ? nil : self
  }

  fileprivate func truncated(maxLength: Int) -> String {
    guard count > maxLength else { return self }
    let endIndex = index(startIndex, offsetBy: max(0, maxLength - 1))
    return String(self[..<endIndex]).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
  }
}
