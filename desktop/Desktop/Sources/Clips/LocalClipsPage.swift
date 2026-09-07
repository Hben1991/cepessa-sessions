import AVKit
import AppKit
import SwiftUI

/// CLIPS is a two-pane document browser, not a dashboard: a list of recordings
/// on the left, the selected clip's handoff details on the right, and one
/// recorder bar pinned under the list. Everything else the old layout carried
/// — the gradient, the 30pt headings, the dark 360pt hero placeholder — was
/// decoration around three controls that already explain themselves.
struct LocalClipsPage: View {
  @StateObject private var model = CepessaSessionsStore.shared.clipModel
  @ObservedObject private var captureLifecycle = CepessaSessionsStore.shared.captureLifecycle
  @State private var hasScreenRecordingAccess = CGPreflightScreenCaptureAccess()

  var body: some View {
    NavigationSplitView {
      sidebar
        .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
    } detail: {
      detail
    }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification))
    { _ in
      hasScreenRecordingAccess = CGPreflightScreenCaptureAccess()
    }
  }

  // MARK: - Sidebar

  private var sidebar: some View {
    List(selection: selection) {
      ForEach(model.clips) { clip in
        clipRow(clip)
          .tag(clip.id)
      }
    }
    .overlay {
      if model.clips.isEmpty {
        ContentUnavailableView {
          Label("No Clips", systemImage: "video.badge.plus")
        } description: {
          Text("Record the screen and narrate it to create an agent handoff.")
        }
      }
    }
    .safeAreaInset(edge: .bottom, spacing: 0) {
      recorderBar
    }
  }

  /// `selectClip` also syncs the draft fields, so selection has to route
  /// through the view model rather than binding straight to the published id.
  private var selection: Binding<LocalClipManifest.ID?> {
    Binding(
      get: { model.selectedClipID },
      set: { id in
        guard let id else { return }
        model.selectClip(id)
      }
    )
  }

  /// Title, then the one line that says what the clip is about, then when it
  /// happened. A status line appears only when the clip is doing something or
  /// needs looking at — stamping "Ready" on every finished row is noise.
  private func clipRow(_ clip: LocalClipManifest) -> some View {
    let status = CepessaStatusStyle.resolve(clip.status)

    return VStack(alignment: .leading, spacing: CepessaChrome.Space.xxs) {
      Text(clip.title)
        .font(.body)
        .lineLimit(1)

      Text(clip.intent ?? clip.transcriptText.nilIfBlank ?? "No transcript yet")
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)

      HStack(spacing: CepessaChrome.Space.xs) {
        Text(clip.startedAt.formatted(date: .abbreviated, time: .shortened))
          .font(.caption2)
          .foregroundStyle(.tertiary)

        if model.isValidating(clip.id) {
          Text("Checking recording…").font(.caption2).foregroundStyle(.secondary)
        } else if status != .ready {
          CepessaStatusLabel(style: status, font: .caption2)
        }
      }
    }
    .padding(.vertical, CepessaChrome.Space.xxs)
    .accessibilityElement(children: .combine)
  }

  /// One capture control, always in the same place, with the transport button
  /// carrying the same red the floating indicator uses for live capture. The
  /// only line of prose under it is the app's own truth about why recording is
  /// or is not possible right now — never a general description of the feature.
  private var recorderBar: some View {
    VStack(spacing: CepessaChrome.Space.s) {
      Divider()

      VStack(spacing: CepessaChrome.Space.xs) {
        HStack(alignment: .bottom, spacing: CepessaChrome.Space.s) {
          VStack(alignment: .leading, spacing: CepessaChrome.Space.xxs) {
            Text("Title")
              .font(.caption)
              .foregroundStyle(.secondary)

            TextField("Optional name", text: $model.newClipTitleDraft)
              .textFieldStyle(.roundedBorder)
              .disabled(model.isRecording || model.isCaptureTransitioning)
          }

          if model.isRecording {
            HStack(spacing: CepessaChrome.Space.xs) {
              Circle()
                .fill(CepessaColors.signalRed)
                .frame(width: 7, height: 7)
              Text(model.recordingDurationText)
                .font(.callout.monospacedDigit())
                .foregroundStyle(CepessaColors.textPrimary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Recording time \(model.recordingDurationText)")
          }

          Button {
            model.isRecording ? model.stopClip() : model.startClip()
          } label: {
            Label(
              model.isCaptureTransitioning
                ? "Please wait…" : (model.isRecording ? "Stop" : "Record"),
              systemImage: model.isRecording ? "stop.fill" : "record.circle"
            )
          }
          .buttonStyle(.borderedProminent)
          .controlSize(.regular)
          .tint(model.isRecording ? CepessaColors.signalRed : CepessaColors.accent)
          .disabled(isRecordBlocked)
          .help(model.isRecording ? "Stop recording this clip" : "Record a new clip")
          .accessibilityLabel(model.isRecording ? "Stop recording" : "Record clip")
        }

        VStack(alignment: .leading, spacing: CepessaChrome.Space.xxs) {
          Text("Agent focus")
            .font(.caption)
            .foregroundStyle(.secondary)

          TextField("Optional guidance", text: $model.newClipIntentDraft)
            .textFieldStyle(.roundedBorder)
            .disabled(model.isRecording || model.isCaptureTransitioning)
            .accessibilityLabel("Agent focus")
        }
      }
      .padding(.horizontal, CepessaChrome.Space.m)

      if let blocker = recorderBlockerMessage {
        VStack(alignment: .leading, spacing: CepessaChrome.Space.xxs) {
          Label(blocker, systemImage: "exclamationmark.triangle.fill")
            .labelStyle(.titleAndIcon)
            .font(.caption)
            .foregroundStyle(CepessaColors.textSecondary)
            .lineLimit(2)

          if !hasScreenRecordingAccess, !isSessionBusy {
            Button("Open Screen Recording Settings") {
              openScreenRecordingSettings()
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, CepessaChrome.Space.m)
      } else if let status = model.statusMessage {
        Text(status)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(2)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, CepessaChrome.Space.m)
      }
    }
    .padding(.bottom, CepessaChrome.Space.m)
    .background(.bar)
  }

  private var isSessionBusy: Bool {
    captureLifecycle.activeKind == .session
  }

  private var isRecordBlocked: Bool {
    model.isCaptureTransitioning
      || (!model.isRecording && (captureLifecycle.isBusy || !hasScreenRecordingAccess))
  }

  private var recorderBlockerMessage: String? {
    guard !model.isRecording else { return nil }
    if isSessionBusy {
      return "Stop the active session recording before starting a clip."
    }
    if !hasScreenRecordingAccess {
      return "Screen Recording access is needed to capture a clip. Grant it in Settings."
    }
    return nil
  }

  // MARK: - Detail

  @ViewBuilder
  private var detail: some View {
    if let clip = model.selectedClip {
      Form {
        Section {
          LabeledContent("Recorded", value: clip.startedAt.formatted(date: .long, time: .shortened))
          if clip.endedAt != nil {
            LabeledContent("Length", value: durationText(clip.duration))
          }
          LabeledContent("Status") {
            if model.isValidating(clip.id) {
              ProgressView("Checking recording…").controlSize(.small)
            } else {
              CepessaStatusLabel(
                style: CepessaStatusStyle.resolve(clip.status),
                detail: clip.errorMessage,
                font: .body
              )
              .multilineTextAlignment(.trailing)
            }
          }
          LabeledContent(
            "Transcript",
            value: clip.transcriptSegments.isEmpty
              ? "Not available"
              : "\(clip.transcriptSegments.count) segments"
          )
        } header: {
          Text(clip.title)
        }

        if clip.status != .recording, !model.isValidating(clip.id),
          let videoURL = model.videoPlaybackURL(for: clip.id),
          let audioURL = model.audioPlaybackURL(for: clip.id)
        {
          Section("Recording") {
            LocalClipPlaybackView(
              videoURL: videoURL,
              audioURL: audioURL
            )
            .id(clip.id)
          }
        }

        Section("Notes") {
          TextField("Title", text: $model.selectedClipTitleDraft)
            .accessibilityLabel("Selected clip title")

          TextField("Agent focus", text: $model.selectedClipIntentDraft)
            .accessibilityLabel("What the agent should understand from this clip")

          TextEditor(text: $model.selectedClipPostNotesDraft)
            .font(.body)
            .frame(minHeight: 96)
            .accessibilityLabel("Post-recording notes")

          HStack(spacing: CepessaChrome.Space.s) {
            Button("Save Context") { model.saveSelectedNotes() }

            if let feedback = model.selectedClipContextSaveFeedback {
              switch feedback {
              case .success(let message):
                Label(message, systemImage: "checkmark.circle.fill")
                  .font(.caption)
                  .foregroundStyle(.secondary)
              case .failure(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                  .font(.caption)
                  .foregroundStyle(CepessaColors.signalRed)
                  .lineLimit(2)
              }
            }
          }
        }

        // Only shown when there is a transcript to show. This is the clip's
        // own recorded text, read-only — the editable fields stay in Notes.
        if !clip.transcriptSegments.isEmpty {
          Section("Transcript") {
            Text(LocalTranscriptTextDirection.displayText(clip.transcriptText))
              .font(.callout)
              .foregroundStyle(CepessaColors.textPrimary)
              .textSelection(.enabled)
              .multilineTextAlignment(
                LocalTranscriptTextDirection.isRightToLeft(clip.transcriptText)
                  ? .trailing : .leading
              )
              .frame(
                maxWidth: .infinity,
                alignment: LocalTranscriptTextDirection.isRightToLeft(clip.transcriptText)
                  ? .trailing : .leading
              )
              .accessibilityLabel("Clip transcript")
          }
        }

        Section {
          if model.canRetryTranscription(for: clip.id) {
            Button("Retry Transcript") { model.retryTranscription(for: clip.id) }
          }

          Button {
            model.copyAgentPrompt(for: clip.id)
          } label: {
            Label("Copy Agent Prompt", systemImage: "doc.on.doc")
          }
          .disabled(!model.canCopyAgentPrompt(for: clip.id))

          Button {
            if let url = model.clipDirectoryURL(for: clip.id) {
              NSWorkspace.shared.activateFileViewerSelecting([url])
            }
          } label: {
            Label("Reveal in Finder", systemImage: "folder")
          }

          if let clipboardMessage = model.clipboardMessage {
            Text(clipboardMessage)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        } header: {
          Text("Handoff")
        } footer: {
          Text("Review the recording and notes before copying the handoff.")
        }
      }
      .formStyle(.grouped)
    } else {
      ContentUnavailableView {
        Label("No Clip Selected", systemImage: "shippingbox")
      } description: {
        Text("Select a clip to review its recording, transcript, and notes.")
      }
    }
  }

  private func durationText(_ duration: TimeInterval) -> String {
    let total = max(0, Int(duration.rounded()))
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    let seconds = total % 60
    return hours > 0
      ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
      : String(format: "%d:%02d", minutes, seconds)
  }

  private func openScreenRecordingSettings() {
    guard
      let url = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
      )
    else { return }
    NSWorkspace.shared.open(url)
  }
}

private struct LocalClipPlaybackView: View {
  let videoURL: URL
  let audioURL: URL
  @State private var player: AVPlayer?
  @State private var errorMessage: String?

  var body: some View {
    Group {
      if let player {
        VideoPlayer(player: player)
          .aspectRatio(16.0 / 9.0, contentMode: .fit)
          .accessibilityLabel("Clip recording player")
      } else if let errorMessage {
        Label(errorMessage, systemImage: "exclamationmark.triangle")
          .font(.callout)
      } else {
        ProgressView("Opening recording…")
      }
    }
    .task(id: videoURL) { await loadRecording() }
    .onDisappear { player?.pause() }
  }

  private func loadRecording() async {
    player?.pause()
    player = nil
    errorMessage = nil
    do {
      let video = AVURLAsset(url: videoURL)
      let composition = AVMutableComposition()
      let videoTracks = try await video.loadTracks(withMediaType: .video)
      guard let sourceVideo = videoTracks.first,
        let videoTrack = composition.addMutableTrack(
          withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
      else { throw CocoaError(.fileReadCorruptFile) }
      let duration = try await video.load(.duration)
      guard duration.seconds.isFinite, duration.seconds > 0 else {
        throw CocoaError(.fileReadCorruptFile)
      }
      try videoTrack.insertTimeRange(
        CMTimeRange(start: .zero, duration: duration), of: sourceVideo, at: .zero)
      videoTrack.preferredTransform = try await sourceVideo.load(.preferredTransform)
      if FileManager.default.fileExists(atPath: audioURL.path) {
        let audio = AVURLAsset(url: audioURL)
        let audioTracks = try await audio.loadTracks(withMediaType: .audio)
        if let sourceAudio = audioTracks.first,
          let audioTrack = composition.addMutableTrack(
            withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        {
          let audioDuration = try await audio.load(.duration)
          try audioTrack.insertTimeRange(
            CMTimeRange(start: .zero, duration: CMTimeMinimum(duration, audioDuration)),
            of: sourceAudio, at: .zero)
        }
      }
      try Task.checkCancellation()
      player = AVPlayer(playerItem: AVPlayerItem(asset: composition))
    } catch is CancellationError {
      return
    } catch {
      errorMessage =
        "This recording could not be opened. Use Reveal in Finder to inspect the saved files."
    }
  }
}

extension String {
  fileprivate var nilIfBlank: String? {
    let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}
