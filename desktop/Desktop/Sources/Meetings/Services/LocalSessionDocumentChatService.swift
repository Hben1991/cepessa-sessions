import Foundation

struct LocalSessionDocumentChatRequest: Sendable {
  let session: LocalSession
  let userMessage: String
}

protocol LocalSessionDocumentChatProviding: Sendable {
  func sendMessage(_ request: LocalSessionDocumentChatRequest) async throws
    -> LocalSessionDocumentEditProposal
}

struct LocalSessionDocumentChatClient: LocalSessionDocumentChatProviding, Sendable {
  let languageModel: any LocalSessionLanguageModelGenerating
  var maxTokens: Int = 900

  init(
    languageModel: any LocalSessionLanguageModelGenerating = EmbeddedLocalLanguageModel.shared,
    maxTokens: Int = 900
  ) {
    self.languageModel = languageModel
    self.maxTokens = maxTokens
  }

  func sendMessage(_ request: LocalSessionDocumentChatRequest) async throws
    -> LocalSessionDocumentEditProposal
  {
    do {
      let rawResponse = try await languageModel.generateText(
        prompt: Self.prompt(for: request),
        maxTokens: maxTokens
      )
      let proposal = Self.decodeProposal(from: rawResponse)
      let isDocumentEditRequest = Self.requestLooksLikeDocumentEdit(request.userMessage)
      if proposal.hasEdits || !isDocumentEditRequest {
        return proposal
      }

      return Self.fallbackProposal(for: request)
    } catch {
      return Self.fallbackProposal(for: request, failureMessage: error.localizedDescription)
    }
  }

  private static func prompt(for request: LocalSessionDocumentChatRequest) -> String {
    let session = request.session
    let markdown = conciseMarkdownContext(for: session)
    let transcript = transcriptContext(for: session)

    let chatHistory = session.documentChat.messages.suffix(12).map { message in
      "\(message.role.rawValue): \(message.text)"
    }
    .joined(separator: "\n")

    return """
      You are a local document editor for a Markdown recap generated from structured session data.

      Return only valid JSON. No markdown fences. No commentary outside JSON.
      The JSON object must match this exact contract:
      {
        "assistantMessage": "plain English explanation for the user",
        "recapPatch": {
          "overview": "optional replacement overview or null",
          "sections": [
            {"kind":"keyPoints|decisions|actionItem|openQuestions|nextSteps|notes|overview","title":"...","summary":"...","bullets":["..."]}
          ]
        },
        "transcriptPatches": [
          {"segmentID":"UUID from transcript below","text":"corrected segment text"}
        ],
        "speakerRenames": [
          {"oldName":"existing speaker/name","newName":"replacement speaker/name"}
        ],
        "warnings": ["risk, ambiguity, or reason no edit was proposed"]
      }

      Rules:
      - Return document edits whenever the user asks to change, clean up, rewrite, summarize into sections, turn into action items, rename speakers, or fix transcript text.
      - If the user asks in Hebrew or asks to translate to Hebrew, write assistantMessage and recapPatch content in Hebrew.
      - The structured session is the source of truth, not the rendered Markdown.
      - You may replace recap overview and recap sections.
      - You may rename speakers/participants across transcript segments.
      - You may correct transcript text only with targeted transcriptPatches by segmentID.
      - Do not rewrite the whole transcript. If asked for broad transcript rewriting, warn and propose only explicit point corrections.
      - For "turn this into action items", return a recapPatch with an actionItem section containing concise bullets.
      - Section kind must be one exact value: keyPoints, decisions, actionItem, openQuestions, nextSteps, notes, or overview.
      - Never return the schema example text as a value.
      - Use empty arrays and null recapPatch only for pure question-answer requests that should not alter the document.
      - assistantMessage must be a short human summary of what changed or why no edit was made.
      - Never put segment IDs, offsets, the transcript excerpt, or raw JSON in assistantMessage.

      Session title: \(session.title)
      Started at: \(session.startedAt.formatted(date: .complete, time: .complete))

      Markdown preview excerpt:
      \(markdown)

      Transcript excerpt with stable segment IDs:
      \(transcript)

      Recent chat:
      \(chatHistory)

      User request:
      \(request.userMessage)

      Final instruction: Return only valid JSON matching the contract above. No markdown fences. No commentary.
      """
  }

