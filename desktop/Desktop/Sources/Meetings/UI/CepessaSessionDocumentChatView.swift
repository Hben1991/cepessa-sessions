import SwiftUI

struct CepessaSessionDocumentChatView: View {
  @ObservedObject var model: LocalMeetingAppModel
  let session: LocalMeetingSession?
  @Binding var draftText: String
  let onClose: (() -> Void)?

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @FocusState private var isComposerFocused: Bool

  init(
    model: LocalMeetingAppModel,
    session: LocalMeetingSession?,
    draftText: Binding<String>,
    onClose: (() -> Void)? = nil
  ) {
    self.model = model
    self.session = session
    self._draftText = draftText
    self.onClose = onClose
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      chatHeader

      if let session {
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
    .padding(12)
    .background {
      strongChatGlassPanel
    }
    .overlay {
      RoundedRectangle(cornerRadius: 18, style: .continuous)
        .stroke(Color.white.opacity(0.92), lineWidth: 1)
    }
    .overlay {
      RoundedRectangle(cornerRadius: 18, style: .continuous)
        .stroke(CepessaColors.capture.opacity(0.16), lineWidth: 1)
        .padding(1)
    }
    .shadow(color: .white.opacity(0.72), radius: 1, x: 0, y: -1)
    .shadow(color: CepessaColors.warmShadow.opacity(0.12), radius: 18, x: 0, y: 10)
    .shadow(color: .black.opacity(0.06), radius: 8, x: 0, y: 3)
    .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: session?.documentChat.status)
    .animation(
      reduceMotion ? nil : .easeOut(duration: 0.18),
      value: session?.documentChat.pendingProposal)
  }

