import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct CepessaSessionsWorkspaceView: View {
    @ObservedObject private var model = CepessaSessionsStore.shared.model
    @State private var centerSection: WorkspaceSection = .recap

    var body: some View {
        GeometryReader { proxy in
            let layout = workspaceLayout(for: proxy.size.width)

            ZStack {
                workspaceBackground

                VStack(spacing: 18) {
                    workspaceHeader(for: layout)

                    workspaceColumns(for: layout, availableHeight: proxy.size.height)

                    floatingSessionDock(for: layout)
                }
                .padding(18)
            }
        }
        .onAppear {
            CepessaSessionFloatingBarController.shared.connect(model: model)
        }
        .onChange(of: model.selectedSessionID) { _, _ in
            centerSection = .recap
        }
    }
}

private extension CepessaSessionsWorkspaceView {
    func workspaceLayout(for width: CGFloat) -> WorkspaceLayoutMode {
        if width >= 1_360 {
            return .wide
        }

        if width >= 1_020 {
            return .split
        }

        return .stacked
    }

    var workspaceBackground: some View {
        LinearGradient(
            colors: [
                OmiColors.backgroundPrimary,
                OmiColors.backgroundPrimary,
                OmiColors.backgroundSecondary.opacity(0.96),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .overlay(alignment: .topLeading) {
            Circle()
                .fill(OmiColors.purplePrimary.opacity(0.10))
                .frame(width: 540, height: 540)
                .blur(radius: 80)
                .offset(x: -220, y: -180)
        }
        .overlay(alignment: .bottomTrailing) {
            Circle()
                .fill(OmiColors.info.opacity(0.06))
                .frame(width: 460, height: 460)
                .blur(radius: 90)
                .offset(x: 170, y: 220)
        }
        .ignoresSafeArea()
    }

    @ViewBuilder
    func workspaceHeader(for layout: WorkspaceLayoutMode) -> some View {
        let compactHeader = layout != .wide

        if compactHeader {
            VStack(alignment: .leading, spacing: 12) {
                workspaceTitleBlock
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        statChip(title: "Sessions", value: "\(model.sessions.count)")
                        statChip(title: "Mode", value: statusSummary)
                        statChip(title: "Storage", value: "Local")
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        statChip(title: "Sessions", value: "\(model.sessions.count)")
                        statChip(title: "Mode", value: statusSummary)
                        statChip(title: "Storage", value: "Local")
                    }
                }

                headerPrimaryAction
            }
            .padding(.horizontal, 6)
        } else {
            HStack(alignment: .bottom, spacing: 16) {
                workspaceTitleBlock

                Spacer(minLength: 0)

                HStack(spacing: 10) {
                    statChip(title: "Sessions", value: "\(model.sessions.count)")
                    statChip(title: "Mode", value: statusSummary)
                    statChip(title: "Storage", value: "Local")
                }

                headerPrimaryAction
            }
            .padding(.horizontal, 6)
        }
    }

    var workspaceTitleBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Cepessa Sessions")
                .scaledFont(size: 30, weight: .semibold)
                .foregroundColor(OmiColors.textPrimary)