  private static func conciseMarkdownContext(for session: LocalSession) -> String {
    let recapOnlySession = LocalSession(
      id: session.id,
      title: session.title,
      startedAt: session.startedAt,
      status: session.status,
      transcriptSegments: [],
      recap: session.recap,
      attachments: session.attachments,
      captureArtifacts: session.captureArtifacts,
      audioArtifacts: session.audioArtifacts,
      documentChat: session.documentChat
    )
    return truncatedText(
      LocalSessionRecapMarkdownDocument(session: recapOnlySession).markdown,
      limit: 8_000
    )
  }

  private static func transcriptContext(for session: LocalSession) -> String {
    let segments = session.transcriptSegments
    let maxHeadSegments = 50
    let maxTailSegments = 25
    let maxSegmentTextCharacters = 180
    let selectedSegments: [LocalSessionTranscriptSegment]
    if segments.count > maxHeadSegments + maxTailSegments {
      selectedSegments =
        Array(segments.prefix(maxHeadSegments)) + Array(segments.suffix(maxTailSegments))
    } else {
      selectedSegments = segments
    }

    let lines = selectedSegments.map { segment in
      let offset = max(0, segment.timestamp.timeIntervalSince(session.startedAt))
      let text = truncatedText(segment.text, limit: maxSegmentTextCharacters)
      return
        "[segmentID=\(segment.id.uuidString) offset=\(String(format: "%.1f", offset))s speaker=\(segment.speaker)] \(text)"
    }

    guard segments.count > selectedSegments.count else {
      return lines.joined(separator: "\n")
    }

    let omittedCount = segments.count - selectedSegments.count
    let insertionIndex = min(maxHeadSegments, lines.count)
    var excerpt = lines
    excerpt.insert(
      "[\(omittedCount) middle transcript segments omitted to keep local generation fast. Ask for a specific timestamp if you need a precise edit there.]",
      at: insertionIndex
    )
    return excerpt.joined(separator: "\n")
  }

