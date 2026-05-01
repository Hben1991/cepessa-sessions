import AVFoundation
import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct CepessaSessionsHomePage: View {
  var body: some View {
    CepessaSessionsWorkspaceView()
  }
}

struct CepessaSessionsLibraryPage: View {
  @ObservedObject private var model = CepessaSessionsStore.shared.model
  @State private var searchText = ""
  @State private var hoveredSessionID: LocalMeetingSession.ID?
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private var filteredSessions: [LocalMeetingSession] {
    let normalized = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else { return model.sessions }

    return model.sessions.filter { session in
      session.displayTitle.localizedCaseInsensitiveContains(normalized)
        || session.transcriptText.localizedCaseInsensitiveContains(normalized)
        || session.attachments.contains(where: {
          $0.title.localizedCaseInsensitiveContains(normalized)
        })
    }
  }

  var body: some View {
    ZStack {
      LinearGradient(
        colors: [
          CepessaColors.paperRaised,
          CepessaColors.paper,
          CepessaColors.paperDeep.opacity(0.68),
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )
      .ignoresSafeArea()

      HStack(spacing: 18) {
        VStack(alignment: .leading, spacing: 18) {
          VStack(alignment: .leading, spacing: 10) {
            Text("Cepessa Sessions")
              .scaledFont(size: 11, weight: .semibold)
              .tracking(0.18)
              .foregroundStyle(CepessaColors.textSecondary)

            Text("Library")
              .scaledFont(size: 30, weight: .semibold)
              .foregroundStyle(CepessaColors.textPrimary)

            Text(
              "Search every local session, revisit transcripts, and reopen recap context on this Mac."
            )
            .scaledFont(size: 13)
            .foregroundStyle(CepessaColors.textSecondary)
          }

          HStack(spacing: 8) {
            infoPill("Local only")
            infoPill("Mixed-language transcripts")
            infoPill("Attachments preserved")
          }

          HStack(spacing: 12) {
            HStack(spacing: 10) {
              Image(systemName: "magnifyingglass")
                .foregroundStyle(CepessaColors.textSecondary)
              TextField("Search sessions, transcripts, or artifact titles", text: $searchText)
                .textFieldStyle(.plain)
                .foregroundStyle(CepessaColors.textPrimary)
                .accessibilityLabel("Search library")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(CepessaColors.backgroundSecondary.opacity(0.86))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
              RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(CepessaColors.border.opacity(0.24), lineWidth: 1)
            )

            Text(
              "\(filteredSessions.count) \(filteredSessions.count == 1 ? "session" : "sessions")"
            )
            .scaledFont(size: 12, weight: .semibold)
            .foregroundStyle(CepessaColors.textSecondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(CepessaColors.backgroundSecondary.opacity(0.72))
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

            Button {
              importRecording()
            } label: {
              Label("Audio file", systemImage: "waveform.badge.plus")
            }
            .buttonStyle(.bordered)
            .help("Choose an existing audio file and transcribe it locally.")
          }

          if filteredSessions.isEmpty {
            emptyState
          } else {
            ScrollView {
              LazyVStack(spacing: 12) {
                ForEach(filteredSessions) { session in
                  libraryRow(
                    session: session,
                    isSelected: model.selectedSessionID == session.id,
                    isHovered: hoveredSessionID == session.id
                  )
                }
              }
              .padding(.trailing, 6)
            }
            .scrollIndicators(.hidden)
          }
        }
        .padding(22)
        .frame(minWidth: 360, idealWidth: 420, maxWidth: 440, maxHeight: .infinity, alignment: .top)
        .cepessaCanvas(radius: 22)

        CepessaLibraryDetailPane(model: model, session: model.selectedSession)
      }
      .padding(20)
    }
    .onAppear {
      CepessaSessionFloatingBarController.shared.connect(model: model)
    }
  }

  private func libraryRow(session: LocalMeetingSession, isSelected: Bool, isHovered: Bool)
    -> some View
  {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .top, spacing: 10) {
        VStack(alignment: .leading, spacing: 4) {
          Text(session.displayTitle)
            .scaledFont(size: 15, weight: .semibold)
            .foregroundStyle(CepessaColors.textPrimary)
            .lineLimit(2)

          Text(session.startedAt.formatted(date: .abbreviated, time: .shortened))
            .scaledFont(size: 11)
            .foregroundStyle(CepessaColors.textSecondary)
        }

        Spacer(minLength: 0)

        sessionStatusBadge(displayStatus(for: session))
      }

      Text(previewText(for: session))
        .scaledFont(size: 12)
        .foregroundStyle(CepessaColors.textSecondary)
        .lineLimit(3)

      HStack(alignment: .center, spacing: 8) {
        infoPill(
          "\(session.segments.count) \(session.segments.count == 1 ? "segment" : "segments")")
        infoPill("\(timelineArtifactCount(for: session)) artifacts")
        infoPill(session.recap.sections.isEmpty ? "Recap pending" : "Structured recap")

        Spacer(minLength: 0)

        if model.canRetranscribe(session), isHovered || isSelected {
          retranscribeSessionButton(for: session)
        }
      }
    }
    .padding(17)
    .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    .background(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(
          isSelected
            ? CepessaColors.capture.opacity(0.14) : CepessaColors.backgroundSecondary.opacity(0.76))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .stroke(
          isSelected ? CepessaColors.capture.opacity(0.28) : CepessaColors.border.opacity(0.22),
          lineWidth: 1)
    )
    .shadow(
      color: Color.black.opacity(isSelected ? 0.03 : 0.0), radius: isSelected ? 3 : 0,
      y: isSelected ? 1 : 0
    )
    .scaleEffect(isHovered && !isSelected && !reduceMotion ? 1.006 : 1)
    .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: isHovered)
    .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: isSelected)
    .onTapGesture {
      model.selectSession(id: session.id)
    }
    .onHover { isInside in
      hoveredSessionID = isInside ? session.id : nil
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(session.displayTitle), \(displayStatus(for: session).label)")
    .accessibilityHint("Opens this session details.")
    .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    .accessibilityAction {
      model.selectSession(id: session.id)
    }
  }

  private func sessionStatusBadge(_ status: LocalMeetingSessionStatus) -> some View {
    Text(status.label)
      .scaledFont(size: 10, weight: .semibold)
      .foregroundStyle(status == .ready ? CepessaColors.backgroundPrimary : Color.white)
      .padding(.horizontal, 9)
      .padding(.vertical, 5)
      .background(status.badgeColor)
      .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
  }

  private func infoPill(_ text: String) -> some View {
    Text(text)
      .scaledFont(size: 10, weight: .medium)
      .foregroundStyle(CepessaColors.textSecondary)
      .padding(.horizontal, 10)
      .padding(.vertical, 6)
      .background(CepessaColors.backgroundSecondary.opacity(0.72))
      .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
  }

  private func previewText(for session: LocalMeetingSession) -> String {
    let recap = session.recap.overview.trimmingCharacters(in: .whitespacesAndNewlines)
    if !recap.isEmpty { return recap }

    let transcript = session.transcriptText.trimmingCharacters(in: .whitespacesAndNewlines)
    if !transcript.isEmpty { return transcript }

    if session.attachments.isEmpty, session.captureArtifacts.isEmpty {
      return "No transcript or artifacts yet."
    }

    return "Artifacts captured in this session will appear here once processing finishes."
  }

  private func timelineArtifactCount(for session: LocalMeetingSession) -> Int {
    session.attachments.count + session.captureArtifacts.count
  }

  private func displayStatus(for session: LocalMeetingSession) -> LocalMeetingSessionStatus {
    if model.processingSnapshot(for: session.id) != nil {
      return .transcribing
    }

    if model.isGeneratingRecap(for: session.id) {
      return .transcribing
    }

    return session.status
  }

  private func importRecording() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.allowedContentTypes = [.audio]
    panel.prompt = "Transcribe"
    panel.message = "Choose an audio file to normalize locally and transcribe on this Mac."

    guard panel.runModal() == .OK, let url = panel.url else { return }
    Task {
      await model.importExistingRecording(from: url)
    }
  }

  @ViewBuilder
  private func retranscribeSessionButton(for session: LocalMeetingSession) -> some View {
    Button {
      model.retranscribeSession(id: session.id)
    } label: {
      Label(
        session.transcriptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          ? "Transcribe"
          : "Retranscribe",
        systemImage: session.transcriptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          ? "waveform.badge.magnifyingglass"
          : "arrow.trianglehead.clockwise"
      )
    }
    .buttonStyle(.bordered)
    .controlSize(.small)
    .help("Run transcription again from the saved audio for this session.")
  }

  private var emptyState: some View {
    VStack(spacing: 12) {
      Image(systemName: "magnifyingglass.circle")
        .scaledFont(size: 28)
        .foregroundStyle(CepessaColors.textTertiary)

      Text("No sessions match this search")
        .scaledFont(size: 16, weight: .semibold)
        .foregroundStyle(CepessaColors.textPrimary)

      Text("Try a transcript phrase, attachment title, or recap keyword.")
        .scaledFont(size: 12)
        .foregroundStyle(CepessaColors.textSecondary)
        .multilineTextAlignment(.center)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(24)
    .background(CepessaColors.backgroundSecondary.opacity(0.80))
    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .stroke(CepessaColors.border.opacity(0.2), lineWidth: 1)
    )
  }
}