            Text("Local-first session workspace with recap, transcript, and captured context kept on this Mac.")
                .scaledFont(size: 13)
                .foregroundColor(OmiColors.textTertiary)
        }
    }

    @ViewBuilder
    var headerPrimaryAction: some View {
        HStack(spacing: 10) {
            if model.isProcessingSession {
                processingCapsule
            }

            Button {
                importRecording()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "waveform.badge.plus")
                        .scaledFont(size: 12, weight: .semibold)

                    Text("Transcribe Recording")
                        .scaledFont(size: 12, weight: .semibold)
                }
                .foregroundColor(OmiColors.textPrimary)
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .background(OmiColors.backgroundTertiary.opacity(0.72))
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)

            Button {
                model.toggleRecording()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: model.isRecording ? "stop.fill" : "record.circle.fill")
                        .scaledFont(size: 13, weight: .semibold)

                    Text(model.isRecording ? "Stop Session" : "Start Session")
                        .scaledFont(size: 13, weight: .semibold)
                }
                .foregroundColor(model.isRecording ? .white : OmiColors.backgroundPrimary)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(model.isRecording ? OmiColors.error : Color.white)
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    var processingCapsule: some View {
        HStack(spacing: 10) {
            if let processingProgress = model.processingProgress {
                ProgressView(value: processingProgress)
                    .progressViewStyle(.linear)
                    .frame(width: 96)
                    .tint(OmiColors.purplePrimary)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .tint(OmiColors.purplePrimary)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(model.processingStatusTitle ?? "Processing locally")
                    .scaledFont(size: 12, weight: .semibold)
                    .foregroundColor(OmiColors.textPrimary)

                Text(model.processingStatusDetail ?? "Processing locally on this Mac.")
                    .scaledFont(size: 11)
                    .foregroundColor(OmiColors.textTertiary)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(OmiColors.backgroundTertiary.opacity(0.58))
        .clipShape(Capsule())
    }

    @ViewBuilder
    func workspaceColumns(for layout: WorkspaceLayoutMode, availableHeight: CGFloat) -> some View {
        let contentHeight = max(availableHeight - 196, 560)

        switch layout {
        case .wide:
            HStack(alignment: .top, spacing: 18) {
                sessionsRail
                    .frame(minWidth: 280, idealWidth: 306, maxWidth: 340)

                centerWorkspace
                    .frame(minWidth: 440, idealWidth: 560, maxWidth: .infinity)

                inspectorRail
                    .frame(minWidth: 300, idealWidth: 324, maxWidth: 360)
            }
            .frame(maxHeight: .infinity, alignment: .top)

        case .split:
            VStack(alignment: .leading, spacing: 18) {
                centerWorkspace
                    .frame(minHeight: max(360, contentHeight * 0.48), maxHeight: .infinity)

                HStack(alignment: .top, spacing: 18) {
                    sessionsRail
                        .frame(minWidth: 280, maxWidth: .infinity, minHeight: max(260, contentHeight * 0.36))

                    inspectorRail
                        .frame(minWidth: 300, maxWidth: .infinity, minHeight: max(260, contentHeight * 0.36))
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)

        case .stacked:
            VStack(alignment: .leading, spacing: 18) {
                centerWorkspace
                    .frame(minHeight: max(340, contentHeight * 0.44))

                sessionsRail
                    .frame(minHeight: max(220, contentHeight * 0.26), maxHeight: max(240, contentHeight * 0.28))

                inspectorRail
                    .frame(minHeight: max(220, contentHeight * 0.26), maxHeight: max(240, contentHeight * 0.28))
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    var sessionsRail: some View {
        VStack(alignment: .leading, spacing: 16) {
            railHeader(
                title: "Session Library",
                subtitle: "The live archive keeps every session one click away from its recap."
            )

            if model.sessions.isEmpty {
                emptyStateCard(
                    icon: "waveform.badge.mic",
                    title: "No sessions yet",
                    message: "Start a session and the local archive will appear here."
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(model.sessions) { session in
                            Button {
                                model.selectSession(id: session.id)
                            } label: {
                                sessionCard(session)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
        }
        .padding(18)
        .frame(maxHeight: .infinity, alignment: .top)
        .omiPanel(
            fill: OmiColors.backgroundTertiary.opacity(0.44),
            radius: 24,
            stroke: OmiColors.border.opacity(0.28),
            shadowOpacity: 0.12,
            shadowRadius: 18,
            shadowY: 10
        )
    }

    var centerWorkspace: some View {
        VStack(alignment: .leading, spacing: 0) {
            centerHeroPanel

            Divider()
                .overlay(OmiColors.border.opacity(0.32))

            centerSectionTabs

            Divider()
                .overlay(OmiColors.border.opacity(0.30))

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    currentCenterSection
                }
                .padding(18)
            }
            .scrollIndicators(.hidden)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .omiPanel(
            fill: OmiColors.backgroundTertiary.opacity(0.42),
            radius: 24,
            stroke: OmiColors.border.opacity(0.28),
            shadowOpacity: 0.12,
            shadowRadius: 18,
            shadowY: 10
        )
    }

    var inspectorRail: some View {
        VStack(alignment: .leading, spacing: 16) {
            railHeader(
                title: "Session Inspector",
                subtitle: "Live state, captured context, and retained source files stay in view."
            )

            captureStatusCard

            attachmentsCard

            Spacer(minLength: 0)
        }
        .padding(18)
        .frame(maxHeight: .infinity, alignment: .top)
        .omiPanel(
            fill: OmiColors.backgroundTertiary.opacity(0.44),
            radius: 24,
            stroke: OmiColors.border.opacity(0.28),
            shadowOpacity: 0.12,
            shadowRadius: 18,
            shadowY: 10
        )
    }

    @ViewBuilder
    func floatingSessionDock(for layout: WorkspaceLayoutMode) -> some View {
        let compactDock = layout == .stacked

        Group {
            if compactDock {
                VStack(alignment: .leading, spacing: 14) {
                    dockLead

                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) {
                            dockMetric(title: "Mic", value: percentText(model.micLevel))
                            dockMetric(title: "System", value: percentText(model.systemLevel))
                            dockMetric(title: "Local", value: model.isProcessingSession ? processingBadgeValue : "On device")
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 8) {
                                dockMetric(title: "Mic", value: percentText(model.micLevel))
                                dockMetric(title: "System", value: percentText(model.systemLevel))
                            }
                            dockMetric(title: "Local", value: model.isProcessingSession ? processingBadgeValue : "On device")
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
                        dockMetric(title: "Local", value: model.isProcessingSession ? processingBadgeValue : "On device")
                    }

                    dockAction
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .omiPanel(
            fill: dockFill,
            radius: 22,
            stroke: dockStroke,
            shadowOpacity: 0.16,
            shadowRadius: 20,
            shadowY: 10
        )
    }

    var dockLead: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                Circle()
                    .fill(dockAccent.opacity(0.18))
                    .frame(width: 36, height: 36)

                Circle()
                    .fill(dockAccent)
                    .frame(width: 12, height: 12)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("Floating capture bar")
                    .scaledFont(size: 13, weight: .semibold)
                    .foregroundColor(OmiColors.textPrimary)

                Text(dockSubtitle)
                    .scaledFont(size: 11)
                    .foregroundColor(OmiColors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    var dockAction: some View {
        if model.isRecording {
            Button {
                model.toggleRecording()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "stop.fill")
                        .scaledFont(size: 12, weight: .semibold)

                    Text("Stop Session")
                        .scaledFont(size: 12, weight: .semibold)
                }
                .foregroundColor(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
                .background(OmiColors.error)
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        } else {
            HStack(spacing: 8) {
                if model.isProcessingSession {
                    if let processingProgress = model.processingProgress {
                        ProgressView(value: processingProgress)
                            .progressViewStyle(.linear)
                            .frame(width: 76)
                            .tint(OmiColors.purplePrimary)
                    } else {
                        ProgressView()
                            .scaleEffect(0.7)
                            .tint(OmiColors.purplePrimary)
                    }

                    Text(processingActionTitle)
                        .scaledFont(size: 12, weight: .medium)
                        .foregroundColor(OmiColors.textSecondary)
                }

                Button {
                    importRecording()
                } label: {
                    Image(systemName: "waveform.badge.plus")
                        .scaledFont(size: 12, weight: .semibold)
                }
                .buttonStyle(.plain)

                Button {
                    model.toggleRecording()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "record.circle.fill")
                            .scaledFont(size: 12, weight: .semibold)

                        Text("Start Session")
                            .scaledFont(size: 12, weight: .semibold)
                    }
                }
                .buttonStyle(.plain)
                .foregroundColor(OmiColors.backgroundPrimary)
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
                .background(Color.white)
                .clipShape(Capsule())
            }
        }
    }

    var centerHeroPanel: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text(heroTitle)
                    .scaledFont(size: 22, weight: .semibold)
                    .foregroundColor(OmiColors.textPrimary)
                    .lineLimit(2)

                HStack(spacing: 8) {
                    statusBadge(for: heroStatus)

                    Text(heroSubtitle)
                        .scaledFont(size: 12)
                        .foregroundColor(OmiColors.textTertiary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            VStack(alignment: .trailing, spacing: 8) {
                Text(selectionMetaTitle)
                    .scaledFont(size: 11, weight: .medium)
                    .foregroundColor(OmiColors.textTertiary)

                Text(selectionMetaValue)
                    .scaledFont(size: 14, weight: .semibold)
                    .foregroundColor(OmiColors.textSecondary)

                if let promptPackageURL = model.promptPackageMarkdownURL(),
                   let sessionFolderURL = model.sessionFolderURL(),
                   FileManager.default.fileExists(atPath: promptPackageURL.path) {
                    HStack(spacing: 8) {
                        heroActionButton(title: "Open package", systemImage: "doc.text") {
                            NSWorkspace.shared.open(promptPackageURL)
                        }

                        heroActionButton(title: "Reveal session", systemImage: "folder") {
                            NSWorkspace.shared.activateFileViewerSelecting([sessionFolderURL])
                        }
                    }
                    .padding(.top, 2)
                }
            }
        }
        .padding(18)
        .background(
            LinearGradient(
                colors: [
                    OmiColors.backgroundSecondary.opacity(0.92),
                    OmiColors.backgroundRaised.opacity(0.78),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }

    var recapCard: some View {
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

                VStack(alignment: .leading, spacing: 12) {
                    if !session.recap.overview.isEmpty {
                        Text(session.recap.overview)
                            .scaledFont(size: 14, weight: .medium)
                            .foregroundColor(OmiColors.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    ForEach(recapSections(for: session)) { section in
                        recapSectionCard(section)
                    }
                }
                .padding(16)
                .background(OmiColors.backgroundSecondary.opacity(0.82))
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
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
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(OmiColors.backgroundSecondary.opacity(0.76))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(OmiColors.border.opacity(0.26), lineWidth: 1)
        )
    }

    var centerSectionTabs: some View {
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
                    .foregroundColor(centerSection == section ? OmiColors.textPrimary : OmiColors.textTertiary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .background {
                        if centerSection == section {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(OmiColors.backgroundRaised.opacity(0.92))
                        }
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(
                                centerSection == section ? OmiColors.purplePrimary.opacity(0.42) : OmiColors.border.opacity(0.18),
                                lineWidth: 1
                            )
                    }
                }
                .buttonStyle(.plain)
            }

            Spacer(minLength: 0)

            Text(centerSection.subtitle)
                .scaledFont(size: 11)
                .foregroundColor(OmiColors.textTertiary)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(OmiColors.backgroundSecondary.opacity(0.66))
    }

    @ViewBuilder
    var currentCenterSection: some View {
        switch centerSection {
        case .recap:
            recapCard
        case .transcript:
            transcriptCard
        case .attachments:
            attachmentsCard
        }
    }

    var transcriptCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            rowHeader(
                title: "Transcript",
                subtitle: "The exact spoken record, including mixed Hebrew and English when needed."
            )

            if let session = selectedSession {
                if session.segments.isEmpty {
                    emptyStateCard(
                        icon: displayStatus(for: session) == .transcribing ? "brain" : "text.bubble",
                        title: displayStatus(for: session) == .transcribing ? "Processing transcript" : "Transcript pending",
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
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(OmiColors.backgroundSecondary.opacity(0.76))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(OmiColors.border.opacity(0.26), lineWidth: 1)
        )
    }

    var captureStatusCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            rowHeader(
                title: "Live Status",
                subtitle: "Session state, on-device processing, and input health."
            )

            HStack(alignment: .center, spacing: 10) {
                Circle()
                    .fill(dockAccent)
                    .frame(width: 10, height: 10)

                Text(statusTitle)
                    .scaledFont(size: 14, weight: .semibold)
                    .foregroundColor(OmiColors.textPrimary)

                Spacer(minLength: 0)

                if model.isRecording {
                    Text(model.recordingDurationText)
                        .scaledFont(size: 12, weight: .medium)
                        .foregroundColor(OmiColors.textSecondary)
                }
            }

            Text(statusDescription)
                .scaledFont(size: 12)
                .foregroundColor(OmiColors.textTertiary)

            if model.isProcessingSession {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Text(model.processingStatusTitle ?? "Processing locally")
                            .scaledFont(size: 12, weight: .semibold)
                            .foregroundColor(OmiColors.textSecondary)

                        Spacer(minLength: 0)

                        if let processingProgress = model.processingProgress {
                            Text("\(Int((processingProgress * 100).rounded()))%")
                                .scaledFont(size: 11, weight: .medium)
                                .foregroundColor(OmiColors.textTertiary)
                                .monospacedDigit()
                        }
                    }

                    if let processingProgress = model.processingProgress {
                        ProgressView(value: processingProgress)
                            .progressViewStyle(.linear)
                            .tint(OmiColors.purplePrimary)
                    } else {
                        ProgressView()
                            .controlSize(.small)
                            .tint(OmiColors.purplePrimary)
                    }

                    Text(model.processingStatusDetail ?? "Building transcript and recap locally")
                        .scaledFont(size: 11)
                        .foregroundColor(OmiColors.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(OmiColors.purplePrimary.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            VStack(alignment: .leading, spacing: 12) {
                meterRow(title: "Mic", value: model.micLevel, icon: "mic.fill")
                meterRow(title: "System", value: model.systemLevel, icon: "speaker.wave.2.fill")
            }

            if let error = model.recorderErrorMessage, !error.isEmpty {
                Text(error)
                    .scaledFont(size: 12)
                    .foregroundColor(OmiColors.error)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(OmiColors.backgroundSecondary.opacity(0.82))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(OmiColors.border.opacity(0.22), lineWidth: 1)
        )
    }

    var attachmentsCard: some View {
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
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(OmiColors.backgroundSecondary.opacity(0.82))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(OmiColors.border.opacity(0.22), lineWidth: 1)
        )
    }

    func sessionCard(_ session: LocalMeetingSession) -> some View {
        let isSelected = model.selectedSessionID == session.id

        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(session.displayTitle)
                        .scaledFont(size: 14, weight: .semibold)
                        .foregroundColor(OmiColors.textPrimary)
                        .lineLimit(2)

                    Text(session.startedAt.formatted(date: .abbreviated, time: .shortened))
                        .scaledFont(size: 11)
                        .foregroundColor(OmiColors.textTertiary)
                }

                Spacer(minLength: 0)

                statusBadge(for: displayStatus(for: session))
            }

            if !session.transcriptText.isEmpty {
                Text(session.transcriptText)
                    .scaledFont(size: 12)
                    .foregroundColor(OmiColors.textSecondary)
                    .lineLimit(3)
            } else {
                Text(displayStatus(for: session) == .transcribing ? "Session processing is being built locally." : "Transcript pending.")
                    .scaledFont(size: 12)
                    .foregroundColor(OmiColors.textSecondary)
                    .lineLimit(2)
            }

            HStack(spacing: 8) {
                smallChip(
                    label: countLabel(session.segments.count, singular: "segment"),
                    tint: OmiColors.backgroundRaised.opacity(0.9)
                )

                smallChip(
                    label: audioSnapshotLabel(for: session),
                    tint: OmiColors.backgroundRaised.opacity(0.9)
                )
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(
                colors: isSelected
                    ? [
                        OmiColors.backgroundSecondary,
                        OmiColors.backgroundRaised.opacity(0.94),
                    ]
                    : [
                        OmiColors.backgroundTertiary.opacity(0.76),
                        OmiColors.backgroundTertiary.opacity(0.58),
                    ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(
                    isSelected ? OmiColors.purplePrimary.opacity(0.46) : OmiColors.border.opacity(0.28),
                    lineWidth: 1
                )
        )
        .shadow(color: Color.black.opacity(isSelected ? 0.09 : 0.04), radius: isSelected ? 14 : 8, y: isSelected ? 8 : 4)
    }

    func transcriptRow(_ segment: LocalMeetingTranscriptSegment) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                speakerBadge(segment.speaker)

                Text(segment.timestamp.formatted(date: .omitted, time: .shortened))
                    .scaledFont(size: 11)
                    .foregroundColor(OmiColors.textTertiary)

                Spacer(minLength: 0)
            }

            Text(segment.text)
                .scaledFont(size: 14)
                .foregroundColor(OmiColors.textPrimary)
                .lineSpacing(2)
                .textSelection(.enabled)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(OmiColors.backgroundSecondary.opacity(0.86))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(OmiColors.border.opacity(0.22), lineWidth: 1)
        )
    }

    func recapSectionCard(_ section: LocalMeetingRecapSection) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Text(section.title)
                    .scaledFont(size: 13, weight: .semibold)
                    .foregroundColor(OmiColors.textPrimary)

                Spacer(minLength: 0)

                if let offset = section.startOffset {
                    Text(timeString(from: offset))
                        .scaledFont(size: 10, weight: .medium)
                        .foregroundColor(OmiColors.textTertiary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(OmiColors.backgroundRaised.opacity(0.72))
                        .clipShape(Capsule())
                }
            }

            if !section.summary.isEmpty {
                Text(section.summary)
                    .scaledFont(size: 12)
                    .foregroundColor(OmiColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !section.bullets.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(section.bullets, id: \.self) { bullet in
                        HStack(alignment: .top, spacing: 8) {
                            Circle()
                                .fill(OmiColors.purplePrimary.opacity(0.84))
                                .frame(width: 6, height: 6)
                                .padding(.top, 5)

                            Text(bullet)
                                .scaledFont(size: 12)
                                .foregroundColor(OmiColors.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
        .padding(14)
        .background(OmiColors.backgroundTertiary.opacity(0.52))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    func meterRow(title: String, value: Double, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(title, systemImage: icon)
                    .scaledFont(size: 12, weight: .medium)
                    .foregroundColor(OmiColors.textSecondary)

                Spacer(minLength: 0)

                Text(percentText(value))
                    .scaledFont(size: 11)
                    .foregroundColor(OmiColors.textTertiary)
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(OmiColors.backgroundTertiary)

                    Capsule()
                        .fill(meterFill(for: value))
                        .frame(width: max(12, proxy.size.width * value))
                }
            }
            .frame(height: 10)
        }
    }

    func artifactRow(title: String, icon: String, fileName: String?, showsStatusBadge: Bool = true) -> some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(OmiColors.backgroundRaised.opacity(0.88))
                    .frame(width: 30, height: 30)

                Image(systemName: icon)
                    .scaledFont(size: 13, weight: .semibold)
                    .foregroundColor(OmiColors.textSecondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .center, spacing: 8) {
                    Text(title)
                        .scaledFont(size: 13, weight: .semibold)
                        .foregroundColor(OmiColors.textPrimary)

                    if showsStatusBadge {
                        Spacer(minLength: 0)

                        statusBadge(for: (fileName == nil || fileName == "Not retained yet") ? .failed : .ready)
                    }
                }

                Text(fileName ?? "Not retained yet")
                    .scaledFont(size: 12)
                    .foregroundColor(fileName == nil ? OmiColors.textTertiary : OmiColors.textSecondary)
                    .lineLimit(2)
            }
        }
        .padding(12)
        .background(OmiColors.backgroundTertiary.opacity(0.48))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    func metricCard(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .scaledFont(size: 11, weight: .medium)
                .foregroundColor(OmiColors.textTertiary)

            Text(value)
                .scaledFont(size: 16, weight: .semibold)
                .foregroundColor(OmiColors.textPrimary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(OmiColors.backgroundTertiary.opacity(0.48))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    func heroActionButton(title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: systemImage)
                    .scaledFont(size: 11, weight: .semibold)

                Text(title)
                    .scaledFont(size: 11, weight: .semibold)
            }
            .foregroundColor(OmiColors.textSecondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(OmiColors.backgroundRaised.opacity(0.82))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    func dockMetric(title: String, value: String) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .scaledFont(size: 11, weight: .medium)
                .foregroundColor(OmiColors.textTertiary)

            Text(value)
                .scaledFont(size: 12, weight: .semibold)
                .foregroundColor(OmiColors.textSecondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(OmiColors.backgroundRaised.opacity(0.72))
        .clipShape(Capsule())
    }

    func smallChip(label: String, tint: Color) -> some View {
        Text(label)
            .scaledFont(size: 10, weight: .semibold)
            .foregroundColor(OmiColors.textSecondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(tint)
            .clipShape(Capsule())
    }

    func statChip(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .scaledFont(size: 10, weight: .medium)
                .foregroundColor(OmiColors.textTertiary)

            Text(value)
                .scaledFont(size: 12, weight: .semibold)
                .foregroundColor(OmiColors.textSecondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(OmiColors.backgroundTertiary.opacity(0.52))
        .clipShape(Capsule())
    }

    func railHeader(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .scaledFont(size: 18, weight: .semibold)
                .foregroundColor(OmiColors.textPrimary)

            Text(subtitle)
                .scaledFont(size: 12)
                .foregroundColor(OmiColors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    func rowHeader(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .scaledFont(size: 18, weight: .semibold)
                .foregroundColor(OmiColors.textPrimary)

            Text(subtitle)
                .scaledFont(size: 12)
                .foregroundColor(OmiColors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    func emptyStateCard(icon: String, title: String, message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .scaledFont(size: 26)
                .foregroundColor(OmiColors.textTertiary)

            VStack(spacing: 4) {
                Text(title)
                    .scaledFont(size: 14, weight: .semibold)
                    .foregroundColor(OmiColors.textPrimary)

                Text(message)
                    .scaledFont(size: 12)
                    .foregroundColor(OmiColors.textSecondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .background(OmiColors.backgroundSecondary.opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(OmiColors.border.opacity(0.18), lineWidth: 1)
        )
    }

    func statusBadge(for status: LocalMeetingSessionStatus) -> some View {
        Text(statusLabel(status))
            .scaledFont(size: 10, weight: .semibold)
            .foregroundColor(statusTextColor(for: status))
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(statusBackground(for: status))
            .clipShape(Capsule())
    }

    func speakerBadge(_ speaker: String) -> some View {
        Text(speaker.isEmpty ? "Speaker" : speaker)
            .scaledFont(size: 11, weight: .semibold)
            .foregroundColor(OmiColors.purplePrimary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(OmiColors.purplePrimary.opacity(0.12))
            .clipShape(Capsule())
    }

    func statusLabel(_ status: LocalMeetingSessionStatus) -> String {
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

    func statusBackground(for status: LocalMeetingSessionStatus) -> Color {
        switch status {
        case .recording:
            return OmiColors.error
        case .transcribing:
            return OmiColors.purplePrimary
        case .ready:
            return OmiColors.success
        case .failed:
            return OmiColors.warning
        }
    }

    func statusTextColor(for status: LocalMeetingSessionStatus) -> Color {
        switch status {
        case .ready:
            return OmiColors.backgroundPrimary
        default:
            return .white
        }
    }

    func meterFill(for value: Double) -> Color {
        if model.isRecording {
            return OmiColors.error.opacity(0.92)
        }

        if model.isProcessingSession {
            return OmiColors.purplePrimary.opacity(0.90)
        }

        return OmiColors.purplePrimary.opacity(0.82)
    }

    func percentText(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }

    func speakerCount(for session: LocalMeetingSession) -> Int {
        let speakers = Set(
            session.segments
                .map { $0.speaker.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )

        return max(1, speakers.count)
    }

    func audioSnapshotLabel(for session: LocalMeetingSession) -> String {
        if session.audioArtifacts.mixedFileName != nil {
            return "Mixed"
        }

        if session.audioArtifacts.micFileName != nil || session.audioArtifacts.systemFileName != nil {
            return "Source"
        }

        return "Pending"
    }

    func recapLines(for session: LocalMeetingSession) -> [String] {
        if !session.recap.sections.isEmpty {
            return session.recap.sections.flatMap { section in
                [section.summary] + section.bullets
            }
            .filter { !$0.isEmpty }
        }

        var lines: [String] = []

        lines.append("\(session.segments.count) transcript segment\(session.segments.count == 1 ? "" : "s") are captured locally.")
        lines.append("Speaker labels: \(speakerCount(for: session)).")

        if let mixed = session.audioArtifacts.mixedFileName, !mixed.isEmpty {
            lines.append("Mixed audio master is retained as \(mixed).")
        } else {
            lines.append("Mixed audio master has not been generated yet.")
        }

        if let firstLine = session.segments.first?.text.trimmingCharacters(in: .whitespacesAndNewlines), !firstLine.isEmpty {
            lines.append("Opening transcript line: \(firstLine.truncated(maxLength: 96)).")
        } else {
            lines.append("Transcript text will appear after the session completes transcription.")
        }

        return lines
    }

    func transcriptPendingMessage(for session: LocalMeetingSession) -> String {
        if session.status == .failed {
            return "This session failed to transcribe locally."
        }

        if model.isTranscribing {
            return model.processingStatusDetail ?? "The session is being processed on-device into a transcript and structured recap."
        }

        if model.isGeneratingRecap(for: session.id) {
            return model.processingStatusDetail ?? "The transcript is ready. The recap is still being generated locally."
        }

        return "Stop the session and the transcript will appear here."
    }

    var selectedSession: LocalMeetingSession? {
        model.selectedSession
    }

    var heroTitle: String {
        selectedSession?.displayTitle ?? "Session workspace"
    }

    var heroSubtitle: String {
        if let session = selectedSession {
            let captures = session.captureArtifacts.count + session.attachments.count
            return [
                session.startedAt.formatted(date: .complete, time: .shortened),
                countLabel(session.segments.count, singular: "segment"),
                countLabel(captures, singular: "capture"),
            ]
            .joined(separator: " • ")
        }

        return "Select a session to inspect recap, transcript, and artifacts."
    }

    var selectionMetaTitle: String {
        if selectedSession != nil {
            return "Selected session"
        }

        return "Workspace status"
    }

    var selectionMetaValue: String {
        if let session = selectedSession {
            switch displayStatus(for: session) {
            case .recording:
                return "Live"
            case .transcribing:
                return processingBadgeValue
            case .ready:
                return model.isGeneratingRecap(for: session.id) ? "Recap" : "Ready"
            case .failed:
                return "Needs attention"
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

    var heroStatus: LocalMeetingSessionStatus {
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

    var statusTitle: String {
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

    var statusSummary: String {
        if model.isRecording {
            return "Live"
        }

        if model.isProcessingSession {
            return processingBadgeValue
        }

        return "Idle"
    }

    var processingBadgeValue: String {
        if let progress = model.processingProgress {
            return "\(Int((progress * 100).rounded()))%"
        }

        return "Processing"
    }

    var processingActionTitle: String {
        model.processingStatusTitle ?? processingBadgeValue
    }

    var statusDescription: String {
        if model.isRecording {
            return model.recordingDurationText
        }

        if model.isTranscribing {
            return model.processingStatusDetail ?? "The session is being processed on-device into a transcript and structured recap."
        }

        if model.isGeneratingRecap {
            return model.processingStatusDetail ?? "Transcript is ready. The recap model is still working locally."
        }

        return "Captured session audio and context stay local under Application Support for later review."
    }

    var dockSubtitle: String {
        if let session = selectedSession {
            return displayStatus(for: session) == .recording
                ? "The floating bar is live and can capture timestamped screenshots or files."
                : "The live overlay mirrors session and processing state on top of the desktop."
        }

        return model.isRecording ? "A live session is in progress." : "Ready to mirror the active session state."
    }

    var dockAccent: Color {
        if model.isRecording {
            return OmiColors.error
        }

        if model.isProcessingSession {
            return OmiColors.purplePrimary
        }

        return OmiColors.textTertiary
    }

    var dockFill: Color {
        if model.isRecording {
            return OmiColors.backgroundSecondary.opacity(0.90)
        }

        if model.isProcessingSession {
            return OmiColors.backgroundSecondary.opacity(0.92)
        }

        return OmiColors.backgroundTertiary.opacity(0.74)
    }

    var dockStroke: Color {
        if model.isRecording {
            return OmiColors.error.opacity(0.26)
        }

        if model.isProcessingSession {
            return OmiColors.purplePrimary.opacity(0.24)
        }

        return OmiColors.border.opacity(0.26)
    }

    func recapSections(for session: LocalMeetingSession) -> [LocalMeetingRecapSection] {
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

    func attachmentTitle(for attachment: LocalMeetingAttachment) -> String {
        attachment.title.isEmpty ? "Attachment" : attachment.title
    }

    func displayStatus(for session: LocalMeetingSession) -> LocalMeetingSessionStatus {
        if model.isGeneratingRecap(for: session.id) {
            return .transcribing
        }

        return session.status
    }

    func importRecording() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.audio]
        panel.prompt = "Transcribe"
        panel.message = "Choose an existing recording to import, normalize locally, and transcribe on this Mac."

        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            await model.importExistingRecording(from: url)
        }
    }

    func attachmentSubtitle(for attachment: LocalMeetingAttachment) -> String {
        let stamp = attachment.sessionOffset.map(timeString(from:)) ?? "00:00"
        let file = attachment.fileName ?? attachment.urlString ?? "Saved locally"
        return "\(stamp)  \(file)"
    }

    func captureArtifactTitle(for artifact: LocalMeetingCaptureArtifact) -> String {
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

    func captureArtifactSubtitle(for artifact: LocalMeetingCaptureArtifact) -> String {
        let stamp = artifact.sessionOffset.map(timeString(from:)) ?? "00:00"

        if let notes = artifact.notes, !notes.isEmpty {
            return "\(stamp)  \(notes)"
        }

        return "\(stamp)  Stored locally"
    }

    func captureArtifactIcon(for artifact: LocalMeetingCaptureArtifact) -> String {
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

    func icon(for attachment: LocalMeetingAttachment) -> String {
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

    func timeString(from interval: TimeInterval) -> String {
        let totalSeconds = max(0, Int(interval.rounded()))
        return String(format: "%02d:%02d", totalSeconds / 60, totalSeconds % 60)
    }

    func countLabel(_ count: Int, singular: String, plural: String? = nil) -> String {
        let pluralText = plural ?? singular + "s"
        return "\(count) \(count == 1 ? singular : pluralText)"
    }
}

private enum WorkspaceSection: String, CaseIterable, Identifiable {
    case recap
    case transcript
    case attachments

    var id: String { rawValue }

    var title: String {
        switch self {
        case .recap:
            return "Recap"
        case .transcript:
            return "Transcript"
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

private extension String {
    func truncated(maxLength: Int) -> String {
        guard count > maxLength else { return self }
        let index = index(startIndex, offsetBy: maxLength)
        return String(self[..<index]) + "…"
    }
}
