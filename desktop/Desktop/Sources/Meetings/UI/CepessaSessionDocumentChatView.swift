import SwiftUI

struct CepessaSessionDocumentChatView: View {
  @ObservedObject var model: LocalMeetingAppModel
  let session: LocalMeetingSession?
  @Binding var draftText: String

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @FocusState private var isComposerFocused: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      chatHeader

      if let session {
        chatMetrics(for: session)

        messageSurface(for: session)

        if let proposal = session.documentChat.pendingProposal {
          proposalCard(proposal, for: session)
        }

        if let error = session.documentChat.errorMessage, !error.isEmpty {
          statusNotice(
            text: error, systemImage: "exclamationmark.triangle.fill", tint: CepessaColors.error)
        }

        composer(for: session)
      } else {
        emptySelectionState
      }
    }
    .padding(18)
    .cepessaGlassPanel(radius: 14, fillOpacity: 0.50, strokeOpacity: 0.34, shadowOpacity: 0.035)
    .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: session?.documentChat.status)
    .animation(
      reduceMotion ? nil : .easeOut(duration: 0.18),
      value: session?.documentChat.pendingProposal)
  }

  private var chatHeader: some View {
    HStack(alignment: .top, spacing: 12) {
      ZStack {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
          .fill(
            LinearGradient(
              colors: [
                Color.accentColor.opacity(0.24),
                CepessaColors.backgroundRaised.opacity(0.82),
              ],
              startPoint: .topLeading,
              endPoint: .bottomTrailing
            )
          )
          .frame(width: 36, height: 36)

        Image(systemName: "bubble.left.and.text.bubble.right.fill")
          .scaledFont(size: 14, weight: .semibold)
          .foregroundColor(Color.accentColor)
      }

      VStack(alignment: .leading, spacing: 4) {
        Text("Session Chat")
          .scaledFont(size: 18, weight: .semibold)
          .foregroundColor(CepessaColors.textPrimary)

        Text(headerSubtitle)
          .scaledFont(size: 12)
          .foregroundColor(CepessaColors.textSecondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      Spacer(minLength: 0)

      if let session {
        chatStatusBadge(for: session.documentChat.status)
      }
    }
  }

  private var headerSubtitle: String {
    if session == nil {
      return "Choose a session to ask about its transcript, recap, speakers, and retained files."
    }

    return "Ask for answers, cleanup, rewrites, and edits grounded in the selected session."
  }

  private func chatMetrics(for session: LocalMeetingSession) -> some View {
    HStack(spacing: 8) {
      compactMetric(title: "Messages", value: "\(session.documentChat.messages.count)")
      compactMetric(title: "Transcript", value: "\(session.segments.count)")
      compactMetric(
        title: "Proposal",
        value: session.documentChat.pendingProposal == nil ? "None" : "Ready"
      )

      Spacer(minLength: 0)
    }
  }

  @ViewBuilder
  private func messageSurface(for session: LocalMeetingSession) -> some View {
    let messages = Array(session.documentChat.messages.suffix(20))

    if messages.isEmpty {
      promptSuggestions(for: session)
        .transition(.opacity.combined(with: .offset(y: 6)))
    } else {
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 12) {
          ForEach(messages) { message in
            SessionDocumentChatBubble(message: message)
              .transition(
                .asymmetric(
                  insertion: .opacity.combined(with: .offset(y: 8)),
                  removal: .opacity
                )
              )
          }

          if session.documentChat.status == .sending {
            thinkingRow
          }
        }
        .padding(12)
      }
      .frame(minHeight: 240, maxHeight: 420)
      .background(CepessaColors.backgroundRaised.opacity(0.50))
      .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .stroke(CepessaColors.border.opacity(0.16), lineWidth: 1)
      )
      .scrollIndicators(.hidden)
      .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: messages.count)
    }
  }

  private func promptSuggestions(for session: LocalMeetingSession) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      statusNotice(
        text: emptyPromptText(for: session),
        systemImage: "sparkles",
        tint: Color.accentColor
      )

      ScrollView(.horizontal) {
        HStack(spacing: 10) {
          suggestionButton("What decisions were made?")
          suggestionButton("Turn this into action items.")
          suggestionButton("Clean up the recap.")
          suggestionButton("Fix speaker names.")
        }
        .padding(.vertical, 1)
      }
      .scrollIndicators(.hidden)
    }
  }

  private func suggestionButton(_ text: String) -> some View {
    Button {
      draftText = text
      isComposerFocused = true
    } label: {
      HStack(spacing: 8) {
        Image(systemName: "arrow.turn.down.right")
          .scaledFont(size: 10, weight: .semibold)
          .foregroundColor(Color.accentColor)

        Text(text)
          .scaledFont(size: 12, weight: .semibold)
          .foregroundColor(CepessaColors.textSecondary)
          .lineLimit(2)

        Spacer(minLength: 0)
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 11)
      .frame(minWidth: 188, idealWidth: 220, maxWidth: 260, alignment: .leading)
      .background(CepessaColors.backgroundRaised.opacity(0.78))
      .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .stroke(CepessaColors.border.opacity(0.16), lineWidth: 1)
      )
    }
    .buttonStyle(CepessaPressStyle(scale: 0.985))
  }

  private var thinkingRow: some View {
    HStack(spacing: 8) {
      ProgressView()
        .scaleEffect(0.72)
        .controlSize(.small)

      Text("Reading the session locally")
        .scaledFont(size: 12, weight: .medium)
        .foregroundColor(CepessaColors.textSecondary)

      Spacer(minLength: 0)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
    .background(CepessaColors.backgroundSecondary.opacity(0.72))
    .clipShape(Capsule())
  }

  private func proposalCard(
    _ proposal: LocalSessionDocumentEditProposal, for session: LocalMeetingSession
  )
    -> some View
  {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .top, spacing: 10) {
        Image(systemName: "doc.badge.gearshape.fill")
          .scaledFont(size: 14, weight: .semibold)
          .foregroundColor(Color.accentColor)
          .frame(width: 28, height: 28)
          .background(Color.accentColor.opacity(0.12))
          .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

        VStack(alignment: .leading, spacing: 4) {
          Text("Edits ready")
            .scaledFont(size: 13, weight: .semibold)
            .foregroundColor(CepessaColors.textPrimary)

          Text(proposalSummary(proposal))
            .scaledFont(size: 12)
            .foregroundColor(CepessaColors.textSecondary)
        }

        Spacer(minLength: 0)
      }

      if !proposal.warnings.isEmpty {
        VStack(alignment: .leading, spacing: 6) {
          ForEach(proposal.warnings, id: \.self) { warning in
            Label(warning, systemImage: "exclamationmark.triangle")
              .scaledFont(size: 11)
              .foregroundColor(CepessaColors.warning)
          }
        }
      }

      HStack(spacing: 8) {
        Button {
          model.applyPendingDocumentChatProposal(for: session.id)
        } label: {
          Label("Apply", systemImage: "checkmark")
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)

        Button {
          model.discardPendingDocumentChatProposal(for: session.id)
        } label: {
          Label("Discard", systemImage: "xmark")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)

        Spacer(minLength: 0)
      }
    }
    .padding(14)
    .background(
      LinearGradient(
        colors: [
          Color.accentColor.opacity(0.10),
          CepessaColors.backgroundRaised.opacity(0.76),
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )
    )
    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .stroke(Color.accentColor.opacity(0.18), lineWidth: 1)
    )
  }

  private func composer(for session: LocalMeetingSession) -> some View {
    let trimmed = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
    let isSending = session.documentChat.status == .sending

    return HStack(alignment: .bottom, spacing: 10) {
      TextField("Ask about this session...", text: $draftText, axis: .vertical)
        .textFieldStyle(.plain)
        .scaledFont(size: 13)
        .lineLimit(1...4)
        .focused($isComposerFocused)
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .background(CepessaColors.backgroundRaised.opacity(0.84))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
          RoundedRectangle(cornerRadius: 12, style: .continuous)
            .stroke(
              isComposerFocused
                ? Color.accentColor.opacity(0.34) : CepessaColors.border.opacity(0.18), lineWidth: 1
            )
        )
        .onSubmit {
          sendDraft(for: session)
        }

      Button {
        sendDraft(for: session)
      } label: {
        Image(systemName: isSending ? "hourglass" : "arrow.up")
          .scaledFont(size: 13, weight: .bold)
          .foregroundColor(trimmed.isEmpty || isSending ? CepessaColors.textTertiary : .white)
          .frame(width: 36, height: 36)
          .background(
            Circle()
              .fill(
                trimmed.isEmpty || isSending
                  ? CepessaColors.backgroundRaised.opacity(0.90) : Color.accentColor)
          )
          .overlay(
            Circle()
              .stroke(Color.white.opacity(trimmed.isEmpty || isSending ? 0.16 : 0.28), lineWidth: 1)
          )
      }
      .buttonStyle(CepessaPressStyle(scale: 0.94, pressedBrightness: -0.03))
      .disabled(trimmed.isEmpty || isSending)
      .accessibilityLabel("Send message")
    }
  }

  private var emptySelectionState: some View {
    VStack(spacing: 12) {
      Image(systemName: "rectangle.stack.badge.person.crop")
        .scaledFont(size: 28)
        .foregroundColor(CepessaColors.textTertiary)

      VStack(spacing: 4) {
        Text("Select a session")
          .scaledFont(size: 14, weight: .semibold)
          .foregroundColor(CepessaColors.textPrimary)

        Text("Chat becomes available after a saved session is selected.")
          .scaledFont(size: 12)
          .foregroundColor(CepessaColors.textSecondary)
          .multilineTextAlignment(.center)
      }
    }
    .frame(maxWidth: .infinity)
    .padding(28)
    .background(CepessaColors.backgroundRaised.opacity(0.58))
    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
  }

  private func statusNotice(text: String, systemImage: String, tint: Color) -> some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: systemImage)
        .scaledFont(size: 12, weight: .semibold)
        .foregroundColor(tint)
        .frame(width: 24, height: 24)
        .background(tint.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

      Text(text)
        .scaledFont(size: 12)
        .foregroundColor(CepessaColors.textSecondary)
        .fixedSize(horizontal: false, vertical: true)

      Spacer(minLength: 0)
    }
    .padding(12)
    .background(CepessaColors.backgroundRaised.opacity(0.60))
    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .stroke(tint.opacity(0.14), lineWidth: 1)
    )
    .transition(.opacity.combined(with: .offset(y: 4)))
  }

  private func compactMetric(title: String, value: String) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(title)
        .scaledFont(size: 10.5, weight: .medium)
        .foregroundColor(CepessaColors.textTertiary)

      Text(value)
        .scaledFont(size: 12, weight: .semibold)
        .foregroundColor(CepessaColors.textSecondary)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 9)
    .background(CepessaColors.backgroundRaised.opacity(0.70))
    .clipShape(Capsule())
    .overlay(
      Capsule()
        .stroke(CepessaColors.border.opacity(0.14), lineWidth: 1)
    )
  }

  private func chatStatusBadge(for status: LocalSessionDocumentChatStatus) -> some View {
    let tint: Color = {
      switch status {
      case .idle:
        return CepessaColors.success
      case .sending:
        return Color.accentColor
      case .failed:
        return CepessaColors.error
      }
    }()

    let label: String = {
      switch status {
      case .idle:
        return "Ready"
      case .sending:
        return "Thinking"
      case .failed:
        return "Needs attention"
      }
    }()

    return Text(label)
      .scaledFont(size: 10, weight: .semibold)
      .foregroundColor(status == .idle ? CepessaColors.backgroundPrimary : .white)
      .padding(.horizontal, 9)
      .padding(.vertical, 5)
      .background(tint)
      .clipShape(Capsule())
  }

  private func emptyPromptText(for session: LocalMeetingSession) -> String {
    if session.transcriptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return
        "This session does not have transcript text yet. You can still prepare the question you want to ask after transcription finishes."
    }

    return
      "Start with a direct request. The assistant can answer from the transcript or propose changes to recap, transcript text, and speaker names."
  }

  private func proposalSummary(_ proposal: LocalSessionDocumentEditProposal) -> String {
    var parts: [String] = []

    if proposal.recapPatch != nil {
      parts.append("recap update")
    }

    if !proposal.transcriptPatches.isEmpty {
      parts.append(
        "\(proposal.transcriptPatches.count) transcript \(proposal.transcriptPatches.count == 1 ? "edit" : "edits")"
      )
    }

    if !proposal.speakerRenames.isEmpty {
      parts.append(
        "\(proposal.speakerRenames.count) speaker \(proposal.speakerRenames.count == 1 ? "rename" : "renames")"
      )
    }

    return parts.isEmpty ? "No document edits were proposed." : parts.joined(separator: ", ")
  }

  private func sendDraft(for session: LocalMeetingSession) {
    let trimmed = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, session.documentChat.status != .sending else { return }
    draftText = ""
    model.sendDocumentChatMessage(trimmed, for: session.id)
  }
}

