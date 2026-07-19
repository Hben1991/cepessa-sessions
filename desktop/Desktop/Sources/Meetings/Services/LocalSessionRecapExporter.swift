import AppKit
import CoreText
import Foundation

enum LocalSessionRecapExportFormat: String, CaseIterable, Sendable {
  case markdown
  case pdf

  var displayTitle: String {
    switch self {
    case .markdown: return "Markdown"
    case .pdf: return "PDF"
    }
  }

  var fileExtension: String {
    switch self {
    case .markdown: return "md"
    case .pdf: return "pdf"
    }
  }
}

enum LocalSessionRecapExportLanguageSelection: String, CaseIterable, Sendable {
  case english
  case hebrew
  case both

  var displayTitle: String {
    switch self {
    case .english: return "English"
    case .hebrew: return "Hebrew"
    case .both: return "English + Hebrew"
    }
  }

  var languages: [LocalSessionDocumentLanguage] {
    switch self {
    case .english: return [.english]
    case .hebrew: return [.hebrew]
    case .both: return [.english, .hebrew]
    }
  }
}

struct LocalSessionRecapExporter {
  func export(
    session: LocalSession,
    format: LocalSessionRecapExportFormat,
    languages: LocalSessionRecapExportLanguageSelection,
    to directory: URL,
    fileManager: FileManager = .default
  ) throws -> [URL] {
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

    return try languages.languages.map { language in
      let markdown = LocalSessionRecapMarkdownDocument.markdown(
        for: session,
        language: language,
        includeTranscript: false
      )
      let url =
        directory
        .appendingPathComponent(fileName(for: session, language: language, format: format))

      switch format {
      case .markdown:
        try markdown.write(to: url, atomically: true, encoding: .utf8)
      case .pdf:
        try pdfData(markdown: markdown, language: language).write(to: url, options: .atomic)
      }

      return url
    }
  }

  func exportTranscriptMarkdown(
    session: LocalSession,
    to directory: URL,
    fileManager: FileManager = .default
  ) throws -> URL {
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

    let title = LocalSessionRecapMarkdownDocument.title(for: session, language: .english)
    let baseName = sanitizedFileName("\(title) Transcript")
    let url = directory.appendingPathComponent(
      "\(baseName.isEmpty ? "session-transcript" : baseName).md")
    try transcriptMarkdown(for: session).write(to: url, atomically: true, encoding: .utf8)
    return url
  }

  private func fileName(
    for session: LocalSession,
    language: LocalSessionDocumentLanguage,
    format: LocalSessionRecapExportFormat
  ) -> String {
    let title = LocalSessionRecapMarkdownDocument.title(for: session, language: language)
    let baseName = sanitizedFileName(title).isEmpty ? "session-recap" : sanitizedFileName(title)
    return "\(baseName)-\(language.rawValue).\(format.fileExtension)"
  }