  @ViewBuilder
  private var strongChatGlassPanel: some View {
    if #available(macOS 26.0, *) {
      RoundedRectangle(cornerRadius: 18, style: .continuous)
        .fill(Color.white.opacity(0.74))
        .glassEffect(
          .regular.tint(CepessaColors.capture.opacity(0.18)),
          in: .rect(cornerRadius: 18)
        )
        .overlay(
          RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(
              LinearGradient(
                colors: [
                  Color.white.opacity(0.78),
                  CepessaColors.paperRaised.opacity(0.62),
                  CepessaColors.capture.opacity(0.10),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
              )
            )
        )
    } else {
      RoundedRectangle(cornerRadius: 18, style: .continuous)
        .fill(.regularMaterial)
        .overlay(
          RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(
              LinearGradient(
                colors: [
                  Color.white.opacity(0.92),
                  CepessaColors.paperRaised.opacity(0.82),
                  CepessaColors.capture.opacity(0.08),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
              )
            )
        )
    }
  }

  private var chatHeader: some View {
    HStack(alignment: .center, spacing: 9) {
      ZStack {
        Circle()
          .stroke(CepessaColors.capture.opacity(0.58), lineWidth: 1)
          .frame(width: 24, height: 24)

        Image(systemName: "bubble.left.and.text.bubble.right.fill")
          .scaledFont(size: 11, weight: .semibold)
          .foregroundColor(CepessaColors.capture)
      }

      VStack(alignment: .leading, spacing: 2) {
        Text("Ask this session")
          .scaledFont(size: 16, weight: .semibold, design: .rounded)
          .foregroundColor(CepessaColors.textPrimary)

        Text(headerSubtitle)
          .scaledFont(size: 11)
          .foregroundColor(CepessaColors.textSecondary)
          .lineLimit(1)
          .fixedSize(horizontal: false, vertical: true)
      }

      Spacer(minLength: 0)

      HStack(spacing: 8) {
        if let session {
          if session.documentChat.undoSnapshot != nil {
            Button {
              model.undoLastDocumentChatEdit(for: session.id)
            } label: {
              Image(systemName: "arrow.uturn.backward")
                .scaledFont(size: 11, weight: .semibold)
                .foregroundColor(CepessaColors.textSecondary)
                .frame(width: 28, height: 28)
                .background(CepessaColors.backgroundRaised.opacity(0.82))
                .clipShape(Circle())
                .overlay(
                  Circle()
                    .stroke(CepessaColors.border.opacity(0.16), lineWidth: 1)
                )
            }
            .buttonStyle(CepessaPressStyle(scale: 0.94, pressedBrightness: -0.02))
            .help("Undo last document edit")
            .accessibilityLabel("Undo last document edit")
          }

          chatStatusBadge(for: session.documentChat.status)
        }

        if let onClose {
          Button(action: onClose) {
            Image(systemName: "xmark")
              .scaledFont(size: 11, weight: .semibold)
              .foregroundColor(CepessaColors.textSecondary)
              .frame(width: 28, height: 28)
              .background(CepessaColors.backgroundRaised.opacity(0.82))
              .clipShape(Circle())
              .overlay(
                Circle()
                  .stroke(CepessaColors.border.opacity(0.16), lineWidth: 1)
              )
          }
          .buttonStyle(CepessaPressStyle(scale: 0.94, pressedBrightness: -0.02))
          .help("Close chat")
          .accessibilityLabel("Close chat")
        }
      }
    }
  }

  private var headerSubtitle: String {
    if session == nil {
      return "Choose a session to ask about its document."
    }

    return "Answers and edits grounded in this session."
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
    let messages = Array(session.documentChat.messages.suffix(10))

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
      .frame(minHeight: 118, maxHeight: 260)
      .background(
        LinearGradient(
          colors: [
            Color.white.opacity(0.78),
            CepessaColors.paperRaised.opacity(0.74),
          ],
          startPoint: .topLeading,
          endPoint: .bottomTrailing
        )
      )
      .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .stroke(Color.white.opacity(0.58), lineWidth: 1)
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
        tint: CepessaColors.capture
      )

      ScrollView(.horizontal) {
        HStack(spacing: 8) {
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
          .foregroundColor(CepessaColors.capture)

        Text(text)
          .scaledFont(size: 12, weight: .semibold)
          .foregroundColor(CepessaColors.textSecondary)
          .lineLimit(2)

        Spacer(minLength: 0)
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 8)
      .frame(minWidth: 150, idealWidth: 172, maxWidth: 220, alignment: .leading)
      .background(CepessaColors.paperDeep.opacity(0.46))
      .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .stroke(CepessaColors.hairline.opacity(0.48), lineWidth: 1)
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
          .foregroundColor(CepessaColors.capture)
          .frame(width: 28, height: 28)
          .background(CepessaColors.capture.opacity(0.12))
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

      proposalPreview(proposal)

      if !proposal.sourceCitations.isEmpty {
        citationStrip(proposal.sourceCitations)
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
          CepessaColors.capture.opacity(0.10),
          CepessaColors.backgroundRaised.opacity(0.76),
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )
    )
    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .stroke(CepessaColors.capture.opacity(0.18), lineWidth: 1)
    )
  }

  private func composer(for session: LocalMeetingSession) -> some View {
    let trimmed = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
    let isSending = session.documentChat.status == .sending

    return HStack(alignment: .bottom, spacing: 10) {
      TextField("Ask about this session...", text: $draftText, axis: .vertical)
        .textFieldStyle(.plain)
        .scaledFont(size: 13)
        .foregroundColor(CepessaColors.textPrimary)
        .tint(CepessaColors.capture)
        .lineLimit(1...4)
        .focused($isComposerFocused)
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .background(Color.white.opacity(0.88))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
          RoundedRectangle(cornerRadius: 12, style: .continuous)
            .stroke(
              isComposerFocused
                ? CepessaColors.capture.opacity(0.34) : CepessaColors.border.opacity(0.18),
              lineWidth: 1
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
          .frame(width: 32, height: 32)
          .background(
            Circle()
              .fill(
                trimmed.isEmpty || isSending
                  ? CepessaColors.backgroundRaised.opacity(0.90) : CepessaColors.capture)
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
    .background(CepessaColors.paperRaised.opacity(0.42))
    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    .overlay(alignment: .top) {
      Rectangle()
        .fill(tint.opacity(0.28))
        .frame(height: 1)
    }
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
        return CepessaColors.processing
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

    if proposal.sessionTitle != nil {
      parts.append("title update")
    }

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

  private func proposalPreview(_ proposal: LocalSessionDocumentEditProposal) -> some View {
    VStack(alignment: .leading, spacing: 7) {
      if let title = proposal.sessionTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
        !title.isEmpty
      {
        previewLine(title: "Title", body: title)
      }

      if let overview = proposal.recapPatch?.overview?.trimmingCharacters(
        in: .whitespacesAndNewlines),
        !overview.isEmpty
      {
        previewLine(title: "Overview", body: overview)
      }

      ForEach(Array((proposal.recapPatch?.sections ?? []).enumerated()), id: \.offset) {
        _, section in
        let title = section.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          ? section.kind.displayTitle
          : section.title
        previewLine(title: title, body: section.summary)
      }

      ForEach(proposal.transcriptPatches, id: \.segmentID) { patch in
        previewLine(title: "Transcript \(patch.segmentID.uuidString.prefix(8))", body: patch.text)
      }

      ForEach(proposal.speakerRenames, id: \.oldName) { rename in
        previewLine(title: "Speaker", body: "\(rename.oldName) -> \(rename.newName)")
      }
    }
    .padding(10)
    .background(CepessaColors.backgroundRaised.opacity(0.62))
    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
  }

  private func previewLine(title: String, body: String) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(title)
        .scaledFont(size: 10.5, weight: .semibold)
        .foregroundColor(CepessaColors.textSecondary)

      Text(body)
        .scaledFont(size: 11.5)
        .foregroundColor(CepessaColors.textPrimary)
        .lineLimit(3)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private func citationStrip(_ citations: [LocalSessionDocumentSourceCitation]) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Label("Sources", systemImage: "quote.bubble")
        .scaledFont(size: 10.5, weight: .semibold)
        .foregroundColor(CepessaColors.textSecondary)

      ForEach(citations.prefix(3)) { citation in
        VStack(alignment: .leading, spacing: 2) {
          Text(citation.title)
            .scaledFont(size: 10, weight: .semibold)
            .foregroundColor(CepessaColors.capture)
          Text(citation.excerpt)
            .scaledFont(size: 10.5)
            .foregroundColor(CepessaColors.textSecondary)
            .lineLimit(2)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CepessaColors.paperRaised.opacity(0.48))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
      }
    }
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
          .padding(.horizontal, 11)
          .padding(.vertical, 9)
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

        if !isUser, !message.sourceCitations.isEmpty {
          VStack(alignment: .leading, spacing: 4) {
            ForEach(message.sourceCitations.prefix(2)) { citation in
              HStack(alignment: .top, spacing: 5) {
                Image(systemName: "quote.opening")
                  .scaledFont(size: 8, weight: .semibold)
                  .foregroundColor(CepessaColors.capture)
                  .frame(width: 12, height: 12)

                VStack(alignment: .leading, spacing: 1) {
                  Text(citation.title)
                    .scaledFont(size: 9.5, weight: .semibold)
                    .foregroundColor(CepessaColors.textSecondary)
                  Text(citation.excerpt)
                    .scaledFont(size: 9.5)
                    .foregroundColor(CepessaColors.textTertiary)
                    .lineLimit(2)
                }
              }
              .padding(.horizontal, 8)
              .padding(.vertical, 6)
              .background(CepessaColors.backgroundRaised.opacity(0.56))
              .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
          }
          .frame(maxWidth: 360, alignment: .leading)
        }
      }
      .frame(maxWidth: 430, alignment: isUser ? .trailing : .leading)

      if !isUser {
        Spacer(minLength: 48)
      }
    }
  }

  private var messageText: String {
    let trimmed = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.looksLikeChatContractLeak else {
      return "I couldn't produce a clean document edit from the local model."
    }
    return trimmed
  }

  private var bubbleFill: some ShapeStyle {
    LinearGradient(
      colors: isUser
        ? [
          CepessaColors.capture.opacity(0.20),
          CepessaColors.capture.opacity(0.10),
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
    isUser ? CepessaColors.capture.opacity(0.22) : CepessaColors.border.opacity(0.18)
  }
}

extension String {
  fileprivate var looksLikeChatContractLeak: Bool {
    let lowercased = lowercased()
    return lowercased.contains("\"recappatch\"")
      || lowercased.contains("\"transcriptpatches\"")
      || lowercased.contains("\"speakerrenames\"")
      || lowercased.contains("\"kind\":\"keypoints|")
      || lowercased.contains("return only valid json")
      || lowercased.contains("the json object must match")
      || lowercased.contains("use empty arrays and null recappatch")
      || lowercased.contains("segmentid=")
  }
}
