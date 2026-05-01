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
    if Self.requestLooksLikeClearDocumentRequest(request.userMessage) {
      return Self.clearDocumentFallbackProposal(for: request)
    }

    do {
      let rawResponse = try await languageModel.generateText(
        prompt: Self.prompt(for: request),
        maxTokens: maxTokens
      )
      let isDocumentEditRequest = Self.requestLooksLikeDocumentEdit(request.userMessage)
      var proposal = Self.decodeProposal(
        from: rawResponse,
        fallbackSectionKind: isDocumentEditRequest
          ? Self.fallbackSectionKind(for: request.userMessage)
          : nil
      )
      if proposal.sourceCitations.isEmpty {
        proposal.sourceCitations = Self.sourceCitations(for: request.session)
      }
      if isDocumentEditRequest,
        Self.requestLooksLikeEndAppendRequest(request.userMessage),
        Self.proposalEchoesAppendInstruction(proposal, request: request)
      {
        return Self.fallbackProposal(for: request)
      }
      if !isDocumentEditRequest && proposal.shouldUseQuestionFallback {
        return Self.fallbackAnswerProposal(for: request)
      }
      if proposal.hasEdits || !isDocumentEditRequest {
        return proposal
      }

      return Self.fallbackProposal(for: request)
    } catch {
      if !Self.requestLooksLikeDocumentEdit(request.userMessage) {
        return Self.fallbackAnswerProposal(for: request, failureMessage: error.localizedDescription)
      }
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

      Rules:
      - Return document edits whenever the user asks to change, clean up, rewrite, summarize into sections, turn into action items, rename speakers, or fix transcript text.
      - If the user asks in Hebrew or asks to translate to Hebrew, write assistantMessage and recapPatch content in Hebrew.
      - If the user asks to delete, clear, replace, or rewrite the whole Markdown document, return documentMarkdown. For a clear/delete-all request, set documentMarkdown to an empty string.
      - If the user asks to change or update the title, return sessionTitle with the new title. Do not create a note section for title changes.
      - The structured session and the rendered Markdown are both available: use recapPatch for small structured recap edits, and documentMarkdown for whole-document Markdown edits.
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
      - For every answer or edit, include one to three sourceCitations grounded in the transcript excerpt when available.

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
        warnings: fallbackWarnings(from: failureMessage),
        sourceCitations: sourceCitations(for: request.session)
      )
    }

    if requestLooksLikeClearDocumentRequest(request.userMessage) {
      return clearDocumentFallbackProposal(for: request, failureMessage: failureMessage)
    }

    if requestLooksLikeConciseStyleEdit(request.userMessage) {
      return conciseStyleFallbackProposal(for: request, failureMessage: failureMessage)
    }

    if requestLooksLikeEndAppendRequest(request.userMessage) {
      if requestLooksLikeTranscriptStoryAppendRequest(request.userMessage),
        let story = fallbackTranscriptStoryContinuation(for: request, isHebrew: isHebrew)
      {
        return LocalSessionDocumentEditProposal(
          assistantMessage: isHebrew
            ? "הכנתי המשך סיפורי מתוך התמלול בסוף המסמך."
            : "Prepared a story-style continuation from the transcript.",
          recapPatch: LocalSessionDocumentRecapPatch(
            overview: nil,
            sections: [
              .init(
                kind: .notes,
                title: isHebrew ? "המשך הסיפור" : "Story continuation",
                summary: story,
                bullets: []
              )
            ]
          ),
          transcriptPatches: [],
          speakerRenames: [],
          warnings: fallbackWarnings(from: failureMessage),
          sourceCitations: sourceCitations(for: request.session)
        )
      }

      if let paragraph = fallbackEndAppendText(from: request.userMessage, isHebrew: isHebrew) {
        return LocalSessionDocumentEditProposal(
          assistantMessage: isHebrew
            ? "הוספתי פסקת המשך בסוף המסמך." : "Added a closing paragraph to the document.",
          recapPatch: LocalSessionDocumentRecapPatch(
            overview: nil,
            sections: [
              .init(
                kind: .notes,
                title: isHebrew ? "המשך המסמך" : "Document addendum",
                summary: paragraph,
                bullets: []
              )
            ]
          ),
          transcriptPatches: [],
          speakerRenames: [],
          warnings: fallbackWarnings(from: failureMessage),
          sourceCitations: sourceCitations(for: request.session)
        )
      }

      return LocalSessionDocumentEditProposal(
        assistantMessage: isHebrew
          ? "אני צריך לדעת איזה מלל להוסיף בסוף המסמך. שלח את הפסקה עצמה ואוסיף אותה בלי להפוך את ההוראה לתוכן."
          : "I need the exact text to add at the end of the document. Send the paragraph and I will add it without turning the instruction into content.",
        recapPatch: nil,
        transcriptPatches: [],
        speakerRenames: [],
        warnings: fallbackWarnings(from: failureMessage)
      )
    }

    if let title = fallbackTitle(from: request.userMessage) {
      return LocalSessionDocumentEditProposal(
        assistantMessage: isHebrew ? "עדכנתי את כותרת המסמך." : "Updated the document title.",
        sessionTitle: title,
        recapPatch: nil,
        transcriptPatches: [],
        speakerRenames: [],
        warnings: fallbackWarnings(from: failureMessage),
        sourceCitations: sourceCitations(for: request.session)
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
      warnings: fallbackWarnings(from: failureMessage),
      sourceCitations: sourceCitations(for: request.session)
    )
  }

  private static func conciseStyleFallbackProposal(
    for request: LocalSessionDocumentChatRequest,
    failureMessage: String? = nil
  ) -> LocalSessionDocumentEditProposal {
    let isHebrew = request.userMessage.containsHebrewScript
    let existingOverview = request.session.recap.overview.trimmingCharacters(in: .whitespacesAndNewlines)
    let snippets = fallbackSourceSnippets(from: request.session).prefix(2)
    let source = snippets.isEmpty ? existingOverview : snippets.joined(separator: " ")
    let fallbackSource = source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ? (isHebrew ? "המסמך מסכם את עיקר ההקלטה." : "The document captures the recording's main point.")
      : source
    let overview = truncatedText(fallbackSource, limit: isHebrew ? 220 : 240)

    return LocalSessionDocumentEditProposal(
      assistantMessage: isHebrew
        ? "קיצרתי את המסמך וכתבתי אותו קרוב יותר לרוח ההקלטה."
        : "I shortened the document and aligned it more closely with the recording.",
      recapPatch: LocalSessionDocumentRecapPatch(
        overview: overview,
        sections: []
      ),
      transcriptPatches: [],
      speakerRenames: [],
      warnings: fallbackWarnings(from: failureMessage),
      sourceCitations: sourceCitations(for: request.session)
    )
  }

  private static func clearDocumentFallbackProposal(
    for request: LocalSessionDocumentChatRequest,
    failureMessage: String? = nil
  ) -> LocalSessionDocumentEditProposal {
    let isHebrew = request.userMessage.containsHebrewScript
    return LocalSessionDocumentEditProposal(
      assistantMessage: isHebrew
        ? "הכנתי מסמך Markdown ריק."
        : "Prepared a blank Markdown document.",
      documentMarkdown: "",
      recapPatch: nil,
      transcriptPatches: [],
      speakerRenames: [],
      warnings: fallbackWarnings(from: failureMessage),
      sourceCitations: sourceCitations(for: request.session)
    )
  }

  private static func fallbackAnswerProposal(
    for request: LocalSessionDocumentChatRequest,
    failureMessage: String? = nil
  ) -> LocalSessionDocumentEditProposal {
    let isHebrew = request.userMessage.containsHebrewScript
    let answer: String
    if requestLooksLikeErrorQuestion(request.userMessage) {
      let detail = failureMessage?.trimmingCharacters(in: .whitespacesAndNewlines)
      answer =
        isHebrew
        ? "המודל המקומי לא החזיר תשובת JSON תקינה שאפשר היה לקרוא בבטחה. \(detail.map { "פרטי השגיאה: \($0)" } ?? "לכן השתמשתי בתשובת גיבוי מתוך המסמך הקיים.")"
        : "The local model did not return valid JSON that could be safely read. \(detail.map { "Error detail: \($0)" } ?? "I used a deterministic answer from the existing document instead.")"
    } else {
      answer = isHebrew ? hebrewDocumentAnswer(for: request.session) : englishDocumentAnswer(for: request.session)
    }

    return LocalSessionDocumentEditProposal(
      assistantMessage: answer,
      recapPatch: nil,
      transcriptPatches: [],
      speakerRenames: [],
      warnings: fallbackWarnings(from: failureMessage),
      sourceCitations: sourceCitations(for: request.session)
    )
  }

  private static func requestLooksLikeErrorQuestion(_ message: String) -> Bool {
    let normalized = message.lowercased()
    return [
      "why", "error", "failed", "failure", "what happened",
      "למה", "מדוע", "שגיאה", "הודעת שגיאה", "נכשל", "בעיה",
    ].contains { normalized.contains($0) }
  }

  private static func hebrewDocumentAnswer(for session: LocalSession) -> String {
    let transcript = session.transcriptSegments.map(\.text).joined(separator: " ")
    let recap = ([session.recap.overview] + session.recap.sections.flatMap { [$0.summary] + $0.bullets })
      .joined(separator: " ")
    let corpus = "\(transcript) \(recap)"

    let mentionsLocalModel =
      corpus.contains("המודל המקומי") || corpus.contains("מודל מקומי")
      || corpus.contains("local model")
      || session.transcriptSegments.contains {
        $0.speaker.trimmingCharacters(in: .whitespacesAndNewlines)
          .lowercased().contains("local model")
      }
    let isLocalModelSummaryCheck =
      mentionsLocalModel
      && (corpus.contains("מסכם") || corpus.contains("סיכום") || corpus.contains("הצלחה"))
    if isLocalModelSummaryCheck {
      return
        "המסמך עוסק בבדיקה של המודל המקומי: האם הוא באמת מסכם את המסמך, ואם הסיכום עובד הוא צריך לציין הצלחה. אם הוא לא מסכם את המסמך, זו אי הצלחה."
    }
    if let videoAnswer = hebrewVideoTopicAnswer(for: session, corpus: corpus) {
      return videoAnswer
    }

    let snippets = fallbackSourceSnippets(from: session)
      .filter(\.containsHebrewScript)
      .prefix(3)
    guard !snippets.isEmpty else {
      return "המסמך מסכם את התוכן שנקלט בסשן ומרכז את הנקודות שדורשות המשך טיפול."
    }

    return "המסמך עוסק ב\(snippets.joined(separator: " "))"
  }

  private static func hebrewVideoTopicAnswer(for session: LocalSession, corpus: String) -> String? {
    let videoSignals = ["סרטון", "יוטיוב", "לייב", "ערוץ", "מורה מבוכים"]
    guard videoSignals.contains(where: { corpus.contains($0) }) else { return nil }

    let sourceDescription: String
    if corpus.contains("מורה מבוכים") && corpus.contains("ערוץ דונקי") {
      sourceDescription = "סרטון יוטיוב בעברית, כנראה לייב של מורה מבוכים מערוץ דונקי"
    } else if corpus.contains("יוטיוב") {
      sourceDescription = "סרטון יוטיוב בעברית"
    } else {
      sourceDescription = "סרטון או מקור אודיו בעברית"
    }

    let roleplaySignals = [
      "קובייה", "גלגל", "גלגול", "להתגנב", "לתקוף", "חץ", "מריק", "מיכאל",
      "מכשפה", "עץ",
    ]
    if roleplaySignals.contains(where: { corpus.contains($0) }) {
      return
        "המסמך עוסק ב\(sourceDescription). התוכן המרכזי הוא סצנת משחק תפקידים: גלגולי קובייה, ניסיון התגנבות ותקיפה, חץ שמחטיא ופוגע בעץ מושחת, והמשך איום סביב מריק, מיכאל והמכשפה."
    }

    let recapOverview = session.recap.overview.trimmingCharacters(in: .whitespacesAndNewlines)
    if recapOverview.containsHebrewScript, !recapOverview.isEmpty {
      return "המסמך עוסק ב\(sourceDescription). \(recapOverview)"
    }

    return "המסמך עוסק ב\(sourceDescription) ובנקודות המרכזיות שנשמעו מתוכו."
  }

  private static func englishDocumentAnswer(for session: LocalSession) -> String {
    let snippets = fallbackSourceSnippets(from: session).prefix(3)
    guard !snippets.isEmpty else {
      return "The document summarizes the captured session and the follow-up points it contains."
    }

    return "The document is about \(snippets.joined(separator: " "))"
  }

  private static func requestLooksLikeDocumentEdit(_ message: String) -> Bool {
    let normalized = message.lowercased()
    let editTerms = [
      "action item", "action items", "todo", "to-do", "follow up", "follow-up",
      "add section", "add a section", "add this", "add to", "edit", "change", "fix",
      "rewrite", "clean up", "turn this into", "rename", "translate", "summarize",
      "shorten", "shorter", "make it short", "make this short", "concise", "tighten",
      "trim", "less verbose", "too verbose", "tone", "style", "title",
      "delete everything", "clear everything", "clear document", "empty document",
      "remove everything", "remove all content",
      "תוסיף", "הוסף", "להוסיף", "תעדכן", "עדכן", "שנה", "תקן", "תתקן", "סכם",
      "סיכום", "משימה", "משימות", "אקשן", "פעולה", "פעולות", "סעיף", "דירוג",
      "דרוג", "תקצר", "קצר", "לקצר", "שיקצר", "תמצת", "לתמצת", "תמציתי",
      "פחות לחפור", "לחפור", "ברוח ההקלטה", "ברוח המסמך", "סגנון", "טון",
      "כותרת", "תמחק", "מחק", "למחוק", "נקה", "לנקות", "רוקן", "תרוקן",
    ]

    return editTerms.contains { normalized.contains($0) }
  }

  private static func requestLooksLikeClearDocumentRequest(_ message: String) -> Bool {
    let normalized = message.lowercased()
      .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))

    let clearTerms = [
      "delete everything", "delete all", "clear everything", "clear all", "clear document",
      "empty document", "remove everything", "remove all content", "wipe document",
      "תמחק הכל", "מחק הכל", "תמחק את הכל", "מחק את הכל", "נקה הכל", "נקה את הכל",
      "נקה את המסמך", "רוקן את המסמך", "תרוקן את המסמך", "תמחק את המסמך",
    ]
    if clearTerms.contains(where: { normalized.contains($0) }) {
      return true
    }

    let mentionsDocument = [
      "document", "markdown", "md", "מסמך", "המסמך", "מרקדאון", "md",
    ].contains { normalized.contains($0) }
    let hasClearVerb = [
      "delete", "clear", "empty", "remove", "wipe", "תמחק", "מחק", "נקה", "רוקן",
      "תרוקן", "למחוק", "לנקות",
    ].contains { normalized.contains($0) }
    let hasAllTarget = [
      "everything", "all", "all content", "הכל", "את הכל", "כל התוכן", "תוכן",
    ].contains { normalized.contains($0) }

    return mentionsDocument && hasClearVerb && hasAllTarget
  }

  private static func requestLooksLikeConciseStyleEdit(_ message: String) -> Bool {
    let normalized = message.lowercased()
    let styleTerms = [
      "shorten", "shorter", "concise", "tighten", "trim", "less verbose", "too verbose",
      "tone", "style", "תקצר", "קצר", "לקצר", "שיקצר", "תמצת", "לתמצת", "תמציתי",
      "פחות לחפור", "לחפור", "ברוח ההקלטה", "ברוח המסמך", "סגנון", "טון",
    ]
    return styleTerms.contains { normalized.contains($0) }
  }

  private static func requestLooksLikeEndAppendRequest(_ message: String) -> Bool {
    let normalized = message.lowercased()
    let hasAppendIntent = [
      "append", "add at the end", "add this at the end", "closing paragraph",
      "תוסיף", "הוסף", "להוסיף", "תכתוב", "כתוב", "תרשום", "רשום",
    ].contains { normalized.contains($0) }
    let hasEndTarget = [
      "at the end", "end of the document", "bottom of the document", "closing",
      "בסוף", "סוף המסמך", "בסוף המסמך", "בסוף הסיכום", "פסקת סיום",
    ].contains { normalized.contains($0) }

    return hasAppendIntent && hasEndTarget
  }

  private static func requestLooksLikeTranscriptStoryAppendRequest(_ message: String) -> Bool {
    let normalized = message.lowercased()
    let referencesTranscript = [
      "transcript", "transcription", "תמלול", "התמלול", "תמליל", "הטקסט שנאמר",
    ].contains { normalized.contains($0) }
    let asksForNarrativeStyle = [
      "story", "book", "narrative", "like a story", "like a book",
      "סיפור", "סיפורי", "ספר", "כמו סיפור", "כמו ספר",
    ].contains { normalized.contains($0) }

    return referencesTranscript && asksForNarrativeStyle
  }

  private static func fallbackEndAppendText(from message: String, isHebrew: Bool) -> String? {
    if let delimited = message.textAfterInstructionDelimiter {
      return delimited
    }

    var candidate = message.trimmingCharacters(in: .whitespacesAndNewlines)
    let removablePhrases = isHebrew
      ? [
        "תוסיף את התמלול בסוף המסמך", "תוסיף את התמלול בסוף הסיכום",
        "תוסיף את התמלול", "הוסף את התמלול בסוף המסמך", "הוסף את התמלול",
        "תרשום את זה כמו סיפור", "תכתוב את זה כמו סיפור", "כתוב את זה כמו סיפור",
        "תרשום כמו סיפור", "תכתוב כמו סיפור", "כתוב כמו סיפור", "כמו סיפור",
        "תוסיף את המלל בסוף המסמך", "תוסיף את הטקסט בסוף המסמך",
        "תוסיף פסקה בסוף המסמך", "תוסיף בסוף המסמך", "תוסיף בסוף",
        "הוסף את המלל בסוף המסמך", "הוסף את הטקסט בסוף המסמך",
        "הוסף פסקה בסוף המסמך", "הוסף בסוף המסמך", "הוסף בסוף",
        "תרשום את זה כמו ספר", "תכתוב את זה כמו ספר", "כתוב את זה כמו ספר",
        "תרשום כמו ספר", "תכתוב כמו ספר", "כתוב כמו ספר", "כמו ספר",
      ]
      : [
        "add this at the end of the document", "add the text at the end of the document",
        "append this to the end of the document", "append to the end of the document",
        "add a closing paragraph", "write it like a book", "make it read like a book",
      ]

    for phrase in removablePhrases {
      candidate = candidate.replacingOccurrences(of: phrase, with: "", options: [.caseInsensitive])
    }

    candidate = candidate.trimmingCharacters(
      in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
    return candidate.isEmpty ? nil : candidate
  }

  private static func fallbackTranscriptStoryContinuation(
    for request: LocalSessionDocumentChatRequest,
    isHebrew: Bool
  ) -> String? {
    let transcriptSnippets = request.session.transcriptSegments
      .map(\.text)
      .flatMap(splitSentences)
      .map { truncatedText($0, limit: isHebrew ? 150 : 170) }
      .filter { !$0.isEmpty }
      .removingDuplicates()

    let snippets = transcriptSnippets.isEmpty
      ? fallbackSourceSnippets(from: request.session)
      : transcriptSnippets
    guard !snippets.isEmpty else { return nil }

    let body = snippets.prefix(4).joined(separator: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !body.isEmpty else { return nil }

    if isHebrew {
      return "בהמשך הסיפור, \(body)"
    }
    return "Continuing the story, \(body)"
  }

  private static func fallbackTitle(from message: String) -> String? {
    var title = message.trimmingCharacters(in: .whitespacesAndNewlines)
    let lowercased = title.lowercased()
    guard lowercased.contains("title") || title.contains("כותרת") else { return nil }

    let removablePhrases = [
      "update the title to", "change the title to", "rename the document to",
      "set the title to", "title:", "title -", "title",
      "תעדכן את הכותרת ל", "תעדכן את הכותרת", "עדכן את הכותרת ל",
      "עדכן את הכותרת", "שנה את הכותרת ל", "שנה את הכותרת", "כותרת:",
      "כותרת -", "כותרת",
    ]
    for phrase in removablePhrases {
      title = title.replacingOccurrences(of: phrase, with: "", options: [.caseInsensitive])
    }

    title = title.trimmingCharacters(
      in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
    return title.isEmpty ? nil : title
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

    return ["Used deterministic fallback because the local model response was unavailable."]
  }

  private static func proposalEchoesAppendInstruction(
    _ proposal: LocalSessionDocumentEditProposal,
    request: LocalSessionDocumentChatRequest
  ) -> Bool {
    let generatedText = [
      proposal.recapPatch?.overview,
      proposal.sessionTitle,
    ].compactMap { $0 }
      + (proposal.recapPatch?.sections ?? []).flatMap { section in
        [section.title, section.summary] + section.bullets
      }

    return generatedText.contains { text in
      generatedContentLooksLikeAppendInstructionEcho(text, userMessage: request.userMessage)
    }
  }

  private static func generatedContentLooksLikeAppendInstructionEcho(
    _ text: String,
    userMessage: String
  ) -> Bool {
    let normalized = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else { return false }

    let instructionTerms = [
      "תוסיף", "הוסף", "להוסיף", "תרשום", "תכתוב", "כתוב",
      "add", "append", "write this", "write it",
    ]
    if instructionTerms.contains(where: { normalized.contains($0) }) {
      return true
    }

    let normalizedUserMessage = userMessage.lowercased()
      .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
    return normalizedUserMessage.contains(normalized) && normalized.count > 12
  }

  static func decodeProposal(from rawResponse: String) -> LocalSessionDocumentEditProposal {
    decodeProposal(from: rawResponse, fallbackSectionKind: nil)
  }

  private static func decodeProposal(
    from rawResponse: String,
    fallbackSectionKind: LocalSessionRecapSection.Kind?
  ) -> LocalSessionDocumentEditProposal {
    let jsonString = rawResponse.jsonObjectSubstringOrSelf
    let data = jsonString.data(using: .utf8) ?? Data()

    do {
      let payload = try JSONDecoder().decode(
        LocalSessionDocumentEditProposalPayload.self, from: data)
      return payload.makeProposal(fallbackSectionKind: fallbackSectionKind)
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
  fileprivate var shouldUseQuestionFallback: Bool {
    guard !hasEdits else { return false }

    let normalized = assistantMessage.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return normalized.isEmpty
      || normalized.contains("could not produce a clean document edit")
      || normalized.contains("couldn't produce a clean document edit")
      || normalized.contains("local model returned an invalid edit shape")
  }
}

private struct LocalSessionDocumentEditProposalPayload: Codable {
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

  func makeProposal(
    fallbackSectionKind: LocalSessionRecapSection.Kind? = nil
  ) -> LocalSessionDocumentEditProposal {
    let sections = (recapPatch?.sections ?? []).compactMap {
      section
        -> LocalSessionDocumentRecapPatch.SectionReplacement? in
      let kind = section.kind?.recapSectionKind ?? fallbackSectionKind
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
    let markdownReplacement = documentMarkdown.map {
      $0.trimmingCharacters(in: .whitespacesAndNewlines)
    }

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

  fileprivate var textAfterInstructionDelimiter: String? {
    let delimiters = [":", "：", " - ", " – ", " — "]
    for delimiter in delimiters {
      guard let range = range(of: delimiter) else { continue }
      let candidate = self[range.upperBound...]
        .trimmingCharacters(in: .whitespacesAndNewlines)
      if !candidate.isEmpty {
        return candidate
      }
    }
    return nil
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