private struct SessionDocumentChatBubble: View {
  let message: LocalSessionDocumentChatMessage

  private var isUser: Bool {
    message.role == .user
  }

  var body: some View {
    HStack(alignment: .bottom, spacing: 10) {
      if isUser {
        Spacer(minLength: 48)
      }

      VStack(alignment: isUser ? .trailing : .leading, spacing: 6) {
        Text(messageText)
          .scaledFont(size: 13)
          .foregroundColor(CepessaColors.textPrimary)
          .lineSpacing(2)
          .textSelection(.enabled)
          .padding(.horizontal, 13)
          .padding(.vertical, 11)
          .background(bubbleFill)
          .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
          .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
              .stroke(bubbleStroke, lineWidth: 1)
          )

        Text(
          "\(isUser ? "You" : "Cepessa")  \(message.createdAt.formatted(date: .omitted, time: .shortened))"
        )
        .scaledFont(size: 10)
        .foregroundColor(CepessaColors.textTertiary)
        .padding(.horizontal, 4)
      }
      .frame(maxWidth: 560, alignment: isUser ? .trailing : .leading)

      if !isUser {
        Spacer(minLength: 48)
      }
    }
  }

  private var messageText: String {
    message.text.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var bubbleFill: some ShapeStyle {
    LinearGradient(
      colors: isUser
        ? [
          Color.accentColor.opacity(0.24),
          Color.accentColor.opacity(0.12),
          CepessaColors.backgroundRaised.opacity(0.68),
        ]
        : [
          CepessaColors.backgroundSecondary.opacity(0.94),
          CepessaColors.backgroundRaised.opacity(0.72),
        ],
      startPoint: .topLeading,
      endPoint: .bottomTrailing
    )
  }

  private var bubbleStroke: Color {
    isUser ? Color.accentColor.opacity(0.22) : CepessaColors.border.opacity(0.18)
  }
}
