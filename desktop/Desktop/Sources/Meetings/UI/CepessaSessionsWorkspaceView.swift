import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct CepessaSessionsWorkspaceView: View {
  @ObservedObject private var model = CepessaSessionsStore.shared.model
  @State private var centerSection: WorkspaceSection = .recap
  @State private var sessionSearchText = ""
  @State private var hoveredSessionID: LocalMeetingSession.ID?
  @State private var isDocumentChatOpen = false
  @State private var isActivityPopoverOpen = false
  @State private var isSessionInspectorOverlayOpen = false
  @State private var openToolbarMenu: ToolbarMenuKind?
  @State private var documentChatDraft = ""
  @State private var exportAlertMessage: String?
  @State private var exportToastMessage: String?
  @AppStorage("cepessa.sessions.documentLanguage") private var documentLanguage =
    LocalSessionDocumentLanguage.english.rawValue
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    GeometryReader { proxy in
      let layout = workspaceLayout(for: proxy.size.width)

      ZStack {
        workspaceBackground

        Group {
          if layout == .wide {
            VStack(spacing: 0) {
              workspaceColumns(for: layout, availableHeight: proxy.size.height)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
          } else {
            ScrollView {
              VStack(alignment: .leading, spacing: 18) {
                workspaceHeader(for: layout)

                workspaceColumns(for: layout, availableHeight: proxy.size.height)
              }
              .padding(.horizontal, 22)
              .padding(.top, 22)
              .padding(.bottom, 18)
            }
            .scrollIndicators(.hidden)
          }
        }
        .animation(
          reduceMotion ? nil : .easeOut(duration: 0.18), value: model.processingQueue.count
        )

        if let activitySnapshot {
          activitySurface(for: layout, snapshot: activitySnapshot)
            .padding(.horizontal, layout == .wide ? 34 : 22)
            .padding(.top, layout == .wide ? 16 : 0)
            .padding(.bottom, layout == .wide ? 0 : 96)
            .padding(.trailing, layout == .wide ? 304 : 0)
            .frame(
              maxWidth: .infinity,
              maxHeight: .infinity,
              alignment: layout == .wide ? .top : .bottom
            )
            .transition(
              .asymmetric(
                insertion: .opacity.combined(
                  with: .offset(y: reduceMotion ? 0 : (layout == .wide ? -8 : 8))
                ),
                removal: .opacity.combined(
                  with: .offset(y: reduceMotion ? 0 : (layout == .wide ? -4 : 4))
                )
              )
            )
            .zIndex(2)
        }

        if isDocumentChatOpen {
          floatingDocumentChat(for: layout)
            .padding(.horizontal, layout == .stacked ? 16 : 22)
            .padding(.bottom, layout == .stacked ? 24 : 22)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            .transition(
              .opacity.combined(with: .offset(y: reduceMotion ? 0 : 14))
            )
            .zIndex(3)
        }
      }
      .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: centerSection)
      .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: isDocumentChatOpen)
    }
    .onAppear {
      CepessaSessionFloatingBarController.shared.connect(model: model)
    }
    .onChange(of: model.selectedSessionID) { _, _ in
      centerSection = .recap
      documentChatDraft = ""
      openToolbarMenu = nil
      exportToastMessage = nil
      isSessionInspectorOverlayOpen = false
    }
    .onChange(of: model.processingQueue.count) { _, count in
      if count == 0 {
        isActivityPopoverOpen = false
      }
    }
    .onExitCommand {
      guard openToolbarMenu != nil else { return }
      withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) {
        openToolbarMenu = nil
      }
    }
    .alert(
      "Export",
      isPresented: Binding(
        get: { exportAlertMessage != nil },
        set: { isPresented in
          if !isPresented {
            exportAlertMessage = nil
          }
        }
      )
    ) {
      Button("OK") {
        exportAlertMessage = nil
      }
    } message: {
      Text(exportAlertMessage ?? "")
    }
  }
}

extension CepessaSessionsWorkspaceView {
  fileprivate var sessionSelection: Binding<LocalMeetingSession.ID?> {
    Binding(
      get: {
        model.selectedSessionID
      },
      set: { newValue in
        if let newValue {
          model.selectSession(id: newValue)
        } else {
          model.clearSelection()
        }
      }
    )
  }

  fileprivate var selectedDocumentLanguage: LocalSessionDocumentLanguage {
    LocalSessionDocumentLanguage(rawValue: documentLanguage) ?? .english
  }

  fileprivate var filteredSessions: [LocalMeetingSession] {
    let normalizedSearch = sessionSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedSearch.isEmpty else { return model.sessions }

    return model.sessions.filter { session in
      sessionMatchesSearch(session, query: normalizedSearch)
    }
  }

  fileprivate var isFilteringSessions: Bool {
    !sessionSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  fileprivate func sessionMatchesSearch(
    _ session: LocalMeetingSession,
    query: String
  ) -> Bool {
    if session.displayTitle.localizedCaseInsensitiveContains(query)
      || session.transcriptText.localizedCaseInsensitiveContains(query)
      || session.recap.overview.localizedCaseInsensitiveContains(query)
      || session.contentClassification?.type.displayTitle.localizedCaseInsensitiveContains(query)
        == true
    {
      return true
    }

    if session.recap.sections.contains(where: { section in
      section.title.localizedCaseInsensitiveContains(query)
        || section.summary.localizedCaseInsensitiveContains(query)
        || section.bullets.contains(where: { $0.localizedCaseInsensitiveContains(query) })
    }) {
      return true
    }

    if session.attachments.contains(where: { attachment in
      attachment.title.localizedCaseInsensitiveContains(query)
        || attachment.note?.localizedCaseInsensitiveContains(query) == true
    }) {
      return true
    }

    return session.captureArtifacts.contains { artifact in
      artifact.title.localizedCaseInsensitiveContains(query)
        || artifact.notes?.localizedCaseInsensitiveContains(query) == true
    }
  }

  fileprivate func nativeSessionRow(_ session: LocalMeetingSession) -> some View {
    let status = displayStatus(for: session)
    let snapshot = model.processingSnapshot(for: session.id)

    return VStack(alignment: .leading, spacing: 5) {
      HStack(spacing: 8) {
        Image(systemName: statusSymbol(for: status))
          .foregroundStyle(statusBackground(for: status))
          .frame(width: 16)

        Text(session.displayTitle)
          .font(.headline)
          .lineLimit(1)

        Spacer(minLength: 0)

        Text(statusLabel(status))
          .font(.caption2)
          .foregroundStyle(.secondary)
      }

      Text(session.startedAt.formatted(date: .abbreviated, time: .shortened))
        .font(.caption)
        .foregroundStyle(.secondary)

      if let snapshot {
        ProgressView(value: snapshot.progress ?? 0)
          .progressViewStyle(.linear)
        Text(snapshot.title)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      } else {
        Text(session.transcriptText.isEmpty ? "No transcript yet" : session.transcriptText)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(2)
      }

      if let contentType = session.contentClassification?.type {
        Label(contentType.displayTitle, systemImage: contentTypeSystemImage(for: contentType))
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
    }
    .padding(.vertical, 4)
  }

  @ViewBuilder
  fileprivate var nativeSessionDetail: some View {
    if let session = selectedSession {
      Form {
        Section {
          LabeledContent("Status") {
            Label(
              statusLabel(displayStatus(for: session)),
              systemImage: statusSymbol(for: displayStatus(for: session))
            )
            .foregroundStyle(statusBackground(for: displayStatus(for: session)))
          }

          LabeledContent("Started") {
            Text(session.startedAt.formatted(date: .abbreviated, time: .shortened))
          }

          LabeledContent("Transcript Segments") {
            Text("\(session.segments.count)")
          }

          LabeledContent("Captured Context") {
            Text("\(session.attachments.count + session.captureArtifacts.count)")
          }

          if let classification = session.contentClassification {
            LabeledContent("Content Type") {
              Label(
                classification.type.displayTitle,
                systemImage: contentTypeSystemImage(for: classification.type)
              )
            }

            LabeledContent("Classification") {
              Text("\(Int((classification.confidence * 100).rounded()))%")
            }
          }
        } header: {
          Text("Session")
        }

        if let snapshot = model.processingSnapshot(for: session.id) {
          Section("Processing") {
            if let progress = snapshot.progress {
              ProgressView(value: progress)
            } else {
              ProgressView()
            }
            Text(snapshot.title)
              .font(.headline)
            Text(snapshot.detail)
              .foregroundStyle(.secondary)
          }
        } else if model.isGeneratingRecap(for: session.id) {
          Section("Processing") {
            ProgressView()
            Text("Generating recap")
              .font(.headline)
            Text(
              model.processingStatusDetail
                ?? "The transcript is ready. The recap is still being generated locally."
            )
            .foregroundStyle(.secondary)
          }
        }

        Section("Transcript") {
          if session.transcriptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            ContentUnavailableView(
              "No Transcript",
              systemImage: "text.bubble",
              description: Text(transcriptPendingMessage(for: session))
            )
          } else {
            ForEach(session.segments) { segment in
              VStack(alignment: .leading, spacing: 4) {
                Text(segment.timestamp.formatted(date: .omitted, time: .shortened))
                  .font(.caption)
                  .foregroundStyle(.secondary)
                Text(segment.text)
                  .textSelection(.enabled)
              }
              .padding(.vertical, 3)
            }
          }
        }

        Section("Recap") {
          if session.recap.overview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            session.recap.sections.isEmpty
          {
            ContentUnavailableView(
              "No Recap",
              systemImage: "doc.text.magnifyingglass",
              description: Text("A recap appears after the transcript is ready.")
            )
          } else {
            LocalSessionMarkdownDocumentPreview(
              markdown: LocalSessionRecapMarkdownDocument(
                session: session,
                language: selectedDocumentLanguage
              ).markdown,
              language: selectedDocumentLanguage
            )
          }
        }

        Section("Files") {
          nativeFileRow(
            "Mixed Master", systemImage: "waveform", fileName: session.audioArtifacts.mixedFileName)
          nativeFileRow(
            "Microphone", systemImage: "mic", fileName: session.audioArtifacts.micFileName)
          nativeFileRow(
            "System Audio", systemImage: "speaker.wave.2",
            fileName: session.audioArtifacts.systemFileName)

          if let promptPackageURL = model.promptPackageMarkdownURL(),
            let sessionFolderURL = model.sessionFolderURL(),
            FileManager.default.fileExists(atPath: promptPackageURL.path)
          {
            Button {
              NSWorkspace.shared.open(promptPackageURL)
            } label: {
              Label("Open Prompt Package", systemImage: "doc.text")
            }

            Button {
              NSWorkspace.shared.activateFileViewerSelecting([sessionFolderURL])
            } label: {
              Label("Reveal Session in Finder", systemImage: "folder")
            }
          }
        }
      }
      .formStyle(.grouped)
      .scrollContentBackground(.visible)
    } else {
      ContentUnavailableView(
        "No Session Selected",
        systemImage: "rectangle.stack",
        description: Text("Choose a session from the list or start a new recording.")
      )
    }
  }

  fileprivate func nativeFileRow(_ title: String, systemImage: String, fileName: String?)
    -> some View
  {
    LabeledContent {
      Text(fileName ?? "Not retained")
        .foregroundStyle(fileName == nil ? .secondary : .primary)
    } label: {
      Label(title, systemImage: systemImage)
    }
  }

  fileprivate func statusSymbol(for status: LocalMeetingSessionStatus) -> String {
    switch status {
    case .recording:
      return "record.circle.fill"
    case .transcribing:
      return "waveform"
    case .ready:
      return "checkmark.circle.fill"
    case .failed:
      return "exclamationmark.triangle.fill"
    }
  }

  fileprivate func contentTypeSystemImage(for contentType: LocalSessionContentType) -> String {
    switch contentType {
    case .meeting:
      return "person.2"
    case .voiceNote:
      return "mic.badge.plus"
    case .videoCommentary:
      return "play.rectangle"
    case .generalTranscript:
      return "text.alignleft"
    }
  }

  fileprivate func recapKindTitle(_ kind: LocalSessionRecapSection.Kind) -> String {
    switch kind {
    case .overview:
      return "Overview"
    case .keyPoints:
      return "Key points"
    case .decisions:
      return "Decisions"
    case .actionItem:
      return "Action items"
    case .openQuestions:
      return "Open questions"
    case .nextSteps:
      return "Next steps"
    case .notes:
      return "Notes"
    }
  }

  fileprivate func workspaceLayout(for width: CGFloat) -> WorkspaceLayoutMode {
    if width >= 1_120 {
      return .wide
    }

    if width >= 880 {
      return .split
    }

    return .stacked
  }

  fileprivate var workspaceBackground: some View {
    ZStack {
      Color.white

      LinearGradient(
        colors: [
          Color(hex: 0xF9FCFF),
          Color.white,
          Color(hex: 0xEEF5FF).opacity(0.58),
          Color(hex: 0xF6F8FB).opacity(0.72),
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )

      RadialGradient(
        colors: [
          Color(hex: 0xDCEBFF).opacity(0.34),
          Color.clear,
        ],
        center: .topTrailing,
        startRadius: 0,
        endRadius: 520
      )
    }
    .ignoresSafeArea()
  }

  @ViewBuilder
  fileprivate func workspaceHeader(for layout: WorkspaceLayoutMode) -> some View {
    ViewThatFits(in: .horizontal) {
      HStack(alignment: .center, spacing: 18) {
        workspaceTitleBlock
        Spacer(minLength: 0)
        headerPrimaryAction(for: layout)
      }

      VStack(alignment: .leading, spacing: 12) {
        workspaceTitleBlock
        headerPrimaryAction(for: layout)
      }
    }
    .padding(.horizontal, 6)
  }

  fileprivate var workspaceTitleBlock: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Sessions")
        .scaledFont(size: 22, weight: .semibold, design: .rounded)
        .foregroundColor(CepessaColors.textPrimary)

      Text(headerSummary)
        .scaledFont(size: 12)
        .foregroundColor(CepessaColors.textSecondary)
    }
  }

