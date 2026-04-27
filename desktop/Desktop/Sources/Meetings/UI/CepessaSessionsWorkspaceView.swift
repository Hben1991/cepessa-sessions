import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct CepessaSessionsWorkspaceView: View {
  @ObservedObject private var model = CepessaSessionsStore.shared.model
  @State private var centerSection: WorkspaceSection = .recap
  @State private var hoveredSessionID: LocalMeetingSession.ID?
  @State private var documentChatDraft = ""
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Namespace private var centerTabNamespace

  var body: some View {
    GeometryReader { proxy in
      let layout = workspaceLayout(for: proxy.size.width)

      ZStack {
        workspaceBackground

        ScrollView {
          VStack(alignment: .leading, spacing: 18) {
            workspaceHeader(for: layout)

            if !model.processingQueue.isEmpty {
              processingQueueSection
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            workspaceColumns(for: layout, availableHeight: proxy.size.height)
          }
          .padding(22)
          .padding(.bottom, 18)
        }
        .scrollIndicators(.hidden)
        .animation(
          reduceMotion ? nil : .easeOut(duration: 0.18), value: model.processingQueue.count
        )
        .safeAreaInset(edge: .bottom, spacing: 0) {
          if centerSection != .chat {
            floatingSessionDock(for: layout)
              .padding(.horizontal, layout == .stacked ? 16 : 22)
              .padding(.top, 8)
              .padding(.bottom, 18)
              .background(
                LinearGradient(
                  colors: [
                    CepessaColors.backgroundPrimary.opacity(0),
                    CepessaColors.backgroundPrimary.opacity(0.78),
                  ],
                  startPoint: .top,
                  endPoint: .bottom
                )
              )
              .transition(.opacity.combined(with: .move(edge: .bottom)))
          }
        }
      }
      .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: centerSection)
    }
    .onAppear {
      CepessaSessionFloatingBarController.shared.connect(model: model)
    }
    .onChange(of: model.selectedSessionID) { _, _ in
      centerSection = .recap
      documentChatDraft = ""
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
              markdown: LocalSessionRecapMarkdownDocument(session: session).markdown
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
    if width >= 1_360 {
      return .wide
    }

    if width >= 1_020 {
      return .split
    }

    return .stacked
  }

  fileprivate var workspaceBackground: some View {
    Color(nsColor: .windowBackgroundColor)
      .ignoresSafeArea()
  }

  @ViewBuilder
  fileprivate func workspaceHeader(for layout: WorkspaceLayoutMode) -> some View {
    ViewThatFits(in: .horizontal) {
      HStack(alignment: .center, spacing: 16) {
        workspaceTitleBlock
        Spacer(minLength: 0)
        headerPrimaryAction
      }

      VStack(alignment: .leading, spacing: 12) {
        workspaceTitleBlock
        headerPrimaryAction
      }
    }
    .padding(.horizontal, 6)
  }

  fileprivate var workspaceTitleBlock: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Cepessa Sessions")
        .scaledFont(size: 30, weight: .semibold)
        .foregroundColor(CepessaColors.textPrimary)

      Text(headerSummary)
        .scaledFont(size: 13)
        .foregroundColor(CepessaColors.textSecondary)
    }
  }

  @ViewBuilder
  fileprivate var headerPrimaryAction: some View {
    HStack(spacing: 10) {
      Button {
        importRecording()
      } label: {
        Label("Transcribe Audio File", systemImage: "waveform.badge.plus")
      }
      .buttonStyle(.bordered)
      .controlSize(.large)
      .help("Choose an existing audio file and transcribe it locally.")

      Button {
        model.toggleRecording()
      } label: {
        Label(
          model.isRecording ? "Stop Session" : "Start Session",
          systemImage: model.isRecording ? "stop.fill" : "record.circle.fill"
        )
      }
      .buttonStyle(.borderedProminent)
      .controlSize(.large)
      .tint(model.isRecording ? CepessaColors.error : Color.accentColor)
      .help(
        model.isRecording ? "Stop the current recording session." : "Start a new local session.")
    }
  }

  @ViewBuilder
  fileprivate func workspaceColumns(for layout: WorkspaceLayoutMode, availableHeight: CGFloat)
    -> some View
  {
    let contentHeight = max(availableHeight - 196, 560)

    switch layout {
    case .wide:
      HStack(alignment: .top, spacing: 18) {
        sessionsRail
          .frame(minWidth: 280, idealWidth: 300, maxWidth: 320)

        centerWorkspace
          .frame(minWidth: 520, idealWidth: 720, maxWidth: .infinity)

        VStack(alignment: .leading, spacing: 14) {
          captureStatusCard
          sessionMemoryCard
        }
        .frame(minWidth: 260, idealWidth: 300, maxWidth: 340)
      }
      .frame(maxHeight: .infinity, alignment: .top)

    case .split:
      VStack(alignment: .leading, spacing: 18) {
        captureStatusCard

        centerWorkspace
          .frame(minHeight: max(360, contentHeight * 0.56), maxHeight: .infinity)

        sessionsRail
          .frame(
            minHeight: max(240, contentHeight * 0.28), maxHeight: max(280, contentHeight * 0.34))
      }
      .frame(maxHeight: .infinity, alignment: .top)

    case .stacked:
      VStack(alignment: .leading, spacing: 18) {
        captureStatusCard

        centerWorkspace
          .frame(minHeight: max(380, contentHeight * 0.56))

        sessionsRail
          .frame(
            minHeight: max(220, contentHeight * 0.28), maxHeight: max(300, contentHeight * 0.34))
      }
      .frame(maxHeight: .infinity, alignment: .top)
    }
  }

  fileprivate var sessionsRail: some View {
    VStack(alignment: .leading, spacing: 14) {
      railHeader(
        title: "Sessions",
        subtitle: "Choose one recording to inspect."
      )

      if model.sessions.isEmpty {
        emptyStateCard(
          icon: "waveform.badge.mic",
          title: "No sessions yet",
          message: "Start or import a recording."
        )
      } else {
        ScrollView {
          LazyVStack(spacing: 10) {
            ForEach(model.sessions) { session in
              sessionCard(session)
            }
          }
        }
        .scrollIndicators(.hidden)
      }
    }
    .padding(18)
    .frame(maxHeight: .infinity, alignment: .top)
    .cepessaPanel(
      fill: CepessaColors.backgroundSecondary.opacity(0.78),
      radius: 10,
      stroke: CepessaColors.border.opacity(0.55),
      shadowOpacity: 0.01,
      shadowRadius: 2,
      shadowY: 1
    )
  }

  fileprivate var centerWorkspace: some View {
    VStack(alignment: .leading, spacing: 0) {
      centerHeroPanel

      Divider()
        .overlay(CepessaColors.border.opacity(0.32))

      centerSectionTabs

      Divider()
        .overlay(CepessaColors.border.opacity(0.30))

      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          currentCenterSection
            .id(centerSection)
            .transition(.opacity.combined(with: .offset(y: reduceMotion ? 0 : 6)))
        }
        .padding(18)
        .padding(.bottom, centerSection == .chat ? 18 : 108)
      }
      .scrollIndicators(.hidden)
      .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: centerSection)
    }
    .frame(maxHeight: .infinity, alignment: .top)
    .cepessaPanel(
      fill: CepessaColors.backgroundSecondary.opacity(0.82),
      radius: 10,
      stroke: CepessaColors.border.opacity(0.55),
      shadowOpacity: 0.01,
      shadowRadius: 2,
      shadowY: 1
    )
  }

  fileprivate var inspectorRail: some View {
    EmptyView()
  }

  fileprivate var sessionMemoryCard: some View {
    VStack(alignment: .leading, spacing: 14) {
      rowHeader(
        title: "Kept locally",
        subtitle: "The useful trail this Mac keeps for the selected session."
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
    .background(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .fill(CepessaColors.backgroundSecondary.opacity(0.82))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .stroke(CepessaColors.border.opacity(0.22), lineWidth: 1)
    )
  }

  @ViewBuilder
  fileprivate func floatingSessionDock(for layout: WorkspaceLayoutMode) -> some View {
    let compactDock = layout == .stacked

    Group {
      if compactDock {
        VStack(alignment: .leading, spacing: 14) {
          dockLead

          ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
              dockMetric(title: "Mic", value: percentText(model.micLevel))
              dockMetric(title: "System", value: percentText(model.systemLevel))
              dockMetric(
                title: "Local",
                value: model.isProcessingSession ? processingBadgeValue : "On device")
            }

            VStack(alignment: .leading, spacing: 8) {
              HStack(spacing: 8) {
                dockMetric(title: "Mic", value: percentText(model.micLevel))
                dockMetric(title: "System", value: percentText(model.systemLevel))
              }
              dockMetric(
                title: "Local",
                value: model.isProcessingSession ? processingBadgeValue : "On device")
            }
          }

          dockAction
        }
      } else {
        HStack(alignment: .center, spacing: 16) {
          dockLead

          Spacer(minLength: 0)

          HStack(spacing: 8) {
            dockMetric(title: "Mic", value: percentText(model.micLevel))
            dockMetric(title: "System", value: percentText(model.systemLevel))
            dockMetric(
              title: "Local", value: model.isProcessingSession ? processingBadgeValue : "On device")
          }

          dockAction
        }
      }
    }
    .padding(16)
    .frame(maxWidth: .infinity)
    .cepessaGlassPanel(
      radius: 10,
      fill: dockFill,
      fillOpacity: 0.80,
      strokeOpacity: model.isRecording || model.isProcessingSession ? 0.46 : 0.34,
      shadowOpacity: 0.045
    )
  }

  fileprivate var dockLead: some View {
    HStack(alignment: .center, spacing: 12) {
      Image(systemName: model.isRecording ? "record.circle.fill" : "waveform")
        .scaledFont(size: 20, weight: .semibold)
        .foregroundColor(dockAccent)
        .frame(width: 28)

      VStack(alignment: .leading, spacing: 3) {
        Text("Floating capture bar")
          .scaledFont(size: 13, weight: .semibold)
          .foregroundColor(CepessaColors.textPrimary)

        Text(dockSubtitle)
          .scaledFont(size: 11)
          .foregroundColor(CepessaColors.textSecondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  @ViewBuilder
  fileprivate var dockAction: some View {
    if model.isRecording {
      Button {
        model.toggleRecording()
      } label: {
        Label("Stop Session", systemImage: "stop.fill")
      }
      .buttonStyle(.borderedProminent)
      .controlSize(.regular)
      .tint(CepessaColors.error)
      .help("Stop the current recording session.")
    } else {
      HStack(spacing: 8) {
        if model.isProcessingSession {
          if let processingProgress = model.processingProgress {
            ProgressView(value: processingProgress)
              .progressViewStyle(.linear)
              .frame(width: 76)
              .tint(CepessaColors.purplePrimary)
          } else {
            ProgressView()
              .scaleEffect(0.7)
              .tint(CepessaColors.purplePrimary)
          }

          Text(processingActionTitle)
            .scaledFont(size: 12, weight: .medium)
            .foregroundColor(CepessaColors.textSecondary)
        }

        Button {
          importRecording()
        } label: {
          Image(systemName: "waveform.badge.plus")
            .scaledFont(size: 12, weight: .semibold)
        }
        .buttonStyle(.bordered)
        .help("Choose an existing audio file and transcribe it locally.")
        .accessibilityLabel("Transcribe audio file")

        Button {
          model.toggleRecording()
        } label: {
          Label("Start Session", systemImage: "record.circle.fill")
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.regular)
        .help("Start a new local session.")
      }
    }
  }

  fileprivate var centerHeroPanel: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .center, spacing: 10) {
        statusBadge(for: heroStatus)

        Text(selectionMetaValue)
          .scaledFont(size: 12, weight: .semibold)
          .foregroundColor(CepessaColors.textSecondary)

        Spacer(minLength: 0)
      }

      Text(heroTitle)
        .scaledFont(size: 22, weight: .semibold)
        .foregroundColor(CepessaColors.textPrimary)
        .lineLimit(2)

      Text(heroSubtitle)
        .scaledFont(size: 13)
        .foregroundColor(CepessaColors.textSecondary)
        .fixedSize(horizontal: false, vertical: true)

      if let promptPackageURL = model.promptPackageMarkdownURL(),
        let sessionFolderURL = model.sessionFolderURL(),
        FileManager.default.fileExists(atPath: promptPackageURL.path)
      {
        HStack(spacing: 8) {
          heroActionButton(title: "Open package", systemImage: "doc.text") {
            NSWorkspace.shared.open(promptPackageURL)
          }

          heroActionButton(title: "Reveal session", systemImage: "folder") {
            NSWorkspace.shared.activateFileViewerSelecting([sessionFolderURL])
          }
        }
      }
    }
    .padding(18)
    .background(CepessaColors.backgroundSecondary.opacity(0.92))
  }

  fileprivate var recapCard: some View {
    VStack(alignment: .leading, spacing: 14) {
      rowHeader(
        title: "Recap",
        subtitle: "A structured readout with decisions, action items, and open questions."
      )

      if let session = selectedSession {
        LazyVGrid(
          columns: [
            GridItem(.flexible(), spacing: 12),
            GridItem(.flexible(), spacing: 12),
            GridItem(.flexible(), spacing: 12),
          ],
          spacing: 12
        ) {
          metricCard(title: "Segments", value: "\(session.segments.count)")
          metricCard(title: "Speakers", value: "\(speakerCount(for: session))")
          metricCard(title: "Audio", value: audioSnapshotLabel(for: session))
        }

        LocalSessionMarkdownDocumentPreview(
          markdown: LocalSessionRecapMarkdownDocument(session: session).markdown
        )
      } else {
        emptyStateCard(
          icon: "rectangle.stack.badge.minus",
          title: "Select a session",
          message: "The recap surface appears once a session is selected from the archive."
        )
      }
    }
    .padding(18)
    .background(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .fill(CepessaColors.backgroundSecondary.opacity(0.76))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .stroke(CepessaColors.border.opacity(0.26), lineWidth: 1)
    )
  }

  fileprivate var centerSectionTabs: some View {
    HStack(alignment: .center, spacing: 10) {
      ForEach(WorkspaceSection.allCases) { section in
        Button {
          withAnimation(.easeOut(duration: 0.18)) {
            centerSection = section
          }
        } label: {
          HStack(spacing: 8) {
            Image(systemName: section.symbol)
              .scaledFont(size: 11, weight: .semibold)

            Text(section.title)
              .scaledFont(size: 12, weight: .semibold)
          }
          .foregroundColor(
            centerSection == section ? CepessaColors.textPrimary : CepessaColors.textSecondary
          )
          .padding(.horizontal, 12)
          .padding(.vertical, 7)
          .background {
            if centerSection == section {
              RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.accentColor.opacity(0.14))
                .matchedGeometryEffect(id: "selectedCenterSection", in: centerTabNamespace)
            }
          }
          .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
              .stroke(
                centerSection == section
                  ? Color.accentColor.opacity(0.24) : Color.clear,
                lineWidth: 1
              )
          }
        }
        .buttonStyle(CepessaPressStyle(scale: 0.985))
        .help("Show \(section.title.lowercased()).")
        .accessibilityLabel("\(section.title) section")
        .accessibilityAddTraits(centerSection == section ? [.isSelected] : [])
      }
    }
    .padding(.horizontal, 18)
    .padding(.vertical, 10)
    .background(CepessaColors.backgroundSecondary.opacity(0.66))
  }

  @ViewBuilder
  fileprivate var currentCenterSection: some View {
    switch centerSection {
    case .recap:
      recapCard
    case .transcript:
      transcriptCard
    case .chat:
      CepessaSessionDocumentChatView(
        model: model,
        session: selectedSession,
        draftText: $documentChatDraft
      )
    case .attachments:
      attachmentsCard
    }
  }

  fileprivate var transcriptCard: some View {
    VStack(alignment: .leading, spacing: 14) {
      rowHeader(
        title: "Transcript",
        subtitle: "The exact spoken record, including mixed Hebrew and English when needed."
      )

      if let session = selectedSession {
        if session.segments.isEmpty {
          emptyStateCard(
            icon: displayStatus(for: session) == .transcribing ? "brain" : "text.bubble",
            title: displayStatus(for: session) == .transcribing
              ? "Processing transcript" : "Transcript pending",
            message: transcriptPendingMessage(for: session)
          )
        } else {
          VStack(alignment: .leading, spacing: 12) {
            ForEach(session.segments) { segment in
              transcriptRow(segment)
            }
          }
        }
      } else {
        emptyStateCard(
          icon: "rectangle.and.text.magnifyingglass",
          title: "No session selected",
          message: "Choose a session from the library to inspect the transcript."
        )
      }
    }
    .padding(18)
    .background(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .fill(CepessaColors.backgroundSecondary.opacity(0.76))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .stroke(CepessaColors.border.opacity(0.26), lineWidth: 1)
    )
  }

  fileprivate var captureStatusCard: some View {
    VStack(alignment: .leading, spacing: 14) {
      rowHeader(
        title: "Status",
        subtitle: "What is happening right now."
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

      if model.isProcessingSession {
        VStack(alignment: .leading, spacing: 10) {
          HStack(spacing: 8) {
            Text(model.processingStatusTitle ?? "Processing locally")
              .scaledFont(size: 12, weight: .semibold)
              .foregroundColor(CepessaColors.textSecondary)

            Spacer(minLength: 0)

            if let processingProgress = model.processingProgress {
              Text("\(Int((processingProgress * 100).rounded()))%")
                .scaledFont(size: 11, weight: .medium)
                .foregroundColor(CepessaColors.textTertiary)
                .monospacedDigit()
            }
          }

          if let processingProgress = model.processingProgress {
            ProgressView(value: processingProgress)
              .progressViewStyle(.linear)
              .tint(CepessaColors.purplePrimary)
          } else {
            ProgressView()
              .controlSize(.small)
              .tint(CepessaColors.purplePrimary)
          }

          Text(model.processingStatusDetail ?? "Building transcript and recap locally")
            .scaledFont(size: 11)
            .foregroundColor(CepessaColors.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(CepessaColors.purplePrimary.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

        if model.processingQueue.count > 1 {
          compactProcessingQueueSection
        }
      }

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
    .background(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .fill(CepessaColors.backgroundSecondary.opacity(0.82))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .stroke(CepessaColors.border.opacity(0.22), lineWidth: 1)
    )
  }

  fileprivate var attachmentsCard: some View {
    VStack(alignment: .leading, spacing: 14) {
      rowHeader(
        title: "Context Timeline",
        subtitle: "Timestamped captures, imported files, and retained source audio."
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
    .background(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .fill(CepessaColors.backgroundSecondary.opacity(0.82))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .stroke(CepessaColors.border.opacity(0.22), lineWidth: 1)
    )
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
          .tint(CepessaColors.purplePrimary)
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
    .padding(13)
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    .background(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(
          isSelected
            ? Color.accentColor.opacity(0.14) : CepessaColors.backgroundSecondary.opacity(0.76))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .stroke(
          isSelected ? Color.accentColor.opacity(0.28) : CepessaColors.border.opacity(0.22),
          lineWidth: 1
        )
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
    .accessibilityLabel("\(session.displayTitle), \(statusLabel(displayStatus(for: session)))")
    .accessibilityHint("Opens this session in the workspace.")
    .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    .accessibilityAction {
      model.selectSession(id: session.id)
    }
  }

  fileprivate func transcriptRow(_ segment: LocalMeetingTranscriptSegment) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .center, spacing: 8) {
        speakerBadge(segment.speaker)

        Text(segment.timestamp.formatted(date: .omitted, time: .shortened))
          .scaledFont(size: 11)
          .foregroundColor(CepessaColors.textTertiary)

        Spacer(minLength: 0)
      }

      Text(segment.text)
        .scaledFont(size: 14)
        .foregroundColor(CepessaColors.textPrimary)
        .lineSpacing(2)
        .textSelection(.enabled)
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(CepessaColors.backgroundSecondary.opacity(0.86))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .stroke(CepessaColors.border.opacity(0.22), lineWidth: 1)
    )
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
                .fill(CepessaColors.purplePrimary.opacity(0.84))
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
    .padding(14)
    .background(CepessaColors.backgroundRaised.opacity(0.82))
    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 16, style: .continuous)
        .stroke(CepessaColors.border.opacity(0.16), lineWidth: 1)
    )
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
    .background(CepessaColors.backgroundRaised.opacity(0.78))
    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
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
        .foregroundColor(CepessaColors.textSecondary)

      Text(value)
        .scaledFont(size: 12, weight: .semibold)
        .foregroundColor(CepessaColors.textSecondary)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 9)
    .background(CepessaColors.backgroundRaised.opacity(0.72))
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
        .scaledFont(size: 16, weight: .semibold)
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
        .scaledFont(size: 18, weight: .semibold)
        .foregroundColor(CepessaColors.textPrimary)

      Text(subtitle)
        .scaledFont(size: 12)
        .foregroundColor(CepessaColors.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  fileprivate var processingQueueSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .center, spacing: 10) {
        VStack(alignment: .leading, spacing: 4) {
          Text("Processing Queue")
            .scaledFont(size: 15, weight: .semibold)
            .foregroundColor(CepessaColors.textPrimary)

          Text("Every active session stays visible until its transcript and recap finish locally.")
            .scaledFont(size: 11)
            .foregroundColor(CepessaColors.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
        }

        Spacer(minLength: 0)

        smallChip(
          label: activeQueueSummary,
          tint: CepessaColors.purplePrimary.opacity(0.16)
        )
      }

      VStack(spacing: 10) {
        ForEach(model.processingQueue) { snapshot in
          Button {
            model.selectSession(id: snapshot.id)
          } label: {
            processingQueueRow(snapshot, isSelected: model.selectedSessionID == snapshot.id)
          }
          .buttonStyle(.plain)
          .help("Open \(sessionTitle(for: snapshot.id)).")
          .accessibilityLabel("\(sessionTitle(for: snapshot.id)), \(snapshot.title)")
        }
      }
    }
    .padding(14)
    .background(CepessaColors.backgroundSecondary.opacity(0.76))
    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 18, style: .continuous)
        .stroke(CepessaColors.border.opacity(0.22), lineWidth: 1)
    )
  }

  fileprivate var compactProcessingQueueSection: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 8) {
        Text("Active queue")
          .scaledFont(size: 12, weight: .semibold)
          .foregroundColor(CepessaColors.textSecondary)

        Spacer(minLength: 0)

        smallChip(
          label: activeQueueSummary,
          tint: CepessaColors.purplePrimary.opacity(0.14)
        )
      }

      ForEach(model.processingQueue.prefix(3)) { snapshot in
        processingQueueRow(
          snapshot, isSelected: model.selectedSessionID == snapshot.id, compact: true)
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
    .background(CepessaColors.backgroundRaised.opacity(0.42))
    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
  }

  fileprivate func processingQueueRow(
    _ snapshot: LocalSessionProcessingSnapshot,
    isSelected: Bool,
    compact: Bool = false
  ) -> some View {
    VStack(alignment: .leading, spacing: compact ? 6 : 8) {
      HStack(alignment: .center, spacing: 8) {
        VStack(alignment: .leading, spacing: 3) {
          Text(sessionTitle(for: snapshot.id))
            .scaledFont(size: compact ? 12 : 13, weight: .semibold)
            .foregroundColor(CepessaColors.textPrimary)
            .lineLimit(1)

          Text(snapshot.title)
            .scaledFont(size: compact ? 10.5 : 11, weight: .medium)
            .foregroundColor(CepessaColors.textSecondary)
            .lineLimit(1)
        }

        Spacer(minLength: 0)

        smallChip(
          label: snapshot.phase.label,
          tint: CepessaColors.backgroundRaised.opacity(0.9)
        )

        if let progressLabel = snapshot.progressLabel {
          Text(progressLabel)
            .scaledFont(size: 10.5, weight: .medium)
            .foregroundColor(CepessaColors.textTertiary)
            .monospacedDigit()
        }
      }

      Text(snapshot.detail)
        .scaledFont(size: compact ? 10.5 : 11)
        .foregroundColor(CepessaColors.textSecondary)
        .lineLimit(compact ? 1 : 2)

      if let progress = snapshot.progress {
        ProgressView(value: progress)
          .progressViewStyle(.linear)
          .tint(CepessaColors.purplePrimary)
      }
    }
    .padding(.horizontal, compact ? 10 : 12)
    .padding(.vertical, compact ? 9 : 11)
    .background(
      RoundedRectangle(cornerRadius: compact ? 14 : 16, style: .continuous)
        .fill(
          isSelected
            ? CepessaColors.backgroundRaised.opacity(0.92)
            : CepessaColors.backgroundRaised.opacity(0.72))
    )
    .overlay(
      RoundedRectangle(cornerRadius: compact ? 14 : 16, style: .continuous)
        .stroke(
          isSelected
            ? CepessaColors.purplePrimary.opacity(0.34) : CepessaColors.border.opacity(0.18),
          lineWidth: 1
        )
    )
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
    .background(CepessaColors.backgroundSecondary.opacity(0.72))
    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 18, style: .continuous)
        .stroke(CepessaColors.border.opacity(0.18), lineWidth: 1)
    )
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
      .foregroundColor(CepessaColors.purplePrimary)
      .padding(.horizontal, 10)
      .padding(.vertical, 5)
      .background(CepessaColors.purplePrimary.opacity(0.12))
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
      return CepessaColors.purplePrimary
    case .ready:
      return CepessaColors.success
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
      return CepessaColors.error.opacity(0.92)
    }

    if model.isProcessingSession {
      return CepessaColors.purplePrimary.opacity(0.90)
    }

    return CepessaColors.purplePrimary.opacity(0.82)
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

  fileprivate var headerSummary: String {
    if model.isRecording {
      return "Recording on this Mac."
    }

    if model.isProcessingSession {
      return model.processingStatusTitle ?? "Processing locally."
    }

    return "Record, transcribe, and review sessions without leaving this Mac."
  }

  fileprivate var heroTitle: String {
    selectedSession?.displayTitle ?? "Session workspace"
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

    return "Choose a session or start a new recording."
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
      return "Session live"
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

    return "Ready to start"
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
        ?? "The session is being processed on-device into a transcript and structured recap."
    }

    if model.isGeneratingRecap {
      return model.processingStatusDetail
        ?? "Transcript is ready. The recap model is still working locally."
    }

    return
      "Captured session audio and context stay local under Application Support for later review."
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
      return CepessaColors.purplePrimary
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
      return CepessaColors.purplePrimary.opacity(0.24)
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

private enum WorkspaceSection: String, CaseIterable, Identifiable {
  case recap
  case transcript
  case chat
  case attachments

  var id: String { rawValue }

  var title: String {
    switch self {
    case .recap:
      return "Recap"
    case .transcript:
      return "Transcript"
    case .chat:
      return "Chat"
    case .attachments:
      return "Attachments"
    }
  }

  var symbol: String {
    switch self {
    case .recap:
      return "sparkles"
    case .transcript:
      return "text.alignleft"
    case .chat:
      return "bubble.left.and.text.bubble.right"
    case .attachments:
      return "paperclip"
    }
  }

  var subtitle: String {
    switch self {
    case .recap:
      return "Default view"
    case .transcript:
      return "Full session text"
    case .chat:
      return "Ask and edit"
    case .attachments:
      return "Screens, files, and captures"
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