  private func sanitizedFileName(_ value: String) -> String {
    let invalid = CharacterSet(charactersIn: "/\\?%*|\"<>:")
      .union(.newlines)
      .union(.controlCharacters)
    let components = value.components(separatedBy: invalid)
    return
      components
      .joined(separator: "-")
      .replacingOccurrences(of: "  ", with: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func transcriptMarkdown(for session: LocalSession) -> String {
    var lines: [String] = []
    let title = LocalSessionRecapMarkdownDocument.title(for: session, language: .english)
    lines.append("# \(title) Transcript")
    lines.append("")
    lines.append(
      session.startedAt.formatted(
        .dateTime
          .weekday(.wide)
          .day()
          .month(.wide)
          .year()
          .hour()
          .minute()
      )
    )
    lines.append("")
    lines.append("## Transcript")
    lines.append("")

    let segments = session.transcriptSegments.filter {
      !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    if segments.isEmpty {
      lines.append("_No transcript text captured._")
    } else {
      for item in session.transcriptTimelineItems {
        let segment = item.segment
        let text = segment.text
          .replacingOccurrences(of: "\n", with: " ")
          .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { continue }

        let offset = max(0, segment.timestamp.timeIntervalSince(session.startedAt))
        let stamp = timeString(for: offset)
        let speaker = segment.speaker.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = speaker.isEmpty ? "Speaker" : speaker
        lines.append("- [\(stamp)] **\(label):** \(text)")

        for attachment in item.attachments {
          guard let imageLine = imageMarkdownLine(for: attachment) else { continue }
          lines.append("  - \(imageLine)")
        }
      }
    }

    return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func imageMarkdownLine(for attachment: LocalSessionAttachment) -> String? {
    guard attachment.kind == .image || attachment.kind == .capture else { return nil }
    guard let urlString = attachment.urlString, !urlString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      return nil
    }

    let fileURL = URL(fileURLWithPath: urlString)
    let title = attachment.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ? "Image"
      : attachment.title
    let stamp = attachment.sessionOffset.map(timeString(for:)) ?? "00:00"
    return "[\(stamp)] ![\(title)](\(fileURL.absoluteString))"
  }

  private func timeString(for offset: TimeInterval) -> String {
    let totalSeconds = max(0, Int(offset.rounded()))
    let hours = totalSeconds / 3_600
    let minutes = (totalSeconds % 3_600) / 60
    let seconds = totalSeconds % 60
    if hours > 0 {
      return String(format: "%d:%02d:%02d", hours, minutes, seconds)
    }
    return String(format: "%02d:%02d", minutes, seconds)
  }

  private func pdfData(markdown: String, language: LocalSessionDocumentLanguage) -> Data {
    let pageWidth: CGFloat = 612
    let pageHeight: CGFloat = 792
    let margin: CGFloat = 54
    let contentRect = CGRect(
      x: margin,
      y: margin,
      width: pageWidth - margin * 2,
      height: pageHeight - margin * 2
    )
    let data = NSMutableData()
    var mediaBox = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)
    guard let consumer = CGDataConsumer(data: data),
      let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)
    else {
      return Data()
    }

    let attributed = styledDocument(from: markdown, language: language)
    let framesetter = CTFramesetterCreateWithAttributedString(attributed)
    var range = CFRange(location: 0, length: 0)

    while range.location < attributed.length {
      context.beginPDFPage(nil)

      let path = CGMutablePath()
      path.addRect(contentRect)
      let frame = CTFramesetterCreateFrame(framesetter, range, path, nil)
      CTFrameDraw(frame, context)
      let visibleRange = CTFrameGetVisibleStringRange(frame)

      context.endPDFPage()

      guard visibleRange.length > 0 else { break }
      range.location += visibleRange.length
    }

    context.closePDF()
    return data as Data
  }

  private func styledDocument(
    from markdown: String,
    language: LocalSessionDocumentLanguage
  ) -> NSAttributedString {
    let output = NSMutableAttributedString()
    let lines = markdown.components(separatedBy: .newlines)

    for line in lines {
      let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

      if trimmed.hasPrefix("# ") {
        append(
          String(trimmed.dropFirst(2)),
          to: output,
          font: .systemFont(ofSize: 26, weight: .semibold),
          color: NSColor(calibratedRed: 0.09, green: 0.08, blue: 0.06, alpha: 1),
          spacingBefore: 0,
          spacingAfter: 12,
          language: language
        )
      } else if trimmed.hasPrefix("## ") {
        append(
          String(trimmed.dropFirst(3)),
          to: output,
          font: .systemFont(ofSize: 14.5, weight: .semibold),
          color: NSColor(calibratedRed: 0.17, green: 0.14, blue: 0.09, alpha: 1),
          spacingBefore: 15,
          spacingAfter: 6,
          language: language
        )
      } else if trimmed.hasPrefix("- ") {
        append(
          "• \(String(trimmed.dropFirst(2)))",
          to: output,
          font: .systemFont(ofSize: 11.2, weight: .regular),
          color: NSColor(calibratedRed: 0.22, green: 0.21, blue: 0.18, alpha: 1),
          spacingBefore: 2,
          spacingAfter: 4,
          firstLineHeadIndent: language == .hebrew ? 0 : 13,
          headIndent: language == .hebrew ? 0 : 13,
          tailIndent: language == .hebrew ? -13 : 0,
          language: language
        )
      } else if trimmed.isEmpty {
        appendSpacer(to: output, height: 3)
      } else {
        append(
          trimmed,
          to: output,
          font: .systemFont(ofSize: 11.4, weight: .regular),
          color: NSColor(calibratedRed: 0.25, green: 0.24, blue: 0.21, alpha: 1),
          spacingBefore: 0,
          spacingAfter: 6,
          language: language
        )
      }
    }

    return output
  }

  private func append(
    _ string: String,
    to output: NSMutableAttributedString,
    font: NSFont,
    color: NSColor,
    spacingBefore: CGFloat,
    spacingAfter: CGFloat,
    firstLineHeadIndent: CGFloat = 0,
    headIndent: CGFloat = 0,
    tailIndent: CGFloat = 0,
    language: LocalSessionDocumentLanguage
  ) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = language == .hebrew ? .right : .left
    paragraph.baseWritingDirection = language == .hebrew ? .rightToLeft : .leftToRight
    paragraph.lineSpacing = 2.4
    paragraph.paragraphSpacingBefore = spacingBefore
    paragraph.paragraphSpacing = spacingAfter
    paragraph.firstLineHeadIndent = firstLineHeadIndent
    paragraph.headIndent = headIndent
    paragraph.tailIndent = tailIndent

    output.append(
      NSAttributedString(
        string: "\(string)\n",
        attributes: [
          .font: font,
          .foregroundColor: color,
          .paragraphStyle: paragraph,
        ]
      )
    )
  }

  private func appendSpacer(to output: NSMutableAttributedString, height: CGFloat) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.minimumLineHeight = height
    paragraph.maximumLineHeight = height
    output.append(
      NSAttributedString(
        string: "\n",
        attributes: [
          .font: NSFont.systemFont(ofSize: 1),
          .paragraphStyle: paragraph,
        ]
      )
    )
  }
}