  @ViewBuilder
  fileprivate func headerPrimaryAction(for layout: WorkspaceLayoutMode) -> some View {
    HStack(spacing: 10) {
      headerIconButton(
        systemImage: "arrow.down.to.line",
        accessibilityLabel: "Transcribe Audio File"
      ) {
        importRecording()
      }
      .help("Choose an existing audio file and transcribe it locally.")

      headerIconButton(
        systemImage: isDocumentChatOpen
          ? "bubble.left.and.text.bubble.right.fill" : "bubble.left.and.text.bubble.right",
        accessibilityLabel: isDocumentChatOpen ? "Hide Chat" : "Ask Session"
      ) {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
          isDocumentChatOpen.toggle()
        }
      }
      .help(
        isDocumentChatOpen ? "Hide the floating session chat." : "Open the floating session chat.")

      if layout != .wide && selectedSession != nil {
        headerIconButton(
          systemImage: isSessionInspectorOverlayOpen ? "info.circle.fill" : "info.circle",
          accessibilityLabel: isSessionInspectorOverlayOpen
            ? "Hide session details" : "Show session details",
          tint: CepessaColors.captureDeep,
          fill: Color.white.opacity(0.44)
        ) {
          openToolbarMenu = nil
          withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) {
            isSessionInspectorOverlayOpen.toggle()
          }
        }
        .help(isSessionInspectorOverlayOpen ? "Hide session details." : "Show session details.")
      }

