import AppKit
import Combine
import Foundation
import SwiftUI

@MainActor
final class LocalClipViewModel: ObservableObject {
  @Published private(set) var clips: [LocalClipManifest] = []
  @Published var selectedClipID: LocalClipManifest.ID?
  @Published private(set) var activeClipID: LocalClipManifest.ID?
  @Published private(set) var isRecording = false
  @Published private(set) var statusMessage: String?
  @Published private(set) var clipboardMessage: String?
  @Published private(set) var recordingDurationText = "00:00"
  @Published var titleDraft = ""
  @Published var intentDraft = ""
  @Published var postNotesDraft = ""

  private let store: LocalClipStore
  private let clipFileLayout: LocalClipFileLayout
  private let sessionFileLayout: LocalSessionFileLayout
  private let audioRecorder: LocalMeetingRecorder
  private let transcriptionService: any LocalSessionTranscribing
  private let fileManager: FileManager
  private var screenRecordingProcess: Process?
  private var timer: Timer?
  private var audioSession: LocalSession?
  private var cancellables: Set<AnyCancellable> = []

  init(
    store: LocalClipStore? = nil,
    clipFileLayout: LocalClipFileLayout = LocalClipFileLayout(),
    sessionFileLayout: LocalSessionFileLayout = LocalSessionFileLayout(
      baseDirectory: LocalSessionStorageRoot.defaultBaseDirectory),
    transcriptionService: any LocalSessionTranscribing = LocalMeetingTranscriptionService(),
    fileManager: FileManager = .default
  ) {
    self.clipFileLayout = clipFileLayout
    self.store = store ?? LocalClipStore(fileLayout: clipFileLayout, fileManager: fileManager)
    self.sessionFileLayout = sessionFileLayout
    self.audioRecorder = LocalMeetingRecorder(fileLayout: sessionFileLayout)
    self.transcriptionService = transcriptionService
    self.fileManager = fileManager
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

  func loadClips() {
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
    syncDrafts()
  }

  func selectClip(_ clipID: LocalClipManifest.ID) {
    guard clips.contains(where: { $0.id == clipID }) else { return }
    selectedClipID = clipID
    syncDrafts()
  }

  func startClip() {
    guard !isRecording else { return }
    Task { await startClipRecording() }
  }

  func stopClip() {
    guard isRecording else { return }
    Task { await stopClipRecording() }
  }

  func saveSelectedNotes() {
    guard let selectedClipID else { return }
    mutateClip(id: selectedClipID) { clip in
      clip.title = normalizedTitle(titleDraft, fallback: clip.title)
      clip.intent = intentDraft.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
      clip.postNotes = postNotesDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    }
  }

  func clipDirectoryURL(for clipID: LocalClipManifest.ID? = nil) -> URL? {
    let id = clipID ?? selectedClipID
    guard let id else { return nil }
    return store.clipDirectory(for: id)
  }

  func copyAgentPrompt(for clipID: LocalClipManifest.ID? = nil) {
    guard let clip = clip(for: clipID ?? selectedClipID) else { return }
    let prompt = agentPrompt(for: clip)
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(prompt, forType: .string)
    clipboardMessage = "Agent prompt copied."
  }

  private func startClipRecording() async {
    let clipID = UUID()
    let title = normalizedTitle(titleDraft, fallback: Self.defaultClipTitle())
    let intent = intentDraft.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
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
      try startScreenRecording(to: clipFileLayout.videoURL(for: clip.id))
      upsertClip(clip)
      activeClipID = clip.id
      selectedClipID = clip.id
      isRecording = true
      statusMessage = "Recording CLIP. Speak while the screen is captured."
      startTimer(startedAt: clip.startedAt)
    } catch {
      stopTimer()
      stopScreenRecording()
      if audioSession != nil {
        _ = await audioRecorder.stopRecording()
      }
      clip.status = .failed
      clip.errorMessage = error.localizedDescription
      upsertClip(clip)
      statusMessage = error.localizedDescription
      activeClipID = nil
      isRecording = false
      audioSession = nil
    }
  }