private struct CepessaLibraryDetailPane: View {
  @ObservedObject var model: LocalMeetingAppModel
  let session: LocalMeetingSession?
  @State private var documentChatDraft = ""
  @State private var isDocumentChatOpen = false
  @AppStorage("cepessa.sessions.documentLanguage") private var documentLanguage =
    LocalSessionDocumentLanguage.english.rawValue
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    Group {
      if let session {
        ZStack(alignment: .bottom) {
          ScrollView {
            VStack(alignment: .leading, spacing: 18) {
              VStack(alignment: .leading, spacing: 8) {
                Text("Selected session")
                  .scaledFont(size: 11, weight: .semibold)
                  .tracking(0.18)
                  .foregroundStyle(CepessaColors.textSecondary)

                Text(session.displayTitle)
                  .scaledFont(size: 28, weight: .semibold)
                  .foregroundStyle(CepessaColors.textPrimary)
                  .lineLimit(2)

                Text(session.startedAt.formatted(date: .complete, time: .shortened))
                  .scaledFont(size: 12)
                  .foregroundStyle(CepessaColors.textSecondary)
              }

              HStack(spacing: 8) {
                infoPill(session.status.label)
                infoPill(
                  "\(session.segments.count) \(session.segments.count == 1 ? "segment" : "segments")"
                )
                infoPill("\(session.attachments.count + session.captureArtifacts.count) artifacts")
                infoPill(session.recap.sections.isEmpty ? "Recap pending" : "Structured recap")
              }

              detailBlock(
                "Markdown recap",
                subtitle:
                  "Read the generated document and use the local model to propose structured edits before anything is saved."
              ) {
                LocalSessionRecapWorkspace(
                  session: session,
                  language: selectedDocumentLanguage,
                  languageSelection: $documentLanguage,
                  isRegenerating: model.isGeneratingRecap(for: session.id),
                  onRegenerate: {
                    model.regenerateRecap(for: session.id)
                  }
                )
              }

              detailBlock(
                "Transcript",
                subtitle:
                  "The transcript keeps the original flow of the session, including mixed Hebrew and English."
              ) {
                if session.transcriptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                  Text("Transcript not available yet.")
                    .scaledFont(size: 13)
                    .foregroundStyle(CepessaColors.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(CepessaColors.backgroundSecondary.opacity(0.82))
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                } else {
                  LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(session.segments) { segment in
                      VStack(alignment: .leading, spacing: 5) {
                        Text(segment.timestamp.formatted(date: .omitted, time: .shortened))
                          .scaledFont(size: 10.5, weight: .semibold)
                          .foregroundStyle(CepessaColors.textTertiary)

                        Text(segment.text)
                          .scaledFont(size: 13)
                          .foregroundStyle(CepessaColors.textSecondary)
                          .textSelection(.enabled)
                          .frame(maxWidth: .infinity, alignment: .leading)
                      }
                      .padding(12)
                      .frame(maxWidth: .infinity, alignment: .leading)
                      .background(CepessaColors.backgroundSecondary.opacity(0.82))
                      .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                  }
                }
              }

              detailBlock(
                "Context timeline",
                subtitle:
                  "Screenshots, documents, and captures stay pinned to the exact session moment."
              ) {
                if session.attachments.isEmpty && session.captureArtifacts.isEmpty {
                  Text(
                    "Screenshots, clips, and documents captured during the session will appear here with exact timestamps."
                  )
                  .scaledFont(size: 13)
                  .foregroundStyle(CepessaColors.textSecondary)
                  .frame(maxWidth: .infinity, alignment: .leading)
                  .padding(14)
                  .background(CepessaColors.backgroundSecondary.opacity(0.82))
                  .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                } else {
                  VStack(alignment: .leading, spacing: 10) {
                    if !session.attachments.isEmpty {
                      Text("Attachments")
                        .scaledFont(size: 12, weight: .semibold)
                        .foregroundStyle(CepessaColors.textPrimary)

                      VStack(spacing: 8) {
                        ForEach(session.attachments) { attachment in
                          artifactRow(
                            icon: icon(for: attachment.kind),
                            tint: tint(for: attachment.kind),
                            title: attachment.title,
                            subtitle: artifactSubtitle(for: attachment)
                          )
                        }
                      }
                    }

                    if !session.captureArtifacts.isEmpty {
                      Text("Captured context")
                        .scaledFont(size: 12, weight: .semibold)
                        .foregroundStyle(CepessaColors.textPrimary)

                      VStack(spacing: 8) {
                        ForEach(session.captureArtifacts) { artifact in
                          artifactRow(
                            icon: icon(for: artifact.kind),
                            tint: tint(for: artifact.kind),
                            title: artifact.title,
                            subtitle: artifactSubtitle(for: artifact)
                          )
                        }
                      }
                    }
                  }
                }
              }
            }
            .padding(24)
            .padding(.bottom, isDocumentChatOpen ? 220 : 76)
          }

          if isDocumentChatOpen {
            CepessaSessionDocumentChatView(
              model: model,
              session: session,
              draftText: $documentChatDraft,
              onClose: {
                withAnimation(.easeOut(duration: 0.18)) {
                  isDocumentChatOpen = false
                }
              }
            )
            .id(session.id)
            .frame(minWidth: 440, idealWidth: 620, maxWidth: 760)
            .padding(.horizontal, 34)
            .padding(.bottom, 18)
            .transition(.opacity.combined(with: .offset(y: reduceMotion ? 0 : 10)))
          } else {
            openChatButton
              .padding(.horizontal, 34)
              .padding(.bottom, 18)
              .transition(.opacity.combined(with: .offset(y: reduceMotion ? 0 : 8)))
          }
        }
      } else {
        VStack(spacing: 12) {
          Image(systemName: "sparkles.rectangle.stack")
            .scaledFont(size: 28)
            .foregroundStyle(CepessaColors.textTertiary)

          Text("Choose a session")
            .scaledFont(size: 16, weight: .semibold)
            .foregroundStyle(CepessaColors.textPrimary)

          Text("Transcript, recap, and artifact context appear here for the selected session.")
            .scaledFont(size: 12)
            .foregroundStyle(CepessaColors.textSecondary)
            .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .cepessaCanvas(radius: 24)
    .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: session?.id)
    .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: isDocumentChatOpen)
    .onChange(of: session?.id) { _, _ in
      documentChatDraft = ""
      isDocumentChatOpen = false
    }
  }

