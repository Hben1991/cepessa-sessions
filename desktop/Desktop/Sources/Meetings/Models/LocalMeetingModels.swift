import Foundation

enum LocalSessionStatus: String, Codable, Equatable, Sendable {
  case recording
  case transcribing
  case ready
  case failed
}

enum LocalSessionProcessingPhase: String, Codable, Equatable, Sendable {
  case importingAudio
  case transcribing
  case generatingRecap

  var rank: Int {
    switch self {
    case .importingAudio:
      return 0
    case .transcribing:
      return 1
    case .generatingRecap:
      return 2
    }
  }

  var label: String {
    switch self {
    case .importingAudio:
      return "Importing"
    case .transcribing:
      return "Transcribing"
    case .generatingRecap:
      return "Recap"
    }
  }
}

struct LocalSessionProcessingSnapshot: Identifiable, Equatable, Sendable {
  let id: UUID
  var phase: LocalSessionProcessingPhase
  var title: String
  var detail: String
  var progress: Double?
  var logEntries: [LocalSessionProcessingLogEntry]
  var updatedAt: Date

  init(
    id: UUID,
    phase: LocalSessionProcessingPhase,
    title: String,
    detail: String,
    progress: Double?,
    logEntries: [LocalSessionProcessingLogEntry] = [],
    updatedAt: Date = Date()
  ) {
    self.id = id
    self.phase = phase
    self.title = title
    self.detail = detail
    self.progress = progress.map { max(0, min($0, 1)) }
    self.logEntries = logEntries
    self.updatedAt = updatedAt
  }

  var progressLabel: String? {
    guard let progress else { return nil }
    return "\(Int((progress * 100).rounded()))%"
  }

  var isIndeterminate: Bool {
    progress == nil
  }
}

struct LocalSessionProcessingLogEntry: Identifiable, Equatable, Sendable {
  let id: UUID
  var timestamp: Date
  var message: String

  init(id: UUID = UUID(), timestamp: Date = Date(), message: String) {
    self.id = id
    self.timestamp = timestamp
    self.message = message
  }
}

struct LocalSessionAudioArtifacts: Codable, Equatable, Sendable {
  var micFileName: String?
  var systemFileName: String?
  var mixedFileName: String?

  static let empty = LocalSessionAudioArtifacts(
    micFileName: nil,
    systemFileName: nil,
    mixedFileName: nil
  )
}

struct LocalSessionTranscriptSegment: Identifiable, Codable, Equatable, Sendable {
  let id: UUID
  var speaker: String
  var text: String
  var timestamp: Date
}

struct LocalSessionRecapSection: Identifiable, Codable, Equatable, Sendable {
  enum Kind: String, Codable, Equatable, Sendable {
    case overview
    case keyPoints
    case decisions
    case actionItem
    case openQuestions
    case nextSteps
    case notes

    init(from decoder: Decoder) throws {
      let container = try decoder.singleValueContainer()
      let rawValue = try container.decode(String.self)

      switch rawValue {
      case "summary":
        self = .overview
      case "highlight":
        self = .keyPoints
      case "decision":
        self = .decisions
      case "actionItem":
        self = .actionItem
      case "nextStep":
        self = .nextSteps
      case "note":
        self = .notes
      default:
        self = Kind(rawValue: rawValue) ?? .notes
      }
    }

    func encode(to encoder: Encoder) throws {
      var container = encoder.singleValueContainer()
      try container.encode(rawValue)
    }
  }

  let id: UUID
  var kind: Kind
  var title: String
  var summary: String
  var bullets: [String]
  var anchorTimestamp: Date?
  var startOffset: TimeInterval?
  var endOffset: TimeInterval?
}

struct LocalSessionRecap: Codable, Equatable, Sendable {
  var overview: String
  var generatedAt: Date?
  var sections: [LocalSessionRecapSection]

  static let empty = LocalSessionRecap(
    overview: "",
    generatedAt: nil,
    sections: []
  )
}

enum LocalSessionDocumentChatRole: String, Codable, Equatable, Sendable {
  case user
  case assistant
}