  private func stopClipRecording() async {
    guard let clipID = activeClipID else { return }
    stopTimer()
    stopScreenRecording()
    let stoppedAudioSession = await audioRecorder.stopRecording()
    let endedAt = Date()
    isRecording = false
    activeClipID = nil
    statusMessage = "Processing CLIP transcript."

    mutateClip(id: clipID) { clip in
      clip.status = .processing
      clip.endedAt = endedAt
    }

    if let stoppedAudioSession {
      copyAudioIfAvailable(from: stoppedAudioSession, to: clipID)
      await transcribeClipAudio(clipID: clipID)
    } else {
      mutateClip(id: clipID) { clip in
        clip.status = .failed
        clip.errorMessage = "CLIP video was saved, but no audio transcript was available."
      }
    }

    audioSession = nil
    if clip(for: clipID)?.status == .ready {
      statusMessage = "CLIP ready. Copy the agent prompt or connect through MCP."
    } else {
      statusMessage = clip(for: clipID)?.errorMessage ?? "CLIP capture needs attention."
    }
  }

  private func startScreenRecording(to videoURL: URL) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    process.arguments = ["-v", "-k", "-x", videoURL.path]
    try process.run()
    screenRecordingProcess = process
  }

  private func stopScreenRecording() {
    guard let process = screenRecordingProcess else { return }
    if process.isRunning {
      process.terminate()
      process.waitUntilExit()
    }
    screenRecordingProcess = nil
  }

  private func copyAudioIfAvailable(from session: LocalSession, to clipID: UUID) {
    guard
      let sourceURL = sessionFileLayout.existingAudioURL(
        for: session.id, artifacts: session.audioArtifacts, fileManager: fileManager)
    else {
      return
    }
    let destinationURL = clipFileLayout.audioURL(for: clipID)
    do {
      if fileManager.fileExists(atPath: destinationURL.path) {
        try fileManager.removeItem(at: destinationURL)
      }
      try fileManager.copyItem(at: sourceURL, to: destinationURL)
    } catch {
      mutateClip(id: clipID) { clip in
        clip.errorMessage = "Could not copy CLIP audio. \(error.localizedDescription)"
      }
    }
  }

  private func transcribeClipAudio(clipID: UUID) async {
    let audioURL = clipFileLayout.audioURL(for: clipID)
    guard fileManager.fileExists(atPath: audioURL.path) else {
      mutateClip(id: clipID) { clip in
        clip.status = .failed
        clip.errorMessage = "CLIP video was saved, but audio was not available for transcription."
      }
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
      mutateClip(id: clipID) { clip in
        clip.status = .ready
        clip.transcriptSegments = result.segments.map {
          LocalClipTranscriptSegment(
            id: UUID(),
            startOffset: $0.startTime,
            endOffset: $0.endTime,
            text: $0.text
          )
        }
        clip.title = inferredClipTitle(for: clip)
        clip.errorMessage = result.warnings.isEmpty ? nil : result.warnings.joined(separator: "\n")
      }
    } catch {
      mutateClip(id: clipID) { clip in
        clip.status = .failed
        clip.errorMessage = "CLIP saved, but transcription failed. \(error.localizedDescription)"
      }
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

  private func mutateClip(id: UUID, _ mutation: (inout LocalClipManifest) -> Void) {
    guard let index = clips.firstIndex(where: { $0.id == id }) else { return }
    var clip = clips[index]
    mutation(&clip)
    upsertClip(clip)
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

  private func upsertClip(_ clip: LocalClipManifest) {
    if let index = clips.firstIndex(where: { $0.id == clip.id }) {
      clips[index] = clip
    } else {
      clips.append(clip)
    }
    clips.sort { $0.startedAt > $1.startedAt }
    do {
      try store.save(clip)
    } catch {
      statusMessage = "Failed to save CLIP. \(error.localizedDescription)"
    }
    syncDrafts()
  }

  private func syncDrafts() {
    guard let selectedClip else { return }
    titleDraft = selectedClip.title
    intentDraft = selectedClip.intent ?? ""
    postNotesDraft = selectedClip.postNotes
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