  private static func truncatedText(_ text: String, limit: Int) -> String {
    let normalized =
      text
      .replacingOccurrences(of: "\n", with: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard normalized.count > limit else { return normalized }

    return String(normalized.prefix(limit)).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
  }

  private static func fallbackProposal(
    for request: LocalSessionDocumentChatRequest,
    failureMessage: String? = nil
  ) -> LocalSessionDocumentEditProposal {
    let isHebrew = request.userMessage.containsHebrewScript
    guard requestLooksLikeDocumentEdit(request.userMessage) else {
      return LocalSessionDocumentEditProposal(
        assistantMessage: isHebrew
          ? "לא הצלחתי להפעיל את המודל המקומי, ולכן השארתי את המסמך ללא שינוי."
          : "I could not run the local model, so I left the document unchanged.",
        recapPatch: nil,
        transcriptPatches: [],
        speakerRenames: [],
        warnings: fallbackWarnings(from: failureMessage)
      )
    }

    let kind = fallbackSectionKind(for: request.userMessage)
    let title = fallbackSectionTitle(
      for: request.userMessage,
      kind: kind,
      isHebrew: isHebrew
    )
    let summary = fallbackSectionSummary(
      for: request.userMessage,
      title: title,
      kind: kind,
      isHebrew: isHebrew
    )
    let bullets = fallbackBullets(
      for: request,
      kind: kind,
      title: title,
      isHebrew: isHebrew
    )

    return LocalSessionDocumentEditProposal(
      assistantMessage: isHebrew
        ? "עדכנתי את המסמך לפי הבקשה גם בלי תגובת מודל מלאה."
        : "Updated the document from the request using the local fallback.",
      recapPatch: LocalSessionDocumentRecapPatch(
        overview: request.session.recap.overview.trimmingCharacters(in: .whitespacesAndNewlines)
          .isEmpty ? summary : nil,
        sections: [
          .init(
            kind: kind,
            title: title,
            summary: summary,
            bullets: bullets
          )
        ]
      ),
      transcriptPatches: [],
      speakerRenames: [],
      warnings: fallbackWarnings(from: failureMessage)
    )
  }

  private static func requestLooksLikeDocumentEdit(_ message: String) -> Bool {
    let normalized = message.lowercased()
    let editTerms = [
      "action item", "action items", "todo", "to-do", "follow up", "follow-up",
      "add section", "add a section", "add this", "add to", "edit", "change", "fix",
      "rewrite", "clean up", "turn this into", "rename", "translate", "summarize",
      "תוסיף", "הוסף", "להוסיף", "תעדכן", "עדכן", "שנה", "תקן", "תתקן", "סכם",
      "סיכום", "משימה", "משימות", "אקשן", "פעולה", "פעולות", "סעיף", "דירוג",
      "דרוג",
    ]

    return editTerms.contains { normalized.contains($0) }
  }

  private static func fallbackSectionKind(for message: String) -> LocalSessionRecapSection.Kind {
    let normalized = message.lowercased()
    if normalized.contains("action item") || normalized.contains("todo")
      || normalized.contains("follow up") || normalized.contains("follow-up")
      || normalized.contains("משימה") || normalized.contains("משימות")
      || normalized.contains("אקשן") || normalized.contains("לביצוע")
    {
      return .actionItem
    }

    if normalized.contains("decision") || normalized.contains("החלט") {
      return .decisions
    }

    if normalized.contains("question") || normalized.contains("שאל") {
      return .openQuestions
    }

    return .notes
  }

  private static func fallbackSectionTitle(
    for message: String,
    kind: LocalSessionRecapSection.Kind,
    isHebrew: Bool
  ) -> String {
    if kind == .actionItem {
      return isHebrew ? "משימות להמשך" : "Action items"
    }

    let topic = fallbackTopic(from: message, isHebrew: isHebrew)
    guard !topic.isEmpty else {
      return isHebrew ? "הערות נוספות" : kind.displayTitle
    }

    return topic
  }

  private static func fallbackSectionSummary(
    for message: String,
    title: String,
    kind: LocalSessionRecapSection.Kind,
    isHebrew: Bool
  ) -> String {
    if kind == .actionItem {
      return isHebrew
        ? "ריכוז משימות ונקודות המשך מתוך השיחה."
        : "Action-oriented follow-ups extracted from the session."
    }

    return isHebrew
      ? "סעיף נוסף במסמך שמתייחס ל\(title)."
      : "Additional document section covering \(title)."
  }

  private static func fallbackBullets(
    for request: LocalSessionDocumentChatRequest,
    kind: LocalSessionRecapSection.Kind,
    title: String,
    isHebrew: Bool
  ) -> [String] {
    if kind != .actionItem {
      return isHebrew
        ? [
          "להוסיף למסמך התייחסות ל\(title).",
          "להשתמש בסעיף הזה כנקודת המשך לעבודה על המסמך.",
        ]
        : [
          "Add explicit document coverage for \(title).",
          "Use this section as the follow-up note for the session document.",
        ]
    }

    let sourceSnippets = fallbackSourceSnippets(from: request.session)
    guard !sourceSnippets.isEmpty else {
      return isHebrew
        ? ["להמשיך טיפול בנקודות שעלו בשיחה.", "לעדכן בעלות וזמנים כשהם יהיו ברורים."]
        : ["Follow up on the points raised in the session.", "Add owners and timing when they are clear."]
    }

    return sourceSnippets.prefix(5).map { snippet in
      isHebrew ? "לטפל ב\(snippet)" : "Follow up on \(snippet)"
    }
  }

  private static func fallbackSourceSnippets(from session: LocalSession) -> [String] {
    let recapBullets = session.recap.sections.flatMap(\.bullets)
    let recapText = ([session.recap.overview] + session.recap.sections.map(\.summary) + recapBullets)
      .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    let transcriptText = session.transcriptSegments.map(\.text)

    return (recapText + transcriptText)
      .flatMap(splitSentences)
      .map { truncatedText($0, limit: 86) }
      .filter { !$0.isEmpty }
      .removingDuplicates()
  }

  private static func splitSentences(_ text: String) -> [String] {
    text
      .components(separatedBy: CharacterSet(charactersIn: ".!?؟\n"))
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
  }

  private static func fallbackTopic(from message: String, isHebrew: Bool) -> String {
    var topic = message.trimmingCharacters(in: .whitespacesAndNewlines)
    let removablePhrases = isHebrew
      ? [
        "תוסיף סעיף", "הוסף סעיף", "להוסיף סעיף", "סעיף שמדבר על", "שמדבר על",
        "בנושא", "על",
      ]
      : [
        "please", "add a section about", "add section about", "add a section",
        "add section", "section about", "about",
      ]

    for phrase in removablePhrases {
      topic = topic.replacingOccurrences(of: phrase, with: "", options: [.caseInsensitive])
    }

    topic = topic
      .replacingOccurrences(of: "דרוג", with: "דירוג")
      .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))