  private func detailBlock<Content: View>(
    _ title: String,
    subtitle: String? = nil,
    @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      VStack(alignment: .leading, spacing: 4) {
        Text(title)
          .scaledFont(size: 14, weight: .semibold)
          .foregroundStyle(CepessaColors.textPrimary)

        if let subtitle {
          Text(subtitle)
            .scaledFont(size: 12)
            .foregroundStyle(CepessaColors.textSecondary)
        }
      }

      content()
    }
  }

  private func infoPill(_ text: String) -> some View {
    Text(text)
      .scaledFont(size: 10, weight: .medium)
      .foregroundStyle(CepessaColors.textSecondary)
      .padding(.horizontal, 10)
      .padding(.vertical, 6)
      .background(CepessaColors.backgroundRaised.opacity(0.72))
      .clipShape(Capsule())
  }

  private func recapOverviewCard(_ text: String) -> some View {
    Text(text)
      .scaledFont(size: 13)
      .foregroundStyle(CepessaColors.textSecondary)
      .textSelection(.enabled)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(14)
      .background(
        LinearGradient(
          colors: [
            CepessaColors.backgroundSecondary.opacity(0.92),
            CepessaColors.backgroundRaised.opacity(0.9),
          ],
          startPoint: .topLeading,
          endPoint: .bottomTrailing
        )
      )
      .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: 18, style: .continuous)
          .stroke(CepessaColors.border.opacity(0.18), lineWidth: 1)
      )
  }

  private func recapSectionCard(_ section: LocalSessionRecapSection) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Circle()
          .fill(recapTint(for: section.kind).opacity(0.9))
          .frame(width: 8, height: 8)

        Text(section.title.isEmpty ? section.kind.displayTitle : section.title)
          .scaledFont(size: 13, weight: .semibold)
          .foregroundStyle(CepessaColors.textPrimary)
      }

      if !section.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        Text(section.summary)
          .scaledFont(size: 12)
          .foregroundStyle(CepessaColors.textSecondary)
          .frame(maxWidth: .infinity, alignment: .leading)
      }

      if !section.bullets.isEmpty {
        VStack(alignment: .leading, spacing: 7) {
          ForEach(section.bullets, id: \.self) { bullet in
            HStack(alignment: .top, spacing: 8) {
              RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(CepessaColors.textTertiary.opacity(0.65))
                .frame(width: 5, height: 5)
                .padding(.top, 6)

              Text(bullet)
                .scaledFont(size: 12)
                .foregroundStyle(CepessaColors.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
          }
        }
      }
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(CepessaColors.backgroundSecondary.opacity(0.82))
    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 18, style: .continuous)
        .stroke(CepessaColors.border.opacity(0.18), lineWidth: 1)
    )
  }

  private func artifactRow(icon: String, tint: Color, title: String, subtitle: String) -> some View
  {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: icon)
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(tint)
        .frame(width: 24, height: 24)
        .background(tint.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

      VStack(alignment: .leading, spacing: 3) {
        Text(title)
          .scaledFont(size: 12.5, weight: .semibold)
          .foregroundStyle(CepessaColors.textPrimary)

        Text(subtitle)
          .scaledFont(size: 11)
          .foregroundStyle(CepessaColors.textSecondary)
      }

      Spacer(minLength: 0)
    }
    .padding(12)
    .background(CepessaColors.backgroundSecondary.opacity(0.82))
    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 16, style: .continuous)
        .stroke(CepessaColors.border.opacity(0.16), lineWidth: 1)
    )
  }

  private func artifactSubtitle(for attachment: LocalSessionAttachment) -> String {
    let stamp = attachment.sessionOffset.map { Self.timeString(for: $0) } ?? "00:00"
    return "\(stamp) • \(attachment.source.displayName)"
  }

  private func artifactSubtitle(for artifact: LocalSessionCaptureArtifact) -> String {
    let stamp = artifact.sessionOffset.map { Self.timeString(for: $0) } ?? "00:00"
    let suffix = artifact.notes?.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let suffix, !suffix.isEmpty else {
      return "\(stamp) • Session capture"
    }
    return "\(stamp) • \(suffix)"
  }

  private func icon(for kind: LocalSessionAttachment.Kind) -> String {
    switch kind {
    case .file: return "doc.text"
    case .image: return "photo"
    case .audio: return "waveform"
    case .link: return "link"
    case .capture: return "rectangle.on.rectangle"
    }
  }

  private func icon(for kind: LocalSessionCaptureArtifact.Kind) -> String {
    switch kind {
    case .floatingBarCapture: return "dock.rectangle"
    case .screenCapture: return "display"
    case .clipboardCapture: return "clipboard"
    case .note: return "note.text"
    }
  }

  private func tint(for kind: LocalSessionAttachment.Kind) -> Color {
    switch kind {
    case .file: return CepessaColors.purplePrimary
    case .image: return CepessaColors.success
    case .audio: return CepessaColors.warning
    case .link: return CepessaColors.textPrimary
    case .capture: return CepessaColors.purplePrimary
    }
  }

  private func tint(for kind: LocalSessionCaptureArtifact.Kind) -> Color {
    switch kind {
    case .floatingBarCapture: return CepessaColors.purplePrimary
    case .screenCapture: return CepessaColors.success
    case .clipboardCapture: return CepessaColors.warning
    case .note: return CepessaColors.textPrimary
    }
  }

  private func recapTint(for kind: LocalSessionRecapSection.Kind) -> Color {
    switch kind {
    case .overview: return CepessaColors.purplePrimary
    case .keyPoints: return CepessaColors.success
    case .decisions: return CepessaColors.warning
    case .actionItem: return CepessaColors.error
    case .openQuestions: return CepessaColors.textTertiary
    case .nextSteps: return CepessaColors.success
    case .notes: return CepessaColors.textPrimary
    }
  }

  private static func timeString(for interval: TimeInterval) -> String {
    let totalSeconds = max(0, Int(interval.rounded()))
    return String(format: "%02d:%02d", totalSeconds / 60, totalSeconds % 60)
  }

  private var selectedDocumentLanguage: LocalSessionDocumentLanguage {
    LocalSessionDocumentLanguage(rawValue: documentLanguage) ?? .english
  }

  private var openChatButton: some View {
    HStack {
      Spacer(minLength: 0)

      Button {
        withAnimation(.easeOut(duration: 0.18)) {
          isDocumentChatOpen = true
        }
      } label: {
        Label("Ask this session", systemImage: "bubble.left.and.text.bubble.right")
          .scaledFont(size: 12, weight: .semibold)
          .foregroundStyle(CepessaColors.textPrimary)
          .padding(.horizontal, 14)
          .padding(.vertical, 10)
          .background(Color.white.opacity(0.86))
          .clipShape(Capsule())
          .overlay(
            Capsule()
              .stroke(CepessaColors.capture.opacity(0.22), lineWidth: 1)
          )
          .shadow(color: CepessaColors.warmShadow.opacity(0.10), radius: 14, x: 0, y: 8)
      }
      .buttonStyle(CepessaPressStyle(scale: 0.97, pressedBrightness: -0.02))
      .accessibilityLabel("Open session chat")
    }
  }
}

