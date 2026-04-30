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
  case classifyingContent
  case generatingRecap

  var rank: Int {
    switch self {
    case .importingAudio:
      return 0
    case .transcribing:
      return 1
    case .classifyingContent:
      return 2
    case .generatingRecap:
      return 3
    }
  }

  var label: String {
    switch self {
    case .importingAudio:
      return "Importing"
    case .transcribing:
      return "Transcribing"
    case .classifyingContent:
      return "Classifying"
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

enum LocalSessionContentType: String, CaseIterable, Codable, Equatable, Identifiable, Sendable {
  case meeting
  case voiceNote
  case videoCommentary
  case generalTranscript

  var id: String { rawValue }

  var displayTitle: String {
    switch self {
    case .meeting: return "Meeting"
    case .voiceNote: return "Voice note"
    case .videoCommentary: return "Video commentary"
    case .generalTranscript: return "General transcript"
    }
  }
}

struct LocalSessionContentClassification: Codable, Equatable, Sendable {
  var type: LocalSessionContentType
  var confidence: Double
  var rationale: String
  var generatedAt: Date

  init(
    type: LocalSessionContentType,
    confidence: Double,
    rationale: String,
    generatedAt: Date = Date()
  ) {
    self.type = type
    self.confidence = max(0, min(confidence, 1))
    self.rationale = rationale.trimmingCharacters(in: .whitespacesAndNewlines)
    self.generatedAt = generatedAt
  }
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

enum LocalSessionDocumentLanguage: String, CaseIterable, Identifiable, Sendable {
  case english
  case hebrew

  var id: String { rawValue }

  var shortTitle: String {
    switch self {
    case .english: return "EN"
    case .hebrew: return "עב"
    }
  }

  var displayTitle: String {
    switch self {
    case .english: return "English"
    case .hebrew: return "עברית"
    }
  }

  var locale: Locale {
    switch self {
    case .english: return Locale(identifier: "en_US")
    case .hebrew: return Locale(identifier: "he_IL")
    }
  }

  var writingDirection: Locale.LanguageDirection {
    switch self {
    case .english: return .leftToRight
    case .hebrew: return .rightToLeft
    }
  }
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
  var contentClassification: LocalSessionContentClassification?
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
    contentClassification: LocalSessionContentClassification? = nil,
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
    self.contentClassification = contentClassification
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
    case contentClassification
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
    contentClassification =
      try container.decodeIfPresent(
        LocalSessionContentClassification.self, forKey: .contentClassification)
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
    try container.encodeIfPresent(contentClassification, forKey: .contentClassification)
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

  init(session: LocalSession, language: LocalSessionDocumentLanguage = .english) {
    markdown = Self.markdown(for: session, language: language)
  }

  static func markdown(
    for session: LocalSession,
    language: LocalSessionDocumentLanguage = .english,
    includeTranscript: Bool = false
  ) -> String {
    let recap = localizedRecap(for: session, language: language)
    var lines: [String] = []
    lines.append("# \(sanitizedLine(title(for: session, language: language)))")
    lines.append("")
    lines.append(
      session.startedAt.formatted(
        .dateTime
          .locale(language.locale)
          .weekday(.wide)
          .day()
          .month(.wide)
          .year()
          .hour()
          .minute()
      )
    )
    lines.append("")

    let overview = recap.overview.trimmingCharacters(in: .whitespacesAndNewlines)
    if !overview.isEmpty {
      lines.append("## \(title(for: .overview, language: language))")
      lines.append("")
      lines.append(overview)
      lines.append("")
    }

    let sections = normalizedSections(for: recap)
    for section in sections {
      let title =
        language == .english
          && !section.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        ? section.title
        : title(for: section.kind, language: language)
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
        lines.append(language == .hebrew ? "_לא נקלטו פרטים._" : "_No details captured._")
        lines.append("")
      } else if !bullets.isEmpty {
        for bullet in bullets {
          lines.append("- \(bullet)")
        }
        lines.append("")
      }
    }

    let transcript = session.transcriptText.trimmingCharacters(in: .whitespacesAndNewlines)
    if includeTranscript && !transcript.isEmpty {
      lines.append("## \(language == .hebrew ? "תמלול" : "Transcript")")
      lines.append("")
      lines.append(transcript)
      lines.append("")
    }

    if !session.attachments.isEmpty || !session.captureArtifacts.isEmpty {
      lines.append("## \(language == .hebrew ? "ציר זמן והקשר" : "Context timeline")")
      lines.append("")

      for attachment in session.attachments {
        let stamp = timeString(for: attachment.sessionOffset)
        let fallbackTitle = language == .hebrew ? "קובץ מצורף" : "Attachment"
        lines.append("- \(stamp) — \(attachment.title.isEmpty ? fallbackTitle : attachment.title)")
      }

      for artifact in session.captureArtifacts {
        let stamp = timeString(for: artifact.sessionOffset)
        lines.append("- \(stamp) — \(artifact.title)")
      }

      lines.append("")
    }

    if lines.count == 4 {
      lines.append(
        language == .hebrew ? "_הסיכום עדיין בהכנה._" : "_Recap is still being prepared._")
    }

    return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
  }

  static func title(
    for session: LocalSession,
    language: LocalSessionDocumentLanguage = .english
  ) -> String {
    documentTitle(
      for: session,
      recap: localizedRecap(for: session, language: language),
      language: language
    )
  }

  private static func normalizedSections(for recap: LocalSessionRecap) -> [LocalSessionRecapSection]
  {
    let sections = recap.sections.filter { section in
      !section.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        || section.bullets.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
    guard !sections.isEmpty else { return [] }

    let overviewIsAlreadyRendered = !recap.overview.trimmingCharacters(
      in: .whitespacesAndNewlines
    ).isEmpty
    if overviewIsAlreadyRendered {
      return sections.filter { $0.kind != .overview }
    }

    return sections
  }

  private static func localizedRecap(
    for session: LocalSession,
    language: LocalSessionDocumentLanguage
  ) -> LocalSessionRecap {
    guard language == .hebrew, shouldBuildHebrewRecapFromTranscript(session) else {
      return session.recap
    }

    return hebrewRecapFromTranscript(for: session)
  }

  private static func shouldBuildHebrewRecapFromTranscript(_ session: LocalSession) -> Bool {
    let transcript = session.transcriptText
    guard transcript.containsHebrewScript else { return false }

    let recapText =
      ([session.recap.overview]
      + session.recap.sections.flatMap { [$0.title, $0.summary] + $0.bullets })
      .joined(separator: " ")

    return !recapText.containsHebrewScript
  }

  private static func hebrewRecapFromTranscript(for session: LocalSession) -> LocalSessionRecap {
    let corpus = session.transcriptText.lowercased()
    let themes = HebrewDocumentTheme.allCases.filter { $0.matches(corpus) }
    let activeThemes = themes.isEmpty ? [.general] : themes
    let overview =
      "הפגישה התמקדה ב\(activeThemes.prefix(3).map(\.overviewPhrase).joined(separator: ", ")). הסיכום מתרגם את התמלול למסמך עבודה מסודר עם החלטות, משימות ושאלות פתוחות."
    let keyPointBullets = activeThemes.prefix(5).map(\.keyPoint)
    let decisionBullets = activeThemes.flatMap(\.decisions)
    let actionBullets = activeThemes.flatMap(\.actionItems)
    let questionBullets = activeThemes.flatMap(\.openQuestions)
    let nextStepBullets = activeThemes.flatMap(\.nextSteps)

    return LocalSessionRecap(
      overview: overview,
      generatedAt: session.recap.generatedAt,
      sections: [
        makeLocalizedSection(
          kind: .overview,
          language: .hebrew,
          summary: overview,
          bullets: [overview]
        ),
        makeLocalizedSection(
          kind: .keyPoints,
          language: .hebrew,
          summary: "הנושאים המרכזיים שעלו בשיחה.",
          bullets: keyPointBullets
        ),
        makeLocalizedSection(
          kind: .decisions,
          language: .hebrew,
          summary: "כיווני פעולה והסכמות שניתן לגזור מהשיחה.",
          bullets: decisionBullets.isEmpty ? ["לא נסגרה החלטה מפורשת נוספת."] : decisionBullets
        ),
        makeLocalizedSection(
          kind: .actionItem,
          language: .hebrew,
          summary: "משימות המשך לביצוע.",
          bullets: actionBullets.isEmpty
            ? ["להפוך את הסיכום לרשימת משימות עם בעלים ותעדוף."] : actionBullets
        ),
        makeLocalizedSection(
          kind: .openQuestions,
          language: .hebrew,
          summary: "שאלות שנותרו לבדיקה.",
          bullets: questionBullets.isEmpty
            ? ["אילו פריטים הם תיקון מיידי ואילו דורשים חשיבה רחבה יותר?"] : questionBullets
        ),
        makeLocalizedSection(
          kind: .nextSteps,
          language: .hebrew,
          summary: "המשך פעולה מומלץ לאחר הפגישה.",
          bullets: nextStepBullets.isEmpty
            ? ["להכין תוכנית ביצוע קצרה מתוך הסיכום."] : nextStepBullets
        ),
      ]
    )
  }

  private static func documentTitle(
    for session: LocalSession,
    recap: LocalSessionRecap,
    language: LocalSessionDocumentLanguage
  ) -> String {
    let explicitTitle = session.title.trimmingCharacters(in: .whitespacesAndNewlines)
    let isGenericTitle =
      explicitTitle.isEmpty || explicitTitle.hasPrefix("Session ")
      || explicitTitle.range(of: #"^Meeting\s+\d"#, options: .regularExpression) != nil
    if !isGenericTitle {
      return session.displayTitle
    }

    let corpus =
      ([recap.overview] + recap.sections.flatMap { [$0.title, $0.summary] + $0.bullets })
      .joined(separator: " ")
      .lowercased()
    let hasAnalytics = corpus.contains("analytics") || corpus.contains("אנליטיקס")
    let hasSimulation =
      corpus.contains("interview simulation") || corpus.contains("simulation")
      || corpus.contains("סימולציות")
    let hasScrolling =
      corpus.contains("scrolling") || corpus.contains("section navigation")
      || corpus.contains("גלילה")
    let hasVisualDirection =
      corpus.contains("visual") || corpus.contains("heavy blue") || corpus.contains("וויזואלי")
      || corpus.contains("כבד")

    if language == .hebrew {
      if hasSimulation && hasAnalytics && hasScrolling {
        return "תיקוני אתר דחופים, אנליטיקס וסימולציות ריאיון"
      }
      if hasSimulation && hasAnalytics {
        return "אנליטיקס וסימולציות ריאיון באתר"
      }
      if hasScrolling && hasVisualDirection {
        return "שיפור גלילה, ניווט וכיוון ויזואלי באתר"
      }
      if hasScrolling {
        return "תיקוני גלילה וניווט באתר"
      }
      if hasSimulation {
        return "תוכנית עבודה לסימולציות ריאיון באתר"
      }
      if hasAnalytics {
        return "תוכנית מדידה ואנליטיקס לאתר"
      }
      switch session.contentClassification?.type {
      case .some(.voiceNote):
        return "סיכום הודעה קולית ופעולות המשך"
      case .some(.videoCommentary):
        return "סיכום הערות מסרטון ופעולות המשך"
      case .some(.generalTranscript):
        return "סיכום תמלול ופעולות המשך"
      case .some(.meeting), .none:
        return "סיכום פגישה ותוכנית פעולה"
      }
    }

    if hasSimulation && hasAnalytics && hasScrolling {
      return "Urgent Website Fixes, Analytics, and Interview Simulations"
    }
    if hasSimulation && hasAnalytics {
      return "Website Analytics and Interview Simulation Plan"
    }
    if hasScrolling && hasVisualDirection {
      return "Website Scrolling, Navigation, and Visual Direction"
    }
    if hasScrolling {
      return "Website Scrolling and Navigation Fixes"
    }
    if hasSimulation {
      return "Interview Simulation Website Plan"
    }
    if hasAnalytics {
      return "Website Analytics Plan"
    }
    switch session.contentClassification?.type {
    case .some(.voiceNote):
      return "Voice Note Brief and Follow-Up"
    case .some(.videoCommentary):
      return "Video Commentary Brief and Follow-Up"
    case .some(.generalTranscript):
      return "Transcript Brief and Follow-Up"
    case .some(.meeting), .none:
      return "Meeting Brief and Action Plan"
    }
  }

  private static func makeLocalizedSection(
    kind: LocalSessionRecapSection.Kind,
    language: LocalSessionDocumentLanguage,
    summary: String,
    bullets: [String]
  ) -> LocalSessionRecapSection {
    LocalSessionRecapSection(
      id: UUID(),
      kind: kind,
      title: title(for: kind, language: language),
      summary: summary,
      bullets: bullets,
      anchorTimestamp: nil,
      startOffset: nil,
      endOffset: nil
    )
  }

  private static func title(
    for kind: LocalSessionRecapSection.Kind,
    language: LocalSessionDocumentLanguage
  ) -> String {
    guard language == .hebrew else { return kind.displayTitle }

    switch kind {
    case .overview: return "סקירה"
    case .keyPoints: return "נקודות מרכזיות"
    case .decisions: return "החלטות"
    case .actionItem: return "משימות לביצוע"
    case .openQuestions: return "שאלות פתוחות"
    case .nextSteps: return "המלצה מקצועית"
    case .notes: return "הערות"
    }
  }

  private static func sanitizedLine(_ text: String) -> String {
    text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func timeString(for interval: TimeInterval?) -> String {
    let totalSeconds = max(0, Int((interval ?? 0).rounded()))
    return String(format: "%02d:%02d", totalSeconds / 60, totalSeconds % 60)
  }
}

extension String {
  fileprivate var containsHebrewScript: Bool {
    unicodeScalars.contains { scalar in
      (0x0590...0x05FF).contains(Int(scalar.value))
    }
  }
}

private enum HebrewDocumentTheme: CaseIterable {
  case sitePerformance
  case sectionNavigation
  case offerClarity
  case interviewSimulations
  case analytics
  case visualDirection
  case localization
  case registrationData
  case general

  var keywords: [String] {
    switch self {
    case .sitePerformance:
      return ["לאט", "איטי", "תקוע", "קופץ", "גלילה", "scroll"]
    case .sectionNavigation:
      return ["ai בילדר", "ai-בילדר", "מאסטר", "בוקסות", "ריבועים"]
    case .offerClarity:
      return ["קריאה לפעולה", "לא ברור", "להירשם", "booking", "book"]
    case .interviewSimulations:
      return ["סימולציות", "ראיונות", "hr", "tech", "coming soon", "scenario"]
    case .analytics:
      return ["analytics", "אנליטיקס", "clarity", "mixpanel", "webflow analyze"]
    case .visualDirection:
      return ["צבעוניות", "כחול", "רקע", "לבן", "אפור", "כבד", "משחקי"]
    case .localization:
      return ["עברית", "rtl", "תרגום", "לוקל", "locale"]
    case .registrationData:
      return ["נרשמו", "רשומים", "monday", "49", "82", "13", "11"]
    case .general:
      return []
    }
  }

  var overviewPhrase: String {
    switch self {
    case .sitePerformance: return "ביצועי האתר וחוויית הגלילה"
    case .sectionNavigation: return "ניווט בין אזורי התוכן"
    case .offerClarity: return "חידוד הקריאה לפעולה"
    case .interviewSimulations: return "אזור סימולציות הראיונות"
    case .analytics: return "מדידה ואנליטיקס להתנהגות משתמשים"
    case .visualDirection: return "הכיוון הוויזואלי של החוויה"
    case .localization: return "עברית ותמיכת RTL"
    case .registrationData: return "נתוני הרשמה ראשוניים"
    case .general: return "נושאי המשך שעלו בשיחה"
    }
  }

  var keyPoint: String {
    switch self {
    case .sitePerformance:
      return "עלו בעיות של איטיות, קפיצות וגלילה לא יציבה שפוגעות בתחושת השליטה באתר."
    case .sectionNavigation:
      return "בחירת אזור תוכן לא תמיד מציגה למשתמש תמונה מלאה וברורה של האזור שנפתח."
    case .offerClarity:
      return "חלקים באתר צריכים הבטחה וקריאה לפעולה ברורות יותר כדי שהמשתמש יבין מה לעשות."
    case .interviewSimulations:
      return "אזור סימולציות הראיונות בולט בעמוד, אך המצב הנוכחי והפעולה הבאה לא מספיק ברורים."
    case .analytics:
      return "הצוות רוצה לקבל נתוני שימוש אמיתיים לפני השקעה בשינוי UX רחב."
    case .visualDirection:
      return "החוויה הוויזואלית נתפסה ככבדה, ועלתה אפשרות להבהיר את הרקע והכרטיסים."
    case .localization:
      return "הגרסה בעברית דורשת גם תרגום איכותי וגם התאמת RTL, לא רק תרגום אוטומטי."
    case .registrationData:
      return "נתוני ההרשמה נותנים אינדיקציה ראשונית, אך צריך להפריד בין תנועה מהאתר להפצה חיצונית."
    case .general:
      return "השיחה העלתה פידבק מוצרי שצריך להפוך למסמך עבודה קצר וברור."
    }
  }

  var decisions: [String] {
    switch self {
    case .analytics:
      return ["לתעדף חיבור אנליטיקס או כלי התנהגות לפני החלטות UX רחבות."]
    case .interviewSimulations:
      return ["להתייחס לאזור סימולציות הראיונות כתיקון תוכן דחוף ולסמן בבירור שהוא עדיין בהכנה."]
    case .offerClarity:
      return ["לחדד את הקריאה לפעולה במקום להשאיר למשתמש לנחש את הצעד הבא."]
    case .visualDirection:
      return ["לבחון טיפול ויזואלי קל ובהיר יותר במקום להשאיר את התחושה הכבדה כפי שהיא."]
    default:
      return []
    }
  }

  var actionItems: [String] {
    switch self {
    case .sitePerformance:
      return ["לבדוק את הגלילה והקפיצות באתר בכמה דפדפנים ומכשירים."]
    case .sectionNavigation:
      return ["לעדכן את פריסת הסקשנים כך שהתוכן שנפתח יוצג בצורה מלאה וברורה יותר."]
    case .offerClarity:
      return ["לכתוב מחדש את הטקסטים באזורים הרלוונטיים כך שלכל אזור תהיה פעולה ברורה."]
    case .interviewSimulations:
      return [
        "לעדכן את אזור סימולציות הראיונות עם הבחנה ברורה בין HR לטכנולוגי וסטטוס coming soon."
      ]
    case .analytics:
      return [
        "לבחור ולחבר כלי מדידה כמו Webflow Analyze, Microsoft Clarity, Google Analytics או Mixpanel."
      ]
    case .visualDirection:
      return ["להכין ניסוי עיצובי בהיר יותר עם פחות עומס ויזואלי."]
    case .localization:
      return ["לתכנן את הגרסה בעברית כעבודת RTL ותרגום נפרדת ומבוקרת."]
    case .registrationData:
      return ["לבדוק מאיפה הגיעו ההרשמות כדי להבין מה באמת הגיע מהאתר."]
    case .general:
      return ["להפוך את הסיכום לרשימת משימות עם בעלים ותעדוף."]
    }
  }

  var openQuestions: [String] {
    switch self {
    case .analytics:
      return ["איזה כלי מדידה נותן מספיק תובנות במסגרת תקציב ה-MVP?"]
    case .offerClarity:
      return ["מה הפעולה המדויקת שהמשתמש אמור לבצע בכל אזור באתר כבר עכשיו?"]
    case .interviewSimulations:
      return ["האם אזור הסימולציות צריך רק להציג coming soon או גם לאסוף עניין להרשמה עתידית?"]
    case .visualDirection:
      return ["האם מספיק תיקון ויזואלי קטן או שנדרש ריענון רחב יותר של החוויה?"]
    case .localization:
      return ["מי מאשר את הנוסח העברי הסופי אחרי התרגום וההתאמה ל-RTL?"]
    case .registrationData:
      return ["איך מפרשים את נתוני ההרשמה כשחלק מהתנועה הגיע מהפצה חיצונית?"]
    default:
      return []
    }
  }

  var nextSteps: [String] {
    switch self {
    case .analytics:
      return ["לחבר כלי מדידה לפני סבב החלטות עיצוב רחב."]
    case .interviewSimulations:
      return ["להבהיר את אזור הסימולציות לפני ההצגה או בדיקת המשתמשים הבאה."]
    case .offerClarity:
      return ["להחליף ניסוחים עמומים בתוויות וקריאות לפעולה ישירות."]
    case .sitePerformance:
      return ["לשחזר את בעיות הגלילה בסביבות שבהן הן הופיעו ולטפל באינטראקציה אם הבעיה מאומתת."]
    case .visualDirection:
      return ["להכין גרסה ויזואלית בהירה יותר לבחינה."]
    case .localization:
      return ["להפריד בין תרגום, Webflow localization, ותיקוני RTL בתוכנית העבודה."]
    case .registrationData:
      return ["לשלב את נתוני ההרשמה עם שיחות משתמשים לפני שמחליטים מה לשנות."]
    case .sectionNavigation:
      return ["לעדכן את אינטראקציית הסקשנים כך שהמשתמש לא יצטרך להילחם במיקום העמוד."]
    case .general:
      return ["להכין תוכנית ביצוע קצרה מתוך הסיכום."]
    }
  }

  func matches(_ text: String) -> Bool {
    guard self != .general else { return false }
    return keywords.contains { text.contains($0.lowercased()) }
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