    return topic.isEmpty ? (isHebrew ? "נושא המשך מהשיחה" : "Session follow-up") : topic
  }

  private static func fallbackWarnings(from failureMessage: String?) -> [String] {
    guard let failureMessage = failureMessage?.trimmingCharacters(in: .whitespacesAndNewlines),
      !failureMessage.isEmpty
    else {
      return []
    }

    return ["Used deterministic fallback because the local model response was unavailable: \(failureMessage)"]
  }

  static func decodeProposal(from rawResponse: String) -> LocalSessionDocumentEditProposal {
    let jsonString = rawResponse.jsonObjectSubstringOrSelf
    let data = jsonString.data(using: .utf8) ?? Data()

    do {
      let payload = try JSONDecoder().decode(
        LocalSessionDocumentEditProposalPayload.self, from: data)
      return payload.makeProposal()
    } catch {
      return LocalSessionDocumentEditProposal(
        assistantMessage: "I could not produce a clean document edit from the local model.",
        recapPatch: nil,
        transcriptPatches: [],
        speakerRenames: [],
        warnings: ["The local model returned an invalid edit shape, so nothing was applied."]
      )
    }
  }
}

private struct LocalSessionDocumentEditProposalPayload: Codable {
  var assistantMessage: String?
  var recapPatch: RecapPatch?
  var transcriptPatches: [TranscriptPatch]?
  var speakerRenames: [SpeakerRename]?
  var warnings: [String]?

  struct RecapPatch: Codable {
    var overview: String?
    var sections: [SectionReplacement]?
  }

  struct SectionReplacement: Codable {
    var kind: String?
    var title: String?
    var summary: String?
    var bullets: [String]?
  }

  struct TranscriptPatch: Codable {
    var segmentID: String?
    var text: String?
  }

  struct SpeakerRename: Codable {
    var oldName: String?
    var newName: String?
  }

  func makeProposal() -> LocalSessionDocumentEditProposal {
    let sections = (recapPatch?.sections ?? []).compactMap {
      section
        -> LocalSessionDocumentRecapPatch.SectionReplacement? in
      guard let kind = section.kind?.recapSectionKind else { return nil }
      let summary = section.summary?.cleanedGeneratedContent ?? ""
      let bullets = (section.bullets ?? []).compactMap(\.cleanedGeneratedContent)

      guard !summary.isEmpty || !bullets.isEmpty else {
        return nil
      }

      return LocalSessionDocumentRecapPatch.SectionReplacement(
        kind: kind,
        title: section.title?.cleanedGeneratedContent ?? kind.displayTitle,
        summary: summary,
        bullets: bullets
      )
    }

    let overview = recapPatch?.overview?.cleanedGeneratedContent
    let recap =
      overview == nil && sections.isEmpty
      ? nil
      : LocalSessionDocumentRecapPatch(overview: overview, sections: sections)

    let transcriptEdits = (transcriptPatches ?? []).compactMap {
      patch
        -> LocalSessionDocumentTranscriptPatch? in
      guard let rawID = patch.segmentID,
        let segmentID = UUID(uuidString: rawID),
        let text = patch.text?.trimmingCharacters(in: .whitespacesAndNewlines),
        !text.isEmpty
      else {
        return nil
      }

      return LocalSessionDocumentTranscriptPatch(segmentID: segmentID, text: text)
    }

    let renames = (speakerRenames ?? []).compactMap {
      rename
        -> LocalSessionDocumentSpeakerRename? in
      guard let oldName = rename.oldName?.trimmingCharacters(in: .whitespacesAndNewlines),
        let newName = rename.newName?.trimmingCharacters(in: .whitespacesAndNewlines),
        !oldName.isEmpty,
        !newName.isEmpty
      else {
        return nil
      }

      return LocalSessionDocumentSpeakerRename(oldName: oldName, newName: newName)
    }

    return LocalSessionDocumentEditProposal(
      assistantMessage: assistantMessage?.cleanedAssistantMessage ?? "",
      recapPatch: recap,
      transcriptPatches: transcriptEdits,
      speakerRenames: renames,
      warnings: (warnings ?? []).compactMap(\.cleanedGeneratedContent)
    )
  }
}