enum LocalSessionDocumentChatStatus: String, Codable, Equatable, Sendable {
  case idle
  case sending
  case failed
}

struct LocalSessionDocumentChatMessage: Identifiable, Codable, Equatable, Sendable {
  let id: UUID
  var role: LocalSessionDocumentChatRole
  var text: String
  var createdAt: Date
}

struct LocalSessionDocumentRecapPatch: Codable, Equatable, Sendable {
  struct SectionReplacement: Codable, Equatable, Sendable {
    var kind: LocalSessionRecapSection.Kind
    var title: String
    var summary: String
    var bullets: [String]
  }

  var overview: String?
  var sections: [SectionReplacement]
}

struct LocalSessionDocumentTranscriptPatch: Codable, Equatable, Sendable {
  var segmentID: UUID
  var text: String
}

struct LocalSessionDocumentSpeakerRename: Codable, Equatable, Sendable {
  var oldName: String
  var newName: String
}

struct LocalSessionDocumentEditProposal: Codable, Equatable, Sendable {
  var assistantMessage: String
  var recapPatch: LocalSessionDocumentRecapPatch?
  var transcriptPatches: [LocalSessionDocumentTranscriptPatch]
  var speakerRenames: [LocalSessionDocumentSpeakerRename]
  var warnings: [String]

  var hasEdits: Bool {
    recapPatch != nil || !transcriptPatches.isEmpty || !speakerRenames.isEmpty
  }
}

struct LocalSessionDocumentChat: Codable, Equatable, Sendable {
  var messages: [LocalSessionDocumentChatMessage]
  var pendingProposal: LocalSessionDocumentEditProposal?
  var status: LocalSessionDocumentChatStatus
  var errorMessage: String?
  var createdAt: Date?
  var updatedAt: Date?

  static let empty = LocalSessionDocumentChat(
    messages: [],
    pendingProposal: nil,
    status: .idle,
    errorMessage: nil,
    createdAt: nil,
    updatedAt: nil
  )
}

extension LocalSessionRecapSection.Kind {
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

struct LocalSessionAttachment: Identifiable, Codable, Equatable, Sendable {
  enum Kind: String, Codable, Equatable, Sendable {
    case file
    case image
    case audio
    case link
    case capture
  }

  enum Source: String, Codable, Equatable, Sendable {
    case manual
    case transcript
    case floatingBar
    case imported
  }

  let id: UUID
  var kind: Kind
  var source: Source
  var title: String
  var timestamp: Date
  var sessionOffset: TimeInterval?
  var fileName: String?
  var mimeType: String?
  var urlString: String?
  var note: String?
}

struct LocalSessionCaptureArtifact: Identifiable, Codable, Equatable, Sendable {
  enum Kind: String, Codable, Equatable, Sendable {
    case floatingBarCapture
    case screenCapture
    case clipboardCapture
    case note
  }

  let id: UUID
  var kind: Kind
  var title: String
  var capturedAt: Date
  var sessionOffset: TimeInterval?
  var attachmentIDs: [UUID]
  var notes: String?
}

struct LocalSession: Identifiable, Codable, Equatable, Sendable {
  let id: UUID
  var title: String
  var startedAt: Date
  var status: LocalSessionStatus
  var transcriptSegments: [LocalSessionTranscriptSegment]
  var recap: LocalSessionRecap
  var attachments: [LocalSessionAttachment]
  var captureArtifacts: [LocalSessionCaptureArtifact]
  var audioArtifacts: LocalSessionAudioArtifacts
  var documentChat: LocalSessionDocumentChat

  var segments: [LocalSessionTranscriptSegment] {
    get { transcriptSegments }
    set { transcriptSegments = newValue }
  }

  var transcriptText: String {
    transcriptSegments.map(\.text).joined(separator: "\n")
  }

