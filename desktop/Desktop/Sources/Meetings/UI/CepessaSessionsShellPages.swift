import AVFoundation
import AppKit
import SwiftUI

struct CepessaSessionsHomePage: View {
    var body: some View {
        CepessaSessionsWorkspaceView()
    }
}

struct CepessaSessionsLibraryPage: View {
    @ObservedObject private var model = CepessaSessionsStore.shared.model
    @State private var searchText = ""

    private var filteredSessions: [LocalMeetingSession] {
        let normalized = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return model.sessions }

        return model.sessions.filter { session in
            session.displayTitle.localizedCaseInsensitiveContains(normalized)
                || session.transcriptText.localizedCaseInsensitiveContains(normalized)
                || session.attachments.contains(where: { $0.title.localizedCaseInsensitiveContains(normalized) })
        }
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [OmiColors.backgroundPrimary, OmiColors.backgroundSecondary.opacity(0.96)],
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
                            .foregroundStyle(OmiColors.textTertiary)

                        Text("Library")
                            .scaledFont(size: 30, weight: .semibold)
                            .foregroundStyle(OmiColors.textPrimary)

                        Text("Search every local session, revisit transcripts, and reopen recap context on this Mac.")
                            .scaledFont(size: 13)
                            .foregroundStyle(OmiColors.textTertiary)
                    }

                    HStack(spacing: 8) {
                        infoPill("Local only")
                        infoPill("Mixed-language transcripts")
                        infoPill("Attachments preserved")
                    }

                    HStack(spacing: 12) {
                        HStack(spacing: 10) {
                            Image(systemName: "magnifyingglass")
                                .foregroundStyle(OmiColors.textTertiary)
                            TextField("Search sessions, transcripts, or artifact titles", text: $searchText)
                                .textFieldStyle(.plain)
                                .foregroundStyle(OmiColors.textPrimary)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .background(OmiColors.backgroundTertiary.opacity(0.66))
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

                        Text("\(filteredSessions.count) \(filteredSessions.count == 1 ? "session" : "sessions")")
                            .scaledFont(size: 12, weight: .semibold)
                            .foregroundStyle(OmiColors.textSecondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(OmiColors.backgroundRaised.opacity(0.72))
                            .clipShape(Capsule())
                    }

                    if filteredSessions.isEmpty {
                        emptyState
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 12) {
                                ForEach(filteredSessions) { session in
                                    Button {
                                        model.selectSession(id: session.id)
                                    } label: {
                                        libraryRow(session: session, isSelected: model.selectedSessionID == session.id)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.trailing, 6)
                        }
                        .scrollIndicators(.hidden)
                    }
                }
                .padding(22)
                .frame(minWidth: 360, idealWidth: 420, maxWidth: 440, maxHeight: .infinity, alignment: .top)
                .omiPanel(
                    fill: OmiColors.backgroundTertiary.opacity(0.4),
                    radius: 28,
                    stroke: OmiColors.border.opacity(0.26),
                    shadowOpacity: 0.12,
                    shadowRadius: 18,
                    shadowY: 10
                )

                CepessaLibraryDetailPane(session: model.selectedSession)
            }
            .padding(20)
        }
        .onAppear {
            CepessaSessionFloatingBarController.shared.connect(model: model)
        }
    }

    private func libraryRow(session: LocalMeetingSession, isSelected: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(session.displayTitle)
                        .scaledFont(size: 15, weight: .semibold)
                        .foregroundStyle(OmiColors.textPrimary)
                        .lineLimit(2)

                    Text(session.startedAt.formatted(date: .abbreviated, time: .shortened))
                        .scaledFont(size: 11)
                        .foregroundStyle(OmiColors.textTertiary)
                }

                Spacer(minLength: 0)

                sessionStatusBadge(session.status)
            }

            Text(previewText(for: session))
                .scaledFont(size: 12)
                .foregroundStyle(OmiColors.textSecondary)
                .lineLimit(3)

            HStack(spacing: 8) {
                        infoPill("\(session.segments.count) \(session.segments.count == 1 ? "segment" : "segments")")
                infoPill("\(timelineArtifactCount(for: session)) artifacts")
                infoPill(session.recap.sections.isEmpty ? "Recap pending" : "Structured recap")
            }
        }
        .padding(17)
        .background(
            LinearGradient(
                colors: [
                    isSelected ? OmiColors.backgroundSecondary : OmiColors.backgroundTertiary.opacity(0.76),
                    isSelected ? OmiColors.backgroundRaised.opacity(0.92) : OmiColors.backgroundTertiary.opacity(0.58)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(isSelected ? OmiColors.purplePrimary.opacity(0.44) : OmiColors.border.opacity(0.22), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(isSelected ? 0.08 : 0.04), radius: isSelected ? 14 : 8, y: isSelected ? 8 : 4)
    }

    private func sessionStatusBadge(_ status: LocalMeetingSessionStatus) -> some View {
        Text(status.label)
            .scaledFont(size: 10, weight: .semibold)
            .foregroundStyle(status == .ready ? OmiColors.backgroundPrimary : Color.white)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(status.badgeColor)
            .clipShape(Capsule())
    }

    private func infoPill(_ text: String) -> some View {
        Text(text)
            .scaledFont(size: 10, weight: .medium)
            .foregroundStyle(OmiColors.textTertiary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(OmiColors.backgroundRaised.opacity(0.72))
            .clipShape(Capsule())
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

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass.circle")
                .scaledFont(size: 28)
                .foregroundStyle(OmiColors.textTertiary)

            Text("No sessions match this search")
                .scaledFont(size: 16, weight: .semibold)
                .foregroundStyle(OmiColors.textPrimary)

            Text("Try a transcript phrase, attachment title, or recap keyword.")
                .scaledFont(size: 12)
                .foregroundStyle(OmiColors.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
        .background(OmiColors.backgroundTertiary.opacity(0.42))
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(OmiColors.border.opacity(0.2), lineWidth: 1)
        )
    }
}

private struct CepessaLibraryDetailPane: View {
    let session: LocalMeetingSession?

    var body: some View {
        Group {
            if let session {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Selected session")
                                .scaledFont(size: 11, weight: .semibold)
                                .tracking(0.18)
                                .foregroundStyle(OmiColors.textTertiary)

                            Text(session.displayTitle)
                                .scaledFont(size: 28, weight: .semibold)
                                .foregroundStyle(OmiColors.textPrimary)
                                .lineLimit(2)

                            Text(session.startedAt.formatted(date: .complete, time: .shortened))
                                .scaledFont(size: 12)
                                .foregroundStyle(OmiColors.textTertiary)
                        }

                        HStack(spacing: 8) {
                            infoPill(session.status.label)
                            infoPill("\(session.segments.count) \(session.segments.count == 1 ? "segment" : "segments")")
                            infoPill("\(session.attachments.count + session.captureArtifacts.count) artifacts")
                            infoPill(session.recap.sections.isEmpty ? "Recap pending" : "Structured recap")
                        }

                        detailBlock("Structured recap", subtitle: "The recap appears in sections so you can edit or reuse one part at a time.") {
                            if session.recap.overview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && session.recap.sections.isEmpty {
                                Text("Recap is still being prepared.")
                                    .scaledFont(size: 13)
                                    .foregroundStyle(OmiColors.textSecondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(14)
                                    .background(OmiColors.backgroundSecondary.opacity(0.82))
                                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                            } else {
                                VStack(alignment: .leading, spacing: 12) {
                                    if !session.recap.overview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                        recapOverviewCard(session.recap.overview)
                                    }

                                    ForEach(session.recap.sections) { section in
                                        recapSectionCard(section)
                                    }
                                }
                            }
                        }

                        detailBlock("Transcript", subtitle: "The transcript keeps the original flow of the session, including mixed Hebrew and English.") {
                            if session.transcriptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                Text("Transcript not available yet.")
                                    .scaledFont(size: 13)
                                    .foregroundStyle(OmiColors.textSecondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(14)
                                    .background(OmiColors.backgroundSecondary.opacity(0.82))
                                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                            } else {
                                Text(session.transcriptText)
                                    .scaledFont(size: 13)
                                    .foregroundStyle(OmiColors.textSecondary)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(14)
                                    .background(OmiColors.backgroundSecondary.opacity(0.82))
                                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                            }
                        }

                        detailBlock("Context timeline", subtitle: "Screenshots, documents, and captures stay pinned to the exact session moment.") {
                            if session.attachments.isEmpty && session.captureArtifacts.isEmpty {
                                Text("Screenshots, clips, and documents captured during the session will appear here with exact timestamps.")
                                    .scaledFont(size: 13)
                                    .foregroundStyle(OmiColors.textSecondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(14)
                                    .background(OmiColors.backgroundSecondary.opacity(0.82))
                                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                            } else {
                                VStack(alignment: .leading, spacing: 10) {
                                    if !session.attachments.isEmpty {
                                        Text("Attachments")
                                            .scaledFont(size: 12, weight: .semibold)
                                            .foregroundStyle(OmiColors.textPrimary)

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
                                            .foregroundStyle(OmiColors.textPrimary)

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
                }
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "sparkles.rectangle.stack")
                        .scaledFont(size: 28)
                        .foregroundStyle(OmiColors.textTertiary)

                    Text("Choose a session")
                        .scaledFont(size: 16, weight: .semibold)
                        .foregroundStyle(OmiColors.textPrimary)

                    Text("Transcript, recap, and artifact context appear here for the selected session.")
                        .scaledFont(size: 12)
                        .foregroundStyle(OmiColors.textSecondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(24)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .omiPanel(
            fill: OmiColors.backgroundTertiary.opacity(0.4),
            radius: 28,
            stroke: OmiColors.border.opacity(0.26),
            shadowOpacity: 0.12,
            shadowRadius: 18,
            shadowY: 10
        )
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
                    .foregroundStyle(OmiColors.textPrimary)

                if let subtitle {
                    Text(subtitle)
                        .scaledFont(size: 12)
                        .foregroundStyle(OmiColors.textTertiary)
                }
            }

            content()
        }
    }

    private func infoPill(_ text: String) -> some View {
        Text(text)
            .scaledFont(size: 10, weight: .medium)
            .foregroundStyle(OmiColors.textTertiary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(OmiColors.backgroundRaised.opacity(0.72))
            .clipShape(Capsule())
    }

    private func recapOverviewCard(_ text: String) -> some View {
        Text(text)
            .scaledFont(size: 13)
            .foregroundStyle(OmiColors.textSecondary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(
                LinearGradient(
                    colors: [OmiColors.backgroundSecondary.opacity(0.92), OmiColors.backgroundRaised.opacity(0.9)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(OmiColors.border.opacity(0.18), lineWidth: 1)
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
                    .foregroundStyle(OmiColors.textPrimary)
            }

            if !section.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(section.summary)
                    .scaledFont(size: 12)
                    .foregroundStyle(OmiColors.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !section.bullets.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(section.bullets, id: \.self) { bullet in
                        HStack(alignment: .top, spacing: 8) {
                            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                                .fill(OmiColors.textTertiary.opacity(0.65))
                                .frame(width: 5, height: 5)
                                .padding(.top, 6)

                            Text(bullet)
                                .scaledFont(size: 12)
                                .foregroundStyle(OmiColors.textSecondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(OmiColors.backgroundSecondary.opacity(0.82))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(OmiColors.border.opacity(0.18), lineWidth: 1)
        )
    }

    private func artifactRow(icon: String, tint: Color, title: String, subtitle: String) -> some View {
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
                    .foregroundStyle(OmiColors.textPrimary)

                Text(subtitle)
                    .scaledFont(size: 11)
                    .foregroundStyle(OmiColors.textTertiary)
            }

            Spacer(minLength: 0)
        }
        .padding(12)
        .background(OmiColors.backgroundSecondary.opacity(0.82))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(OmiColors.border.opacity(0.16), lineWidth: 1)
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
        case .file: return OmiColors.purplePrimary
        case .image: return OmiColors.success
        case .audio: return OmiColors.warning
        case .link: return OmiColors.textPrimary
        case .capture: return OmiColors.purplePrimary
        }
    }

    private func tint(for kind: LocalSessionCaptureArtifact.Kind) -> Color {
        switch kind {
        case .floatingBarCapture: return OmiColors.purplePrimary
        case .screenCapture: return OmiColors.success
        case .clipboardCapture: return OmiColors.warning
        case .note: return OmiColors.textPrimary
        }
    }

    private func recapTint(for kind: LocalSessionRecapSection.Kind) -> Color {
        switch kind {
        case .overview: return OmiColors.purplePrimary
        case .keyPoints: return OmiColors.success
        case .decisions: return OmiColors.warning
        case .actionItem: return OmiColors.error
        case .openQuestions: return OmiColors.textTertiary
        case .nextSteps: return OmiColors.success
        case .notes: return OmiColors.textPrimary
        }
    }

    private static func timeString(for interval: TimeInterval) -> String {
        let totalSeconds = max(0, Int(interval.rounded()))
        return String(format: "%02d:%02d", totalSeconds / 60, totalSeconds % 60)
    }
}

struct CepessaSessionsSettingsPage: View {
    @AppStorage("cepessa.sessions.keepAudio") private var keepAudio = true
    @AppStorage("cepessa.sessions.preferredTranscriptLanguage") private var transcriptLanguage = "Mixed"
    @AppStorage("cepessa.sessions.preferredRecapStyle") private var recapStyle = "Structured recap"
    @AppStorage("cepessa.sessions.floatingBarEnabled") private var floatingBarEnabled = true

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [OmiColors.backgroundPrimary, OmiColors.backgroundSecondary.opacity(0.96)],
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
                            .foregroundStyle(OmiColors.textTertiary)

                        Text("Workspace Settings")
                            .scaledFont(size: 30, weight: .semibold)
                            .foregroundStyle(OmiColors.textPrimary)

                        Text("Tune capture behavior, storage, and permissions for this Mac.")
                            .scaledFont(size: 13)
                            .foregroundStyle(OmiColors.textTertiary)
                    }

                    settingsCard(title: "Capture") {
                        VStack(spacing: 14) {
                            pickerRow(title: "Transcript language", value: $transcriptLanguage, options: ["Mixed", "Hebrew-first", "English-first"])
                            pickerRow(title: "Recap style", value: $recapStyle, options: ["Structured recap", "Concise recap", "Action items only"])

                            Text("Keep everything local by default. Cepessa can preserve raw audio, build a structured recap after each session, and keep the floating capture bar visible while you work.")
                                .scaledFont(size: 12)
                                .foregroundStyle(OmiColors.textTertiary)
                                .frame(maxWidth: .infinity, alignment: .leading)

                            Toggle(isOn: $keepAudio) {
                                Text("Keep raw audio after processing")
                                    .scaledFont(size: 13)
                                    .foregroundStyle(OmiColors.textPrimary)
                            }
                            .toggleStyle(.switch)

                            Toggle(isOn: $floatingBarEnabled) {
                                Text("Show the floating capture bar during live sessions")
                                    .scaledFont(size: 13)
                                    .foregroundStyle(OmiColors.textPrimary)
                            }
                            .toggleStyle(.switch)
                        }
                    }

                    settingsCard(title: "Permissions") {
                        VStack(spacing: 12) {
                            permissionRow(title: "Microphone access", isGranted: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized)
                            permissionRow(title: "Screen capture access", isGranted: CGPreflightScreenCaptureAccess())

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
                                .foregroundStyle(OmiColors.textTertiary)

                            Text(storageRoot.path)
                                .scaledFont(size: 12)
                                .foregroundStyle(OmiColors.textSecondary)
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
        }
        .onChange(of: floatingBarEnabled) { _, _ in
            CepessaSessionFloatingBarController.shared.connect(model: CepessaSessionsStore.shared.model)
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
            baseDirectory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Cepessa", isDirectory: true)
        )
    }

    private func settingsCard<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .scaledFont(size: 18, weight: .semibold)
                .foregroundStyle(OmiColors.textPrimary)

            content()
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .omiPanel(
            fill: OmiColors.backgroundTertiary.opacity(0.42),
            radius: 24,
            stroke: OmiColors.border.opacity(0.24),
            shadowOpacity: 0.1,
            shadowRadius: 14,
            shadowY: 8
        )
    }

    private func pickerRow(title: String, value: Binding<String>, options: [String]) -> some View {
        HStack {
            Text(title)
                .scaledFont(size: 13)
                .foregroundStyle(OmiColors.textPrimary)

            Spacer(minLength: 20)

            Picker(title, selection: value) {
                ForEach(options, id: \.self) { option in
                    Text(option).tag(option)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 180)
        }
    }

    private func permissionRow(title: String, isGranted: Bool) -> some View {
        HStack {
            Label(title, systemImage: isGranted ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .scaledFont(size: 13, weight: .medium)
                .foregroundStyle(isGranted ? OmiColors.textPrimary : OmiColors.warning)

            Spacer(minLength: 0)

            Text(isGranted ? "Ready" : "Needs access")
                .scaledFont(size: 11, weight: .semibold)
                .foregroundStyle(isGranted ? OmiColors.backgroundPrimary : Color.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(isGranted ? OmiColors.success : OmiColors.warning)
                .clipShape(Capsule())
        }
    }

    private func settingsAction(title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .scaledFont(size: 12, weight: .semibold)
                .foregroundStyle(OmiColors.textPrimary)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(OmiColors.backgroundSecondary.opacity(0.84))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func openSystemSettings(anchor: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") else { return }
        NSWorkspace.shared.open(url)
    }
}

private extension LocalMeetingSessionStatus {
    var label: String {
        switch self {
        case .recording: return "Recording"
        case .transcribing: return "Processing"
        case .ready: return "Ready"
        case .failed: return "Needs attention"
        }
    }

    var badgeColor: Color {
        switch self {
        case .recording: return OmiColors.error
        case .transcribing: return OmiColors.purplePrimary
        case .ready: return OmiColors.success
        case .failed: return OmiColors.warning
        }
    }
}

private extension LocalSessionAttachment.Source {
    var displayName: String {
        switch self {
        case .manual: return "Manual"
        case .transcript: return "Transcript anchor"
        case .floatingBar: return "Floating bar"
        case .imported: return "Imported"
        }
    }
}

private extension LocalSessionRecapSection.Kind {
    var displayTitle: String {
        switch self {
        case .overview: return "Overview"
        case .keyPoints: return "Key points"
        case .decisions: return "Decisions"
        case .actionItem: return "Action items"
        case .openQuestions: return "Open questions"
        case .nextSteps: return "Next steps"
        case .notes: return "Notes"
        }
    }
}
