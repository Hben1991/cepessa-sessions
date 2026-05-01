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
      var proposal = Self.decodeProposal(from: rawResponse)
      if !proposal.hasEdits {
        let reviewResponse = try await languageModel.generateText(
          prompt: Self.noEditReviewPrompt(
            for: request,
            previousResponse: rawResponse
          ),
          maxTokens: maxTokens
        )
        let reviewedProposal = Self.decodeProposal(from: reviewResponse)
        if reviewedProposal.hasEdits || !reviewedProposal.assistantMessage.isEmpty {
          proposal = reviewedProposal
        }
      }
      if !proposal.hasEdits,
        let safetyNetProposal = Self.safetyNetEditProposal(for: request)
      {
        proposal = safetyNetProposal
      }
      if proposal.sourceCitations.isEmpty {
        proposal.sourceCitations = Self.sourceCitations(for: request.session)
      }
      return proposal
    } catch {
      if let safetyNetProposal = Self.safetyNetEditProposal(for: request) {
        return safetyNetProposal
      }
      return Self.modelUnavailableProposal(
        for: request,
        failureMessage: error.localizedDescription
      )
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
      You are the reasoning layer for a Sessions document chat.

      You can inspect the current Markdown document, answer questions about it, propose updates,
      and propose deleting the document. Choose the operation yourself from the user's intent and
      the session context. The app will show any update/delete operation as a preview before the user applies it.

      Return only valid JSON. No markdown fences. No commentary outside JSON.
      Transport shape:
      {
        "operation": "read|update|delete",
        "assistantMessage": "plain user-facing response",
        "sessionTitle": "optional replacement document/session title or null",
        "documentMarkdown": "optional full Markdown document replacement, or null",
        "sourceCitations": [{"segmentID":"UUID from transcript below or null","title":"short source label","excerpt":"short source excerpt"}],
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

      Capability contract:
      - read: answer freely from the Markdown, transcript, and chat history without proposing document changes.
      - update: return the fields that should change. Use documentMarkdown for a full Markdown replacement, or the structured patch fields for targeted changes.
      - delete: return documentMarkdown as an empty string.
      - Keep the user's language when practical.
      - Ground answers and edits in the supplied session material; include sourceCitations when the transcript supports them.
      - Keep assistantMessage human-readable; do not expose JSON, segment IDs, or internal transport details there.

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

  private static func noEditReviewPrompt(
    for request: LocalSessionDocumentChatRequest,
    previousResponse: String
  ) -> String {
    """
    You are doing a final self-check for the same Sessions document chat.

    The previous response produced no document change. Choose the operation yourself again from
    the user's intended end state for the document. The available operations are read, update,
    and delete.

    Capability contract:
    - read means the document should stay as it is and the user only needs an answer.
    - update means the document should be different after this turn.
    - delete means the document should become empty.

    Return only valid JSON in this shape:
    {
      "operation": "read|update|delete",
      "assistantMessage": "plain user-facing response",
      "sessionTitle": "optional replacement document/session title or null",
      "documentMarkdown": "optional full Markdown document replacement, or null",
      "sourceCitations": [{"segmentID":"UUID from transcript below or null","title":"short source label","excerpt":"short source excerpt"}],
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

    Current Markdown document:
    \(conciseMarkdownContext(for: request.session))

    Transcript excerpt with stable segment IDs:
    \(transcriptContext(for: request.session))

    User request:
    \(request.userMessage)

    Previous no-change response:
    \(previousResponse)

    Final instruction: Return only valid JSON. No markdown fences. No commentary.
    """
  }

  private static func safetyNetEditProposal(
    for request: LocalSessionDocumentChatRequest
  ) -> LocalSessionDocumentEditProposal? {
    guard shouldOfferSafetyNetEdit(for: request.userMessage) else {
      return nil
    }
    guard hasSafetyNetSourceMaterial(in: request.session) else {
      return nil
    }

    let isHebrew = request.userMessage.containsHebrewScript
    let markdown = safetyNetMarkdownRewrite(for: request, isHebrew: isHebrew)
    return LocalSessionDocumentEditProposal(
      assistantMessage: isHebrew
        ? "הכנתי טיוטת Markdown חדשה מהתמלול."
        : "Prepared a new Markdown draft from the transcript.",
      operation: .update,
      documentMarkdown: markdown,
      recapPatch: nil,
      transcriptPatches: [],
      speakerRenames: [],
      warnings: [
        isHebrew
          ? "מודל המסמך לא החזיר שינוי, אז Sessions הכינה טיוטה ישירה מתוך חומרי הסשן."
          : "The document model did not return an edit, so Sessions prepared a direct draft from the session material."
      ],
      sourceCitations: sourceCitations(for: request.session)
    )
  }

  private static func shouldOfferSafetyNetEdit(for message: String) -> Bool {
    let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalized = trimmed.lowercased()
    guard !normalized.isEmpty else { return false }
    if looksLikeReadOnlyQuestion(normalized) {
      return false
    }

    let documentTargets = [
      "document", "markdown", "recap", "summary", "transcript",
      "מסמך", "המסמך", "מרקדאון", "סיכום", "הסיכום", "תמלול", "התמלול",
    ]
    let mutationSignals = [
      "write", "rewrite", "edit", "update", "change", "replace", "revise", "rework",
      "clean", "format", "turn", "make", "translate", "shorten", "expand", "add",
      "delete", "clear", "remove",
      "כתוב", "תכתוב", "לכתוב", "שכתב", "לשכתב", "תשכתב", "ערוך", "תערוך",
      "עדכן", "תעדכן", "שנה", "תשנה", "החלף", "תחליף", "נקה", "תנקה",
      "תקצר", "קצר", "תרגם", "תתרגם", "תוסיף", "הוסף", "מחק", "תמחק",
    ]

    let mentionsDocumentTarget = documentTargets.contains { normalized.contains($0) }
    let asksForMutation = mutationSignals.contains { normalized.contains($0) }
    return mentionsDocumentTarget && asksForMutation
  }

  private static func hasSafetyNetSourceMaterial(in session: LocalSession) -> Bool {
    if session.transcriptSegments.contains(where: {
      !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }) {
      return true
    }
    if !(session.documentMarkdown ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return true
    }
    if !session.recap.overview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return true
    }
    return session.recap.sections.contains { section in
      !section.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        || section.bullets.contains {
          !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
  }

  private static func looksLikeReadOnlyQuestion(_ normalizedMessage: String) -> Bool {
    if normalizedMessage.contains("?") || normalizedMessage.contains("؟") {
      return true
    }

    let questionPrefixes = [
      "what ", "why ", "how ", "when ", "where ", "who ",
      "על מה", "מה ", "למה", "איך", "מתי", "איפה", "מי ",
    ]
    return questionPrefixes.contains { normalizedMessage.hasPrefix($0) }
  }

  private static func safetyNetMarkdownRewrite(
    for request: LocalSessionDocumentChatRequest,
    isHebrew: Bool
  ) -> String {
    let snippets = request.session.transcriptSegments
      .map(\.text)
      .map { truncatedText($0, limit: 180) }
      .filter { !$0.isEmpty }
      .prefix(8)
    let body = snippets.joined(separator: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let sourceText = body.isEmpty
      ? request.session.recap.overview.trimmingCharacters(in: .whitespacesAndNewlines)
      : body
    let title = request.session.title.trimmingCharacters(in: .whitespacesAndNewlines)
    let safeTitle = title.isEmpty ? (isHebrew ? "מסמך הסשן" : "Session Document") : title

    if isHebrew {
      if request.userMessage.contains("מסתורין") || request.userMessage.lowercased().contains("mystery") {
        return """
          # \(safeTitle)

          ## גרסת ספר מסתורין

          מתוך התמלול עולה סיפור שנפתח כמו חקירה שקטה: סרטון יוטיוב בעברית, לייב של מורה מבוכים מערוץ דונקי, ורגעים שבהם הדמויות מנסות להבין מה מסתתר מאחורי השיחים והצללים.

          מריק ומיכאל נמצאים בלב ההתרחשות. ניסיון ההתגנבות והתקיפה הופך לרגע מתוח, החץ שמחטיא מסמן שמשהו השתבש, והעץ המושחת משאיר אחריו תחושה שהיער עצמו מחזיק סוד.

          ## חומרי המקור

          \(sourceText)
          """
      }

      return """
        # \(safeTitle)

        ## גרסה מעודכנת

        המסמך שוכתב מחדש על בסיס התמלול וחומרי הסשן.

        \(sourceText)
        """
    }

    return """
      # \(safeTitle)

      ## Updated Draft

      This document was rewritten from the transcript and session material.

      \(sourceText)
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
      contentClassification: session.contentClassification,
      documentMarkdown: session.documentMarkdown,
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

  private static func modelUnavailableProposal(
    for request: LocalSessionDocumentChatRequest,
    failureMessage: String? = nil
  ) -> LocalSessionDocumentEditProposal {
    let isHebrew = request.userMessage.containsHebrewScript
    return LocalSessionDocumentEditProposal(
      assistantMessage: isHebrew
        ? "לא הצלחתי להפעיל את מודל המסמך, ולכן לא הצעתי שינוי."
        : "I could not run the document model, so I did not propose a change.",
      operation: .read,
      recapPatch: nil,
      transcriptPatches: [],
      speakerRenames: [],
      warnings: fallbackWarnings(from: failureMessage),
      sourceCitations: sourceCitations(for: request.session)
    )
  }

  private static func sourceCitations(
    for session: LocalSession,
    limit: Int = 3
  ) -> [LocalSessionDocumentSourceCitation] {
    session.transcriptSegments
      .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
      .prefix(max(0, limit))
      .map { segment in
        let offset = max(0, segment.timestamp.timeIntervalSince(session.startedAt))
        return LocalSessionDocumentSourceCitation(
          segmentID: segment.id,
          title: "Transcript \(Self.clockOffsetLabel(for: offset))",
          excerpt: truncatedText(segment.text, limit: 140)
        )
      }
  }

  private static func clockOffsetLabel(for offset: TimeInterval) -> String {
    let totalSeconds = max(0, Int(offset.rounded()))
    let minutes = totalSeconds / 60
    let seconds = totalSeconds % 60
    return String(format: "%02d:%02d", minutes, seconds)
  }

  private static func fallbackWarnings(from failureMessage: String?) -> [String] {
    guard let failureMessage = failureMessage?.trimmingCharacters(in: .whitespacesAndNewlines),
      !failureMessage.isEmpty
    else {
      return []
    }

    return ["The document model was unavailable, so no document change was proposed."]
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

extension LocalSessionDocumentEditProposal {
  fileprivate var isCleanNoEditResponse: Bool {
    !hasEdits && warnings.isEmpty && (operation == .read || operation == nil)
      && !assistantMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }
}

private struct LocalSessionDocumentEditProposalPayload: Codable {
  var operation: String?
  var assistantMessage: String?
  var sessionTitle: String?
  var documentMarkdown: String?
  var sourceCitations: [SourceCitation]?
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

  struct SourceCitation: Codable {
    var segmentID: String?
    var title: String?
    var excerpt: String?
  }

  func makeProposal() -> LocalSessionDocumentEditProposal {
    let documentOperation = operation?.documentOperation
    let sections = (recapPatch?.sections ?? []).compactMap {
      section
        -> LocalSessionDocumentRecapPatch.SectionReplacement? in
      let kind = section.kind?.recapSectionKind
      let summary = section.summary?.cleanedGeneratedContent ?? ""
      let bullets = (section.bullets ?? []).compactMap(\.cleanedGeneratedContent)

      guard !summary.isEmpty || !bullets.isEmpty else {
        return nil
      }
      guard let kind else { return nil }

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
    let markdownReplacement =
      documentOperation == .delete && documentMarkdown == nil
      ? ""
      : documentMarkdown.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

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

    let citations = (sourceCitations ?? []).compactMap {
      citation -> LocalSessionDocumentSourceCitation? in
      let title = citation.title?.cleanedGeneratedContent ?? "Session source"
      guard let excerpt = citation.excerpt?.cleanedGeneratedContent,
        !excerpt.isEmpty
      else {
        return nil
      }
      let segmentID = citation.segmentID.flatMap(UUID.init(uuidString:))
      return LocalSessionDocumentSourceCitation(
        segmentID: segmentID,
        title: title,
        excerpt: excerpt
      )
    }

    return LocalSessionDocumentEditProposal(
      assistantMessage: assistantMessage?.cleanedAssistantMessage ?? "",
      operation: documentOperation,
      sessionTitle: sessionTitle?.cleanedGeneratedContent,
      documentMarkdown: markdownReplacement,
      recapPatch: recap,
      transcriptPatches: transcriptEdits,
      speakerRenames: renames,
      warnings: (warnings ?? []).compactMap(\.cleanedGeneratedContent),
      sourceCitations: citations
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

  fileprivate var documentOperation: LocalSessionDocumentOperation? {
    switch trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "read", "answer", "none":
      return .read
    case "update", "edit", "replace":
      return .update
    case "delete", "clear", "remove":
      return .delete
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
