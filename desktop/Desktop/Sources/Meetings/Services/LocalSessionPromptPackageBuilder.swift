import Darwin
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

    let markdownData = Data(renderMarkdown(for: session).utf8)
    try writeIfChanged(markdownData, to: markdownURL)
    let data = try encoder.encode(packageManifest(for: session))
    try writeIfChanged(data, to: jsonURL)
  }

  private func writeIfChanged(_ data: Data, to url: URL) throws {
    var original = stat()
    if lstat(url.path, &original) == 0 {
      guard (original.st_mode & S_IFMT) == S_IFREG, original.st_nlink == 1 else {
        throw CocoaError(.fileReadInvalidFileName)
      }
      let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
      guard descriptor >= 0 else { throw CocoaError(.fileReadNoPermission) }
      let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
      defer { try? handle.close() }
      var opened = stat()
      guard fstat(descriptor, &opened) == 0, opened.st_dev == original.st_dev,
        opened.st_ino == original.st_ino, opened.st_nlink == 1,
        (opened.st_mode & S_IFMT) == S_IFREG
      else { throw CocoaError(.fileReadInvalidFileName) }
      if try handle.readToEnd() == data { return }
    } else if errno != ENOENT {
      throw CocoaError(.fileReadNoPermission)
    }
    try data.write(to: url, options: .atomic)
  }

  private func renderMarkdown(for session: LocalSession) -> String {
    let transcriptBlock =
      session.transcriptSegments.isEmpty
      ? "No transcript text is available yet."
      : session.transcriptTimelineItems.map { item in
        let segment = item.segment
        let time = transcriptTimeRange(for: segment, in: session)
        let contextLines = item.attachments.map { attachment in
          "  - Context: \(attachment.title) (\(attachment.fileName ?? attachment.urlString ?? "saved locally"))"
        }
        let contextBlock = contextLines.isEmpty ? "" : "\n" + contextLines.joined(separator: "\n")
        return "[\(time)] \(segment.speaker): \(segment.text)\(contextBlock)"
      }.joined(separator: "\n")

    let recapOverview =
      session.recap.overview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ? "No recap overview is available yet."
      : session.recap.overview

    let recapSections =
      session.recap.sections.isEmpty
      ? "No recap sections are available yet."
      : session.recap.sections.map { section in
        let bullets =
          section.bullets.isEmpty
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

      ## Transcript Evidence
      \(evidenceLines(for: session))

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
      transcriptNotice: LocalSessionReadingNotice.resolve(session),
      evidenceOrigin: session.transcriptionEvidence == nil
        ? "legacy-session-json" : "transcription-run-reference",
      transcriptionEvidence: session.transcriptionEvidence,
      latestTranscriptionAttempt: session.latestTranscriptionAttempt,
      processingError: session.processingError,
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
          note: attachment.note,
          transcriptSegmentID: attachment.transcriptSegmentID
        )
      },
      captureArtifacts: session.captureArtifacts,
      audioFiles: [
        packageFile(
          named: session.audioArtifacts.importedFileName, for: session,
          defaultURL: fileLayout.importedAudioURL(for: session.id)),
        packageFile(
          named: session.audioArtifacts.micFileName, for: session,
          defaultURL: fileLayout.micAudioURL(for: session.id)),
        packageFile(
          named: session.audioArtifacts.systemFileName, for: session,
          defaultURL: fileLayout.systemAudioURL(for: session.id)),
        packageFile(
          named: session.audioArtifacts.mixedFileName, for: session,
          defaultURL: fileLayout.mixedAudioURL(for: session.id)),
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
      (
        "Imported", session.audioArtifacts.importedFileName,
        fileLayout.importedAudioURL(for: session.id)
      ),
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

  private func evidenceLines(for session: LocalSession) -> String {
    let notice = LocalSessionReadingNotice.resolve(session)
    var lines = ["\(notice.title). \(notice.detail)"]
    if let evidence = session.transcriptionEvidence {
      lines += summaryLines(evidence)
    } else {
      lines.append("- Evidence origin: legacy-session-json; no transcription run is referenced.")
    }
    if let latest = session.latestTranscriptionAttempt {
      lines += ["", "### Latest transcription attempt"] + summaryLines(latest)
    }
    if let error = session.processingError, !error.isEmpty {
      lines.append("- Processing warning: \(error)")
    }
    lines.append(
      "Timing and speech coverage checks do not verify every recognized word. Use the source audio to review wording."
    )
    return lines.joined(separator: "\n")
  }

  private func summaryLines(_ summary: LocalSessionTranscriptionEvidenceSummary) -> [String] {
    let coverage =
      summary.speechCoverage.flatMap { value in
        value.isFinite ? String(format: "%.2f%%", value * 100) : nil
      } ?? "Unknown"
    return [
      "- Disposition: \(summary.disposition.rawValue)",
      "- Complete: \(summary.isComplete.map { $0 ? "Yes" : "No" } ?? "Unknown")",
      "- Detected speech coverage: \(coverage)",
      "- Verifiable timestamps: \(summary.hasVerifiableTimestamps.map { $0 ? "Yes" : "No" } ?? "Unknown")",
      "- Run: \(summary.runFileName) (revision \(summary.revision))",
      "- Content hash: \(summary.contentHash)",
    ] + summary.issues.map { "- Issue: \($0)" }
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
    let rationale =
      session.contentClassification?.rationale.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return rationale.isEmpty ? "Not available" : rationale
  }

  private func packageFile(named fileName: String?, for session: LocalSession, defaultURL: URL)
    -> LocalSessionPromptPackageManifest.PackageFile?
  {
    guard let fileName else { return nil }
    return .init(fileName: fileName, path: defaultURL.path)
  }

  private func timeString(from offset: TimeInterval) -> String {
    let totalSeconds = max(0, Int(offset.rounded()))
    let minutes = totalSeconds / 60
    let seconds = totalSeconds % 60
    return String(format: "%02d:%02d", minutes, seconds)
  }

  private func transcriptTimeRange(
    for segment: LocalSessionTranscriptSegment, in session: LocalSession
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
    let transcriptSegmentID: UUID?
  }

  struct PackageFile: Codable {
    let fileName: String
    let path: String
  }

  let sessionID: UUID
  let title: String
  let startedAt: Date
  let status: String
  let transcriptNotice: LocalSessionReadingNotice
  let evidenceOrigin: String
  let transcriptionEvidence: LocalSessionTranscriptionEvidenceSummary?
  let latestTranscriptionAttempt: LocalSessionTranscriptionEvidenceSummary?
  let processingError: String?
  let contentClassification: LocalSessionContentClassification?
  let transcriptText: String
  let transcriptSegments: [LocalSessionTranscriptSegment]
  let recap: LocalSessionRecap
  let attachments: [Attachment]
  let captureArtifacts: [LocalSessionCaptureArtifact]
  let audioFiles: [PackageFile]
}
