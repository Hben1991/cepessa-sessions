import AppKit
import SwiftUI

/// CLIPS is a two-pane document browser, not a dashboard: a list of recordings
/// on the left, the selected clip's handoff details on the right, and one
/// recorder bar pinned under the list. Everything else the old layout carried
/// — the gradient, the 30pt headings, the dark 360pt hero placeholder — was
/// decoration around three controls that already explain themselves.
struct LocalClipsPage: View {
  @StateObject private var model = CepessaSessionsStore.shared.clipModel
  @ObservedObject private var sessionModel = CepessaSessionsStore.shared.model

  var body: some View {
    NavigationSplitView {
      sidebar
        .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
    } detail: {
      detail
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

        if status != .ready {
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
        HStack(spacing: CepessaChrome.Space.s) {
          TextField("Clip title", text: $model.titleDraft)
            .textFieldStyle(.roundedBorder)
            .disabled(model.isRecording)

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
              model.isRecording ? "Stop" : "Record",
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

        TextField("Agent focus (optional)", text: $model.intentDraft)
          .textFieldStyle(.roundedBorder)
          .disabled(model.isRecording)
          .accessibilityLabel("Agent focus")
      }
      .padding(.horizontal, CepessaChrome.Space.m)

      if let blocker = recorderBlockerMessage {
        Label(blocker, systemImage: "exclamationmark.triangle.fill")
          .labelStyle(.titleAndIcon)
          .font(.caption)
          .foregroundStyle(CepessaColors.textSecondary)
          .lineLimit(2)
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
    sessionModel.isRecording || sessionModel.isTranscribing
  }

  private var isRecordBlocked: Bool {
    !model.isRecording && (isSessionBusy || !hasScreenRecordingAccess)
  }

  /// A clip is a screen recording; without that permission the capture would
  /// start and immediately produce an empty file. Saying so up front is more
  /// honest than letting it fail.
  private var hasScreenRecordingAccess: Bool {
    CGPreflightScreenCaptureAccess()
  }

  private var recorderBlockerMessage: String? {
    guard !model.isRecording else { return nil }
    if isSessionBusy {
      return "Finish the active session recording or transcription before starting a clip."
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
            CepessaStatusLabel(
              style: CepessaStatusStyle.resolve(clip.status),
              detail: clip.errorMessage,
              font: .body
            )
            .multilineTextAlignment(.trailing)
          }
          LabeledContent(
            "Transcript",
            value: clip.transcriptSegments.isEmpty
              ? "Not available"
              : "\(clip.transcriptSegments.count) segments"
          )
          LabeledContent("Clip ID") {
            Text(clip.id.uuidString)
              .font(.caption.monospaced())
              .textSelection(.enabled)
          }
        } header: {
          Text(clip.title)
        }

        Section("Notes") {
          TextField("Agent focus", text: $model.intentDraft)
            .accessibilityLabel("What the agent should understand from this clip")

          TextEditor(text: $model.postNotesDraft)
            .font(.body)
            .frame(minHeight: 96)
            .accessibilityLabel("Post-recording notes")

          Button("Save Context") { model.saveSelectedNotes() }
        }

        // Only shown when there is a transcript to show. This is the clip's
        // own recorded text, read-only — the editable fields stay in Notes.
        if !clip.transcriptSegments.isEmpty {
          Section("Transcript") {
            Text(clip.transcriptText)
              .font(.callout)
              .foregroundStyle(CepessaColors.textPrimary)
              .textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading)
              .accessibilityLabel("Clip transcript")
          }
        }

        Section {
          Button {
            model.copyAgentPrompt(for: clip.id)
          } label: {
            Label("Copy Agent Prompt", systemImage: "doc.on.doc")
          }

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
          Text("The prompt points an agent at this clip's video and transcript through MCP.")
        }
      }
      .formStyle(.grouped)
    } else {
      ContentUnavailableView {
        Label("No Clip Selected", systemImage: "shippingbox")
      } description: {
        Text("Select a clip to copy its agent prompt.")
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
}

extension String {
  fileprivate var nilIfBlank: String? {
    let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}