extension String {
  fileprivate var containsHebrewScript: Bool {
    unicodeScalars.contains { scalar in
      (0x0590...0x05FF).contains(Int(scalar.value))
    }
  }

  fileprivate var recapSectionKind: LocalSessionRecapSection.Kind? {
    switch trimmingCharacters(in: .whitespacesAndNewlines) {
    case "overview", "summary":
      return .overview
    case "keyPoints", "highlight":
      return .keyPoints
    case "decisions", "decision":
      return .decisions
    case "actionItem", "actionItems":
      return .actionItem
    case "openQuestions", "openQuestion":
      return .openQuestions
    case "nextSteps", "nextStep":
      return .nextSteps
    case "notes", "note":
      return .notes
    default:
      return nil
    }
  }

  fileprivate var cleanedAssistantMessage: String? {
    guard let cleaned = cleanedGeneratedContent else { return nil }
    guard !cleaned.looksLikeModelContractLeak else { return nil }
    return cleaned
  }

  fileprivate var cleanedGeneratedContent: String? {
    let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    let lowercased = trimmed.lowercased()
    let placeholders: Set<String> = [
      "...", "…", "....", "n/a", "na", "none", "null", "nil", "no summary",
    ]
    guard !placeholders.contains(lowercased) else { return nil }

    let punctuationOnly = trimmed.unicodeScalars.allSatisfy { scalar in
      CharacterSet.whitespacesAndNewlines.contains(scalar)
        || CharacterSet.punctuationCharacters.contains(scalar)
        || CharacterSet.symbols.contains(scalar)
    }
    guard !punctuationOnly else { return nil }

    return trimmed
  }

  fileprivate var looksLikeModelContractLeak: Bool {
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

  fileprivate var jsonObjectSubstringOrSelf: String {
    let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
    guard let firstBrace = firstIndex(of: "{") else {
      return trimmed
    }

    var depth = 0
    var isInsideString = false
    var isEscaped = false
    var index = firstBrace

    while index < endIndex {
      let character = self[index]

      if isInsideString {
        if isEscaped {
          isEscaped = false
        } else if character == "\\" {
          isEscaped = true
        } else if character == "\"" {
          isInsideString = false
        }
      } else if character == "\"" {
        isInsideString = true
      } else if character == "{" {
        depth += 1
      } else if character == "}" {
        depth -= 1
        if depth == 0 {
          return String(self[firstBrace...index])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        }
      }

      index = self.index(after: index)
    }

    guard let lastBrace = lastIndex(of: "}"), firstBrace <= lastBrace else {
      return trimmed
    }

    return String(self[firstBrace...lastBrace]).trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

extension Array where Element == String {
  fileprivate func removingDuplicates() -> [String] {
    var seen = Set<String>()
    var result: [String] = []

    for item in self {
      let key = item.lowercased()
      guard !seen.contains(key) else { continue }
      seen.insert(key)
      result.append(item)
    }

    return result
  }
}