private struct LocalSessionRecapWorkspace: View {
  let session: LocalMeetingSession
  let language: LocalSessionDocumentLanguage
  @Binding var languageSelection: String
  let isRegenerating: Bool
  let onRegenerate: () -> Void

  private var hasRecap: Bool {
    !session.recap.overview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      || !session.recap.sections.isEmpty
  }

  var body: some View {
    recapSurface
      .frame(maxWidth: .infinity, alignment: .topLeading)
  }

  @ViewBuilder
  private var recapSurface: some View {
    if hasRecap {
      VStack(alignment: .trailing, spacing: 12) {
        HStack(spacing: 10) {
          regenerateRecapButton
          LocalSessionDocumentLanguageToggle(selection: $languageSelection)
        }

        if isRegenerating {
          HStack(spacing: 8) {
            ProgressView()
              .controlSize(.small)
              .scaleEffect(0.72)

            Text(
              "Rewriting the brief from the session material. If the model is slow, a local fallback will finish it."
            )
            .scaledFont(size: 12)
            .foregroundStyle(CepessaColors.textSecondary)

            Spacer(minLength: 0)
          }
          .padding(.horizontal, 12)
          .padding(.vertical, 10)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(CepessaColors.capture.opacity(0.08))
          .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
          .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
              .stroke(CepessaColors.capture.opacity(0.18), lineWidth: 1)
          )
        }

        LocalSessionMarkdownDocumentPreview(
          markdown: LocalSessionRecapMarkdownDocument.markdown(
            for: session,
            language: language,
            includeTranscript: false
          ),
          language: language
        )
      }
    } else {
      Text("Recap is still being prepared.")
        .scaledFont(size: 13)
        .foregroundStyle(CepessaColors.textSecondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(CepessaColors.backgroundSecondary.opacity(0.82))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
  }

  private var regenerateRecapButton: some View {
    Button(action: onRegenerate) {
      Label(isRegenerating ? "Refreshing" : "Rewrite brief", systemImage: "arrow.clockwise")
        .scaledFont(size: 12, weight: .semibold)
    }
    .buttonStyle(.bordered)
    .controlSize(.small)
    .disabled(
      isRegenerating
        || session.transcriptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    )
    .help("Read the transcript again and create a new recap.")
  }
}

struct LocalSessionMarkdownDocumentPreview: View, Equatable {
  let markdown: String
  let language: LocalSessionDocumentLanguage
  private let markdownBlocks: [LocalSessionMarkdownBlock]

  init(markdown: String, language: LocalSessionDocumentLanguage = .english) {
    self.markdown = markdown
    self.language = language
    self.markdownBlocks = Self.blocks(from: markdown)
  }

  static func == (
    lhs: LocalSessionMarkdownDocumentPreview, rhs: LocalSessionMarkdownDocumentPreview
  )
    -> Bool
  {
    lhs.markdown == rhs.markdown && lhs.language == rhs.language
  }

  var body: some View {
    VStack(alignment: .center, spacing: 0) {
      VStack(alignment: .leading, spacing: 20) {
        ForEach(Array(markdownBlocks.enumerated()), id: \.offset) { _, block in
          renderedBlock(block)
        }
      }
      .padding(.horizontal, 56)
      .padding(.top, 40)
      .padding(.bottom, 70)
      .frame(maxWidth: 780, alignment: .topLeading)
      .environment(
        \.layoutDirection,
        language == .hebrew ? .rightToLeft : .leftToRight
      )
    }
    .frame(maxWidth: .infinity, alignment: .center)
  }

  @ViewBuilder
  private func renderedBlock(_ block: LocalSessionMarkdownBlock) -> some View {
    switch block {
    case .heading(let level, let text):
      Text(inlineMarkdown(text))
        .scaledFont(size: headingSize(for: level), weight: .semibold)
        .tracking(level == 1 ? -0.5 : -0.25)
        .foregroundStyle(CepessaColors.textPrimary.opacity(level == 1 ? 0.98 : 0.92))
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, level == 1 ? 0 : 10)

    case .paragraph(let text):
      Text(inlineMarkdown(text))
        .scaledFont(size: 15)
        .lineSpacing(5)
        .foregroundStyle(CepessaColors.textPrimary.opacity(0.82))
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)

    case .unorderedList(let items):
      VStack(alignment: .leading, spacing: 9) {
        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
          HStack(alignment: .firstTextBaseline, spacing: 11) {
            Circle()
              .fill(CepessaColors.purplePrimary.opacity(0.72))
              .frame(width: 5, height: 5)
            Text(inlineMarkdown(item))
              .scaledFont(size: 14.5)
              .lineSpacing(4)
              .foregroundStyle(CepessaColors.textPrimary.opacity(0.82))
              .textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
        }
      }

    case .orderedList(let items):
      VStack(alignment: .leading, spacing: 9) {
        ForEach(Array(items.enumerated()), id: \.offset) { index, item in
          HStack(alignment: .firstTextBaseline, spacing: 11) {
            Text("\(index + 1).")
              .scaledFont(size: 12.5, weight: .semibold, design: .rounded)
              .foregroundStyle(CepessaColors.purplePrimary)
              .frame(width: 26, alignment: .trailing)
            Text(inlineMarkdown(item))
              .scaledFont(size: 14.5)
              .lineSpacing(4)
              .foregroundStyle(CepessaColors.textPrimary.opacity(0.82))
              .textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
        }
      }

    case .quote(let text):
      Text(inlineMarkdown(text))
        .scaledFont(size: 14.5)
        .lineSpacing(4)
        .foregroundStyle(CepessaColors.textSecondary)
        .textSelection(.enabled)
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
          CepessaColors.purplePrimary.opacity(0.07),
          in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
        .overlay(alignment: .leading) {
          Capsule()
            .fill(CepessaColors.purplePrimary.opacity(0.65))
            .frame(width: 3)
            .padding(.vertical, 10)
        }

    case .code(let text):
      Text(text)
        .scaledFont(size: 12.5, design: .monospaced)
        .foregroundStyle(CepessaColors.textPrimary.opacity(0.86))
        .textSelection(.enabled)
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
          Color.black.opacity(0.045), in: RoundedRectangle(cornerRadius: 15, style: .continuous))

