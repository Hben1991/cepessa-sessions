import Foundation

struct LocalSessionPromptPackageBuilder {
    private let fileLayout: LocalSessionFileLayout
    private let fileManager: FileManager
    private let encoder: JSONEncoder

    init(fileLayout: LocalSessionFileLayout, fileManager: FileManager = .default) {
        self.fileLayout = fileLayout
        self.fileManager = fileManager

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder
    }

    func writePackage(for session: LocalSession) throws {
        try fileLayout.ensureDirectories(fileManager: fileManager, for: session.id)

        let markdownURL = fileLayout.promptPackageMarkdownURL(for: session.id)
        let jsonURL = fileLayout.promptPackageJSONURL(for: session.id)

        try renderMarkdown(for: session).write(to: markdownURL, atomically: true, encoding: .utf8)
        let data = try encoder.encode(packageManifest(for: session))
        try data.write(to: jsonURL, options: .atomic)
    }

    private func renderMarkdown(for session: LocalSession) -> String {
        let transcriptBlock = session.transcriptSegments.isEmpty
            ? "No transcript text is available yet."
            : session.transcriptSegments.map { segment in
                let time = segment.timestamp.formatted(date: .omitted, time: .standard)
                return "[\(time)] \(segment.speaker): \(segment.text)"
            }.joined(separator: "\n")

        let recapOverview = session.recap.overview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "No recap overview is available yet."
            : session.recap.overview

        let recapSections = session.recap.sections.isEmpty
            ? "No recap sections are available yet."
            : session.recap.sections.map { section in
                let bullets = section.bullets.isEmpty
                    ? "No bullets."
                    : section.bullets.map { "- \($0)" }.joined(separator: "\n")
                let timeAnchor = section.startOffset.map { "\nTime anchor: \(timeString(from: $0))" } ?? ""
                return """
                ## \(section.title)
                \(section.summary.isEmpty ? "No summary." : section.summary)\(timeAnchor)

                \(bullets)
                """
            }.joined(separator: "\n\n")

        let attachmentsBlock = attachmentLines(for: session)
        let audioBlock = audioLines(for: session)

        return """
        # \(session.displayTitle)

        Generated locally by Cepessa Sessions.

        - Session ID: \(session.id.uuidString)
        - Started at: \(session.startedAt.formatted(date: .complete, time: .standard))
        - Status: \(session.status.rawValue)
        - Content type: \(contentTypeLine(for: session))
        - Classification confidence: \(classificationConfidenceLine(for: session))
        - Classification rationale: \(classificationRationaleLine(for: session))

        ## Reusable AI Prompt
        Use the transcript, recap, attachments, and source audio references below as context for downstream AI work. Keep mixed Hebrew/English phrasing when it reflects the original session.

        ## Recap Overview
        \(recapOverview)

        ## Recap Sections
        \(recapSections)

        ## Transcript
        \(transcriptBlock)

        ## Attachments
        \(attachmentsBlock)

        ## Audio Files
        \(audioBlock)
        """
    }

    private func packageManifest(for session: LocalSession) -> LocalSessionPromptPackageManifest {
        LocalSessionPromptPackageManifest(
            sessionID: session.id,
            title: session.displayTitle,
            startedAt: session.startedAt,
            status: session.status.rawValue,
            contentClassification: session.contentClassification,
            transcriptText: session.transcriptText,
            transcriptSegments: session.transcriptSegments,
            recap: session.recap,
            attachments: session.attachments.map { attachment in
                LocalSessionPromptPackageManifest.Attachment(
                    id: attachment.id,
                    title: attachment.title,
                    kind: attachment.kind.rawValue,
                    source: attachment.source.rawValue,
                    timestamp: attachment.timestamp,
                    sessionOffset: attachment.sessionOffset,
                    fileName: attachment.fileName,
                    mimeType: attachment.mimeType,
                    urlString: attachment.urlString,
                    note: attachment.note
                )
            },
            captureArtifacts: session.captureArtifacts,
            audioFiles: [
                packageFile(named: session.audioArtifacts.micFileName, for: session, defaultURL: fileLayout.micAudioURL(for: session.id)),
                packageFile(named: session.audioArtifacts.systemFileName, for: session, defaultURL: fileLayout.systemAudioURL(for: session.id)),
                packageFile(named: session.audioArtifacts.mixedFileName, for: session, defaultURL: fileLayout.mixedAudioURL(for: session.id)),
            ].compactMap { $0 }
        )
    }

    private func attachmentLines(for session: LocalSession) -> String {
        if session.attachments.isEmpty {
            return "No attachments were captured for this session."
        }

        return session.attachments.map { attachment in
            let offset = attachment.sessionOffset.map(timeString(from:)) ?? "No time anchor"
            let path = attachment.urlString ?? "No stored path"
            return "- \(attachment.title) [\(attachment.kind.rawValue)] at \(offset)\n  Path: \(path)"
        }.joined(separator: "\n")
    }

    private func audioLines(for session: LocalSession) -> String {
        let audioFiles = [
            ("Mic", session.audioArtifacts.micFileName, fileLayout.micAudioURL(for: session.id)),
            ("System", session.audioArtifacts.systemFileName, fileLayout.systemAudioURL(for: session.id)),
            ("Mixed", session.audioArtifacts.mixedFileName, fileLayout.mixedAudioURL(for: session.id)),
        ]

        return audioFiles.map { label, fileName, url in
            if let fileName {
                return "- \(label): \(fileName)\n  Path: \(url.path)"
            }
            return "- \(label): Not retained"
        }.joined(separator: "\n")
    }

    private func contentTypeLine(for session: LocalSession) -> String {
        session.contentClassification?.type.displayTitle ?? "Unclassified"
    }

    private func classificationConfidenceLine(for session: LocalSession) -> String {
        guard let confidence = session.contentClassification?.confidence else {
            return "Not available"
        }

        return "\(Int((confidence * 100).rounded()))%"
    }

    private func classificationRationaleLine(for session: LocalSession) -> String {
        let rationale = session.contentClassification?.rationale.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return rationale.isEmpty ? "Not available" : rationale
    }

    private func packageFile(named fileName: String?, for session: LocalSession, defaultURL: URL) -> LocalSessionPromptPackageManifest.PackageFile? {
        guard let fileName else { return nil }
        return .init(fileName: fileName, path: defaultURL.path)
    }

    private func timeString(from offset: TimeInterval) -> String {
        let totalSeconds = max(0, Int(offset.rounded()))
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

private struct LocalSessionPromptPackageManifest: Codable {
    struct Attachment: Codable {
        let id: UUID
        let title: String
        let kind: String
        let source: String
        let timestamp: Date
        let sessionOffset: TimeInterval?
        let fileName: String?
        let mimeType: String?
        let urlString: String?
        let note: String?
    }

    struct PackageFile: Codable {
        let fileName: String
        let path: String
    }

    let sessionID: UUID
    let title: String
    let startedAt: Date
    let status: String
    let contentClassification: LocalSessionContentClassification?
    let transcriptText: String
    let transcriptSegments: [LocalSessionTranscriptSegment]
    let recap: LocalSessionRecap
    let attachments: [Attachment]
    let captureArtifacts: [LocalSessionCaptureArtifact]
    let audioFiles: [PackageFile]
}