      headerIconButton(
        systemImage: model.isRecording ? "stop.fill" : "record.circle.fill",
        accessibilityLabel: model.isRecording ? "Stop Session" : "Start Session",
        tint: model.isRecording ? CepessaColors.error : CepessaColors.captureDeep,
        fill: model.isRecording ? CepessaColors.error.opacity(0.12) : Color.white.opacity(0.44)
      ) {
        model.toggleRecording()
      }
      .help(
        model.isRecording ? "Stop the current recording session." : "Start a new local session.")
    }
  }

  fileprivate func headerIconButton(
    systemImage: String,
    accessibilityLabel: String,
    tint: Color = CepessaColors.textSecondary,
    fill: Color = Color.white.opacity(0.36),
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Image(systemName: systemImage)
        .scaledFont(size: 13, weight: .semibold)
        .foregroundColor(tint)
        .frame(width: 42, height: 42)
        .background {
          if #available(macOS 26.0, *) {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
              .fill(fill.opacity(0.24))
              .glassEffect(
                .regular.tint(fill.opacity(0.18)).interactive(),
                in: .rect(cornerRadius: 18)
              )
          } else {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
              .fill(.ultraThinMaterial)

            RoundedRectangle(cornerRadius: 18, style: .continuous)
              .fill(fill)
          }
        }
        .overlay {
          RoundedRectangle(cornerRadius: 18, style: .continuous)
            .stroke(Color.white.opacity(0.76), lineWidth: 1)
        }
        .overlay {
          RoundedRectangle(cornerRadius: 18, style: .continuous)
            .stroke(CepessaColors.border.opacity(0.24), lineWidth: 1)
            .padding(0.5)
        }
        .shadow(color: CepessaColors.warmShadow.opacity(0.10), radius: 12, x: 0, y: 7)
    }
    .buttonStyle(CepessaPressStyle(scale: 0.965, pressedBrightness: -0.02))
    .accessibilityLabel(accessibilityLabel)
  }

  fileprivate func floatingDocumentChat(for layout: WorkspaceLayoutMode) -> some View {
    CepessaSessionDocumentChatView(
      model: model,
      session: selectedSession,
      draftText: $documentChatDraft,
      onClose: {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
          isDocumentChatOpen = false
        }
      }
    )
    .frame(
      minWidth: layout == .stacked ? 0 : 440,
      idealWidth: layout == .stacked ? 420 : 560,
      maxWidth: layout == .stacked ? .infinity : 640
    )
  }

  @ViewBuilder
  fileprivate func activitySurface(
    for layout: WorkspaceLayoutMode,
    snapshot: LocalSessionProcessingSnapshot
  ) -> some View {
    activitySurfaceContent(for: layout, snapshot: snapshot)
  }

  fileprivate func activitySurfaceContent(
    for layout: WorkspaceLayoutMode,
    snapshot: LocalSessionProcessingSnapshot
  ) -> some View {
    let isWide = layout == .wide

    return VStack(spacing: 10) {
      if !isWide && isActivityPopoverOpen {
        activityPopover
          .transition(.opacity.combined(with: .offset(y: reduceMotion ? 0 : 4)))
      }

      activityCapsule(snapshot)

      if isWide && isActivityPopoverOpen {
        activityPopover
          .transition(.opacity.combined(with: .offset(y: reduceMotion ? 0 : -4)))
      }
    }
    .frame(maxWidth: isWide ? 560 : .infinity)
    .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: isActivityPopoverOpen)
  }

  fileprivate func activityCapsule(_ snapshot: LocalSessionProcessingSnapshot) -> some View {
    VStack(spacing: 8) {
      HStack(alignment: .center, spacing: 11) {
        ProcessingWaveformGlyph(tint: activityTint(for: snapshot), reduceMotion: reduceMotion)
          .frame(width: 24, height: 24)

        VStack(alignment: .leading, spacing: 2) {
          HStack(spacing: 7) {
            Text(activityTitle(for: snapshot))
              .scaledFont(size: 12.5, weight: .semibold)
              .foregroundColor(CepessaColors.textPrimary)
              .lineLimit(1)

            if model.processingQueue.count > 1 {
              Text(activeQueueSummary)
                .scaledFont(size: 10.5, weight: .semibold)
                .foregroundColor(CepessaColors.textSecondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(CepessaColors.backgroundRaised.opacity(0.72), in: Capsule())
            }
          }

          Text(activityDetail(for: snapshot))
            .scaledFont(size: 11)
            .foregroundColor(CepessaColors.textSecondary)
            .lineLimit(1)
        }

        Spacer(minLength: 10)

        if let progressLabel = snapshot.progressLabel {
          Text(progressLabel)
            .scaledFont(size: 11, weight: .semibold)
            .foregroundColor(CepessaColors.textSecondary)
            .monospacedDigit()
            .contentTransition(.numericText())
        } else {
          Text("Working")
            .scaledFont(size: 10.5, weight: .semibold)
            .foregroundColor(activityTint(for: snapshot))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(activityTint(for: snapshot).opacity(0.10), in: Capsule())
        }

        Image(systemName: "chevron.down")
          .scaledFont(size: 8.5, weight: .bold)
          .foregroundColor(CepessaColors.textTertiary)
          .rotationEffect(.degrees(isActivityPopoverOpen ? 180 : 0))
      }

      activityProgressTrace(progress: snapshot.progress, tint: activityTint(for: snapshot))
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .frame(maxWidth: .infinity)
    .contentShape(Capsule())
    .onTapGesture {
      withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) {
        isActivityPopoverOpen.toggle()
      }
    }
    .background(
      Capsule()
        .fill(CepessaColors.paperRaised.opacity(0.96))
    )
    .overlay {
      Capsule()
        .stroke(Color.white.opacity(0.88), lineWidth: 0.8)
    }
    .overlay {
      Capsule()
        .stroke(activityTint(for: snapshot).opacity(0.34), lineWidth: 0.8)
        .padding(0.5)
    }
    .shadow(color: CepessaColors.warmShadow.opacity(0.18), radius: 24, x: 0, y: 14)
    .help("Show active local work.")
    .accessibilityLabel("\(activityTitle(for: snapshot)), \(activityDetail(for: snapshot))")
  }

  fileprivate var activityPopover: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        Text("Active work")
          .scaledFont(size: 12, weight: .semibold)
          .foregroundColor(CepessaColors.textPrimary)

        Spacer(minLength: 0)

        Text(activeQueueSummary)
          .scaledFont(size: 10.5, weight: .semibold)
          .foregroundColor(CepessaColors.textSecondary)
          .monospacedDigit()
      }
      .padding(.horizontal, 4)

      ForEach(model.processingQueue) { snapshot in
        Button {
          model.selectSession(id: snapshot.id)
          withAnimation(reduceMotion ? nil : .easeOut(duration: 0.14)) {
            isActivityPopoverOpen = false
          }
        } label: {
          activityPopoverRow(snapshot)
        }
        .buttonStyle(CepessaPressStyle(scale: 0.985, pressedBrightness: -0.01))
        .help("Open \(sessionTitle(for: snapshot.id)).")
        .accessibilityLabel("\(sessionTitle(for: snapshot.id)), \(activityTitle(for: snapshot))")
      }
    }
    .padding(10)
    .background(
      RoundedRectangle(cornerRadius: 28, style: .continuous)
        .fill(CepessaColors.paperRaised.opacity(0.96))
    )
    .overlay {
      RoundedRectangle(cornerRadius: 28, style: .continuous)
        .stroke(Color.white.opacity(0.88), lineWidth: 0.8)
    }
    .overlay {
      RoundedRectangle(cornerRadius: 28, style: .continuous)
        .stroke(CepessaColors.border.opacity(0.28), lineWidth: 0.8)
        .padding(0.5)
    }
    .shadow(color: CepessaColors.warmShadow.opacity(0.20), radius: 30, x: 0, y: 16)
  }

  fileprivate func activityPopoverRow(_ snapshot: LocalSessionProcessingSnapshot) -> some View {
    let recentLogEntries = Array(snapshot.logEntries.suffix(3))

    return VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .center, spacing: 9) {
        ProcessingWaveformGlyph(tint: activityTint(for: snapshot), reduceMotion: reduceMotion)
          .frame(width: 20, height: 20)

        VStack(alignment: .leading, spacing: 2) {
          Text(sessionTitle(for: snapshot.id))
            .scaledFont(size: 12.5, weight: .semibold)
            .foregroundColor(CepessaColors.textPrimary)
            .lineLimit(1)

          Text(activityTitle(for: snapshot))
            .scaledFont(size: 10.5, weight: .medium)
            .foregroundColor(CepessaColors.textSecondary)
            .lineLimit(1)
        }

        Spacer(minLength: 0)

        if let progressLabel = snapshot.progressLabel {
          Text(progressLabel)
            .scaledFont(size: 10.5, weight: .semibold)
            .foregroundColor(CepessaColors.textTertiary)
            .monospacedDigit()
        }
      }

      Text(snapshot.detail)
        .scaledFont(size: 11)
        .foregroundColor(CepessaColors.textSecondary)
        .lineLimit(2)

      if !recentLogEntries.isEmpty {
        VStack(alignment: .leading, spacing: 5) {
          ForEach(recentLogEntries) { entry in
            HStack(alignment: .firstTextBaseline, spacing: 6) {
              Circle()
                .fill(activityTint(for: snapshot).opacity(0.58))
                .frame(width: 4, height: 4)

              Text(entry.message)
                .scaledFont(size: 10.5)
                .foregroundColor(CepessaColors.textSecondary)
                .lineLimit(1)
            }
          }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(
          CepessaColors.backgroundRaised.opacity(0.74),
          in: RoundedRectangle(cornerRadius: 12, style: .continuous))
      }

      activityProgressTrace(progress: snapshot.progress, tint: activityTint(for: snapshot))
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: 18, style: .continuous)
        .fill(
          model.selectedSessionID == snapshot.id
            ? CepessaColors.backgroundRaised.opacity(0.84)
            : Color.white.opacity(0.46)
        )
    )
    .overlay {
      RoundedRectangle(cornerRadius: 18, style: .continuous)
        .stroke(
          model.selectedSessionID == snapshot.id
            ? activityTint(for: snapshot).opacity(0.32)
            : CepessaColors.border.opacity(0.18),
          lineWidth: 0.8
        )
    }
  }

  fileprivate func activityProgressTrace(progress: Double?, tint: Color) -> some View {
    GeometryReader { proxy in
      let width = proxy.size.width
      let clampedProgress = min(max(progress ?? 0.34, 0), 1)
      let traceWidth = progress == nil ? max(38, width * 0.34) : max(12, width * clampedProgress)

      ZStack(alignment: .leading) {
        Capsule()
          .fill(CepessaColors.border.opacity(0.20))

        Capsule()
          .fill(tint.opacity(progress == nil ? 0.42 : 0.78))
          .frame(width: traceWidth)
          .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: progress)
      }
    }
    .frame(height: 3)
  }

  @ViewBuilder
  fileprivate func workspaceColumns(for layout: WorkspaceLayoutMode, availableHeight: CGFloat)
    -> some View
  {
    let contentHeight = max(availableHeight - 196, 560)

    switch layout {
    case .wide:
      HStack(alignment: .top, spacing: 0) {
        centerWorkspace(for: layout)
          .frame(minWidth: 640, idealWidth: 820, maxWidth: .infinity)

        inspectorRail
          .frame(width: 304)
          .frame(minHeight: max(640, availableHeight), alignment: .top)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)

    case .split:
      VStack(alignment: .leading, spacing: 18) {
        if selectedSession == nil {
          captureStatusCard
        }

        centerWorkspace(for: layout)
          .frame(minHeight: max(520, contentHeight * 0.72), maxHeight: .infinity)

        if selectedSession == nil {
          sessionsRail
            .frame(
              minHeight: max(240, contentHeight * 0.28),
              maxHeight: max(280, contentHeight * 0.34))
        }
      }
      .frame(maxHeight: .infinity, alignment: .top)

    case .stacked:
      VStack(alignment: .leading, spacing: 18) {
        if selectedSession == nil {
          captureStatusCard
        }

        centerWorkspace(for: layout)
          .frame(minHeight: max(380, contentHeight * 0.56))

        if selectedSession == nil {
          sessionsRail
            .frame(
              minHeight: max(220, contentHeight * 0.28),
              maxHeight: max(300, contentHeight * 0.34))
        }
      }
      .frame(maxHeight: .infinity, alignment: .top)
    }
  }

  fileprivate var sessionsRail: some View {
    VStack(alignment: .leading, spacing: 14) {
      railHeader(
        title: "Sessions",
        subtitle: "Local recordings and notes."
      )

      if !model.sessions.isEmpty {
        sessionSearchField
        sessionCountLine
      }

      if model.sessions.isEmpty {
        emptyStateCard(
          icon: "waveform.badge.mic",
          title: "No sessions yet",
          message: "Start or import a recording."
        )
      } else if filteredSessions.isEmpty {
        emptyStateCard(
          icon: "magnifyingglass.circle",
          title: "No matching sessions",
          message: "Try a title, transcript line, or note."
        )
      } else {
        ScrollView {
          LazyVStack(spacing: 10) {
            ForEach(filteredSessions) { session in
              sessionCard(session)
            }
          }
          .overlay(alignment: .leading) {
            Rectangle()
              .fill(CepessaColors.hairline.opacity(0.46))
              .frame(width: 1)
              .padding(.leading, 8)
              .padding(.vertical, 4)
          }
        }
        .scrollIndicators(.hidden)
      }
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 18)
    .frame(maxHeight: .infinity, alignment: .top)
    .cepessaGlassPanel(
      radius: 34,
      fill: CepessaColors.paperRaised,
      fillOpacity: 0.18,
      strokeOpacity: 0.52,
      shadowOpacity: 0.08
    )
  }

  fileprivate var sessionSearchField: some View {
    HStack(spacing: 9) {
      Image(systemName: "magnifyingglass")
        .scaledFont(size: 12, weight: .semibold)
        .foregroundColor(CepessaColors.textTertiary)

      TextField("Search sessions, transcripts, context", text: $sessionSearchText)
        .textFieldStyle(.plain)
        .scaledFont(size: 12)
        .foregroundColor(CepessaColors.textPrimary)
        .accessibilityLabel("Search sessions")

      if isFilteringSessions {
        Button {
          sessionSearchText = ""
        } label: {
          Image(systemName: "xmark.circle.fill")
            .scaledFont(size: 12, weight: .semibold)
        }
        .buttonStyle(.plain)
        .foregroundColor(CepessaColors.textTertiary)
        .help("Clear session search")
        .accessibilityLabel("Clear session search")
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
    .background(CepessaColors.backgroundRaised.opacity(0.74))
    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 16, style: .continuous)
        .stroke(CepessaColors.border.opacity(0.18), lineWidth: 1)
    )
  }

  fileprivate var sessionCountLine: some View {
    HStack(spacing: 7) {
      Image(systemName: isFilteringSessions ? "line.3.horizontal.decrease.circle" : "externaldrive")
        .scaledFont(size: 11, weight: .semibold)
        .foregroundColor(CepessaColors.textTertiary)

      Text(sessionCountLabel)
        .scaledFont(size: 11, weight: .medium)
        .foregroundColor(CepessaColors.textSecondary)

      Spacer(minLength: 0)
    }
    .padding(.horizontal, 2)
  }

  fileprivate func centerWorkspace(for layout: WorkspaceLayoutMode) -> some View {
    ZStack(alignment: .bottom) {
      ScrollViewReader { scrollProxy in
        ScrollView {
          VStack(alignment: .leading, spacing: 16) {
            Color.clear
              .frame(height: 0)
              .id("centerWorkspaceTop")

            currentCenterSection
              .id(centerSection)
              .transition(.opacity.combined(with: .offset(y: reduceMotion ? 0 : 6)))
          }
          .padding(.horizontal, 26)
          .padding(.top, 24)
          .padding(.bottom, centerSection == .transcript ? 178 : 148)
        }
        .scrollIndicators(.hidden)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: centerSection)
        .onChange(of: centerSection) { _, _ in
          withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
            scrollProxy.scrollTo("centerWorkspaceTop", anchor: .top)
          }
        }
        .onChange(of: model.selectedSessionID) { _, _ in
          withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
            scrollProxy.scrollTo("centerWorkspaceTop", anchor: .top)
          }
        }
      }

      if let exportToastMessage {
        exportToast(exportToastMessage)
          .padding(.horizontal, 34)
          .padding(.bottom, 88)
          .transition(.opacity.combined(with: .offset(y: reduceMotion ? 0 : 8)))
          .zIndex(2)
      }

      if layout != .wide && isSessionInspectorOverlayOpen {
        sessionInspectorOverlay
          .padding(.horizontal, 34)
          .padding(.bottom, 92)
          .transition(.opacity.combined(with: .offset(y: reduceMotion ? 0 : 8)))
          .zIndex(3)
      }

      floatingDocumentToolbar(for: layout)
        .padding(.horizontal, 34)
        .padding(.bottom, 26)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .background {
      ZStack {
        Rectangle()
          .fill(Color.white.opacity(0.78))

        LinearGradient(
          colors: [
            Color.white.opacity(0.92),
            Color(hex: 0xF8FBFF).opacity(0.70),
            Color.white.opacity(0.84),
          ],
          startPoint: .top,
          endPoint: .bottom
        )
      }
    }
    .overlay(alignment: .leading) {
      Rectangle()
        .fill(CepessaColors.border.opacity(0.34))
        .frame(width: 1)
    }
  }

  fileprivate var inspectorRail: some View {
    VStack(alignment: .leading, spacing: 22) {
      if let session = selectedSession {
        VStack(alignment: .leading, spacing: 18) {
          HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
              Text("Session")
                .scaledFont(size: 12, weight: .medium)
                .foregroundColor(CepessaColors.textTertiary)

              Text(session.displayTitle)
                .scaledFont(size: 14, weight: .semibold, design: .rounded)
                .foregroundColor(CepessaColors.textPrimary)
                .lineLimit(2)
            }

            Spacer(minLength: 0)

            Image(systemName: "star")
              .scaledFont(size: 14, weight: .medium)
              .foregroundColor(CepessaColors.textSecondary)
          }
        }

        VStack(alignment: .leading, spacing: 18) {
          inspectorField("Date", session.startedAt.formatted(date: .abbreviated, time: .omitted))
          inspectorField("Time", sessionTimeRange(for: session))
          inspectorField("Duration", compactDurationLabel(for: session))
          inspectorStatusField(displayStatus(for: session))
          inspectorField("Audio", audioSnapshotLabel(for: session))
        }

        VStack(alignment: .leading, spacing: 10) {
          Text("Files")
            .scaledFont(size: 12, weight: .medium)
            .foregroundColor(CepessaColors.textTertiary)

          inspectorFileRow(
            icon: "waveform", title: "Audio", value: audioRetentionValue(for: session))
          inspectorFileRow(
            icon: "text.alignleft", title: "Transcript", value: transcriptMemoryValue(for: session))
          inspectorFileRow(
            icon: "paperclip", title: "Context",
            value: countLabel(timelineArtifactCount(for: session), singular: "item"))
        }

        if model.canRetranscribe(session) {
          retranscribeSessionButton(for: session, compact: true)
        }
      } else {
        emptyStateCard(
          icon: "rectangle.stack",
          title: "No session selected",
          message: "Start or import a recording."
        )
      }

      Spacer(minLength: 0)
    }
    .padding(.leading, 26)
    .padding(.trailing, 22)
    .padding(.top, 24)
    .padding(.bottom, 26)
    .frame(maxHeight: .infinity, alignment: .top)
    .background {
      Rectangle()
        .fill(.ultraThinMaterial)
        .opacity(0.82)

      Rectangle()
        .fill(Color.white.opacity(0.66))

      LinearGradient(
        colors: [
          Color(hex: 0xF9FCFF).opacity(0.92),
          Color.white.opacity(0.60),
        ],
        startPoint: .top,
        endPoint: .bottom
      )
    }
    .overlay(alignment: .leading) {
      Rectangle()
        .fill(Color(hex: 0xA8C7F5).opacity(0.50))
        .frame(width: 1)
    }
  }

  @ViewBuilder
  fileprivate var sessionInspectorOverlay: some View {
    if let session = selectedSession {
      VStack(alignment: .leading, spacing: 14) {
        HStack(alignment: .top, spacing: 12) {
          VStack(alignment: .leading, spacing: 4) {
            Text("Session")
              .scaledFont(size: 11, weight: .medium)
              .foregroundColor(CepessaColors.textTertiary)

            Text(session.displayTitle)
              .scaledFont(size: 14, weight: .semibold, design: .rounded)
              .foregroundColor(CepessaColors.textPrimary)
              .lineLimit(2)
          }

          Spacer(minLength: 0)

          compactStatusBadge(displayStatus(for: session))

          Button {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.14)) {
              isSessionInspectorOverlayOpen = false
            }
          } label: {
            Image(systemName: "xmark")
              .scaledFont(size: 10.5, weight: .bold)
              .foregroundColor(CepessaColors.textTertiary)
              .frame(width: 26, height: 26)
              .contentShape(Circle())
          }
          .buttonStyle(CepessaPressStyle(scale: 0.965, pressedBrightness: -0.02))
          .help("Close session details")
          .accessibilityLabel("Close session details")
        }

        LazyVGrid(
          columns: [GridItem(.adaptive(minimum: 126), spacing: 10, alignment: .leading)],
          alignment: .leading,
          spacing: 10
        ) {
          compactInspectorMetric(
            icon: "calendar",
            title: "Date",
            value: session.startedAt.formatted(date: .abbreviated, time: .omitted)
          )
          compactInspectorMetric(
            icon: "clock", title: "Time", value: sessionTimeRange(for: session))
          compactInspectorMetric(
            icon: "timer",
            title: "Duration",
            value: compactDurationLabel(for: session)
          )
          compactInspectorMetric(
            icon: "waveform",
            title: "Audio",
            value: audioSnapshotLabel(for: session)
          )
          compactInspectorMetric(
            icon: "text.alignleft",
            title: "Transcript",
            value: transcriptMemoryValue(for: session)
          )
          compactInspectorMetric(
            icon: "paperclip",
            title: "Context",
            value: countLabel(timelineArtifactCount(for: session), singular: "item")
          )
        }

        if model.canRetranscribe(session) {
          retranscribeSessionButton(for: session, compact: true)
        }
      }
      .padding(.horizontal, 18)
      .padding(.vertical, 16)
      .frame(width: 382, alignment: .leading)
      .cepessaGlassPanel(
        radius: 26,
        fill: CepessaColors.paperRaised,
        fillOpacity: 0.18,
        strokeOpacity: 0.42,
        shadowOpacity: 0.07
      )
      .frame(maxWidth: .infinity, alignment: .trailing)
    }
  }

  fileprivate func compactStatusBadge(_ status: LocalMeetingSessionStatus) -> some View {
    Text(statusLabel(status))
      .scaledFont(size: 11, weight: .semibold)
      .foregroundColor(status == .ready ? CepessaColors.mossDeep : .white)
      .padding(.horizontal, 9)
      .padding(.vertical, 5)
      .background(
        status == .ready
          ? CepessaColors.moss.opacity(0.18)
          : statusBackground(for: status).opacity(0.92),
        in: Capsule()
      )
      .fixedSize()
  }

  fileprivate func compactInspectorMetric(icon: String, title: String, value: String) -> some View {
    HStack(spacing: 9) {
      Image(systemName: icon)
        .scaledFont(size: 11, weight: .semibold)
        .foregroundColor(CepessaColors.textSecondary)
        .frame(width: 24, height: 24)
        .background(Color.white.opacity(0.56))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .scaledFont(size: 10.5, weight: .medium)
          .foregroundColor(CepessaColors.textTertiary)
          .lineLimit(1)

        Text(value)
          .scaledFont(size: 11.5, weight: .semibold)
          .foregroundColor(CepessaColors.textPrimary)
          .lineLimit(1)
      }

      Spacer(minLength: 0)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 9)
    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
    .background(Color.white.opacity(0.54))
    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .stroke(CepessaColors.border.opacity(0.18), lineWidth: 0.8)
    }
  }

  fileprivate var sessionMemoryCard: some View {
    VStack(alignment: .leading, spacing: 14) {
      rowHeader(
        title: "Local files",
        subtitle: "Audio, transcript, and context."
      )

      if let session = selectedSession {
        memoryLine(icon: "waveform", title: "Raw audio", value: audioRetentionValue(for: session))
        memoryLine(
          icon: "text.alignleft", title: "Transcript", value: transcriptMemoryValue(for: session))
        memoryLine(
          icon: "paperclip", title: "Context",
          value: countLabel(timelineArtifactCount(for: session), singular: "item"))

        if model.canRetranscribe(session) {
          retranscribeSessionButton(for: session)
        }
      } else {
        emptyStateCard(
          icon: "externaldrive",
          title: "No session selected",
          message: "Pick a session to see what is already saved on this Mac."
        )
      }
    }
    .padding(16)
    .cepessaPaper(radius: 28)
  }

  fileprivate func floatingDocumentToolbar(for layout: WorkspaceLayoutMode) -> some View {
    HStack(alignment: .center, spacing: 7) {
      if selectedSession != nil {
        nativeToolbarIconButton(
          systemImage: "chevron.left",
          accessibilityLabel: "Back to sessions",
          help: "Clear the selected session."
        ) {
          model.clearSelection()
        }

        toolbarDivider
      }

      compactSectionMenu

      toolbarDivider

      compactLanguageMenu

      if selectedSession != nil {
        compactDocumentChatButton
        if layout != .wide {
          compactSessionInspectorButton
        }
        compactRewriteButton
        compactDownloadMenu
      }

      toolbarDivider

      compactStartButton

      compactImportButton
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
    .cepessaFloatingToolbarSurface()
  }

  fileprivate var compactDocumentChatButton: some View {
    nativeToolbarIconButton(
      systemImage: isDocumentChatOpen
        ? "bubble.left.and.text.bubble.right.fill" : "bubble.left.and.text.bubble.right",
      accessibilityLabel: isDocumentChatOpen ? "Hide Chat" : "Ask Session",
      help: isDocumentChatOpen ? "Hide session chat" : "Ask Session"
    ) {
      openToolbarMenu = nil
      withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
        isDocumentChatOpen.toggle()
      }
    }
  }

  fileprivate var compactSessionInspectorButton: some View {
    nativeToolbarIconButton(
      systemImage: isSessionInspectorOverlayOpen ? "info.circle.fill" : "info.circle",
      accessibilityLabel: isSessionInspectorOverlayOpen
        ? "Hide session details" : "Show session details",
      help: isSessionInspectorOverlayOpen ? "Hide session details" : "Show session details"
    ) {
      openToolbarMenu = nil
      withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) {
        isSessionInspectorOverlayOpen.toggle()
      }
    }
  }

  fileprivate var compactSectionMenu: some View {
    CepessaToolbarMenu(
      isOpen: Binding(
        get: { openToolbarMenu == .section },
        set: { openToolbarMenu = $0 ? .section : nil }
      ),
      alignment: .leading,
      label: {
        nativeToolbarMenuLabel(title: centerSection.title, systemImage: centerSection.symbol)
          .accessibilityLabel("Document section")
      },
      content: {
        VStack(spacing: 4) {
          ForEach(WorkspaceSection.allCases) { section in
            cepessaMenuRow(
              title: section.title,
              subtitle: section.subtitle,
              systemImage: section.symbol,
              isSelected: centerSection == section
            ) {
              withAnimation(.spring(response: 0.24, dampingFraction: 0.92)) {
                centerSection = section
                openToolbarMenu = nil
              }
            }
          }
        }
        .frame(width: 224)
      }
    )
  }

  fileprivate var compactLanguageMenu: some View {
    CepessaToolbarMenu(
      isOpen: Binding(
        get: { openToolbarMenu == .language },
        set: { openToolbarMenu = $0 ? .language : nil }
      ),
      alignment: .center,
      label: {
        nativeToolbarMenuLabel(
          title: selectedDocumentLanguage.shortTitle,
          systemImage: "character.bubble"
        )
        .accessibilityLabel("Document language")
      },
      content: {
        VStack(spacing: 4) {
          ForEach(LocalSessionDocumentLanguage.allCases) { language in
            cepessaMenuRow(
              title: language.displayTitle,
              subtitle: language == .english ? "English brief" : "Hebrew brief",
              systemImage: "character.bubble",
              isSelected: selectedDocumentLanguage == language
            ) {
              documentLanguage = language.rawValue
              openToolbarMenu = nil
            }
          }
        }
        .frame(width: 196)
      }
    )
  }

  @ViewBuilder
  fileprivate var compactRewriteButton: some View {
    if let session = selectedSession {
      nativeToolbarIconButton(
        systemImage: model.isGeneratingRecap(for: session.id)
          ? "arrow.triangle.2.circlepath" : "arrow.clockwise",
        accessibilityLabel: model.isGeneratingRecap(for: session.id)
          ? "Updating document" : "Rewrite document",
        help: "Rewrite document"
      ) {
        model.regenerateRecap(for: session.id)
      }
      .disabled(
        model.isGeneratingRecap(for: session.id)
          || session.transcriptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      )
    }
  }

  @ViewBuilder
  fileprivate var compactDownloadMenu: some View {
    if selectedSession != nil {
      CepessaToolbarMenu(
        isOpen: Binding(
          get: { openToolbarMenu == .download },
          set: { openToolbarMenu = $0 ? .download : nil }
        ),
        alignment: .trailing,
        label: {
          Image(systemName: "square.and.arrow.down")
            .scaledFont(size: 12.5, weight: .medium)
            .frame(width: 40, height: 40)
            .contentShape(Rectangle())
            .accessibilityLabel("Download recap")
        },
        content: {
          VStack(alignment: .leading, spacing: 8) {
            ForEach(LocalSessionRecapExportFormat.allCases, id: \.rawValue) { format in
              VStack(alignment: .leading, spacing: 4) {
                Text(format.displayTitle)
                  .scaledFont(size: 10.5, weight: .semibold)
                  .foregroundColor(CepessaColors.textTertiary)
                  .padding(.horizontal, 9)
                  .padding(.top, format == .markdown ? 0 : 4)

                VStack(spacing: 2) {
                  downloadLanguageRows(for: format)
                }
              }
            }
          }
          .frame(width: 218)
        }
      )
      .buttonStyle(CepessaPressStyle(scale: 0.965, pressedBrightness: -0.02))
      .foregroundColor(CepessaColors.textSecondary)
      .help("Download recap")
    }
  }

  @ViewBuilder
  fileprivate func downloadLanguageRows(for format: LocalSessionRecapExportFormat) -> some View {
    ForEach(LocalSessionRecapExportLanguageSelection.allCases, id: \.rawValue) {
      languageSelection in
      cepessaMenuRow(
        title: languageSelection.displayTitle,
        subtitle: exportSubtitle(for: format, languages: languageSelection),
        systemImage: exportLanguageIcon(for: languageSelection),
        isSelected: false
      ) {
        exportSelectedRecap(format: format, languages: languageSelection)
        openToolbarMenu = nil
      }
    }
  }

  fileprivate func exportSubtitle(
    for format: LocalSessionRecapExportFormat,
    languages: LocalSessionRecapExportLanguageSelection
  ) -> String {
    switch (format, languages) {
    case (.markdown, .english):
      return "One .md file"
    case (.markdown, .hebrew):
      return "One Hebrew .md file"
    case (.markdown, .both):
      return "Two .md files"
    case (.pdf, .english):
      return "Designed English PDF"
    case (.pdf, .hebrew):
      return "Designed Hebrew PDF"
    case (.pdf, .both):
      return "Two designed PDFs"
    }
  }

  fileprivate func cepessaMenuRow(
    title: String,
    subtitle: String,
    systemImage: String,
    isSelected: Bool,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      HStack(alignment: .center, spacing: 10) {
        ZStack {
          RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(
              isSelected
                ? CepessaColors.accentPrimary.opacity(0.16)
                : CepessaColors.backgroundRaised.opacity(0.70)
            )
            .frame(width: 26, height: 26)

          Image(systemName: isSelected ? "checkmark" : systemImage)
            .scaledFont(size: 11, weight: .semibold)
            .foregroundColor(isSelected ? CepessaColors.accentPrimary : CepessaColors.textSecondary)
        }

        VStack(alignment: .leading, spacing: 1) {
          Text(title)
            .scaledFont(size: 12, weight: .semibold)
            .foregroundColor(CepessaColors.textPrimary)
            .lineLimit(1)

          Text(subtitle)
            .scaledFont(size: 10.5, weight: .medium)
            .foregroundColor(CepessaColors.textTertiary)
            .lineLimit(1)
        }

        Spacer(minLength: 0)
      }
      .padding(.horizontal, 9)
      .padding(.vertical, 7)
      .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
      .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
    .buttonStyle(CepessaPressStyle(scale: 0.985, pressedBrightness: -0.01))
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(title)
    .accessibilityValue(subtitle)
    .accessibilityAddTraits(isSelected ? [.isSelected] : [])
  }

  @ViewBuilder
  fileprivate var compactStartButton: some View {
    if model.isRecording {
      Button {
        model.toggleRecording()
      } label: {
        Label("Stop", systemImage: "stop.fill")
          .scaledFont(size: 12, weight: .semibold)
          .foregroundColor(.white)
          .padding(.horizontal, 13)
          .frame(height: 40)
          .background(CepessaColors.error.opacity(0.92), in: Capsule())
      }
      .buttonStyle(CepessaPressStyle(scale: 0.965, pressedBrightness: -0.02))
      .help("Stop the current recording session.")
    } else {
      Button {
        model.toggleRecording()
      } label: {
        Label("Start", systemImage: "record.circle.fill")
          .scaledFont(size: 12, weight: .semibold)
          .foregroundColor(CepessaColors.error)
          .padding(.horizontal, 13)
          .frame(height: 40)
          .background(CepessaColors.error.opacity(0.08), in: Capsule())
      }
      .buttonStyle(CepessaPressStyle(scale: 0.965, pressedBrightness: -0.02))
      .help("Start a new local session.")
    }
  }

  fileprivate var compactImportButton: some View {
    nativeToolbarIconButton(
      systemImage: "arrow.down.to.line",
      accessibilityLabel: "Import audio",
      help: "Import audio"
    ) {
      importRecording()
    }
  }

  fileprivate var toolbarDivider: some View {
    Rectangle()
      .fill(Color(nsColor: .separatorColor).opacity(0.65))
      .frame(width: 1, height: 20)
      .padding(.horizontal, 2)
  }

  fileprivate func nativeToolbarIconButton(
    systemImage: String,
    accessibilityLabel: String,
    help: String,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Image(systemName: systemImage)
        .scaledFont(size: 12.5, weight: .medium)
        .frame(width: 40, height: 40)
        .contentShape(Rectangle())
    }
    .buttonStyle(CepessaPressStyle(scale: 0.965, pressedBrightness: -0.02))
    .foregroundColor(CepessaColors.textSecondary)
    .help(help)
    .accessibilityLabel(accessibilityLabel)
  }

  fileprivate func exportLanguageIcon(
    for selection: LocalSessionRecapExportLanguageSelection
  ) -> String {
    switch selection {
    case .english: return "textformat.abc"
    case .hebrew: return "character.bubble"
    case .both: return "square.split.2x1"
    }
  }

  fileprivate func exportSelectedRecap(
    format: LocalSessionRecapExportFormat,
    languages: LocalSessionRecapExportLanguageSelection
  ) {
    guard let session = selectedSession else { return }

    do {
      let urls = try LocalSessionRecapExporter().export(
        session: session,
        format: format,
        languages: languages,
        to: downloadsDirectory
      )

      showExportToast(exportedMessage(for: urls, format: format, languages: languages))
    } catch {
      exportAlertMessage = "Could not export the recap: \(error.localizedDescription)"
    }
  }

  fileprivate var downloadsDirectory: URL {
    FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
      ?? FileManager.default.homeDirectoryForCurrentUser
  }

  fileprivate func exportedMessage(
    for urls: [URL],
    format: LocalSessionRecapExportFormat,
    languages: LocalSessionRecapExportLanguageSelection
  ) -> String {
    let fileLabel = urls.count == 1 ? "file" : "files"
    return
      "Downloaded \(urls.count) \(format.displayTitle) \(fileLabel) to Downloads (\(languages.displayTitle))."
  }

  fileprivate func showExportToast(_ message: String) {
    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) {
      exportToastMessage = message
    }

    Task { @MainActor in
      try? await Task.sleep(nanoseconds: 2_600_000_000)
      guard exportToastMessage == message else { return }
      withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) {
        exportToastMessage = nil
      }
    }
  }

  fileprivate func exportToast(_ message: String) -> some View {
    HStack(spacing: 10) {
      Image(systemName: "checkmark.circle.fill")
        .scaledFont(size: 14, weight: .semibold)
        .foregroundColor(CepessaColors.captureDeep)

      Text(message)
        .scaledFont(size: 12, weight: .semibold)
        .foregroundColor(CepessaColors.textPrimary)
        .lineLimit(2)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 11)
    .frame(maxWidth: 420, alignment: .leading)
    .background {
      if #available(macOS 26.0, *) {
        Capsule()
          .fill(Color.white.opacity(0.58))
          .glassEffect(
            .regular.tint(Color(hex: 0xDFF5EA).opacity(0.10)).interactive(),
            in: .capsule
          )
      } else {
        Capsule()
          .fill(.ultraThinMaterial)
      }
    }
    .overlay {
      Capsule()
        .stroke(Color.white.opacity(0.86), lineWidth: 0.8)
    }
    .shadow(color: CepessaColors.warmShadow.opacity(0.13), radius: 22, x: 0, y: 12)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(message)
  }

  fileprivate func nativeToolbarMenuLabel(title: String, systemImage: String) -> some View {
    HStack(spacing: 6) {
      Image(systemName: systemImage)
        .scaledFont(size: 11.5, weight: .medium)
        .foregroundColor(CepessaColors.textSecondary)

      Text(title)
        .scaledFont(size: 12.5, weight: .medium)
        .foregroundColor(CepessaColors.textPrimary)

      Image(systemName: "chevron.down")
        .scaledFont(size: 8.5, weight: .semibold)
        .foregroundColor(CepessaColors.textTertiary)
    }
    .padding(.horizontal, 12)
    .frame(height: 40)
    .cepessaFloatingToolbarPillSurface()
  }

  fileprivate var recapCard: some View {
    VStack(alignment: .leading, spacing: 0) {
      if let session = selectedSession {
        LocalSessionMarkdownDocumentPreview(
          markdown: LocalSessionRecapMarkdownDocument(
            session: session,
            language: selectedDocumentLanguage
          ).markdown,
          language: selectedDocumentLanguage
        )
      } else {
        emptyStateCard(
          icon: "rectangle.stack.badge.minus",
          title: "Select a session",
          message: "The recap surface appears once a session is selected from the list."
        )
      }
    }
    .frame(maxWidth: .infinity, alignment: .top)
  }

  @ViewBuilder
  fileprivate var currentCenterSection: some View {
    switch centerSection {
    case .recap:
      recapCard
    case .decisions:
      focusedRecapSectionCard(
        title: "Decisions",
        subtitle: "What was decided and why.",
        kinds: [.decisions, .keyPoints],
        icon: "checkmark.circle",
        emptyMessage: "Decisions appear here after the recap is ready."
      )
    case .actions:
      focusedRecapSectionCard(
        title: "Action Items",
        subtitle: "Follow-ups pulled from the meeting.",
        kinds: [.actionItem, .nextSteps],
        icon: "list.bullet",
        emptyMessage: "Action items appear here after the recap is ready."
      )
    case .transcript:
      transcriptWorkspaceCard
    }
  }

  fileprivate var transcriptWorkspaceCard: some View {
    VStack(alignment: .leading, spacing: 14) {
      rowHeader(
        title: "Transcript",
        subtitle: "Timecoded notes with screenshots pinned to the matching moment."
      )

      if let session = selectedSession {
        let transcript = session.transcriptText.trimmingCharacters(in: .whitespacesAndNewlines)

        if transcript.isEmpty {
          emptyStateCard(
            icon: "text.bubble",
            title: "Transcript not ready",
            message: transcriptPendingMessage(for: session)
          )
        } else {
          VStack(alignment: .leading, spacing: 12) {
            ForEach(session.transcriptTimelineItems) { item in
              transcriptTimelineRow(item, in: session)
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
      } else {
        emptyStateCard(
          icon: "rectangle.stack.badge.minus",
          title: "Select a session",
          message: "The transcript appears here after you pick a session."
        )
      }
    }
    .frame(maxWidth: .infinity, alignment: .topLeading)
  }

  fileprivate func transcriptTimelineRow(
    _ item: LocalSessionTranscriptTimelineItem,
    in session: LocalMeetingSession
  ) -> some View {
    let hasContext = !item.attachments.isEmpty || !item.captureArtifacts.isEmpty
    let bullets = transcriptBullets(from: item.segment.text)

    return HStack(alignment: .top, spacing: 16) {
      transcriptTimelineRail(item, in: session, hasContext: hasContext)
        .frame(width: 152, alignment: .topLeading)

      VStack(alignment: .leading, spacing: 12) {
        HStack(alignment: .center, spacing: 8) {
          Text(item.segment.speaker)
            .scaledFont(size: 11.5, weight: .semibold)
            .foregroundColor(CepessaColors.textPrimary)
            .lineLimit(1)

          if hasContext {
            transcriptContextChip(for: item)
          }

          Spacer(minLength: 0)
        }

        VStack(alignment: .leading, spacing: 8) {
          ForEach(bullets, id: \.self) { bullet in
            HStack(alignment: .top, spacing: 9) {
              Circle()
                .fill(hasContext ? CepessaColors.info.opacity(0.72) : CepessaColors.textQuaternary)
                .frame(width: 5.5, height: 5.5)
                .padding(.top, 7)

              Text(bullet)
                .scaledFont(size: 14.5)
                .lineSpacing(3.5)
                .foregroundColor(CepessaColors.textPrimary.opacity(0.88))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            }
          }
        }

        if !item.captureArtifacts.isEmpty {
          HStack(alignment: .center, spacing: 7) {
            ForEach(item.captureArtifacts.prefix(3)) { artifact in
              Label(
                captureArtifactTitle(for: artifact),
                systemImage: captureArtifactIcon(for: artifact)
              )
              .scaledFont(size: 10.5, weight: .medium)
              .foregroundColor(CepessaColors.textSecondary)
              .lineLimit(1)
              .padding(.horizontal, 9)
              .padding(.vertical, 5)
              .background(Color.white.opacity(0.58), in: Capsule())
            }
          }
        }
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 15)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        RoundedRectangle(cornerRadius: 20, style: .continuous)
          .fill(hasContext ? Color(hex: 0xF4F8FA).opacity(0.90) : Color.white.opacity(0.64))
      )
      .overlay {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
          .stroke(
            hasContext ? CepessaColors.info.opacity(0.16) : CepessaColors.border.opacity(0.16),
            lineWidth: 1
          )
      }
    }
    .padding(.vertical, 4)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(
      "\(item.segment.speaker), \(transcriptTimeRangeLabel(for: item.segment, in: session)), \(item.segment.text)"
    )
  }

  fileprivate func transcriptTimelineRail(
    _ item: LocalSessionTranscriptTimelineItem,
    in session: LocalMeetingSession,
    hasContext: Bool
  ) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 9) {
        ZStack {
          Circle()
            .fill(hasContext ? CepessaColors.info.opacity(0.15) : CepessaColors.backgroundRaised)
            .frame(width: 34, height: 34)

          Image(systemName: "play.fill")
            .scaledFont(size: 12, weight: .bold)
            .foregroundColor(hasContext ? CepessaColors.info : CepessaColors.textTertiary)
            .offset(x: 1)
        }

        transcriptWaveformGlyph(tint: hasContext ? CepessaColors.info : CepessaColors.textTertiary)
          .frame(width: 40, height: 18)

        Circle()
          .fill(Color.white)
          .frame(width: 30, height: 30)
          .overlay {
            Image(systemName: speakerIcon(for: item.segment.speaker))
              .scaledFont(size: 13, weight: .semibold)
              .foregroundColor(CepessaColors.textSecondary)
          }
          .overlay {
            Circle()
              .stroke(Color.white.opacity(0.92), lineWidth: 1)
          }
      }

      Text(transcriptTimeRangeLabel(for: item.segment, in: session))
        .scaledFont(size: 20, weight: .medium, design: .rounded)
        .monospacedDigit()
        .foregroundColor(CepessaColors.textTertiary)
        .lineLimit(1)

      if !item.attachments.isEmpty {
        HStack(spacing: -10) {
          ForEach(item.attachments.prefix(3)) { attachment in
            timelineAttachmentThumbnail(attachment)
          }
        }
        .padding(.top, 2)
      }
    }
    .padding(.leading, 2)
  }

  fileprivate func transcriptContextChip(for item: LocalSessionTranscriptTimelineItem) -> some View
  {
    let label =
      item.captureArtifacts.first.map { captureArtifactTitle(for: $0) }
      ?? item.attachments.first.map { attachmentTitle(for: $0) }
      ?? "Context"

    return Text(label)
      .scaledFont(size: 11.5, weight: .semibold, design: .rounded)
      .foregroundColor(CepessaColors.info.opacity(0.88))
      .lineLimit(1)
      .padding(.horizontal, 11)
      .padding(.vertical, 6)
      .background(CepessaColors.info.opacity(0.10), in: Capsule())
      .overlay {
        Capsule()
          .stroke(CepessaColors.info.opacity(0.12), lineWidth: 0.8)
      }
  }

  fileprivate func timelineAttachmentThumbnail(_ attachment: LocalMeetingAttachment) -> some View {
    ZStack {
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .fill(Color.white.opacity(0.72))

      if let image = thumbnailImage(for: attachment) {
        Image(nsImage: image)
          .resizable()
          .scaledToFill()
      } else {
        Image(systemName: icon(for: attachment))
          .scaledFont(size: 15, weight: .semibold)
          .foregroundColor(CepessaColors.textSecondary)
      }
    }
    .frame(width: 68, height: 50)
    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .stroke(Color.white.opacity(0.92), lineWidth: 1.2)
    }
    .shadow(color: CepessaColors.warmShadow.opacity(0.11), radius: 12, x: 0, y: 5)
  }

  fileprivate func transcriptWaveformGlyph(tint: Color) -> some View {
    HStack(alignment: .center, spacing: 3) {
      ForEach(Array([10.0, 17.0, 23.0, 15.0, 20.0].enumerated()), id: \.offset) { _, height in
        Capsule()
          .fill(tint.opacity(0.56))
          .frame(width: 4, height: height)
      }
    }
  }

  fileprivate func transcriptBullets(from text: String) -> [String] {
    let lines =
      text
      .components(separatedBy: .newlines)
      .map {
        $0.trimmingCharacters(in: .whitespacesAndNewlines)
          .trimmingCharacters(in: CharacterSet(charactersIn: "-•*"))
          .trimmingCharacters(in: .whitespacesAndNewlines)
      }
      .filter { !$0.isEmpty }

    return lines.isEmpty ? ["Uncaptured speech."] : lines
  }

  fileprivate func transcriptTimeRangeLabel(
    for segment: LocalMeetingTranscriptSegment,
    in session: LocalMeetingSession
  ) -> String {
    let start = max(0, segment.timestamp.timeIntervalSince(session.startedAt))
    guard let endTimestamp = segment.endTimestamp else {
      return timeString(from: start)
    }

    let end = max(start, endTimestamp.timeIntervalSince(session.startedAt))
    guard Int(start.rounded()) != Int(end.rounded()) else {
      return timeString(from: start)
    }

    return "\(timeString(from: start)) -> \(timeString(from: end))"
  }

  fileprivate func thumbnailImage(for attachment: LocalMeetingAttachment) -> NSImage? {
    guard attachment.kind == .image || attachment.kind == .capture else { return nil }

    if let urlString = attachment.urlString {
      if urlString.hasPrefix("/") {
        return NSImage(contentsOfFile: urlString)
      }

      if let url = URL(string: urlString), url.isFileURL {
        return NSImage(contentsOf: url)
      }
    }

    return nil
  }

  fileprivate func speakerIcon(for speaker: String) -> String {
    if speaker.localizedCaseInsensitiveContains("remote") {
      return "person.wave.2"
    }

    if speaker.localizedCaseInsensitiveContains("you") {
      return "person.crop.circle"
    }

    return "person.fill"
  }

  fileprivate func focusedRecapSectionCard(
    title: String,
    subtitle: String,
    kinds: [LocalSessionRecapSection.Kind],
    icon: String,
    emptyMessage: String
  ) -> some View {
    VStack(alignment: .leading, spacing: 14) {
      rowHeader(title: title, subtitle: subtitle)

      if let session = selectedSession {
        if let section = recapSection(for: session, kinds: kinds) {
          spatialNoteCard(
            title: section.title.isEmpty ? title : section.title,
            body: noteBody(for: section, fallback: emptyMessage),
            bullets: noteBullets(for: section),
            systemImage: icon,
            tint: CepessaColors.captureDeep,
            emphasis: true
          )
        } else {
          emptyStateCard(
            icon: icon,
            title: title,
            message: emptyMessage
          )
        }
      } else {
        emptyStateCard(
          icon: "rectangle.stack.badge.minus",
          title: "Select a session",
          message: "Choose a session to inspect this section."
        )
      }
    }
    .padding(18)
    .cepessaPaper(radius: 30)
  }

  fileprivate var captureStatusCard: some View {
    VStack(alignment: .leading, spacing: 14) {
      rowHeader(
        title: "Now",
        subtitle: "Capture state."
      )

      HStack(alignment: .center, spacing: 10) {
        Circle()
          .fill(dockAccent)
          .frame(width: 10, height: 10)

        Text(statusTitle)
          .scaledFont(size: 14, weight: .semibold)
          .foregroundColor(CepessaColors.textPrimary)

        Spacer(minLength: 0)

        if model.isRecording {
          Text(model.recordingDurationText)
            .scaledFont(size: 12, weight: .medium)
            .foregroundColor(CepessaColors.textSecondary)
        }
      }

      Text(statusDescription)
        .scaledFont(size: 12)
        .foregroundColor(CepessaColors.textSecondary)

      VStack(alignment: .leading, spacing: 12) {
        meterRow(title: "Mic", value: model.micLevel, icon: "mic.fill")
        meterRow(title: "System", value: model.systemLevel, icon: "speaker.wave.2.fill")
      }

      if let error = model.recorderErrorMessage, !error.isEmpty {
        Text(error)
          .scaledFont(size: 12)
          .foregroundColor(CepessaColors.error)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(16)
    .cepessaPaper(radius: 28)
  }

  fileprivate var attachmentsCard: some View {
    VStack(alignment: .leading, spacing: 14) {
      rowHeader(
        title: "Context",
        subtitle: "Files, captures, and source audio."
      )

      if let session = selectedSession {
        VStack(alignment: .leading, spacing: 10) {
          HStack {
            Spacer(minLength: 0)
            heroActionButton(
              title: "Transcribe Recording",
              systemImage: "waveform.badge.plus"
            ) {
              importRecording()
            }
          }

          if session.captureArtifacts.isEmpty {
            artifactRow(
              title: "Context captures",
              icon: "paperclip",
              fileName: "No captures have been added yet.",
              showsStatusBadge: false
            )
          } else {
            ForEach(session.captureArtifacts.prefix(4)) { artifact in
              artifactRow(
                title: captureArtifactTitle(for: artifact),
                icon: captureArtifactIcon(for: artifact),
                fileName: captureArtifactSubtitle(for: artifact)
              )
            }
          }

          if !session.attachments.isEmpty {
            ForEach(session.attachments.prefix(4)) { attachment in
              artifactRow(
                title: attachmentTitle(for: attachment),
                icon: icon(for: attachment),
                fileName: attachmentSubtitle(for: attachment)
              )
            }
          }

          artifactRow(
            title: "Mic capture",
            icon: "mic",
            fileName: session.audioArtifacts.micFileName
          )

          artifactRow(
            title: "System capture",
            icon: "speaker.wave.2",
            fileName: session.audioArtifacts.systemFileName
          )

          artifactRow(
            title: "Mixed master",
            icon: "square.stack.3d.down.forward",
            fileName: session.audioArtifacts.mixedFileName
          )
        }
      } else {
        emptyStateCard(
          icon: "externaldrive.badge.xmark",
          title: "Nothing selected",
          message: "Attachments surface once a session is chosen."
        )
      }
    }
    .padding(16)
    .cepessaPaper(radius: 30)
  }

  fileprivate func sessionCard(_ session: LocalMeetingSession) -> some View {
    let isSelected = model.selectedSessionID == session.id
    let isHovered = hoveredSessionID == session.id
    let processingSnapshot = model.processingSnapshot(for: session.id)

    return VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .top, spacing: 10) {
        VStack(alignment: .leading, spacing: 4) {
          Text(session.displayTitle)
            .scaledFont(size: 14, weight: .semibold)
            .foregroundColor(CepessaColors.textPrimary)
            .lineLimit(2)

          Text(session.startedAt.formatted(date: .abbreviated, time: .shortened))
            .scaledFont(size: 11)
            .foregroundColor(CepessaColors.textSecondary)

          if let contentType = session.contentClassification?.type {
            Label(contentType.displayTitle, systemImage: contentTypeSystemImage(for: contentType))
              .scaledFont(size: 10, weight: .medium)
              .foregroundColor(CepessaColors.textTertiary)
              .lineLimit(1)
          }
        }

        Spacer(minLength: 0)

        statusBadge(for: displayStatus(for: session))
      }

      Text(sessionCardSummary(for: session, snapshot: processingSnapshot))
        .scaledFont(size: 12)
        .foregroundColor(CepessaColors.textSecondary)
        .lineLimit(2)

      if let progress = processingSnapshot?.progress {
        ProgressView(value: progress)
          .progressViewStyle(.linear)
          .tint(CepessaColors.accentPrimary)
      }

      HStack(alignment: .center, spacing: 10) {
        Text(session.startedAt.formatted(date: .omitted, time: .shortened))
          .scaledFont(size: 11)
          .foregroundColor(CepessaColors.textTertiary)

        Spacer(minLength: 0)

        if model.canRetranscribe(session), isHovered || isSelected {
          retranscribeSessionButton(for: session, compact: true)
        }
      }
    }
    .padding(.leading, 24)
    .padding(.trailing, 12)
    .padding(.vertical, 13)
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    .background(
      RoundedRectangle(cornerRadius: 18, style: .continuous)
        .fill(
          isSelected
            ? CepessaColors.graphite.opacity(0.46)
            : (isHovered ? Color.white.opacity(0.36) : Color.clear))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 18, style: .continuous)
        .stroke(
          isSelected ? Color.white.opacity(0.70) : Color.clear,
          lineWidth: 1
        )
    )
    .overlay(alignment: .leading) {
      Circle()
        .fill(
          isSelected
            ? CepessaColors.textPrimary
            : statusBackground(for: displayStatus(for: session)).opacity(0.72)
        )
        .frame(width: isSelected ? 11 : 9, height: isSelected ? 11 : 9)
        .padding(.leading, 4)
    }
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
    .accessibilityLabel("\(session.displayTitle), \(statusLabel(displayStatus(for: session)))")
    .accessibilityHint("Opens this session in the workspace.")
    .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    .accessibilityAction {
      model.selectSession(id: session.id)
    }
  }

  fileprivate func recapSectionCard(_ section: LocalMeetingRecapSection) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .top, spacing: 10) {
        Text(section.title)
          .scaledFont(size: 13, weight: .semibold)
          .foregroundColor(CepessaColors.textPrimary)

        Spacer(minLength: 0)

        if let offset = section.startOffset {
          Text(timeString(from: offset))
            .scaledFont(size: 10, weight: .medium)
            .foregroundColor(CepessaColors.textTertiary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(CepessaColors.backgroundRaised.opacity(0.72))
            .clipShape(Capsule())
        }
      }

      if !section.summary.isEmpty {
        Text(section.summary)
          .scaledFont(size: 12)
          .foregroundColor(CepessaColors.textSecondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      if !section.bullets.isEmpty {
        VStack(alignment: .leading, spacing: 8) {
          ForEach(section.bullets, id: \.self) { bullet in
            HStack(alignment: .top, spacing: 8) {
              Circle()
                .fill(CepessaColors.accentPrimary.opacity(0.84))
                .frame(width: 6, height: 6)
                .padding(.top, 5)

              Text(bullet)
                .scaledFont(size: 12)
                .foregroundColor(CepessaColors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            }
          }
        }
      }
    }
    .padding(14)
    .background(CepessaColors.backgroundRaised.opacity(0.78))
    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .stroke(CepessaColors.border.opacity(0.16), lineWidth: 1)
    )
  }

  fileprivate func meterRow(title: String, value: Double, icon: String) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Label(title, systemImage: icon)
          .scaledFont(size: 12, weight: .medium)
          .foregroundColor(CepessaColors.textSecondary)

        Spacer(minLength: 0)

        Text(percentText(value))
          .scaledFont(size: 11)
          .foregroundColor(CepessaColors.textTertiary)
      }

      GeometryReader { proxy in
        ZStack(alignment: .leading) {
          Capsule()
            .fill(CepessaColors.border.opacity(0.34))

          Capsule()
            .fill(meterFill(for: value))
            .frame(width: max(12, proxy.size.width * value))
        }
      }
      .frame(height: 10)
    }
  }

  fileprivate func artifactRow(
    title: String, icon: String, fileName: String?, showsStatusBadge: Bool = true
  ) -> some View {
    HStack(alignment: .top, spacing: 10) {
      ZStack {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .fill(CepessaColors.backgroundRaised.opacity(0.88))
          .frame(width: 30, height: 30)

        Image(systemName: icon)
          .scaledFont(size: 13, weight: .semibold)
          .foregroundColor(CepessaColors.textSecondary)
      }

      VStack(alignment: .leading, spacing: 4) {
        HStack(alignment: .center, spacing: 8) {
          Text(title)
            .scaledFont(size: 13, weight: .semibold)
            .foregroundColor(CepessaColors.textPrimary)

          if showsStatusBadge {
            Spacer(minLength: 0)

            statusBadge(for: (fileName == nil || fileName == "Not retained yet") ? .failed : .ready)
          }
        }

        Text(fileName ?? "Not retained yet")
          .scaledFont(size: 12)
          .foregroundColor(
            fileName == nil ? CepessaColors.textTertiary : CepessaColors.textSecondary
          )
          .lineLimit(2)
      }
    }
    .padding(12)
    .background(CepessaColors.backgroundRaised.opacity(0.78))
    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 16, style: .continuous)
        .stroke(CepessaColors.border.opacity(0.16), lineWidth: 1)
    )
  }

  fileprivate func metricCard(title: String, value: String) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(title)
        .scaledFont(size: 11, weight: .medium)
        .foregroundColor(CepessaColors.textSecondary)

      Text(value)
        .scaledFont(size: 16, weight: .semibold)
        .foregroundColor(CepessaColors.textPrimary)
        .lineLimit(1)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.top, 10)
    .overlay(alignment: .top) {
      Rectangle()
        .fill(CepessaColors.hairline.opacity(0.72))
        .frame(height: 1)
    }
  }

  fileprivate func spatialRecapBoard(for session: LocalMeetingSession) -> some View {
    let summary = primaryRecapText(for: session)
    let decisions = recapSection(for: session, kinds: [.decisions, .keyPoints])
    let actionItems = recapSection(for: session, kinds: [.actionItem, .nextSteps])
    let keyFocus = keyFocusBullets(for: session)

    return VStack(alignment: .leading, spacing: 18) {
      ViewThatFits(in: .horizontal) {
        HStack(alignment: .top, spacing: 18) {
          spatialNoteCard(
            title: "Summary",
            body: summary,
            bullets: Array(recapLines(for: session).dropFirst().prefix(2)),
            systemImage: "doc.text",
            tint: CepessaColors.captureDeep,
            emphasis: true
          )
          .frame(minWidth: 360, idealWidth: 480, maxWidth: .infinity)

          spatialNoteCard(
            title: "Key Focus",
            body: "",
            bullets: keyFocus,
            systemImage: "scope",
            tint: Color(hex: 0xD79B22),
            warm: true
          )
          .frame(width: 220)
        }

        VStack(alignment: .leading, spacing: 12) {
          spatialNoteCard(
            title: "Summary",
            body: summary,
            bullets: Array(recapLines(for: session).dropFirst().prefix(2)),
            systemImage: "doc.text",
            tint: CepessaColors.captureDeep,
            emphasis: true
          )

          spatialNoteCard(
            title: "Key Focus",
            body: "",
            bullets: keyFocus,
            systemImage: "scope",
            tint: Color(hex: 0xD79B22),
            warm: true
          )
        }
      }

      ViewThatFits(in: .horizontal) {
        HStack(alignment: .top, spacing: 18) {
          spatialNoteCard(
            title: "Decisions",
            body: noteBody(for: decisions, fallback: "No decisions have been isolated yet."),
            bullets: noteBullets(for: decisions),
            systemImage: "checkmark.circle",
            tint: CepessaColors.captureDeep
          )

          spatialNoteCard(
            title: "Action Items",
            body: noteBody(
              for: actionItems, fallback: "Action items appear after the recap is ready."),
            bullets: noteBullets(for: actionItems),
            systemImage: "list.bullet",
            tint: CepessaColors.captureDeep
          )
        }

        VStack(alignment: .leading, spacing: 12) {
          spatialNoteCard(
            title: "Decisions",
            body: noteBody(for: decisions, fallback: "No decisions have been isolated yet."),
            bullets: noteBullets(for: decisions),
            systemImage: "checkmark.circle",
            tint: CepessaColors.captureDeep
          )

          spatialNoteCard(
            title: "Action Items",
            body: noteBody(
              for: actionItems, fallback: "Action items appear after the recap is ready."),
            bullets: noteBullets(for: actionItems),
            systemImage: "list.bullet",
            tint: CepessaColors.captureDeep
          )
        }
      }

    }
  }

  fileprivate func spatialNoteCard(
    title: String,
    body: String,
    bullets: [String],
    systemImage: String,
    tint: Color,
    emphasis: Bool = false,
    warm: Bool = false
  ) -> some View {
    VStack(alignment: .leading, spacing: emphasis ? 12 : 10) {
      HStack(alignment: .center, spacing: 9) {
        Image(systemName: systemImage)
          .scaledFont(size: 12, weight: .semibold)
          .foregroundColor(tint)
          .frame(width: 24, height: 24)
          .background(tint.opacity(0.12))
          .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

        Text(title)
          .scaledFont(size: emphasis ? 15 : 13, weight: .semibold, design: .rounded)
          .foregroundColor(CepessaColors.textPrimary)

        Spacer(minLength: 0)
      }

      if !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        Text(body.trimmingCharacters(in: .whitespacesAndNewlines))
          .scaledFont(size: emphasis ? 14 : 12.5)
          .lineSpacing(emphasis ? 4 : 3)
          .foregroundColor(CepessaColors.textSecondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      if !bullets.isEmpty {
        VStack(alignment: .leading, spacing: 7) {
          ForEach(bullets.prefix(3), id: \.self) { bullet in
            HStack(alignment: .top, spacing: 8) {
              Circle()
                .fill(tint.opacity(0.82))
                .frame(width: 5, height: 5)
                .padding(.top, 6)

              Text(bullet)
                .scaledFont(size: 12)
                .lineSpacing(2)
                .foregroundColor(CepessaColors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            }
          }
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .topLeading)
    .padding(emphasis ? 18 : 15)
    .background {
      if #available(macOS 26.0, *) {
        UnevenRoundedRectangle(
          topLeadingRadius: emphasis ? 32 : 26,
          bottomLeadingRadius: emphasis ? 24 : 22,
          bottomTrailingRadius: emphasis ? 34 : 28,
          topTrailingRadius: emphasis ? 26 : 24,
          style: .continuous
        )
        .fill(
          warm ? Color(hex: 0xF6E8B5).opacity(0.34) : Color.white.opacity(emphasis ? 0.30 : 0.22)
        )
        .glassEffect(
          .regular.tint(
            warm ? Color(hex: 0xF1CF67).opacity(0.10) : tint.opacity(emphasis ? 0.035 : 0.025)),
          in: .rect(cornerRadius: emphasis ? 30 : 24)
        )

        UnevenRoundedRectangle(
          topLeadingRadius: emphasis ? 32 : 26,
          bottomLeadingRadius: emphasis ? 24 : 22,
          bottomTrailingRadius: emphasis ? 34 : 28,
          topTrailingRadius: emphasis ? 26 : 24,
          style: .continuous
        )
        .fill(
          warm ? Color(hex: 0xFFF2BE).opacity(0.42) : Color.white.opacity(emphasis ? 0.52 : 0.44))
      } else {
        UnevenRoundedRectangle(
          topLeadingRadius: emphasis ? 32 : 26,
          bottomLeadingRadius: emphasis ? 24 : 22,
          bottomTrailingRadius: emphasis ? 34 : 28,
          topTrailingRadius: emphasis ? 26 : 24,
          style: .continuous
        )
        .fill(.ultraThinMaterial)

        UnevenRoundedRectangle(
          topLeadingRadius: emphasis ? 32 : 26,
          bottomLeadingRadius: emphasis ? 24 : 22,
          bottomTrailingRadius: emphasis ? 34 : 28,
          topTrailingRadius: emphasis ? 26 : 24,
          style: .continuous
        )
        .fill(
          warm ? Color(hex: 0xFFF1B6).opacity(0.56) : Color.white.opacity(emphasis ? 0.70 : 0.58))
      }
    }
    .overlay {
      UnevenRoundedRectangle(
        topLeadingRadius: emphasis ? 32 : 26,
        bottomLeadingRadius: emphasis ? 24 : 22,
        bottomTrailingRadius: emphasis ? 34 : 28,
        topTrailingRadius: emphasis ? 26 : 24,
        style: .continuous
      )
      .stroke(Color.white.opacity(0.76), lineWidth: 1)
    }
    .overlay {
      UnevenRoundedRectangle(
        topLeadingRadius: emphasis ? 32 : 26,
        bottomLeadingRadius: emphasis ? 24 : 22,
        bottomTrailingRadius: emphasis ? 34 : 28,
        topTrailingRadius: emphasis ? 26 : 24,
        style: .continuous
      )
      .stroke(CepessaColors.border.opacity(0.22), lineWidth: 1)
      .padding(0.5)
    }
    .shadow(
      color: CepessaColors.warmShadow.opacity(emphasis ? 0.08 : 0.052), radius: 16, x: 0, y: 9)
  }

  fileprivate func inspectorField(_ title: String, _ value: String) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title)
        .scaledFont(size: 12, weight: .medium)
        .foregroundColor(CepessaColors.textTertiary)

      Text(value)
        .scaledFont(size: 13, weight: .medium)
        .foregroundColor(CepessaColors.textPrimary)
        .lineLimit(2)
    }
  }

  fileprivate func inspectorStatusField(_ status: LocalMeetingSessionStatus) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Status")
        .scaledFont(size: 12, weight: .medium)
        .foregroundColor(CepessaColors.textTertiary)

      Text(statusLabel(status))
        .scaledFont(size: 12, weight: .semibold)
        .foregroundColor(status == .ready ? CepessaColors.mossDeep : .white)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
          status == .ready
            ? CepessaColors.moss.opacity(0.18)
            : statusBackground(for: status).opacity(0.92),
          in: Capsule()
        )
        .fixedSize()
    }
  }

  fileprivate func inspectorFileRow(icon: String, title: String, value: String) -> some View {
    HStack(spacing: 10) {
      Image(systemName: icon)
        .scaledFont(size: 12, weight: .semibold)
        .foregroundColor(CepessaColors.textSecondary)
        .frame(width: 30, height: 30)
        .accessibilityHidden(true)

      Text(title)
        .scaledFont(size: 13, weight: .medium)
        .foregroundColor(CepessaColors.textPrimary)

      Spacer(minLength: 0)

      Text(value)
        .scaledFont(size: 12, weight: .medium)
        .foregroundColor(CepessaColors.textPrimary)
        .lineLimit(1)
    }
    .padding(.horizontal, 14)
    .frame(height: 58)
    .background(Color.white.opacity(0.58))
    .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 15, style: .continuous)
        .stroke(Color.white.opacity(0.74), lineWidth: 0.8)
    }
    .overlay {
      RoundedRectangle(cornerRadius: 15, style: .continuous)
        .stroke(CepessaColors.border.opacity(0.26), lineWidth: 0.7)
    }
  }

  fileprivate func documentIconButton(
    systemImage: String,
    accessibilityLabel: String,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Image(systemName: systemImage)
        .scaledFont(size: 13, weight: .medium)
        .foregroundColor(CepessaColors.textPrimary)
        .frame(width: 34, height: 34)
        .background(Color.white.opacity(0.22))
        .clipShape(Circle())
        .contentShape(Circle())
    }
    .buttonStyle(CepessaPressStyle(scale: 0.965))
    .accessibilityLabel(accessibilityLabel)
  }

  fileprivate func memoryLine(icon: String, title: String, value: String) -> some View {
    HStack(alignment: .center, spacing: 10) {
      Image(systemName: icon)
        .scaledFont(size: 12, weight: .semibold)
        .foregroundColor(CepessaColors.textSecondary)
        .frame(width: 24, height: 24)
        .background(CepessaColors.backgroundRaised.opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

      Text(title)
        .scaledFont(size: 12, weight: .medium)
        .foregroundColor(CepessaColors.textSecondary)

      Spacer(minLength: 0)

      Text(value)
        .scaledFont(size: 11, weight: .semibold)
        .foregroundColor(CepessaColors.textSecondary)
        .lineLimit(1)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
    .background(CepessaColors.backgroundRaised.opacity(0.54))
    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 18, style: .continuous)
        .stroke(CepessaColors.border.opacity(0.14), lineWidth: 1)
    )
  }

  fileprivate func heroActionButton(
    title: String, systemImage: String, action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      HStack(spacing: 7) {
        Image(systemName: systemImage)
          .scaledFont(size: 11, weight: .semibold)

        Text(title)
          .scaledFont(size: 11, weight: .semibold)
      }
      .foregroundColor(CepessaColors.textSecondary)
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
      .background(CepessaColors.backgroundRaised.opacity(0.82))
      .clipShape(Capsule())
      .overlay(
        Capsule()
          .stroke(CepessaColors.border.opacity(0.16), lineWidth: 1)
      )
    }
    .buttonStyle(CepessaPressStyle(scale: 0.975))
  }

  fileprivate func dockMetric(title: String, value: String) -> some View {
    HStack(spacing: 6) {
      Text(title)
        .scaledFont(size: 11, weight: .medium)
        .foregroundColor(CepessaColors.textTertiary)

      Text(value)
        .scaledFont(size: 12, weight: .semibold)
        .foregroundColor(CepessaColors.textSecondary)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 9)
    .background(Color.white.opacity(0.46))
    .clipShape(Capsule())
  }

  fileprivate func smallChip(label: String, tint: Color) -> some View {
    Text(label)
      .scaledFont(size: 10, weight: .semibold)
      .foregroundColor(CepessaColors.textSecondary)
      .padding(.horizontal, 9)
      .padding(.vertical, 5)
      .background(tint)
      .clipShape(Capsule())
  }

  fileprivate func statChip(title: String, value: String) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(title)
        .scaledFont(size: 10, weight: .medium)
        .foregroundColor(CepessaColors.textTertiary)

      Text(value)
        .scaledFont(size: 12, weight: .semibold)
        .foregroundColor(CepessaColors.textSecondary)
        .lineLimit(1)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
    .background(CepessaColors.backgroundRaised.opacity(0.78))
    .clipShape(Capsule())
    .overlay(
      Capsule()
        .stroke(CepessaColors.border.opacity(0.14), lineWidth: 1)
    )
  }

  fileprivate func railHeader(title: String, subtitle: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title)
        .scaledFont(size: 16, weight: .semibold, design: .rounded)
        .foregroundColor(CepessaColors.textPrimary)

      Text(subtitle)
        .scaledFont(size: 11)
        .foregroundColor(CepessaColors.textTertiary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  fileprivate func rowHeader(title: String, subtitle: String) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title)
        .scaledFont(size: 18, weight: .semibold, design: .rounded)
        .foregroundColor(CepessaColors.textPrimary)

      Text(subtitle)
        .scaledFont(size: 12)
        .foregroundColor(CepessaColors.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  fileprivate func emptyStateCard(icon: String, title: String, message: String) -> some View {
    VStack(spacing: 12) {
      Image(systemName: icon)
        .scaledFont(size: 26)
        .foregroundColor(CepessaColors.textTertiary)

      VStack(spacing: 4) {
        Text(title)
          .scaledFont(size: 14, weight: .semibold)
          .foregroundColor(CepessaColors.textPrimary)

        Text(message)
          .scaledFont(size: 12)
          .foregroundColor(CepessaColors.textSecondary)
          .multilineTextAlignment(.center)
      }
    }
    .frame(maxWidth: .infinity)
    .padding(24)
    .background(CepessaColors.paperRaised.opacity(0.48))
    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    .overlay(alignment: .top) {
      Rectangle()
        .fill(CepessaColors.hairline.opacity(0.58))
        .frame(height: 1)
    }
  }

  fileprivate func statusBadge(for status: LocalMeetingSessionStatus) -> some View {
    Text(statusLabel(status))
      .scaledFont(size: 10, weight: .semibold)
      .foregroundColor(statusTextColor(for: status))
      .padding(.horizontal, 9)
      .padding(.vertical, 5)
      .background(statusBackground(for: status))
      .clipShape(Capsule())
  }

  fileprivate func speakerBadge(_ speaker: String) -> some View {
    Text(speaker.isEmpty ? "Speaker" : speaker)
      .scaledFont(size: 11, weight: .semibold)
      .foregroundColor(CepessaColors.accentPrimary)
      .padding(.horizontal, 10)
      .padding(.vertical, 5)
      .background(CepessaColors.accentPrimary.opacity(0.12))
      .clipShape(Capsule())
  }

  fileprivate func statusLabel(_ status: LocalMeetingSessionStatus) -> String {
    switch status {
    case .recording:
      return "Live"
    case .transcribing:
      return "Processing"
    case .ready:
      return "Ready"
    case .failed:
      return "Needs attention"
    }
  }

  fileprivate func statusBackground(for status: LocalMeetingSessionStatus) -> Color {
    switch status {
    case .recording:
      return CepessaColors.error
    case .transcribing:
      return CepessaColors.processing
    case .ready:
      return CepessaColors.ready
    case .failed:
      return CepessaColors.warning
    }
  }

  fileprivate func statusTextColor(for status: LocalMeetingSessionStatus) -> Color {
    switch status {
    case .ready:
      return CepessaColors.backgroundPrimary
    default:
      return .white
    }
  }

  fileprivate func meterFill(for value: Double) -> Color {
    if model.isRecording {
      return CepessaColors.capture.opacity(0.92)
    }

    if model.isProcessingSession {
      return CepessaColors.processing.opacity(0.90)
    }

    return CepessaColors.processing.opacity(0.82)
  }

  fileprivate func percentText(_ value: Double) -> String {
    "\(Int((value * 100).rounded()))%"
  }

  fileprivate func speakerCount(for session: LocalMeetingSession) -> Int {
    let speakers = Set(
      session.segments
        .map { $0.speaker.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
    )

    return max(1, speakers.count)
  }

  fileprivate func audioSnapshotLabel(for session: LocalMeetingSession) -> String {
    if session.audioArtifacts.mixedFileName != nil {
      return "Mixed"
    }

    if session.audioArtifacts.micFileName != nil || session.audioArtifacts.systemFileName != nil {
      return "Source"
    }

    return "Pending"
  }

  fileprivate func audioRetentionValue(for session: LocalMeetingSession) -> String {
    let retainedCount = [
      session.audioArtifacts.micFileName,
      session.audioArtifacts.systemFileName,
      session.audioArtifacts.mixedFileName,
    ].compactMap { $0 }.count

    if retainedCount == 0 {
      return "Pending"
    }

    return countLabel(retainedCount, singular: "file")
  }

  fileprivate func transcriptMemoryValue(for session: LocalMeetingSession) -> String {
    if session.segments.isEmpty {
      return displayStatus(for: session) == .transcribing ? "Working" : "Pending"
    }

    return countLabel(session.segments.count, singular: "segment")
  }

  fileprivate func timelineArtifactCount(for session: LocalMeetingSession) -> Int {
    session.attachments.count + session.captureArtifacts.count
  }

  fileprivate func recapLines(for session: LocalMeetingSession) -> [String] {
    if !session.recap.sections.isEmpty {
      return session.recap.sections.flatMap { section in
        [section.summary] + section.bullets
      }
      .filter { !$0.isEmpty }
    }

    var lines: [String] = []

    lines.append(
      "\(session.segments.count) transcript segment\(session.segments.count == 1 ? "" : "s") are captured locally."
    )
    lines.append("Speaker labels: \(speakerCount(for: session)).")

    if let mixed = session.audioArtifacts.mixedFileName, !mixed.isEmpty {
      lines.append("Mixed audio master is retained as \(mixed).")
    } else {
      lines.append("Mixed audio master has not been generated yet.")
    }

    if let firstLine = session.segments.first?.text.trimmingCharacters(in: .whitespacesAndNewlines),
      !firstLine.isEmpty
    {
      lines.append("Opening transcript line: \(firstLine.truncated(maxLength: 96)).")
    } else {
      lines.append("Transcript text will appear after the session completes transcription.")
    }

    return lines
  }

  fileprivate func primaryRecapText(for session: LocalMeetingSession) -> String {
    let overview = session.recap.overview.trimmingCharacters(in: .whitespacesAndNewlines)
    if !overview.isEmpty {
      return overview.truncated(maxLength: 180)
    }

    return recapLines(for: session).first ?? "Recap is still being prepared."
  }

  fileprivate func recapSection(
    for session: LocalMeetingSession,
    kinds: [LocalSessionRecapSection.Kind]
  ) -> LocalMeetingRecapSection? {
    session.recap.sections.first { section in
      kinds.contains(section.kind)
    }
  }

  fileprivate func noteBody(
    for section: LocalMeetingRecapSection?,
    fallback: String
  ) -> String {
    guard let section else { return fallback }

    let summary = section.summary.trimmingCharacters(in: .whitespacesAndNewlines)
    if !summary.isEmpty {
      return summary.truncated(maxLength: 132)
    }

    return section.bullets.first?.truncated(maxLength: 132) ?? fallback
  }

  fileprivate func noteBullets(for section: LocalMeetingRecapSection?) -> [String] {
    guard let section else { return [] }

    let bullets = section.bullets
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }

    guard !bullets.isEmpty else { return [] }
    return Array(bullets.dropFirst().prefix(3))
  }

  fileprivate func keyFocusBullets(for session: LocalMeetingSession) -> [String] {
    let keyPoints = recapSection(for: session, kinds: [.keyPoints, .overview])?.bullets ?? []
    let source = keyPoints.isEmpty ? Array(recapLines(for: session).dropFirst()) : keyPoints
    let bullets =
      source
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).truncated(maxLength: 42) }
      .filter { !$0.isEmpty }

    if bullets.isEmpty {
      return ["Transcript", "Summary", "Follow-up"]
    }

    return Array(bullets.prefix(4))
  }

  fileprivate func transcriptPendingMessage(for session: LocalMeetingSession) -> String {
    if session.status == .failed {
      if model.canRetranscribe(session) {
        return "The raw audio is saved. Run Transcribe to try again."
      }

      return "This session failed before a reusable local audio file was saved."
    }

    if let snapshot = model.processingSnapshot(for: session.id) {
      return snapshot.detail
    }

    if model.isGeneratingRecap(for: session.id) {
      return model.processingStatusDetail
        ?? "The transcript is ready. The recap is still being generated locally."
    }

    return "Stop the session and the transcript will appear here."
  }

  fileprivate var selectedSession: LocalMeetingSession? {
    model.selectedSession
  }

  fileprivate var activitySnapshot: LocalSessionProcessingSnapshot? {
    selectedSession.flatMap { model.processingSnapshot(for: $0.id) } ?? model.processingQueue.first
  }

  fileprivate func activityTitle(for snapshot: LocalSessionProcessingSnapshot) -> String {
    switch snapshot.phase {
    case .importingAudio:
      return "Importing audio"
    case .transcribing:
      return "Transcribing"
    case .classifyingContent:
      return "Reading context"
    case .generatingRecap:
      return "Preparing recap"
    }
  }

  fileprivate func activityDetail(for snapshot: LocalSessionProcessingSnapshot) -> String {
    let sessionTitle = sessionTitle(for: snapshot.id)
    let detail = snapshot.detail.trimmingCharacters(in: .whitespacesAndNewlines)

    guard !detail.isEmpty else {
      return sessionTitle
    }

    return "\(sessionTitle) - \(detail)"
  }

  fileprivate func activityTint(for snapshot: LocalSessionProcessingSnapshot) -> Color {
    switch snapshot.phase {
    case .importingAudio:
      return CepessaColors.captureDeep
    case .transcribing:
      return CepessaColors.processing
    case .classifyingContent:
      return CepessaColors.capture
    case .generatingRecap:
      return CepessaColors.accentPrimary
    }
  }

  fileprivate var headerSummary: String {
    if model.isRecording {
      return "Recording locally."
    }

    if model.isProcessingSession {
      return model.processingStatusTitle ?? "Processing."
    }

    return "Record, import, search, review."
  }

  fileprivate var sessionCountLabel: String {
    let total = model.sessions.count
    let visible = filteredSessions.count
    let totalLabel = "\(total) \(total == 1 ? "session" : "sessions")"

    guard isFilteringSessions else {
      return "\(totalLabel) saved locally"
    }

    let visibleLabel = "\(visible) \(visible == 1 ? "match" : "matches")"
    return "\(visibleLabel) from \(totalLabel)"
  }

  fileprivate var heroTitle: String {
    selectedSession?.displayTitle ?? "Sessions"
  }

  fileprivate var heroSubtitle: String {
    if let session = selectedSession {
      if let snapshot = model.processingSnapshot(for: session.id) {
        return snapshot.detail
      }

      if displayStatus(for: session) == .failed {
        if model.canRetranscribe(session) {
          return "The raw audio is saved. Run Transcribe to try this session again."
        }

        return "This session stopped before a transcript could be made."
      }

      if !session.recap.overview.isEmpty {
        return session.recap.overview.truncated(maxLength: 120)
      }

      if !session.transcriptText.isEmpty {
        return session.transcriptText.truncated(maxLength: 120)
      }

      return "No transcript yet."
    }

    return "Choose a session or start recording."
  }

  fileprivate var documentMetaLine: String {
    guard let session = selectedSession else {
      return model.isRecording ? "Recording now" : "Choose a session - Start or import audio"
    }

    return [
      session.startedAt.formatted(date: .abbreviated, time: .omitted),
      session.startedAt.formatted(date: .omitted, time: .shortened),
      compactDurationLabel(for: session),
    ].joined(separator: " - ")
  }

  fileprivate var selectionMetaTitle: String {
    if selectedSession != nil {
      return "Session"
    }

    return "State"
  }

  fileprivate var selectionMetaValue: String {
    if let session = selectedSession {
      switch displayStatus(for: session) {
      case .recording:
        return "Live"
      case .transcribing:
        return processingBadgeValue
      case .ready:
        return model.isGeneratingRecap(for: session.id) ? "Recap" : "Ready"
      case .failed:
        return model.canRetranscribe(session) ? "Audio saved" : "Stopped early"
      }
    }

    if model.isRecording {
      return "Live"
    }

    if model.isProcessingSession {
      return processingBadgeValue
    }

    return "Idle"
  }

  fileprivate func sessionCardSummary(
    for session: LocalMeetingSession,
    snapshot: LocalSessionProcessingSnapshot?
  ) -> String {
    if let snapshot {
      return snapshot.title
    }

    if displayStatus(for: session) == .failed {
      return model.canRetranscribe(session)
        ? "Audio saved. Transcribe again." : "Stopped before audio was ready."
    }

    if !session.recap.overview.isEmpty {
      return session.recap.overview.truncated(maxLength: 80)
    }

    if !session.transcriptText.isEmpty {
      return session.transcriptText.truncated(maxLength: 80)
    }

    return "No transcript yet"
  }

  fileprivate var heroStatus: LocalMeetingSessionStatus {
    if let session = selectedSession {
      return displayStatus(for: session)
    }

    if model.isRecording {
      return .recording
    }

    if model.isProcessingSession {
      return .transcribing
    }

    return .ready
  }

  fileprivate var statusTitle: String {
    if model.isRecording {
      return "Session live"
    }

    if model.isTranscribing {
      return model.processingStatusTitle ?? "Processing locally"
    }

    if model.isGeneratingRecap {
      return "Generating recap"
    }

    return "Ready"
  }

  fileprivate var statusSummary: String {
    if model.isRecording {
      return "Live"
    }

    if model.isProcessingSession {
      return activeQueueSummary
    }

    return "Idle"
  }

  fileprivate var processingBadgeValue: String {
    if model.processingQueue.count > 1 {
      return activeQueueSummary
    }

    if let progress = model.processingProgress {
      return "\(Int((progress * 100).rounded()))%"
    }

    return "Processing"
  }

  fileprivate var processingActionTitle: String {
    model.processingStatusTitle ?? processingBadgeValue
  }

  fileprivate var statusDescription: String {
    if model.isRecording {
      return model.recordingDurationText
    }

    if model.isTranscribing {
      return model.processingStatusDetail
        ?? "Building transcript and notes on this Mac."
    }

    if model.isGeneratingRecap {
      return model.processingStatusDetail
        ?? "Transcript ready. Notes are still updating."
    }

    return
      "Audio and notes stay local."
  }

  fileprivate var dockSubtitle: String {
    if let session = selectedSession {
      return displayStatus(for: session) == .recording
        ? "The floating bar is live and can capture timestamped screenshots or files."
        : (model.processingSnapshot(for: session.id)?.detail
          ?? "The live overlay mirrors session and processing state on top of the desktop.")
    }

    if model.processingQueue.count > 1 {
      return "Several sessions are processing locally. Open the queue to follow each one."
    }

    return model.isRecording
      ? "A live session is in progress." : "Ready to mirror the active session state."
  }

  fileprivate var dockAccent: Color {
    if model.isRecording {
      return CepessaColors.error
    }

    if model.isProcessingSession {
      return CepessaColors.processing
    }

    return CepessaColors.textTertiary
  }

  fileprivate var dockFill: Color {
    if model.isRecording {
      return CepessaColors.backgroundSecondary.opacity(0.90)
    }

    if model.isProcessingSession {
      return CepessaColors.backgroundSecondary.opacity(0.92)
    }

    return CepessaColors.backgroundTertiary.opacity(0.74)
  }

  fileprivate var dockStroke: Color {
    if model.isRecording {
      return CepessaColors.error.opacity(0.26)
    }

    if model.isProcessingSession {
      return CepessaColors.accentPrimary.opacity(0.24)
    }

    return CepessaColors.border.opacity(0.26)
  }

  fileprivate func recapSections(for session: LocalMeetingSession) -> [LocalMeetingRecapSection] {
    if !session.recap.sections.isEmpty {
      return session.recap.sections
    }

    return [
      LocalMeetingRecapSection(
        id: UUID(),
        kind: .overview,
        title: "Overview",
        summary: recapLines(for: session).first ?? "Recap is still being generated locally.",
        bullets: Array(recapLines(for: session).dropFirst().prefix(3)),
        anchorTimestamp: session.startedAt,
        startOffset: 0,
        endOffset: nil
      )
    ]
  }

  fileprivate func attachmentTitle(for attachment: LocalMeetingAttachment) -> String {
    attachment.title.isEmpty ? "Attachment" : attachment.title
  }

  fileprivate func displayStatus(for session: LocalMeetingSession) -> LocalMeetingSessionStatus {
    if model.processingSnapshot(for: session.id) != nil {
      return .transcribing
    }

    if model.isGeneratingRecap(for: session.id) {
      return .transcribing
    }

    return session.status
  }

  fileprivate func importRecording() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.allowedContentTypes = [.audio]
    panel.prompt = "Transcribe"
    panel.message =
      "Choose an existing recording to import, normalize locally, and transcribe on this Mac."

    guard panel.runModal() == .OK, let url = panel.url else { return }
    Task {
      await model.importExistingRecording(from: url)
    }
  }

  @ViewBuilder
  fileprivate func retranscribeSessionButton(
    for session: LocalMeetingSession,
    compact: Bool = false
  ) -> some View {
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
    .controlSize(compact ? .small : .regular)
    .help("Run transcription again from the saved audio for this session.")
  }

  fileprivate func attachmentSubtitle(for attachment: LocalMeetingAttachment) -> String {
    let stamp = attachment.sessionOffset.map(timeString(from:)) ?? "00:00"
    let file = attachment.fileName ?? attachment.urlString ?? "Saved locally"
    return "\(stamp)  \(file)"
  }

  fileprivate func captureArtifactTitle(for artifact: LocalMeetingCaptureArtifact) -> String {
    if !artifact.title.isEmpty {
      return artifact.title
    }

    switch artifact.kind {
    case .floatingBarCapture:
      return "Floating bar capture"
    case .screenCapture:
      return "Screen capture"
    case .clipboardCapture:
      return "Clipboard capture"
    case .note:
      return "Captured note"
    }
  }

  fileprivate func captureArtifactSubtitle(for artifact: LocalMeetingCaptureArtifact) -> String {
    let stamp = artifact.sessionOffset.map(timeString(from:)) ?? "00:00"

    if let notes = artifact.notes, !notes.isEmpty {
      return "\(stamp)  \(notes)"
    }

    return "\(stamp)  Stored locally"
  }

  fileprivate func captureArtifactIcon(for artifact: LocalMeetingCaptureArtifact) -> String {
    switch artifact.kind {
    case .floatingBarCapture:
      return "square.stack.3d.up"
    case .screenCapture:
      return "camera.viewfinder"
    case .clipboardCapture:
      return "doc.on.clipboard"
    case .note:
      return "note.text"
    }
  }

  fileprivate func sessionTitle(for sessionID: LocalMeetingSession.ID) -> String {
    model.sessions.first(where: { $0.id == sessionID })?.displayTitle ?? "Session"
  }

  fileprivate func icon(for attachment: LocalMeetingAttachment) -> String {
    switch attachment.kind {
    case .image, .capture:
      return "photo"
    case .audio:
      return "waveform"
    case .link:
      return "link"
    case .file:
      return "doc"
    }
  }

  fileprivate func timeString(from interval: TimeInterval) -> String {
    let totalSeconds = max(0, Int(interval.rounded()))
    return String(format: "%02d:%02d", totalSeconds / 60, totalSeconds % 60)
  }

  fileprivate func sessionTimeRange(for session: LocalMeetingSession) -> String {
    let start = session.startedAt.formatted(date: .omitted, time: .shortened)
    guard let lastSegment = session.segments.last else { return start }

    let end = lastSegment.timestamp.formatted(date: .omitted, time: .shortened)
    return "\(start) - \(end)"
  }

  fileprivate func compactDurationLabel(for session: LocalMeetingSession) -> String {
    if displayStatus(for: session) == .recording, model.isRecording {
      return model.recordingDurationText
    }

    guard let lastSegment = session.segments.last else { return "Pending" }

    let duration = max(0, lastSegment.timestamp.timeIntervalSince(session.startedAt))
    if duration < 60 {
      return "\(max(1, Int(duration.rounded())))s"
    }

    return "\(max(1, Int((duration / 60).rounded())))m"
  }

  fileprivate func countLabel(_ count: Int, singular: String, plural: String? = nil) -> String {
    let pluralText = plural ?? singular + "s"
    return "\(count) \(count == 1 ? singular : pluralText)"
  }

  fileprivate var activeQueueSummary: String {
    let count = model.processingQueue.count
    guard count > 0 else { return "Idle" }
    return count == 1 ? "1 active" : "\(count) active"
  }
}