  init(
    id: UUID,
    title: String,
    startedAt: Date,
    status: LocalSessionStatus,
    transcriptSegments: [LocalSessionTranscriptSegment],
    recap: LocalSessionRecap = .empty,
    attachments: [LocalSessionAttachment] = [],
    captureArtifacts: [LocalSessionCaptureArtifact] = [],
    audioArtifacts: LocalSessionAudioArtifacts,
    documentChat: LocalSessionDocumentChat = .empty
  ) {
    self.id = id
    self.title = title
    self.startedAt = startedAt
    self.status = status
    self.transcriptSegments = transcriptSegments
    self.recap = recap
    self.attachments = attachments
    self.captureArtifacts = captureArtifacts
    self.audioArtifacts = audioArtifacts
    self.documentChat = documentChat
  }

  enum CodingKeys: String, CodingKey {
    case id
    case title
    case startedAt
    case status
    case transcriptSegments
    case segments
    case recap
    case attachments
    case captureArtifacts
    case audioArtifacts
    case documentChat
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UUID.self, forKey: .id)
    title = try container.decode(String.self, forKey: .title)
    startedAt = try container.decode(Date.self, forKey: .startedAt)
    status = try container.decode(LocalSessionStatus.self, forKey: .status)
    transcriptSegments =
      try container.decodeIfPresent(
        [LocalSessionTranscriptSegment].self, forKey: .transcriptSegments)
      ?? container.decodeIfPresent([LocalSessionTranscriptSegment].self, forKey: .segments)
      ?? []
    recap = try container.decodeIfPresent(LocalSessionRecap.self, forKey: .recap) ?? .empty
    attachments =
      try container.decodeIfPresent([LocalSessionAttachment].self, forKey: .attachments) ?? []
    captureArtifacts =
      try container.decodeIfPresent([LocalSessionCaptureArtifact].self, forKey: .captureArtifacts)
      ?? []
    audioArtifacts =
      try container.decodeIfPresent(LocalSessionAudioArtifacts.self, forKey: .audioArtifacts)
      ?? .empty
    documentChat =
      try container.decodeIfPresent(LocalSessionDocumentChat.self, forKey: .documentChat)
      ?? .empty
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(title, forKey: .title)
    try container.encode(startedAt, forKey: .startedAt)
    try container.encode(status, forKey: .status)
    try container.encode(transcriptSegments, forKey: .transcriptSegments)
    try container.encode(transcriptSegments, forKey: .segments)
    try container.encode(recap, forKey: .recap)
    try container.encode(attachments, forKey: .attachments)
    try container.encode(captureArtifacts, forKey: .captureArtifacts)
    try container.encode(audioArtifacts, forKey: .audioArtifacts)
    try container.encode(documentChat, forKey: .documentChat)
  }

