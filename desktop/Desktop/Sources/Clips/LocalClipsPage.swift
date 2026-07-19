import AppKit
import SwiftUI

struct LocalClipsPage: View {
  @StateObject private var model = LocalClipViewModel()
  @State private var hoverClipID: LocalClipManifest.ID?
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    ZStack {
      LinearGradient(
        colors: [
          CepessaColors.paperRaised,
          CepessaColors.paper,
          CepessaColors.paperDeep.opacity(0.72),
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )
      .ignoresSafeArea()

      HStack(spacing: 18) {
        clipList
        clipComposer
        clipInspector
      }
      .padding(20)
    }
  }

  private var clipList: some View {
    VStack(alignment: .leading, spacing: 18) {
      VStack(alignment: .leading, spacing: 8) {
        Text("CLIPS")
          .scaledFont(size: 11, weight: .semibold)
          .tracking(0.18)
          .foregroundStyle(CepessaColors.textSecondary)

        Text("Visual handoffs")
          .scaledFont(size: 30, weight: .semibold)
          .foregroundStyle(CepessaColors.textPrimary)

        Text("Record the screen, speak over it, then copy a prompt that tells an agent how to inspect the video and transcript through MCP.")
          .scaledFont(size: 13)
          .foregroundStyle(CepessaColors.textSecondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      if model.clips.isEmpty {
        emptyClipList
      } else {
        ScrollView {
          LazyVStack(spacing: 10) {
            ForEach(model.clips) { clip in
              clipRow(clip)
            }
          }
          .padding(.trailing, 4)
        }
        .scrollIndicators(.hidden)
      }
    }
    .padding(22)
    .frame(minWidth: 300, idealWidth: 340, maxWidth: 370, maxHeight: .infinity, alignment: .top)
    .cepessaCanvas(radius: 22)
  }

  private var clipComposer: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack(alignment: .center, spacing: 12) {
        VStack(alignment: .leading, spacing: 6) {
          Text(model.isRecording ? "Recording CLIP" : "New CLIP")
            .scaledFont(size: 24, weight: .semibold)
            .foregroundStyle(CepessaColors.textPrimary)

          Text(model.statusMessage ?? "Use CLIPS when a transcript is not enough and the agent needs to see what changed.")
            .scaledFont(size: 13)
            .foregroundStyle(CepessaColors.textSecondary)
            .lineLimit(2)
        }

        Spacer(minLength: 0)

        Text(model.recordingDurationText)
          .scaledFont(size: 16, weight: .semibold, design: .monospaced)
          .foregroundStyle(model.isRecording ? CepessaColors.error : CepessaColors.textSecondary)
          .padding(.horizontal, 12)
          .padding(.vertical, 8)
          .background(CepessaColors.backgroundSecondary.opacity(0.82))
          .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
      }

      HStack(spacing: 10) {
        TextField("CLIP title", text: $model.titleDraft)
          .textFieldStyle(.plain)
          .padding(.horizontal, 12)
          .frame(height: 38)
          .background(CepessaColors.backgroundSecondary.opacity(0.86))
          .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

        Button {
          model.isRecording ? model.stopClip() : model.startClip()
        } label: {
          Label(
            model.isRecording ? "Stop CLIP" : "Record CLIP",
            systemImage: model.isRecording ? "stop.circle.fill" : "record.circle.fill"
          )
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .tint(model.isRecording ? CepessaColors.error : CepessaColors.capture)
      }

      TextField("What should the agent understand from this?", text: $model.intentDraft)
        .textFieldStyle(.plain)
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(CepessaColors.backgroundSecondary.opacity(0.86))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

      recordingPreview

      HStack(spacing: 8) {
        Label("Screen video", systemImage: "display")
        Label("Mic + system audio", systemImage: "waveform")
        Label("Transcript", systemImage: "text.quote")
        Label("Post notes", systemImage: "note.text")
      }
      .scaledFont(size: 11, weight: .medium)
      .foregroundStyle(CepessaColors.textSecondary)
    }
    .padding(22)
    .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .cepessaCanvas(radius: 22)
  }

  private var clipInspector: some View {
    VStack(alignment: .leading, spacing: 16) {
      if let clip = model.selectedClip {
        Text("Agent prompt")
          .scaledFont(size: 24, weight: .semibold)
          .foregroundStyle(CepessaColors.textPrimary)

        Button {
          model.copyAgentPrompt(for: clip.id)
        } label: {
          Label("Copy agent prompt", systemImage: "doc.on.doc")
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)

        if let clipboardMessage = model.clipboardMessage {
          Text(clipboardMessage)
            .scaledFont(size: 11, weight: .semibold)
            .foregroundStyle(CepessaColors.success)
        }

        packetRow("MCP clip id", detail: clip.id.uuidString, symbol: "server.rack")
        packetRow("clip-video.mov", detail: "Screen recording path is included in the prompt", symbol: "play.rectangle")
        packetRow("transcript.json", detail: "\(clip.transcriptSegments.count) transcript segments", symbol: "text.quote")
        packetRow("notes.md", detail: "Optional post-recording context", symbol: "note.text")

        VStack(alignment: .leading, spacing: 8) {
          Text("Post notes")
            .scaledFont(size: 13, weight: .semibold)
            .foregroundStyle(CepessaColors.textPrimary)

          TextEditor(text: $model.postNotesDraft)
            .font(.system(size: 13))
            .scrollContentBackground(.hidden)
            .frame(minHeight: 112)
            .padding(8)
            .background(CepessaColors.backgroundSecondary.opacity(0.8))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

          HStack {
            Button("Save notes") {
              model.saveSelectedNotes()
            }
            .buttonStyle(.bordered)

            Button {
              if let url = model.clipDirectoryURL(for: clip.id) {
                NSWorkspace.shared.activateFileViewerSelecting([url])
              }
            } label: {
              Label("Reveal", systemImage: "folder")
            }
            .buttonStyle(.bordered)
          }
        }

        Text("MCP: get_local_clip(\(clip.id.uuidString))")
          .scaledFont(size: 11, weight: .semibold, design: .monospaced)
          .foregroundStyle(CepessaColors.textSecondary)
          .lineLimit(2)
      } else {
        emptyInspector
      }
    }
    .padding(22)
    .frame(minWidth: 320, idealWidth: 360, maxWidth: 400, maxHeight: .infinity, alignment: .top)
    .cepessaCanvas(radius: 22)
  }

  private var recordingPreview: some View {
    ZStack {
      RoundedRectangle(cornerRadius: 18, style: .continuous)
        .fill(CepessaColors.captureDeep.opacity(0.94))

      VStack(spacing: 8) {
        Image(systemName: model.isRecording ? "record.circle.fill" : "display.and.arrow.down")
          .scaledFont(size: 34, weight: .semibold)
        Text(model.isRecording ? "Screen recording in progress" : "Screen handoff recorder")
          .scaledFont(size: 18, weight: .semibold)
        Text("After recording, copy a prompt that points the agent to this CLIP through MCP.")
          .scaledFont(size: 13)
          .multilineTextAlignment(.center)
          .frame(maxWidth: 430)
      }
      .foregroundStyle(Color.white.opacity(0.88))
    }
    .frame(minHeight: 360)
    .overlay(
      RoundedRectangle(cornerRadius: 18, style: .continuous)
        .stroke(CepessaColors.border.opacity(0.25), lineWidth: 1)
    )
  }

  private func clipRow(_ clip: LocalClipManifest) -> some View {
    let isSelected = model.selectedClipID == clip.id
    return VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text(clip.title)
          .scaledFont(size: 14, weight: .semibold)
          .foregroundStyle(CepessaColors.textPrimary)
          .lineLimit(1)

        Spacer()

        Text(clip.status.rawValue.uppercased())
          .scaledFont(size: 9, weight: .bold)
          .foregroundStyle(clip.status == .ready ? CepessaColors.backgroundPrimary : Color.white)
          .padding(.horizontal, 8)
          .padding(.vertical, 4)
          .background(clip.status == .ready ? CepessaColors.success : CepessaColors.capture)
          .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
      }

      Text(clip.intent ?? clip.transcriptText.nilIfBlank ?? "No transcript yet")
        .scaledFont(size: 12)
        .foregroundStyle(CepessaColors.textSecondary)
        .lineLimit(2)

      Text(clip.startedAt.formatted(date: .abbreviated, time: .shortened))
        .scaledFont(size: 11)
        .foregroundStyle(CepessaColors.textTertiary)
    }
    .padding(14)
    .background(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(isSelected ? CepessaColors.capture.opacity(0.13) : CepessaColors.backgroundSecondary.opacity(0.74))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .stroke(isSelected ? CepessaColors.capture.opacity(0.34) : CepessaColors.border.opacity(0.22), lineWidth: 1)
    )
    .scaleEffect(hoverClipID == clip.id && !isSelected && !reduceMotion ? 1.006 : 1)
    .onTapGesture {
      model.selectClip(clip.id)
    }
    .onHover { isInside in
      hoverClipID = isInside ? clip.id : nil
    }
  }

  private func packetRow(_ title: String, detail: String, symbol: String) -> some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: symbol)
        .scaledFont(size: 15, weight: .semibold)
        .foregroundStyle(CepessaColors.capture)
        .frame(width: 22)
      VStack(alignment: .leading, spacing: 3) {
        Text(title)
          .scaledFont(size: 13, weight: .semibold)
          .foregroundStyle(CepessaColors.textPrimary)
        Text(detail)
          .scaledFont(size: 11)
          .foregroundStyle(CepessaColors.textSecondary)
      }
      Spacer(minLength: 0)
    }
    .padding(12)
    .background(CepessaColors.backgroundSecondary.opacity(0.72))
    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
  }

  private var emptyClipList: some View {
    VStack(spacing: 10) {
      Image(systemName: "video.badge.plus")
        .scaledFont(size: 30)
        .foregroundStyle(CepessaColors.textTertiary)
      Text("No CLIPS yet")
        .scaledFont(size: 15, weight: .semibold)
      Text("Record the screen, narrate, and add post notes for agent handoffs.")
        .scaledFont(size: 12)
        .foregroundStyle(CepessaColors.textSecondary)
        .multilineTextAlignment(.center)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var emptyInspector: some View {
    VStack(spacing: 10) {
      Image(systemName: "shippingbox")
        .scaledFont(size: 30)
        .foregroundStyle(CepessaColors.textTertiary)
      Text("No CLIP selected")
        .scaledFont(size: 15, weight: .semibold)
      Text("Select or record a CLIP to copy the agent prompt.")
        .scaledFont(size: 12)
        .foregroundStyle(CepessaColors.textSecondary)
        .multilineTextAlignment(.center)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

private extension String {
  var nilIfBlank: String? {
    let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}