private struct ProcessingWaveformGlyph: View {
  let tint: Color
  let reduceMotion: Bool
  @State private var isAnimating = false

  private let restingHeights: [CGFloat] = [7, 13, 9, 16]
  private let activeHeights: [CGFloat] = [15, 8, 17, 10]

  var body: some View {
    HStack(alignment: .center, spacing: 3) {
      ForEach(restingHeights.indices, id: \.self) { index in
        Capsule()
          .fill(tint.opacity(index == 1 ? 0.92 : 0.66))
          .frame(width: 3, height: barHeight(at: index))
      }
    }
    .frame(width: 24, height: 24)
    .accessibilityHidden(true)
    .onAppear {
      guard !reduceMotion else { return }
      withAnimation(.easeInOut(duration: 0.72).repeatForever(autoreverses: true)) {
        isAnimating = true
      }
    }
  }

  private func barHeight(at index: Int) -> CGFloat {
    guard !reduceMotion else {
      return restingHeights[index]
    }

    return isAnimating ? activeHeights[index] : restingHeights[index]
  }
}

private enum ToolbarMenuKind {
  case section
  case language
  case download
}

private enum WorkspaceSection: String, CaseIterable, Identifiable {
  case recap
  case decisions
  case actions
  case transcript

  var id: String { rawValue }

  var title: String {
    switch self {
    case .recap:
      return "Summary"
    case .decisions:
      return "Decisions"
    case .actions:
      return "Action Items"
    case .transcript:
      return "Transcript"
    }
  }

  var symbol: String {
    switch self {
    case .recap:
      return "sparkles"
    case .decisions:
      return "checkmark.circle"
    case .actions:
      return "list.bullet"
    case .transcript:
      return "text.bubble"
    }
  }

  var subtitle: String {
    switch self {
    case .recap:
      return "Notes view"
    case .decisions:
      return "Meeting calls"
    case .actions:
      return "Follow-ups"
    case .transcript:
      return "Raw session text"
    }
  }
}

private enum WorkspaceLayoutMode {
  case wide
  case split
  case stacked
}

extension String {
  fileprivate func truncated(maxLength: Int) -> String {
    guard count > maxLength else { return self }
    let index = index(startIndex, offsetBy: maxLength)
    return String(self[..<index]) + "…"
  }
}