  static let sampleSessions: [LocalSession] = [
    LocalSession(
      id: UUID(uuidString: "2E5AE0E5-8B3B-4C2E-9FAF-3C7E7A0C8A11")!,
      title: "Weekly sync",
      startedAt: Date(timeIntervalSince1970: 1_742_680_200),
      status: .ready,
      transcriptSegments: [
        LocalSessionTranscriptSegment(
          id: UUID(uuidString: "9BC64E75-9BC2-4386-862A-8A2D7F8D9D51")!,
          speaker: "Maya",
          text: "Let's keep this focused on blockers and next steps.",
          timestamp: Date(timeIntervalSince1970: 1_742_680_260)
        ),
        LocalSessionTranscriptSegment(
          id: UUID(uuidString: "D4AAE4FB-2E22-4E82-88B4-1A4B10B13F5E")!,
          speaker: "Noam",
          text: "I can own the follow-up and send a summary today.",
          timestamp: Date(timeIntervalSince1970: 1_742_680_320)
        ),
      ],
      recap: LocalSessionRecap(
        overview: "Aligned on blockers and next steps.",
        generatedAt: Date(timeIntervalSince1970: 1_742_680_400),
        sections: [
          LocalSessionRecapSection(
            id: UUID(uuidString: "15C4B3D2-0C68-4D81-8AC8-87B7B0D7D1A0")!,
            kind: .keyPoints,
            title: "Highlights",
            summary: "The team narrowed the discussion to delivery risk and owner clarity.",
            bullets: [
              "Confirmed the launch blocker.",
              "Assigned follow-up ownership.",
            ],
            anchorTimestamp: Date(timeIntervalSince1970: 1_742_680_260),
            startOffset: 60,
            endOffset: 180
          )
        ]
      ),
      attachments: [
        LocalSessionAttachment(
          id: UUID(uuidString: "2D8D174A-9020-4E07-BF0A-ACF3B3A0A2B7")!,
          kind: .file,
          source: .manual,
          title: "Project brief",
          timestamp: Date(timeIntervalSince1970: 1_742_680_290),
          sessionOffset: 90,
          fileName: "project-brief.pdf",
          mimeType: "application/pdf",
          urlString: nil,
          note: "Placeholder attachment for recap context."
        )
      ],
      captureArtifacts: [
        LocalSessionCaptureArtifact(
          id: UUID(uuidString: "9C3A4D07-2D29-4C23-9E53-34C31CF0DF59")!,
          kind: .floatingBarCapture,
          title: "Floating bar capture placeholder",
          capturedAt: Date(timeIntervalSince1970: 1_742_680_330),
          sessionOffset: 130,
          attachmentIDs: [],
          notes: "Reserved for future floating-bar capture flow."
        )
      ],
      audioArtifacts: .empty
    ),
    LocalSession(
      id: UUID(uuidString: "D9280F3A-4D57-4C18-80D2-2B5DB2C0D4D2")!,
      title: "Product review",
      startedAt: Date(timeIntervalSince1970: 1_742_594_400),
      status: .ready,
      transcriptSegments: [
        LocalSessionTranscriptSegment(
          id: UUID(uuidString: "B3F9B4AD-9E5E-48A2-97F7-1E5A1F80E3FD")!,
          speaker: "Dana",
          text: "The local recorder should stay simple and dependable.",
          timestamp: Date(timeIntervalSince1970: 1_742_594_460)
        )
      ],
      recap: LocalSessionRecap(
        overview: "Validated the recorder direction.",
        generatedAt: Date(timeIntervalSince1970: 1_742_594_500),
        sections: []
      ),
      attachments: [],
      captureArtifacts: [],
      audioArtifacts: .empty
    ),
  ]
}

typealias LocalMeetingSessionStatus = LocalSessionStatus
typealias LocalMeetingAudioArtifacts = LocalSessionAudioArtifacts
typealias LocalMeetingTranscriptSegment = LocalSessionTranscriptSegment
typealias LocalMeetingRecapSection = LocalSessionRecapSection
typealias LocalMeetingRecap = LocalSessionRecap
typealias LocalMeetingAttachment = LocalSessionAttachment
typealias LocalMeetingCaptureArtifact = LocalSessionCaptureArtifact
typealias LocalMeetingSession = LocalSession

extension LocalSessionRecap {
  func section(kind: LocalSessionRecapSection.Kind) -> LocalSessionRecapSection? {
    sections.first { $0.kind == kind }
  }

  mutating func upsertSection(_ section: LocalSessionRecapSection) {
    if let index = sections.firstIndex(where: { $0.kind == section.kind }) {
      sections[index] = section
    } else {
      sections.append(section)
    }
  }
}

struct LocalSessionRecapMarkdownDocument: Equatable, Sendable {
  let markdown: String

  init(session: LocalSession) {
    markdown = Self.markdown(for: session)
  }