    case .rule:
      Rectangle()
        .fill(CepessaColors.border.opacity(0.5))
        .frame(height: 1)
        .padding(.vertical, 4)
    }
  }

  private func inlineMarkdown(_ text: String) -> AttributedString {
    (try? AttributedString(markdown: text)) ?? AttributedString(text)
  }

  private func headingSize(for level: Int) -> CGFloat {
    switch level {
    case 1: return 31
    case 2: return 22
    case 3: return 17
    default: return 15.5
    }
  }

  static func blocks(from markdown: String) -> [LocalSessionMarkdownBlock] {
    var blocks: [LocalSessionMarkdownBlock] = []
    var paragraph: [String] = []
    var unordered: [String] = []
    var ordered: [String] = []
    var quote: [String] = []
    var code: [String] = []
    var isInCode = false

    func flushParagraph() {
      guard !paragraph.isEmpty else { return }
      blocks.append(.paragraph(paragraph.joined(separator: " ")))
      paragraph.removeAll()
    }

    func flushUnordered() {
      guard !unordered.isEmpty else { return }
      blocks.append(.unorderedList(unordered))
      unordered.removeAll()
    }

    func flushOrdered() {
      guard !ordered.isEmpty else { return }
      blocks.append(.orderedList(ordered))
      ordered.removeAll()
    }

    func flushQuote() {
      guard !quote.isEmpty else { return }
      blocks.append(.quote(quote.joined(separator: "\n")))
      quote.removeAll()
    }

    func flushCode() {
      guard !code.isEmpty else { return }
      blocks.append(.code(code.joined(separator: "\n")))
      code.removeAll()
    }

    func flushAll() {
      flushParagraph()
      flushUnordered()
      flushOrdered()
      flushQuote()
    }

    for rawLine in markdown.replacingOccurrences(of: "\r\n", with: "\n").components(
      separatedBy: "\n")
    {
      let line = rawLine.trimmingCharacters(in: .whitespaces)

      if isInCode {
        if line.hasPrefix("```") {
          flushCode()
          isInCode = false
        } else {
          code.append(rawLine)
        }
        continue
      }

      if line.hasPrefix("```") {
        flushAll()
        isInCode = true
        continue
      }

      if line.isEmpty {
        flushAll()
        continue
      }

      if let heading = parseHeading(line) {
        flushAll()
        blocks.append(.heading(level: heading.level, text: heading.text))
        continue
      }

      if isHorizontalRule(line) {
        flushAll()
        blocks.append(.rule)
        continue
      }

      if let item = parseUnorderedItem(line) {
        flushParagraph()
        flushOrdered()
        flushQuote()
        unordered.append(item)
        continue
      } else {
        flushUnordered()
      }

      if let item = parseOrderedItem(line) {
        flushParagraph()
        flushUnordered()
        flushQuote()
        ordered.append(item)
        continue
      } else {
        flushOrdered()
      }

      if line.hasPrefix(">") {
        flushParagraph()
        flushUnordered()
        flushOrdered()
        quote.append(String(line.dropFirst()).trimmingCharacters(in: .whitespaces))
        continue
      } else {
        flushQuote()
      }

      paragraph.append(line)
    }

    if isInCode {
      flushCode()
    }
    flushAll()
    return blocks.isEmpty ? [.paragraph(markdown)] : blocks
  }

  private static func parseHeading(_ line: String) -> (level: Int, text: String)? {
    let prefix = line.prefix { $0 == "#" }
    guard !prefix.isEmpty, prefix.count <= 6 else { return nil }
    let remainder = line.dropFirst(prefix.count)
    guard remainder.first == " " else { return nil }
    return (prefix.count, String(remainder).trimmingCharacters(in: .whitespaces))
  }

  private static func parseUnorderedItem(_ line: String) -> String? {
    guard line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") else { return nil }
    return String(line.dropFirst(2))
  }

  private static func parseOrderedItem(_ line: String) -> String? {
    let digits = line.prefix { $0.isNumber }
    guard !digits.isEmpty else { return nil }
    let suffix = line.dropFirst(digits.count)
    guard suffix.hasPrefix(". ") else { return nil }
    return String(suffix.dropFirst(2))
  }

  private static func isHorizontalRule(_ line: String) -> Bool {
    let stripped = line.replacingOccurrences(of: " ", with: "")
    return stripped == "---" || stripped == "***" || stripped == "___"
  }
}

struct LocalSessionDocumentLanguageToggle: View {
  @Binding var selection: String

  private var selectedLanguage: LocalSessionDocumentLanguage {
    LocalSessionDocumentLanguage(rawValue: selection) ?? .english
  }

  var body: some View {
    HStack(spacing: 4) {
      ForEach(LocalSessionDocumentLanguage.allCases) { language in
        Button {
          selection = language.rawValue
        } label: {
          Text(language.displayTitle)
            .scaledFont(size: 12, weight: .semibold)
            .foregroundStyle(
              selectedLanguage == language ? CepessaColors.textPrimary : CepessaColors.textSecondary
            )
            .frame(minWidth: 74)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background {
              if selectedLanguage == language {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                  .fill(Color.white.opacity(0.84))
                  .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                      .stroke(CepessaColors.capture.opacity(0.22), lineWidth: 1)
                  )
              }
            }
        }
        .buttonStyle(CepessaPressStyle(scale: 0.97, pressedBrightness: -0.02))
        .accessibilityLabel("Show document in \(language.displayTitle)")
        .accessibilityAddTraits(selectedLanguage == language ? [.isSelected] : [])
      }
    }
    .padding(4)
    .background(CepessaColors.paperRaised.opacity(0.72))
    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .stroke(CepessaColors.border.opacity(0.16), lineWidth: 1)
    )
  }
}

private struct LocalSessionDocumentChatRail: View {
  @ObservedObject var model: LocalMeetingAppModel
  let session: LocalMeetingSession
  @State private var draft = ""
  @State private var showsProposalPreview = false

  private var chat: LocalSessionDocumentChat {
    model.sessions.first(where: { $0.id == session.id })?.documentChat ?? session.documentChat
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      headerView

      if let error = chat.errorMessage, chat.status == .failed {
        offlineState(error)
      }

      chatHistory

      if let proposal = chat.pendingProposal {
        pendingProposalCard(proposal)
      }

      composer
    }
    .padding(.horizontal, 18)
    .padding(.vertical, 14)
    .background {
      RoundedRectangle(cornerRadius: 28, style: .continuous)
        .fill(.ultraThinMaterial)
        .overlay(
          LinearGradient(
            colors: [
              Color.white.opacity(0.54),
              CepessaColors.backgroundSecondary.opacity(0.18),
              Color.white.opacity(0.22),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
          )
        )
        .overlay(
          RoundedRectangle(cornerRadius: 28, style: .continuous)
            .stroke(Color.white.opacity(0.64), lineWidth: 0.8)
            .blur(radius: 0.2)
            .padding(0.5)
        )
        .overlay(
          RoundedRectangle(cornerRadius: 28, style: .continuous)
            .stroke(CepessaColors.border.opacity(0.18), lineWidth: 1)
        )
    }
    .overlay(alignment: .topLeading) {
      Capsule()
        .fill(Color.white.opacity(0.42))
        .frame(width: 190, height: 1)
        .padding(.leading, 36)
        .padding(.top, 1)
    }
    .shadow(color: .white.opacity(0.55), radius: 1, x: 0, y: -1)
    .shadow(color: .black.opacity(0.075), radius: 28, x: 0, y: 14)
    .shadow(color: .black.opacity(0.035), radius: 8, x: 0, y: 2)
  }

  private var headerView: some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: "sparkle.magnifyingglass")
        .scaledFont(size: 13, weight: .semibold)
        .foregroundStyle(CepessaColors.purplePrimary)
        .frame(width: 30, height: 30)
        .background(
          .thinMaterial,
          in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay(
          RoundedRectangle(cornerRadius: 10, style: .continuous)
            .stroke(Color.white.opacity(0.48), lineWidth: 0.8)
        )

      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 8) {
          Text("Document chat")
            .scaledFont(size: 13, weight: .semibold)
            .foregroundStyle(CepessaColors.textPrimary)

          Text("Local model")
            .scaledFont(size: 9.5, weight: .semibold)
            .foregroundStyle(CepessaColors.purplePrimary)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(
              .thinMaterial,
              in: Capsule()
            )
            .overlay(
              Capsule()
                .stroke(CepessaColors.purplePrimary.opacity(0.14), lineWidth: 0.8)
            )
        }

        Text("Suggest edits, review the diff, then apply explicitly.")
          .scaledFont(size: 11)
          .foregroundStyle(CepessaColors.textSecondary)
      }

      Spacer(minLength: 0)

      if chat.undoSnapshot != nil {
        Button {
          model.undoLastDocumentChatEdit(for: session.id)
        } label: {
          Image(systemName: "arrow.uturn.backward")
            .scaledFont(size: 12, weight: .semibold)
            .frame(width: 30, height: 30)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Undo last document edit")
        .help("Undo last document edit")
      }
    }
  }

  @ViewBuilder
  private var chatHistory: some View {
    if chat.messages.isEmpty {
      emptyChatState
    } else {
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 10) {
          ForEach(chat.messages) { message in
            messageBubble(message)
          }
        }
        .padding(.vertical, 2)
      }
      .frame(minHeight: 72, maxHeight: 150)
      .scrollIndicators(.hidden)
    }
  }

  private var composer: some View {
    VStack(spacing: 10) {
      TextField(
        "Ask the local model to tighten the recap, rename speakers, or fix a line",
        text: $draft,
        axis: .vertical
      )
      .lineLimit(2...4)
      .textFieldStyle(.plain)
      .padding(12)
      .background(
        .thinMaterial,
        in: RoundedRectangle(cornerRadius: 16, style: .continuous)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 16, style: .continuous)
          .stroke(Color.white.opacity(0.42), lineWidth: 0.8)
      )
      .disabled(chat.status == .sending)

      HStack(alignment: .center, spacing: 10) {
        Text(chat.status == .sending ? "Local model is reading the document..." : "Local model")
          .scaledFont(size: 10)
          .foregroundStyle(CepessaColors.textTertiary)

        Spacer(minLength: 0)

        Button {
          model.sendDocumentChatMessage(draft, for: session.id)
          draft = ""
        } label: {
          if chat.status == .sending {
            HStack(spacing: 6) {
              ProgressView()
                .controlSize(.small)
              Text("Sending")
            }
          } else {
            Label("Send", systemImage: "arrow.up.circle.fill")
          }
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.regular)
        .frame(minHeight: 40)
        .disabled(
          draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || chat.status == .sending
        )
      }
    }
  }

  private var emptyChatState: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Start with a precise edit")
        .scaledFont(size: 11, weight: .semibold)
        .foregroundStyle(CepessaColors.textPrimary)

      HStack(spacing: 8) {
        suggestionButton("Make the overview sharper.")
        suggestionButton("Rename Speaker 1 to the client name.")
        suggestionButton("Fix the segment where I said launch gate, not lunch gate.")
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(12)
    .background(
      .thinMaterial,
      in: RoundedRectangle(cornerRadius: 16, style: .continuous)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 16, style: .continuous)
        .stroke(Color.white.opacity(0.36), lineWidth: 0.8)
    )
    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
  }

  private func suggestionButton(_ prompt: String) -> some View {
    Button {
      draft = prompt
    } label: {
      HStack(alignment: .center, spacing: 8) {
        Image(systemName: "arrow.turn.down.right")
          .scaledFont(size: 10, weight: .semibold)
          .foregroundStyle(CepessaColors.purplePrimary.opacity(0.82))
        Text("\"\(prompt)\"")
          .scaledFont(size: 11)
          .foregroundStyle(CepessaColors.textSecondary)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 9)
      .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
      .background(
        Color.white.opacity(0.22),
        in: RoundedRectangle(cornerRadius: 12, style: .continuous)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .stroke(Color.white.opacity(0.32), lineWidth: 0.7)
      )
      .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
    .buttonStyle(CepessaPressStyle(scale: 0.985))
    .disabled(chat.status == .sending)
  }

  private func offlineState(_ error: String) -> some View {
    HStack(alignment: .center, spacing: 8) {
      Label("Local model offline", systemImage: "wifi.slash")
        .scaledFont(size: 11, weight: .semibold)
        .foregroundStyle(CepessaColors.error)

      Text("Install the app model, then retry.")
        .scaledFont(size: 10.5)
        .foregroundStyle(CepessaColors.textSecondary)
        .lineLimit(1)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 7)
    .background(CepessaColors.error.opacity(0.055))
    .clipShape(Capsule())
    .help(error)
  }

  private func messageBubble(_ message: LocalSessionDocumentChatMessage) -> some View {
    let isUser = message.role == .user
    return HStack {
      if isUser {
        Spacer(minLength: 36)
      }

      VStack(alignment: isUser ? .trailing : .leading, spacing: 6) {
        Text(message.text)
          .scaledFont(size: 11.5)
          .foregroundStyle(isUser ? Color.white : CepessaColors.textPrimary)
          .textSelection(.enabled)
          .padding(.horizontal, 11)
          .padding(.vertical, 9)
          .background(
            isUser
              ? CepessaColors.purplePrimary.opacity(0.9)
              : CepessaColors.backgroundRaised.opacity(0.82),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
          )

        if !isUser, !message.sourceCitations.isEmpty {
          citationStrip(message.sourceCitations, limit: 2)
        }
      }
      .frame(maxWidth: 280, alignment: isUser ? .trailing : .leading)

      if !isUser {
        Spacer(minLength: 36)
      }
    }
    .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
  }

  private func pendingProposalCard(_ proposal: LocalSessionDocumentEditProposal) -> some View {
    VStack(alignment: .leading, spacing: 9) {
      Label("Pending proposal", systemImage: "doc.badge.gearshape")
        .scaledFont(size: 11, weight: .semibold)
        .foregroundStyle(CepessaColors.textPrimary)

      VStack(alignment: .leading, spacing: 5) {
        if proposal.recapPatch != nil {
          proposalLine("Recap edits ready")
        }
        if proposal.sessionTitle != nil {
          proposalLine("Title update ready")
        }
        if !proposal.transcriptPatches.isEmpty {
          proposalLine("\(proposal.transcriptPatches.count) targeted transcript correction(s)")
        }
        if !proposal.speakerRenames.isEmpty {
          proposalLine("\(proposal.speakerRenames.count) speaker rename(s)")
        }
        ForEach(proposal.warnings, id: \.self) { warning in
          proposalLine("Warning: \(warning)")
        }
      }

      if showsProposalPreview {
        proposalPreview(proposal)
      }

      if !proposal.sourceCitations.isEmpty {
        citationStrip(proposal.sourceCitations, limit: 3)
      }

      HStack(spacing: 8) {
        Button(showsProposalPreview ? "Hide preview" : "Preview changes") {
          showsProposalPreview.toggle()
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .frame(minHeight: 40)

        Button("Discard") {
          model.discardPendingDocumentChatProposal(for: session.id)
          showsProposalPreview = false
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .frame(minHeight: 40)

        Button("Apply") {
          model.applyPendingDocumentChatProposal(for: session.id)
          showsProposalPreview = false
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.regular)
        .frame(minHeight: 40)
      }
    }
    .padding(11)
    .background(CepessaColors.purplePrimary.opacity(0.08))
    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .stroke(CepessaColors.purplePrimary.opacity(0.18), lineWidth: 1)
    )
  }

  private func proposalLine(_ text: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 7) {
      Circle()
        .fill(CepessaColors.purplePrimary.opacity(0.7))
        .frame(width: 4, height: 4)
      Text(text)
        .scaledFont(size: 10.5)
        .foregroundStyle(CepessaColors.textSecondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private func proposalPreview(_ proposal: LocalSessionDocumentEditProposal) -> some View {
    VStack(alignment: .leading, spacing: 7) {
      if let overview = proposal.recapPatch?.overview,
        !overview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      {
        previewSection("Overview", overview)
      }

      ForEach(Array((proposal.recapPatch?.sections ?? []).enumerated()), id: \.offset) {
        _, section in
        previewSection(
          section.title.isEmpty ? section.kind.displayTitle : section.title, section.summary)
      }

      ForEach(proposal.transcriptPatches, id: \.segmentID) { patch in
        previewSection("Transcript \(patch.segmentID.uuidString.prefix(8))", patch.text)
      }

      ForEach(proposal.speakerRenames, id: \.oldName) { rename in
        previewSection("Speaker rename", "\(rename.oldName) -> \(rename.newName)")
      }
    }
    .padding(10)
    .background(CepessaColors.backgroundRaised.opacity(0.72))
    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
  }

  private func previewSection(_ title: String, _ body: String) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(title)
        .scaledFont(size: 10.5, weight: .semibold)
        .foregroundStyle(CepessaColors.textPrimary)
      Text(body.isEmpty ? "Replace section with empty body." : body)
        .scaledFont(size: 10.5)
        .foregroundStyle(CepessaColors.textSecondary)
        .lineLimit(4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private func citationStrip(
    _ citations: [LocalSessionDocumentSourceCitation],
    limit: Int
  ) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      ForEach(citations.prefix(limit)) { citation in
        HStack(alignment: .top, spacing: 6) {
          Image(systemName: "quote.opening")
            .scaledFont(size: 8.5, weight: .semibold)
            .foregroundStyle(CepessaColors.purplePrimary.opacity(0.8))
            .frame(width: 12, height: 12)

          VStack(alignment: .leading, spacing: 2) {
            Text(citation.title)
              .scaledFont(size: 9.5, weight: .semibold)
              .foregroundStyle(CepessaColors.textPrimary)
              .lineLimit(1)
            Text(citation.excerpt)
              .scaledFont(size: 9.5)
              .foregroundStyle(CepessaColors.textTertiary)
              .lineLimit(2)
          }
        }
      }
    }
    .padding(.horizontal, 9)
    .padding(.vertical, 7)
    .background(CepessaColors.backgroundRaised.opacity(0.58))
    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
  }
}

enum LocalSessionMarkdownBlock: Equatable {
  case heading(level: Int, text: String)
  case paragraph(String)
  case unorderedList([String])
  case orderedList([String])
  case quote(String)
  case code(String)
  case rule
}

struct CepessaSessionsSettingsPage: View {
  @AppStorage("cepessa.sessions.keepAudio") private var keepAudio = true
  @AppStorage("cepessa.sessions.preferredTranscriptLanguage") private var transcriptLanguage =
    "Mixed"
  @AppStorage("cepessa.sessions.transcriptionSpeedMode") private var transcriptionSpeedMode =
    "Balanced"
  @AppStorage("cepessa.sessions.preferredRecapStyle") private var recapStyle = "Structured recap"
  @AppStorage(CepessaSessionFloatingBarPreferences.enabledKey) private var floatingBarEnabled =
    true
  @State private var openSettingsPickerTitle: String?

  var body: some View {
    ZStack {
      LinearGradient(
        colors: [CepessaColors.backgroundPrimary, CepessaColors.backgroundSecondary.opacity(0.96)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )
      .ignoresSafeArea()

      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          VStack(alignment: .leading, spacing: 10) {
            Text("Cepessa Sessions")
              .scaledFont(size: 11, weight: .semibold)
              .tracking(0.18)
              .foregroundStyle(CepessaColors.textTertiary)

            Text("Workspace Settings")
              .scaledFont(size: 30, weight: .semibold)
              .foregroundStyle(CepessaColors.textPrimary)

            Text("Tune capture behavior, storage, and permissions for this Mac.")
              .scaledFont(size: 13)
              .foregroundStyle(CepessaColors.textSecondary)
          }

          settingsCard(title: "Capture") {
            VStack(spacing: 14) {
              pickerRow(
                title: "Transcript language", value: $transcriptLanguage,
                options: ["Mixed", "Hebrew-first", "English-first"])
              pickerRow(
                title: "Transcription speed", value: $transcriptionSpeedMode,
                options: ["Fast draft", "Balanced", "Most accurate"])
              pickerRow(
                title: "Recap style", value: $recapStyle,
                options: ["Structured recap", "Concise recap", "Action items only"])

              Text(
                "Fast draft starts with lighter local models when available. Hebrew-first and English-first skip repeated language detection; Mixed keeps bilingual detection on."
              )
              .scaledFont(size: 12)
              .foregroundStyle(CepessaColors.textSecondary)
              .frame(maxWidth: .infinity, alignment: .leading)

              Toggle(isOn: $keepAudio) {
                Text("Keep raw audio after processing")
                  .scaledFont(size: 13)
                  .foregroundStyle(CepessaColors.textPrimary)
              }
              .toggleStyle(.switch)

              Toggle(isOn: $floatingBarEnabled) {
                Text("Show floating recording bar")
                  .scaledFont(size: 13)
                  .foregroundStyle(CepessaColors.textPrimary)
              }
              .toggleStyle(.switch)

              Text(
                "A draggable recording control appears while capture is live. The status bar still handles transcription and recap processing."
              )
              .scaledFont(size: 12)
              .foregroundStyle(CepessaColors.textSecondary)
              .frame(maxWidth: .infinity, alignment: .leading)
            }
          }

          settingsCard(title: "Permissions") {
            VStack(spacing: 12) {
              permissionRow(
                title: "Microphone access",
                isGranted: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized)
              permissionRow(
                title: "Screen capture access", isGranted: CGPreflightScreenCaptureAccess())

              HStack(spacing: 10) {
                settingsAction(title: "Open Microphone Privacy") {
                  openSystemSettings(anchor: "Privacy_Microphone")
                }
                settingsAction(title: "Open Screen Recording Privacy") {
                  openSystemSettings(anchor: "Privacy_ScreenCapture")
                }
              }
            }
          }

          settingsCard(title: "Local storage") {
            VStack(alignment: .leading, spacing: 12) {
              Text("Sessions, transcripts, recaps, audio, and attachments stay here by default.")
                .scaledFont(size: 12)
                .foregroundStyle(CepessaColors.textSecondary)

              Text(storageRoot.path)
                .scaledFont(size: 12)
                .foregroundStyle(CepessaColors.textSecondary)
                .textSelection(.enabled)

              HStack(spacing: 10) {
                settingsAction(title: "Reveal Sessions Folder") {
                  NSWorkspace.shared.activateFileViewerSelecting([storageRoot])
                }
                settingsAction(title: "Reveal Models Folder") {
                  NSWorkspace.shared.activateFileViewerSelecting([modelsRoot])
                }
              }
            }
          }
        }
        .padding(24)
      }
    }
    .onAppear {
      CepessaSessionFloatingBarController.shared.connect(model: CepessaSessionsStore.shared.model)
      CepessaSessionStatusBarController.shared.connect(model: CepessaSessionsStore.shared.model)
    }
    .onChange(of: floatingBarEnabled) { _, _ in
      CepessaSessionFloatingBarController.shared.connect(model: CepessaSessionsStore.shared.model)
    }
    .onExitCommand {
      guard openSettingsPickerTitle != nil else { return }
      withAnimation(.easeOut(duration: 0.12)) {
        openSettingsPickerTitle = nil
      }
    }
  }

  private var storageRoot: URL {
    fileLayout.sessionsDirectory
  }

  private var modelsRoot: URL {
    fileLayout.modelsDirectory
  }

  private var fileLayout: LocalMeetingFileLayout {
    LocalMeetingFileLayout(
      baseDirectory: FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Cepessa", isDirectory: true)
    )
  }

  private func settingsCard<Content: View>(title: String, @ViewBuilder content: () -> Content)
    -> some View
  {
    VStack(alignment: .leading, spacing: 14) {
      Text(title)
        .scaledFont(size: 18, weight: .semibold)
        .foregroundStyle(CepessaColors.textPrimary)

      content()
    }
    .padding(20)
    .frame(maxWidth: .infinity, alignment: .leading)
    .cepessaPaper(radius: 16)
  }

  private func pickerRow(title: String, value: Binding<String>, options: [String]) -> some View {
    HStack {
      Text(title)
        .scaledFont(size: 13)
        .foregroundStyle(CepessaColors.textPrimary)

      Spacer(minLength: 20)

      CepessaToolbarMenu(
        isOpen: Binding(
          get: { openSettingsPickerTitle == title },
          set: { openSettingsPickerTitle = $0 ? title : nil }
        ),
        alignment: .trailing,
        label: {
          HStack(spacing: 8) {
            Text(value.wrappedValue)
              .scaledFont(size: 12, weight: .semibold)
              .foregroundStyle(CepessaColors.textPrimary)
              .lineLimit(1)

            Image(systemName: "chevron.down")
              .scaledFont(size: 8.5, weight: .bold)
              .foregroundStyle(CepessaColors.textTertiary)
          }
          .padding(.horizontal, 12)
          .frame(width: 190, height: 40, alignment: .trailing)
          .background(CepessaColors.backgroundRaised.opacity(0.72))
          .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
          .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
              .stroke(CepessaColors.border.opacity(0.18), lineWidth: 1)
          }
        },
        content: {
          VStack(spacing: 3) {
            ForEach(options, id: \.self) { option in
              settingsMenuOption(title: option, isSelected: value.wrappedValue == option) {
                value.wrappedValue = option
                openSettingsPickerTitle = nil
              }
            }
          }
          .frame(width: 210)
        }
      )
    }
  }

  private func settingsMenuOption(
    title: String,
    isSelected: Bool,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      HStack(spacing: 9) {
        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
          .scaledFont(size: 12, weight: .semibold)
          .foregroundStyle(isSelected ? CepessaColors.accentPrimary : CepessaColors.textTertiary)

        Text(title)
          .scaledFont(size: 12, weight: .semibold)
          .foregroundStyle(CepessaColors.textPrimary)
          .lineLimit(1)

        Spacer(minLength: 0)
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 8)
      .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
      .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
    .buttonStyle(CepessaPressStyle(scale: 0.985, pressedBrightness: -0.01))
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(title)
    .accessibilityAddTraits(isSelected ? [.isSelected] : [])
  }

  private func permissionRow(title: String, isGranted: Bool) -> some View {
    HStack {
      Label(title, systemImage: isGranted ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
        .scaledFont(size: 13, weight: .medium)
        .foregroundStyle(isGranted ? CepessaColors.textPrimary : CepessaColors.warning)

      Spacer(minLength: 0)

      Text(isGranted ? "Ready" : "Needs access")
        .scaledFont(size: 11, weight: .semibold)
        .foregroundStyle(isGranted ? CepessaColors.backgroundPrimary : Color.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(isGranted ? CepessaColors.success : CepessaColors.warning)
        .clipShape(Capsule())
    }
  }

  private func settingsAction(title: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Text(title)
        .scaledFont(size: 12, weight: .semibold)
        .foregroundStyle(CepessaColors.textPrimary)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(CepessaColors.backgroundSecondary.opacity(0.84))
        .clipShape(Capsule())
    }
    .buttonStyle(CepessaPressStyle(scale: 0.975))
  }

  private func openSystemSettings(anchor: String) {
    guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")
    else { return }
    NSWorkspace.shared.open(url)
  }
}

extension LocalMeetingSessionStatus {
  fileprivate var label: String {
    switch self {
    case .recording: return "Recording"
    case .transcribing: return "Processing"
    case .ready: return "Ready"
    case .failed: return "Needs attention"
    }
  }

  fileprivate var badgeColor: Color {
    switch self {
    case .recording: return CepessaColors.error
    case .transcribing: return CepessaColors.purplePrimary
    case .ready: return CepessaColors.success
    case .failed: return CepessaColors.warning
    }
  }
}

extension LocalSessionAttachment.Source {
  fileprivate var displayName: String {
    switch self {
    case .manual: return "Manual"
    case .transcript: return "Transcript anchor"
    case .floatingBar: return "Floating bar"
    case .imported: return "Imported"
    }
  }
}