  static func markdown(for session: LocalSession) -> String {
    var lines: [String] = []
    lines.append("# \(sanitizedLine(session.displayTitle))")
    lines.append("")
    lines.append(session.startedAt.formatted(date: .complete, time: .shortened))
    lines.append("")

    let overview = session.recap.overview.trimmingCharacters(in: .whitespacesAndNewlines)
    if !overview.isEmpty {
      lines.append("## Overview")
      lines.append("")
      lines.append(overview)
      lines.append("")
    }

    let sections = normalizedSections(for: session)
    for section in sections {
      let title =
        section.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        ? section.kind.displayTitle
        : section.title
      lines.append("## \(sanitizedLine(title))")
      lines.append("")

      let summary = section.summary.trimmingCharacters(in: .whitespacesAndNewlines)
      if !summary.isEmpty {
        lines.append(summary)
        lines.append("")
      }

      let bullets = section.bullets
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
      if bullets.isEmpty && summary.isEmpty {
        lines.append("_No details captured._")
        lines.append("")
      } else if !bullets.isEmpty {
        for bullet in bullets {
          lines.append("- \(bullet)")
        }
        lines.append("")
      }
    }

    let transcript = session.transcriptText.trimmingCharacters(in: .whitespacesAndNewlines)
    if !transcript.isEmpty {
      lines.append("## Transcript")
      lines.append("")
      lines.append(transcript)
      lines.append("")
    }

    if !session.attachments.isEmpty || !session.captureArtifacts.isEmpty {
      lines.append("## Context timeline")
      lines.append("")

      for attachment in session.attachments {
        let stamp = timeString(for: attachment.sessionOffset)
        lines.append("- \(stamp) — \(attachment.title.isEmpty ? "Attachment" : attachment.title)")
      }

      for artifact in session.captureArtifacts {
        let stamp = timeString(for: artifact.sessionOffset)
        lines.append("- \(stamp) — \(artifact.title)")
      }

      lines.append("")
    }

    if lines.count == 4 {
      lines.append("_Recap is still being prepared._")
    }

    return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func normalizedSections(for session: LocalSession) -> [LocalSessionRecapSection] {
    let sections = session.recap.sections.filter { section in
      !section.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        || section.bullets.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
    guard !sections.isEmpty else { return [] }

    let overviewIsAlreadyRendered = !session.recap.overview.trimmingCharacters(
      in: .whitespacesAndNewlines
    ).isEmpty
    if overviewIsAlreadyRendered {
      return sections.filter { $0.kind != .overview }
    }

    return sections
  }

  private static func sanitizedLine(_ text: String) -> String {
    text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func timeString(for interval: TimeInterval?) -> String {
    let totalSeconds = max(0, Int((interval ?? 0).rounded()))
    return String(format: "%02d:%02d", totalSeconds / 60, totalSeconds % 60)
  }
}

extension LocalSession {
  var displayTitle: String {
    guard title.hasPrefix("Meeting ") else { return title }
    return "Session " + title.dropFirst("Meeting ".count)
  }

  mutating func addAttachment(_ attachment: LocalSessionAttachment) {
    attachments.append(attachment)
  }

  mutating func addScreenshotAttachment(
    title: String,
    timestamp: Date,
    sessionOffset: TimeInterval? = nil,
    fileName: String? = nil,
    mimeType: String = "image/png",
    urlString: String? = nil,
    note: String? = nil
  ) -> LocalSessionAttachment {
    let attachment = LocalSessionAttachment(
      id: UUID(),
      kind: .image,
      source: .manual,
      title: title,
      timestamp: timestamp,
      sessionOffset: sessionOffset,
      fileName: fileName,
      mimeType: mimeType,
      urlString: urlString,
      note: note
    )
    addAttachment(attachment)
    return attachment
  }

  mutating func addDocumentAttachment(
    title: String,
    timestamp: Date,
    sessionOffset: TimeInterval? = nil,
    fileName: String? = nil,
    mimeType: String = "application/pdf",
    urlString: String? = nil,
    note: String? = nil
  ) -> LocalSessionAttachment {
    let attachment = LocalSessionAttachment(
      id: UUID(),
      kind: .file,
      source: .manual,
      title: title,
      timestamp: timestamp,
      sessionOffset: sessionOffset,
      fileName: fileName,
      mimeType: mimeType,
      urlString: urlString,
      note: note
    )
    addAttachment(attachment)
    return attachment
  }

  mutating func addCaptureArtifact(
    title: String,
    capturedAt: Date,
    sessionOffset: TimeInterval? = nil,
    attachmentIDs: [UUID] = [],
    notes: String? = nil
  ) -> LocalSessionCaptureArtifact {
    let capture = LocalSessionCaptureArtifact(
      id: UUID(),
      kind: .floatingBarCapture,
      title: title,
      capturedAt: capturedAt,
      sessionOffset: sessionOffset,
      attachmentIDs: attachmentIDs,
      notes: notes
    )
    captureArtifacts.append(capture)
    return capture
  }

  mutating func setRecapSection(_ section: LocalSessionRecapSection) {
    recap.upsertSection(section)
  }
}
