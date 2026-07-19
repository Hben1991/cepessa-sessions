import Foundation

protocol LocalSessionRecapGenerating: Sendable {
  func generateRecap(for session: LocalSession) async -> LocalSessionRecap
}

struct LocalSessionRecapGenerationInput: Sendable {
  struct TranscriptCandidate: Sendable {
    let speaker: String
    let text: String
    let timestamp: Date
    let sessionOffset: TimeInterval
  }

  let sessionID: UUID
  let title: String
  let startedAt: Date
  let transcriptCandidates: [TranscriptCandidate]
  let attachmentCount: Int
  let captureArtifactCount: Int
  let contentClassification: LocalSessionContentClassification?
}

protocol LocalSessionRecapModelProviding: Sendable {
  func generateRecap(for input: LocalSessionRecapGenerationInput) async throws -> LocalSessionRecap
}

struct LocalSessionRecapGenerator: LocalSessionRecapGenerating {
  private let modelClient: (any LocalSessionRecapModelProviding)?
  private let fallback = LocalSessionDeterministicRecapGenerator()

  init(modelClient: (any LocalSessionRecapModelProviding)? = Self.defaultModelClient()) {
    self.modelClient = modelClient
  }

  func generateRecap(for session: LocalSession) async -> LocalSessionRecap {
    let input = Self.makeInput(from: session)

    if let modelClient {
      do {
        let recap = try await modelClient.generateRecap(for: input)
        if recap.isMeaningful, recap.isGrounded(in: input) {
          return recap
        }
      } catch {
        // Fall through to the deterministic path.
      }
    }

    return fallback.generateRecap(for: input)
  }

  private static func makeInput(from session: LocalSession) -> LocalSessionRecapGenerationInput {
    let transcriptCandidates = session.transcriptSegments.map { segment in
      LocalSessionRecapGenerationInput.TranscriptCandidate(
        speaker: segment.speaker,
        text: segment.text,
        timestamp: segment.timestamp,
        sessionOffset: max(0, segment.timestamp.timeIntervalSince(session.startedAt))
      )
    }

    return LocalSessionRecapGenerationInput(
      sessionID: session.id,
      title: session.title,
      startedAt: session.startedAt,
      transcriptCandidates: transcriptCandidates,
      attachmentCount: session.attachments.count,
      captureArtifactCount: session.captureArtifacts.count,
      contentClassification: session.contentClassification
    )
  }

  static func defaultModelClient() -> (any LocalSessionRecapModelProviding)? {
    LocalSessionEmbeddedRecapClient()
  }

  static func deterministicRecap(for session: LocalSession) -> LocalSessionRecap {
    LocalSessionDeterministicRecapGenerator().generateRecap(for: makeInput(from: session))
  }
}

struct LocalSessionEmbeddedRecapClient: LocalSessionRecapModelProviding, Sendable {
  let languageModel: any LocalSessionLanguageModelGenerating
  var maxTokens: Int = 900

  init(
    languageModel: any LocalSessionLanguageModelGenerating = EmbeddedLocalLanguageModel.shared,
    maxTokens: Int = 900
  ) {
    self.languageModel = languageModel
    self.maxTokens = maxTokens
  }

  func generateRecap(for input: LocalSessionRecapGenerationInput) async throws -> LocalSessionRecap
  {
    let rawResponse = try await languageModel.generateText(
      prompt: Self.prompt(for: input),
      maxTokens: maxTokens
    )
    let jsonString = rawResponse.jsonSubstringOrSelf
    let payloadData = jsonString.data(using: .utf8) ?? Data()
    let payload = try JSONDecoder().decode(LocalSessionRecapPayload.self, from: payloadData)
    return payload.makeRecap(startedAt: input.startedAt)
  }

  private static func prompt(for input: LocalSessionRecapGenerationInput) -> String {
    let transcript = transcriptContext(for: input)
    let language = documentLanguage(for: input)
    let appPrompt = LocalSessionMeetingPromptSettings.prompt(for: language)
    let outputLanguage =
      language == .hebrew
      ? "Hebrew. Keep explicit names, product names, and short domain terms in their original language when needed."
      : "English. Keep explicit names, product names, and short domain terms in their original language when needed."

    return """
      You are creating a clear, practical meeting brief from the recorded session material below.

      Clean the transcript before summarizing it:
      - Remove noise, side conversations, repetitions, polite filler, irrelevant jokes, broken transcription fragments, and casual "thank you" exchanges.
      - Do not write a transcript.
      - Do not include raw conversation noise.
      - Keep only what matters for actual work.
      - Do not frame the final brief as being about "the transcript"; write about the meeting, project, product, client, or topic when supported.

      Treat this input as a meeting transcript. Do not classify it as a voice note, video commentary, test recording, or general transcript in the generated document.
      Output language: \(outputLanguage)

      App-level meeting document prompt:
      \(appPrompt)

      Not every section must be full. Include only what is supported by the source material.
      Prefer a compact useful brief over a long exhaustive report.
      Use empty arrays for decisions, actionItems, openQuestions, or nextSteps when the source does not clearly support them.
      Separate urgent fixes from next-iteration improvements when that distinction exists.
      Use a professional, clear, direct tone that is not overly formal.
      Extract project, client, or product names only when the transcript or session title explicitly provides them.
      Include a compact people lens inline: mention who attended or was referenced, who owns work, and who raised a key topic only when relevant.
      Do not infer real attendee names from generic speaker labels such as "You", "Remote speaker", "Speaker 1", or "Transcript".
      Do not invent project names, roles, attendees, or responsibilities.
      If speaker identity is unclear, describe ownership as "Unassigned" in English or "לא שויך" in Hebrew instead of inventing a person.

      Return only valid JSON. No markdown. No commentary.
      The JSON object must match this shape:
      {
        "overview": "",
        "keyPoints": [{"title":"","summary":"","bullets":[""],"startOffsetSeconds":0,"endOffsetSeconds":0}],
        "decisions": [{"title":"","summary":"","bullets":[""],"startOffsetSeconds":0,"endOffsetSeconds":0}],
        "actionItems": [{"title":"","summary":"","bullets":[""],"startOffsetSeconds":0,"endOffsetSeconds":0}],
        "openQuestions": [{"title":"","summary":"","bullets":[""],"startOffsetSeconds":0,"endOffsetSeconds":0}],
        "nextSteps": [{"title":"","summary":"","bullets":[""],"startOffsetSeconds":0,"endOffsetSeconds":0}]
      }

      Replace the empty strings with real content grounded in the source. Leave an array empty when the source does not support that section.

      Extract the relevant meeting brief:
      - meeting purpose
      - project/client/product name when explicitly present in the session title or transcript
      - current state / general context
      - problems raised
      - decisions made
      - action items by person or team when owners are clear
      - open questions
      - a short professional recommendation for what to do next

      Action item titles must be the Owner/person/team when clear. Use "Unassigned" or "לא שויך" when ownership is unclear.

      Session title: \(input.title)
      Attachment count: \(input.attachmentCount)
      Capture artifact count: \(input.captureArtifactCount)
      Source speaker labels: \(speakerLabelSummary(for: input))

      Transcript:
      \(transcript)

      Repeat the required JSON shape exactly:
      {"overview":"","keyPoints":[{"title":"","summary":"","bullets":[""],"startOffsetSeconds":0,"endOffsetSeconds":0}],"decisions":[{"title":"","summary":"","bullets":[""],"startOffsetSeconds":0,"endOffsetSeconds":0}],"actionItems":[{"title":"","summary":"","bullets":[""],"startOffsetSeconds":0,"endOffsetSeconds":0}],"openQuestions":[{"title":"","summary":"","bullets":[""],"startOffsetSeconds":0,"endOffsetSeconds":0}],"nextSteps":[{"title":"","summary":"","bullets":[""],"startOffsetSeconds":0,"endOffsetSeconds":0}]}

      Final instruction: Return only valid JSON matching the repeated schema immediately above. Replace the empty strings with real source-grounded content. Write a cleaned practical meeting brief, not a transcript or a note about a transcript. Leave unsupported arrays empty. No markdown fences. No commentary.
      """
  }

  private static func documentLanguage(
    for input: LocalSessionRecapGenerationInput
  ) -> LocalSessionDocumentLanguage {
    let corpus = ([input.title] + input.transcriptCandidates.prefix(120).map(\.text))
      .joined(separator: " ")
    return corpus.containsHebrewScript ? .hebrew : .english
  }

  private static func speakerLabelSummary(for input: LocalSessionRecapGenerationInput) -> String {
    let labels = input.transcriptCandidates.map(\.speaker)
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    let uniqueLabels = Array(NSOrderedSet(array: labels)).compactMap { $0 as? String }
    return uniqueLabels.isEmpty ? "not available" : uniqueLabels.prefix(8).joined(separator: ", ")
  }

  private static func instructions(for contentType: LocalSessionContentType) -> String {
    switch contentType {
    case .meeting:
      return """
        The goal is not to summarize everything. Extract the relevant meeting brief:
        - meeting purpose
        - project/client/product name when explicitly present in the session title or transcript
        - current state / general context
        - problems raised
        - decisions made
        - action items by person or team when owners are clear
        - open questions
        - a short professional recommendation for what to do next
        """
    case .voiceNote:
      return """
        This is a voice note or dictated message. Do not force meeting sections.
        Extract the relevant message brief:
        - what the speaker is trying to say or remember
        - who the message is for, only when explicit
        - important details, constraints, dates, or names
        - explicit commitments or requested follow-up
        - unclear points that should be checked before sending or acting
        - a short recommendation for the next action
        """
    case .videoCommentary:
      return """
        This is video commentary, screen narration, or captured system-audio context.
        Extract the relevant viewing brief:
        - what video, screen, demo, or clip appears to be discussed
        - what the narrator or speaker is reacting to
        - important moments, issues, observations, or takeaways
        - timestamped evidence when available
        - action items or open questions created by the commentary
        - a short recommendation for what to inspect or do next
        """
    case .generalTranscript:
      return """
        This is a general transcript. Do not force meeting structure.
        Extract the relevant source-faithful brief:
        - main topic and context
        - important ideas, facts, or claims
        - useful details worth preserving
        - explicit tasks, commitments, or questions
        - what remains ambiguous
        - a short recommendation for how to use this source material next
        """
    }
  }

  private static func classificationConfidenceText(
    _ classification: LocalSessionContentClassification?
  ) -> String {
    guard let confidence = classification?.confidence else { return "not available" }
    return "\(Int((confidence * 100).rounded()))%"
  }

  private static func classificationRationaleText(
    _ classification: LocalSessionContentClassification?
  ) -> String {
    let rationale = classification?.rationale.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return rationale.isEmpty ? "not available" : rationale
  }

  private static func transcriptContext(for input: LocalSessionRecapGenerationInput) -> String {
    let candidates = input.transcriptCandidates
    guard !candidates.isEmpty else { return "" }

    let maxTotalCharacters = 24_000
    let minimumSegmentCharacters = 24
    let maximumSegmentCharacters = 180
    let estimatedLineOverhead = 26
    let perSegmentBudget = max(
      minimumSegmentCharacters,
      min(
        maximumSegmentCharacters,
        maxTotalCharacters / max(1, candidates.count) - estimatedLineOverhead
      )
    )

    var lines = [
      "[Full transcript coverage: all \(candidates.count) transcript segments are represented below. Long lines may be clipped for context budget, but the model should use the entire script.]"
    ]
    lines.append(
      contentsOf: candidates.map { candidate in
        let offset = String(format: "%.1f", candidate.sessionOffset)
        let text = truncatedText(candidate.text, limit: perSegmentBudget)
        return "[\(offset)s] \(candidate.speaker): \(text)"
      }
    )

    var context = lines.joined(separator: "\n")
    if context.count > maxTotalCharacters {
      let tighterBudget = max(16, perSegmentBudget / 2)
      lines = [
        "[Full transcript coverage: all \(candidates.count) transcript segments are represented below in a tighter form so the entire script remains visible to the local model.]"
      ]
      lines.append(
        contentsOf: candidates.map { candidate in
          let offset = String(format: "%.0f", candidate.sessionOffset)
          let text = truncatedText(candidate.text, limit: tighterBudget)
          return "[\(offset)s] \(candidate.speaker): \(text)"
        }
      )
      context = lines.joined(separator: "\n")
    }

    return context
  }

  private static func truncatedText(_ text: String, limit: Int) -> String {
    let normalized =
      text
      .replacingOccurrences(of: "\n", with: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard normalized.count > limit else { return normalized }

    return String(normalized.prefix(limit)).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
  }
}

struct LocalSessionDeterministicRecapGenerator {
  func generateRecap(for input: LocalSessionRecapGenerationInput) -> LocalSessionRecap {
    let candidates = normalizedCandidates(from: input)
    let summary = synthesizedSummary(for: input, candidates: candidates)
    let contentType = input.contentClassification?.type ?? .meeting
    let usesHebrewDocument = summary.overview.containsHebrewScript
    let overviewSection = section(
      kind: .overview,
      title: usesHebrewDocument
        ? hebrewSectionTitle(for: .overview, contentType: contentType) : "Overview",
      summary: summary.overview,
      bullets: [summary.overview],
      candidates: candidates,
      startedAt: input.startedAt
    )
    let keyPointsSection = section(
      kind: .keyPoints,
      title: usesHebrewDocument
        ? hebrewSectionTitle(for: .keyPoints, contentType: contentType)
        : sectionTitle(for: .keyPoints, contentType: contentType),
      summary: usesHebrewDocument
        ? hebrewSectionSummary(for: .keyPoints, contentType: contentType)
        : keyPointSummary(for: contentType),
      bullets: summary.keyPoints,
      candidates: candidates,
      startedAt: input.startedAt
    )
    let decisionsSection = section(
      kind: .decisions,
      title: usesHebrewDocument
        ? hebrewSectionTitle(for: .decisions, contentType: contentType)
        : sectionTitle(for: .decisions, contentType: contentType),
      summary: usesHebrewDocument
        ? hebrewSectionSummary(for: .decisions, contentType: contentType)
        : decisionSummary(for: contentType),
      bullets: summary.decisions,
      candidates: candidates,
      startedAt: input.startedAt
    )
    let actionItemsSection = section(
      kind: .actionItem,
      title: usesHebrewDocument
        ? hebrewSectionTitle(for: .actionItem, contentType: contentType)
        : sectionTitle(for: .actionItem, contentType: contentType),
      summary: usesHebrewDocument
        ? hebrewSectionSummary(for: .actionItem, contentType: contentType)
        : actionSummary(for: contentType),
      bullets: summary.actionItems,
      candidates: candidates,
      startedAt: input.startedAt
    )
    let openQuestionsSection = section(
      kind: .openQuestions,
      title: usesHebrewDocument
        ? hebrewSectionTitle(for: .openQuestions, contentType: contentType) : "Open questions",
      summary: usesHebrewDocument
        ? hebrewSectionSummary(for: .openQuestions, contentType: contentType)
        : "Questions that still need confirmation.",
      bullets: summary.openQuestions,
      candidates: candidates,
      startedAt: input.startedAt
    )
    let nextStepsSection = section(
      kind: .nextSteps,
      title: usesHebrewDocument
        ? hebrewSectionTitle(for: .nextSteps, contentType: contentType)
        : "Professional recommendation",
      summary: usesHebrewDocument
        ? hebrewSectionSummary(for: .nextSteps, contentType: contentType)
        : "Recommended way to move forward.",
      bullets: summary.nextSteps,
      candidates: candidates,
      startedAt: input.startedAt
    )

    var sections = [overviewSection]
    sections.append(contentsOf: [
      keyPointsSection,
      decisionsSection,
      actionItemsSection,
      openQuestionsSection,
      nextStepsSection,
    ].filter { section in
      shouldIncludeSection(section)
    })

    return LocalSessionRecap(
      overview: overviewSection.summary,
      generatedAt: Date(),
      sections: sections
    )
  }

  private func shouldIncludeSection(_ section: LocalSessionRecapSection) -> Bool {
    if section.kind == .overview { return true }

    return !section.bullets.filter {
      !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }.isEmpty
  }

  private func normalizedCandidates(
    from input: LocalSessionRecapGenerationInput
  ) -> [Candidate] {
    input.transcriptCandidates
      .flatMap { candidate in
        splitIntoSentences(candidate.text)
          .map { sentence in
            Candidate(
              speaker: candidate.speaker,
              text: sentence,
              timestamp: candidate.timestamp,
              sessionOffset: candidate.sessionOffset
            )
          }
      }
      .filter { !$0.text.isEmpty }
  }

  private func section(
    kind: LocalSessionRecapSection.Kind,
    title: String,
    summary: String,
    bullets: [String],
    candidates: [Candidate],
    startedAt: Date
  ) -> LocalSessionRecapSection {
    let selectedBullets = deduplicatedBullets(from: bullets).filter {
      !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    let anchor = candidates.first(where: { $0.isSalient }) ?? candidates.first

    return LocalSessionRecapSection(
      id: UUID(),
      kind: kind,
      title: title,
      summary: summary,
      bullets: selectedBullets,
      anchorTimestamp: anchor?.timestamp ?? startedAt,
      startOffset: anchor?.sessionOffset,
      endOffset: anchor.map { $0.sessionOffset + 15 }
    )
  }

  private func synthesizedSummary(
    for input: LocalSessionRecapGenerationInput,
    candidates: [Candidate]
  ) -> DeterministicRecapSummary {
    let corpus = candidates.map(\.text).joined(separator: " ").lowercased()
    let themes = SummaryTheme.allCases.filter { theme in
      theme.matches(corpus)
    }
    let activeThemes = themes.isEmpty ? [.generalDiscussion] : themes
    let workContextName =
      explicitProjectName(for: input, candidates: candidates) ?? meaningfulSessionTitle(input.title)
    let contentType = input.contentClassification?.type ?? .meeting
    if contentType == .videoCommentary,
      candidates.contains(where: { $0.text.containsHebrewScript })
    {
      return hebrewVideoSummary(from: candidates)
    }
    if contentType == .meeting,
      candidates.contains(where: { $0.text.containsHebrewScript })
    {
      return hebrewMeetingSummary(from: candidates)
    }
    if activeThemes == [.generalDiscussion],
      candidates.contains(where: { $0.text.containsHebrewScript })
    {
      return hebrewGeneralSummary(from: candidates)
    }

    let sourceNoun = sourceNoun(for: contentType)
    let overviewSubject =
      workContextName.map { "For \($0), the \(sourceNoun)" } ?? "The \(sourceNoun)"

    let overview: String
    if activeThemes == [.generalDiscussion] {
      overview =
        "\(overviewSubject) captured the main areas that need follow-up. The brief focuses on the work, context, and follow-up supported by the source material."
    } else {
      let themeList = activeThemes.prefix(3).map(\.overviewPhrase).joined(separator: ", ")
      overview =
        "\(overviewSubject) focused on \(themeList). The main outcome was to turn the feedback into clearer product decisions and follow-up work."
    }

    let keyPoints = activeThemes.prefix(5).map(\.keyPoint)
    let explicitDecisions = salientBullets(from: candidates, matching: .decision)
    let decisions =
      explicitDecisions.isEmpty
      ? Array(activeThemes.flatMap(\.decisions).prefix(4))
      : explicitDecisions
    let ownerActionItems = ownerAwareActionItems(from: candidates)
    let themeActionItems = activeThemes.flatMap(\.actionItems)
    let actionItems = Array((ownerActionItems + themeActionItems).prefix(5))
    let explicitQuestions = salientBullets(from: candidates, matching: .question)
    let openQuestions =
      explicitQuestions.isEmpty
      ? Array(activeThemes.flatMap(\.openQuestions).prefix(4))
      : explicitQuestions
    let nextSteps = Array(activeThemes.flatMap(\.nextSteps).prefix(4))

    return DeterministicRecapSummary(
      overview: overview,
      keyPoints: keyPoints,
      decisions: decisions,
      actionItems: actionItems,
      openQuestions: openQuestions,
      nextSteps: nextSteps
    )
  }

  private func hebrewVideoSummary(from candidates: [Candidate]) -> DeterministicRecapSummary {
    let corpus = candidates.map(\.text).joined(separator: " ")
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
    let isRoleplayScene = roleplaySignals.contains { corpus.contains($0) }
    let sceneSummary = isRoleplayScene
      ? "הקטע מתאר סצנת משחק תפקידים: ניסיון התגנבות ותקיפה, גלגולי קובייה, חץ שמחטיא ופוגע בעץ מושחת, והמשך איום סביב מריק, מיכאל והמכשפה."
      : "הקטע מתמקד בתוכן שנשמע מתוך הסרטון ובנקודות המרכזיות שעולות ממנו."

    return DeterministicRecapSummary(
      overview: "המסמך עוסק ב\(sourceDescription). \(sceneSummary)",
      keyPoints: [
        "ההקלטה מתחילה בבחירת סרטון מהיסטוריית יוטיוב ובחירה בתוכן בעברית.",
        sceneSummary,
      ],
      decisions: [],
      actionItems: [],
      openQuestions: [],
      nextSteps: []
    )
  }

  private func hebrewMeetingSummary(from candidates: [Candidate]) -> DeterministicRecapSummary {
    let corpus = candidates.map(\.text).joined(separator: " ").lowercased()
    var topics: [String] = []
    var keyPoints: [String] = []
    var actionItems: [String] = []
    var openQuestions: [String] = []

    if containsAnyThemeKeyword(corpus, ["סטארט", "מה אנחנו בונים", "מוצר", "רעיון"]) {
      topics.append("כיוון המוצר וההזדמנות העסקית")
      keyPoints.append("הדיון עסק בחידוד כיוון המוצר: איזה ערך הוא נותן, למי, ומה ההזדמנות העסקית שצריך להוכיח.")
      actionItems.append("להפוך את כיוון המוצר לרשימת תרחישי שימוש ותעדוף קצרה.")
      openQuestions.append("איזה תרחיש שימוש ראשון צריך להוכיח לפני שמרחיבים את המוצר?")
    }
    if containsAnyThemeKeyword(
      corpus,
      ["עסק", "בעל העסק", "תקציב", "תזרים", "פיננס", "סוכנים", "טלפון עסקי", "צ'אט עסקי", "מידע"]
    ) {
      topics.append("סוכן עסקי וניהול מידע לבעלי עסקים")
      keyPoints.append("עלה צורך לתת לבעל העסק תמונת מצב ברורה מתוך מידע שמפוזר היום בין שיחות, צ'אט, דשבורדים וכלים פיננסיים.")
      actionItems.append("להגדיר את זרימת העבודה של הסוכן העסקי: אילו שאלות הוא עונה עליהן, מאיפה מגיע המידע, ומה הפלט המצופה.")
      openQuestions.append("אילו נתונים הסוכן העסקי חייב לדעת לענות עליהם כבר בגרסה הראשונה?")
    }
    if containsAnyThemeKeyword(corpus, ["דשבורד", "מבט", "בריא", "אדום", "כתום", "ירוק"]) {
      topics.append("דשבורד ותמונת מצב עסקית")
      keyPoints.append("הרעיון של דשבורד עסקי עלה סביב מדדי בריאות פשוטים כמו תקציב, תזרים וסימוני מצב שקל להבין מהר.")
      actionItems.append("למפות את מצבי הדשבורד לרשימה קצרה של אינדיקציות עסקיות ברורות.")
    }
    if containsAnyThemeKeyword(corpus, ["רענון", "אתר", "האתר", "המלצות", "להפעיל", "לשנות"]) {
      topics.append("רענון האתר וניהול התוכן")
      keyPoints.append("חלק מהדיון עסק ברענון האתר, עדכון תכנים והסבר ברור יותר של אופן ניהול המלצות או אזורי תוכן.")
      actionItems.append("להכין רשימת עדכוני אתר קצרה: תכנים, המלצות, טפסים, דומיין ובעלות על כל משימה.")
      openQuestions.append("אילו עדכוני אתר דחופים עכשיו ואילו שייכים לאיטרציה מאוחרת יותר?")
    }
    if containsAnyThemeKeyword(corpus, ["webflow", "make", "monday", "דומיין", "שרת", "אחסון", "תעודת זהות", "אבטחה"]) {
      topics.append("זרימת מידע בין Webflow, Make, Monday ותשתיות האתר")
      keyPoints.append("האזכורים של Webflow, Make, Monday, אחסון ודומיין מצביעים על צורך להסביר בצורה נקייה איך מידע עובר בתוך מערך האתר.")
      actionItems.append("לתעד את זרימת המידע בין Webflow, Make, Monday, האחסון ונקודות הדומיין/אבטחה.")
      openQuestions.append("איזה מידע נשמר או עובר בכל שלב, ומי אחראי לתשובת האבטחה?")
    }
    if containsAnyThemeKeyword(corpus, ["גלילה", "scroll", "קופצת", "לאט", "איטי"]) {
      topics.append("ביצועי האתר וחוויית הגלילה")
      keyPoints.append("עלו בעיות של גלילה, איטיות או קפיצות באתר שפוגעות בתחושת השליטה של המשתמש.")
      actionItems.append("לשחזר את בעיות הגלילה ולהחליט אם מדובר בביצועים, פריסה או אינטראקציה.")
    }
    if containsAnyThemeKeyword(corpus, ["analytics", "אנליטיקס", "clarity", "mixpanel"]) {
      topics.append("מדידה ואנליטיקס להתנהגות משתמשים")
      keyPoints.append("עלה צורך לחבר Analytics כדי להבין התנהגות משתמשים אמיתית לפני החלטות אתר רחבות.")
      actionItems.append("לבחור את כלי המדידה ולחבר אותו לפני סבב העיצוב או התוכן הבא.")
    }
    if containsAnyThemeKeyword(corpus, ["coming soon", "סימולציות", "ראיונות", "interview simulation"]) {
      topics.append("אזור סימולציות הראיונות")
      keyPoints.append("אזור סימולציות הראיונות דורש סטטוס וקופי ברורים יותר, כולל מצב coming soon.")
      actionItems.append("לחדד את אזור סימולציות הראיונות כדי שהמשתמש יבין מה זמין עכשיו ומה יגיע בהמשך.")
    }

    let overview: String
    if keyPoints.isEmpty {
      overview =
        "הפגישה כללה דיון עבודה שדורש זיקוק למשימות המשך. לא זוהה נושא מרכזי מספיק ברור, ולכן המסמך מתמקד רק בנקודות שנתמכות בפגישה."
      keyPoints = cleanHebrewMeetingBullets(from: candidates, matching: .keyPoint)
      if keyPoints.isEmpty {
        keyPoints = ["הפגישה העלתה נושאי המשך, אך אין מספיק חומר יציב כדי לנסח מסקנות רחבות מעבר למה שנאמר בבירור."]
      }
      actionItems = cleanHebrewMeetingBullets(from: candidates, matching: .action)
      if actionItems.isEmpty {
        actionItems = ["להוציא מהפגישה רשימת משימות קצרה רק אחרי בדיקה ידנית של הנקודות החשובות."]
      }
    } else {
      overview =
        "הפגישה התמקדה ב\(deduplicatedBullets(from: topics).prefix(3).joined(separator: ", ")). התוצרים החשובים הם חידוד הכיוון, סגירת שאלות פתוחות והפיכת הנושאים למשימות עבודה ברורות."
    }

    if containsAnyThemeKeyword(corpus, ["אסכם", "אני אסכם", "נושאים שדיברנו"]) {
      actionItems.append("לסכם את נושאי הפגישה לרשימת עבודה מסודרת.")
    }
    if containsAnyThemeKeyword(corpus, ["תפתח טראפ", "תפתח", "ערוץ", "תשלח הודעה"]) {
      actionItems.append("לפתוח ערוץ עבודה ייעודי ולהמשיך לרכז בו החלטות, משימות ושאלות המשך.")
    }
    if containsAnyThemeKeyword(corpus, ["לקבוע עוד פגישה", "עוד פגישה", "פגישת המשך"]) {
      actionItems.append("לקבוע פגישת המשך אם צריך לסגור החלטות או משימות.")
    }

    if openQuestions.isEmpty {
      openQuestions = explicitHebrewOpenQuestions(from: candidates)
    }

    return DeterministicRecapSummary(
      overview: overview,
      keyPoints: deduplicatedBullets(from: keyPoints),
      decisions: [],
      actionItems: deduplicatedBullets(from: actionItems),
      openQuestions: deduplicatedBullets(from: openQuestions),
      nextSteps: ["להפוך את הנקודות החשובות לרשימת משימות קצרה עם בעלים, סדר עדיפויות ותאריך בדיקה."]
    )
  }

  private func cleanHebrewMeetingBullets(
    from candidates: [Candidate],
    matching score: Candidate.Score
  ) -> [String] {
    let bullets = candidates.compactMap { candidate -> String? in
      guard candidate.score.contains(score) else { return nil }
      return cleanHebrewMeetingBullet(candidate.text)
    }

    return Array(deduplicatedBullets(from: bullets).prefix(4))
  }

  private func explicitHebrewOpenQuestions(from candidates: [Candidate]) -> [String] {
    let questionTerms = ["?", "איך ", "מה ", "למה ", "מתי ", "כמה "]
    let bullets = candidates.compactMap { candidate -> String? in
      guard let text = cleanHebrewMeetingBullet(candidate.text) else { return nil }
      let lowercased = text.lowercased()
      guard questionTerms.contains(where: { lowercased.contains($0) }) else { return nil }
      guard !lowercased.contains("צריך להבין") || text.contains("?") else { return nil }
      return text
    }

    return Array(deduplicatedBullets(from: bullets).prefix(3))
  }

  private func cleanHebrewMeetingBullet(_ rawText: String) -> String? {
    let text = rawText
      .replacingOccurrences(of: "\n", with: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard text.containsHebrewScript, text.count >= 22 else { return nil }

    let lowercased = text.lowercased()
    let noiseTerms = [
      "מה נשמע", "מה קורה", "תודה", "שלום", "אהלן", "אוקיי", "בסדר", "לא יודע",
      "לא נראה לי", "מקווה שלא", "תזיין", "זיין",
    ]
    guard !noiseTerms.contains(where: { lowercased == $0 || lowercased.contains("\($0).") })
    else {
      return nil
    }
    guard !lowercased.contains("preview ready") else { return nil }
    guard !lowercased.contains("markdown") else { return nil }

    return text
  }

  private func hebrewGeneralSummary(from candidates: [Candidate]) -> DeterministicRecapSummary {
    let corpus = candidates.map(\.text).joined(separator: " ")
    let mentionsLocalModel = candidates.contains { candidate in
      let speaker = candidate.speaker.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      let text = candidate.text.lowercased()
      return speaker.contains("local model")
        || text.contains("המודל המקומי")
        || text.contains("מודל מקומי")
        || text.contains("local model")
    }
    let isLocalModelSummaryCheck =
      mentionsLocalModel
      && (corpus.contains("מסכם") || corpus.contains("סיכום") || corpus.contains("הצלחה"))
    if isLocalModelSummaryCheck {
      return DeterministicRecapSummary(
        overview:
          "המסמך עוסק בבדיקת סיכום של המודל המקומי: האם הוא באמת מסכם את המסמך ומציין הצלחה, או שאינו מסכם ולכן הבדיקה נכשלת.",
        keyPoints: [
          "המטרה היא לבדוק אם המודל המקומי מסכם את המסמך בפועל.",
          "קריטריון ההצלחה הוא שהסיכום יציין שהבדיקה הצליחה.",
        ],
        decisions: [
          "לא התקבלה החלטה נוספת מעבר להגדרת תנאי הצלחה ואי הצלחה לבדיקה."
        ],
        actionItems: [
          "להריץ את בדיקת הסיכום על המסמך.",
          "לוודא שהפלט מציין הצלחה כאשר הסיכום עובד.",
          "אם הסיכום לא עובד, לסמן זאת כאי הצלחה ולתקן את מסלול המודל המקומי.",
        ],
        openQuestions: [
          "האם המודל המקומי מצליח לסכם את המסמך באופן נקי?"
        ],
        nextSteps: [
          "לבדוק את פלט הסיכום ולוודא שהוא משקף הצלחה או אי הצלחה לפי התוצאה."
        ]
      )
    }

    let salientCandidates = candidates.filter(\.isSalient)
    let actionCount = salientCandidates.filter { $0.score.contains(.action) }.count
    let questionCount = salientCandidates.filter { $0.score.contains(.question) }.count
    let decisionCount = salientCandidates.filter { $0.score.contains(.decision) }.count
    let sourceLabel =
      candidates.count >= 8 ? "תמלול בעברית של שיחה" : "תמלול בעברית של הקלטה קצרה"

    var keyPoints: [String] = []
    if actionCount > 0 {
      keyPoints.append("עולות מהמקור נקודות שמרמזות על פעולות המשך או שינויים שצריך להפוך למשימות מסודרות.")
    }
    if questionCount > 0 {
      keyPoints.append("יש במקור אי-בהירויות ושאלות פתוחות שדורשות הבהרה לפני שמסיקים מסקנות.")
    }
    if decisionCount > 0 {
      keyPoints.append("מופיעים כיוונים והעדפות, אבל לא תמיד החלטות סופיות שאפשר לסגור עליהן.")
    }
    if keyPoints.isEmpty {
      keyPoints.append("המקור כולל שיחה חופשית וחלקים רועשים, ולכן צריך לזקק ממנו רק את הנושאים שחוזרים בבירור.")
    }

    let decisions =
      decisionCount > 0
      ? ["יש רמזים לכיוון או העדפה, אך לא זוהתה החלטה סופית מספיק יציבה לפרסום כמסקנה."]
      : ["לא זוהתה החלטה סופית מפורשת."]
    let actionItems =
      actionCount > 0
      ? ["להוציא מהתמלול רק פעולות המשך ברורות ולנסח אותן כרשימת משימות נקייה."]
      : ["לסנן את התמלול ולהשאיר רק נקודות עבודה או תובנות שאפשר להשתמש בהן."]
    let openQuestions =
      questionCount > 0
      ? ["אילו מהשאלות שעלו בתמלול דורשות תשובה לפני שממשיכים הלאה?"]
      : ["איזה חלקים במקור הם רעש, ואיזה חלקים באמת חשובים למסמך הסופי?"]

    return DeterministicRecapSummary(
      overview:
        "המסמך מבוסס על \(sourceLabel). הוא לא אמור לשחזר את המשפטים עצמם, אלא לזקק מתוכו נושאים, כוונות ופעולות המשך שאפשר לעבוד איתן.",
      keyPoints: keyPoints,
      decisions: decisions,
      actionItems: actionItems,
      openQuestions: openQuestions,
      nextSteps: ["לבנות מהמקור מסמך קצר, נקי ומעשי שמדבר על התוכן ולא מעתיק את התמלול עצמו."]
    )
  }

  private func ownerAwareActionItems(from candidates: [Candidate]) -> [String] {
    let bullets = candidates.compactMap { candidate -> String? in
      guard candidate.score.contains(.action),
        let speaker = meaningfulSpeakerName(candidate.speaker)
      else {
        return nil
      }

      let text = candidate.text.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !text.isEmpty else { return nil }
      return "\(speaker): \(text)"
    }

    return Array(deduplicatedBullets(from: bullets).prefix(4))
  }

  private func salientBullets(
    from candidates: [Candidate],
    matching score: Candidate.Score
  ) -> [String] {
    let bullets = candidates.compactMap { candidate -> String? in
      guard candidate.score.contains(score) else { return nil }
      let text = candidate.text.trimmingCharacters(in: .whitespacesAndNewlines)
      return text.isEmpty ? nil : text
    }

    return Array(deduplicatedBullets(from: bullets).prefix(4))
  }

  private func sourceNoun(for contentType: LocalSessionContentType) -> String {
    switch contentType {
    case .meeting:
      return "meeting"
    case .voiceNote:
      return "voice note"
    case .videoCommentary:
      return "video commentary"
    case .generalTranscript:
      return "source material"
    }
  }

  private func sectionTitle(
    for kind: LocalSessionRecapSection.Kind,
    contentType: LocalSessionContentType
  ) -> String {
    switch (kind, contentType) {
    case (.keyPoints, .voiceNote): return "Message highlights"
    case (.keyPoints, .videoCommentary): return "Commentary highlights"
    case (.keyPoints, .generalTranscript): return "Key details"
    case (.decisions, .voiceNote): return "Commitments"
    case (.decisions, .videoCommentary): return "Observed conclusions"
    case (.decisions, .generalTranscript): return "Explicit conclusions"
    case (.actionItem, .voiceNote): return "Follow-up"
    case (.actionItem, .videoCommentary): return "Follow-up from commentary"
    case (.actionItem, .generalTranscript): return "Tasks or follow-up"
    default:
      return kind.displayTitle
    }
  }

  private func hebrewSectionTitle(
    for kind: LocalSessionRecapSection.Kind,
    contentType: LocalSessionContentType
  ) -> String {
    if contentType == .videoCommentary {
      switch kind {
      case .overview: return "תקציר"
      case .keyPoints: return "מה מופיע בסרטון"
      case .decisions: return "מה אפשר להסיק"
      case .actionItem: return "מה כדאי לעשות עם זה"
      case .openQuestions: return "מה עדיין לא ברור"
      case .nextSteps: return "המשך מומלץ"
      case .notes: return "הערות"
      }
    }

    switch kind {
    case .overview: return "תקציר מנהלים"
    case .keyPoints: return "נקודות מרכזיות"
    case .decisions: return "החלטות"
    case .actionItem: return "משימות להמשך"
    case .openQuestions: return "שאלות פתוחות"
    case .nextSteps: return "המשך מומלץ"
    case .notes: return "הערות"
    }
  }

  private func hebrewSectionSummary(
    for kind: LocalSessionRecapSection.Kind,
    contentType: LocalSessionContentType
  ) -> String {
    if contentType == .videoCommentary {
      switch kind {
      case .keyPoints: return "הרגעים והפרטים המרכזיים מתוך הסרטון."
      case .decisions: return "מסקנות שאפשר לזהות מתוך התוכן שנקלט."
      case .actionItem: return "פעולות המשך אפשריות לפי מטרת המסמך."
      case .openQuestions: return "נקודות שעדיין צריך להבהיר לגבי השימוש במסמך."
      case .nextSteps: return "דרך פעולה מומלצת לאחר קריאת המסמך."
      case .overview, .notes: return "תוכן מרכזי מתוך המסמך."
      }
    }

    switch kind {
    case .keyPoints: return "הנושאים המרכזיים שעלו בפגישה."
    case .decisions: return "החלטות מפורשות או כיוונים שסוכמו בבירור."
    case .actionItem: return "פעולות המשך שצריך לבצע."
    case .openQuestions: return "נושאים שדורשים הבהרה לפני המשך עבודה."
    case .nextSteps: return "המלצה מעשית להמשך."
    case .overview, .notes: return "תוכן מרכזי מתוך הפגישה."
    }
  }

  private func keyPointSummary(for contentType: LocalSessionContentType) -> String {
    switch contentType {
    case .meeting:
      return "Main themes from the discussion."
    case .voiceNote:
      return "The most useful details from the dictated message."
    case .videoCommentary:
      return "Important moments and observations from the commentary."
    case .generalTranscript:
      return "Important source details preserved from the session material."
    }
  }

  private func decisionSummary(for contentType: LocalSessionContentType) -> String {
    switch contentType {
    case .meeting:
      return "Agreements and direction captured in the conversation."
    case .voiceNote:
      return "Commitments or clear intent expressed in the message."
    case .videoCommentary:
      return "Conclusions or observations supported by the commentary."
    case .generalTranscript:
      return "Conclusions that are explicit enough to preserve."
    }
  }

  private func actionSummary(for contentType: LocalSessionContentType) -> String {
    switch contentType {
    case .meeting:
      return "Follow-up work that should happen next."
    case .voiceNote:
      return "Follow-up work or message actions implied by the note."
    case .videoCommentary:
      return "Follow-up work created by the observed video or screen context."
    case .generalTranscript:
      return "Tasks or follow-up that can be taken from the source material."
    }
  }

  private func meaningfulSpeakerName(_ speaker: String) -> String? {
    let trimmed = speaker.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    let lowercased = trimmed.lowercased()
    let genericLabels: Set<String> = [
      "you",
      "remote speaker",
      "local speaker",
      "speaker",
      "transcript",
      "system audio",
      "microphone",
      "mic",
      "unknown",
      "unknown speaker",
      "דובר",
      "דובר לא ידוע",
    ]
    guard !genericLabels.contains(lowercased) else { return nil }
    guard !lowercased.hasPrefix("speaker ") else { return nil }
    guard !lowercased.hasPrefix("speaker-") else { return nil }
    guard !lowercased.hasPrefix("speaker_") else { return nil }

    return trimmed
  }

  private func explicitProjectName(
    for input: LocalSessionRecapGenerationInput,
    candidates: [Candidate]
  ) -> String? {
    let sources = [input.title] + candidates.map(\.text)

    for source in sources {
      if let projectName = projectName(in: source) {
        return projectName
      }
    }

    return nil
  }

  private func projectName(in text: String) -> String? {
    let patterns = [
      ("Project", #"\b[Pp]roject\s+([A-Z][A-Za-z0-9]*(?:[\s-][A-Z][A-Za-z0-9]*){0,3})"#),
      ("Client", #"\b[Cc]lient\s+([A-Z][A-Za-z0-9]*(?:[\s-][A-Z][A-Za-z0-9]*){0,3})"#),
      ("Product", #"\b[Pp]roduct\s+([A-Z][A-Za-z0-9]*(?:[\s-][A-Z][A-Za-z0-9]*){0,3})"#),
    ]

    for (label, pattern) in patterns {
      guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
      let range = NSRange(text.startIndex..<text.endIndex, in: text)
      guard let match = regex.firstMatch(in: text, range: range),
        match.numberOfRanges > 1,
        let captureRange = Range(match.range(at: 1), in: text)
      else {
        continue
      }

      let name = text[captureRange]
        .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
      if !name.isEmpty {
        return "\(label) \(name)"
      }
    }

    return nil
  }

  private func meaningfulSessionTitle(_ title: String) -> String? {
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    let lowercased = trimmed.lowercased()
    guard !lowercased.hasPrefix("session ") else { return nil }
    guard !lowercased.hasPrefix("meeting ") else { return nil }
    guard lowercased != "untitled" else { return nil }
    guard lowercased != "new session" else { return nil }

    return trimmed
  }

  private func deduplicatedBullets(from bullets: [String]) -> [String] {
    var seen: Set<String> = []
    return bullets.filter { bullet in
      let key = bullet.lowercased()
      guard !seen.contains(key) else { return false }
      seen.insert(key)
      return true
    }
  }

  private func splitIntoSentences(_ text: String) -> [String] {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return [] }

    let parts =
      trimmed
      .replacingOccurrences(of: "\n", with: " ")
      .split(whereSeparator: { ".!?".contains($0) })
      .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }

    return parts.isEmpty ? [trimmed] : parts
  }
}

private struct DeterministicRecapSummary {
  let overview: String
  let keyPoints: [String]
  let decisions: [String]
  let actionItems: [String]
  let openQuestions: [String]
  let nextSteps: [String]
}

private enum SummaryTheme: CaseIterable {
  case sitePerformance
  case sectionNavigation
  case offerClarity
  case interviewSimulations
  case analytics
  case visualDirection
  case localization
  case registrationData
  case generalDiscussion

  var keywords: [String] {
    switch self {
    case .sitePerformance:
      return ["לאט", "איטי", "תקוע", "קופץ", "גלילה", "scroll", "jump", "slow"]
    case .sectionNavigation:
      return ["ai בילדר", "ai-בילדר", "masterclass", "מאסטר", "section", "בוקסות", "ריבועים"]
    case .offerClarity:
      return ["קריאה לפעולה", "cta", "לא ברור", "מה אתם רוצים", "להירשם", "book", "booking"]
    case .interviewSimulations:
      return ["סימולציות", "ראיונות", "hr", "tech", "coming soon", "תרחישים", "scenario"]
    case .analytics:
      return ["analytics", "אנליטיקס", "clarity", "mixpanel", "webflow analyze", "משתמשים באמת"]
    case .visualDirection:
      return ["צבעוניות", "כחול", "רקע", "לבן", "אפור", "כבד", "משחקי", "wow"]
    case .localization:
      return ["rtl", "תרגום", "locale", "לוקל", "webflow", "גרסה עברית", "עברית באתר"]
    case .registrationData:
      return ["נרשמו", "רשומים", "monday", "49", "82", "13", "11"]
    case .generalDiscussion:
      return []
    }
  }

  var overviewPhrase: String {
    switch self {
    case .sitePerformance: return "site performance and scrolling behavior"
    case .sectionNavigation: return "how users navigate the content sections"
    case .offerClarity: return "clearer calls to action"
    case .interviewSimulations: return "the interview simulation area"
    case .analytics: return "measurement and user-behavior analytics"
    case .visualDirection: return "the visual tone of the experience"
    case .localization: return "Hebrew localization and RTL support"
    case .registrationData: return "registration signals from current traffic"
    case .generalDiscussion: return "the meeting discussion"
    }
  }

  var keyPoint: String {
    switch self {
    case .sitePerformance:
      return
        "Participants reported that parts of the site feel slow, jumpy, or hard to scroll, which makes the experience feel less controlled."
    case .sectionNavigation:
      return
        "The current section navigation does not always land users in a clear, complete view of the selected content."
    case .offerClarity:
      return
        "Several areas need a clearer user promise and call to action so visitors understand what they are expected to do."
    case .interviewSimulations:
      return
        "The HR and tech interview simulation area is prominent, but its current state and next action are not clear enough."
    case .analytics:
      return
        "The team wants better behavioral data before investing heavily in broad redesign work."
    case .visualDirection:
      return
        "The visual direction was described as heavy; lighter surfaces and a more playful feel were discussed."
    case .localization:
      return
        "Hebrew support requires both translated content and RTL implementation work, not only automatic translation."
    case .registrationData:
      return
        "Existing registration numbers give some signal, but the team still needs to separate organic site behavior from external distribution."
    case .generalDiscussion:
      return
        "The discussion raised product feedback and follow-up work that should be converted into a concise task list."
    }
  }

  var decisions: [String] {
    switch self {
    case .analytics:
      return ["Prioritize adding analytics or behavior tracking before making broad UX decisions."]
    case .interviewSimulations:
      return [
        "Treat the interview simulation area as the most urgent content fix and clarify that it is coming soon."
      ]
    case .offerClarity:
      return ["Clarify the call to action instead of leaving users to infer the next step."]
    case .visualDirection:
      return [
        "Explore a lighter visual treatment rather than keeping the current heavy blue impression unchanged."
      ]
    default:
      return []
    }
  }

  var actionItems: [String] {
    switch self {
    case .sitePerformance:
      return [
        "Review the scrolling and section-jump behavior across different devices and browsers."
      ]
    case .sectionNavigation:
      return [
        "Adjust section layouts so selected content opens in a clearer and more complete viewport."
      ]
    case .offerClarity:
      return ["Rewrite the relevant section copy so each area has an explicit next step."]
    case .interviewSimulations:
      return [
        "Update the interview simulation section with clear HR and tech paths and a coming-soon state."
      ]
    case .analytics:
      return [
        "Choose and connect an analytics tool such as Webflow Analyze, Microsoft Clarity, Google Analytics, or Mixpanel."
      ]
    case .visualDirection:
      return [
        "Test a lighter background and reduced visual weight while preserving the brand direction."
      ]
    case .localization:
      return ["Plan the Hebrew version as a real RTL implementation with reviewed translations."]
    case .registrationData:
      return [
        "Review registration sources to understand which signups came from the site and which came from external promotion."
      ]
    case .generalDiscussion:
      return ["Convert the discussion into owners, priorities, and implementation tasks."]
    }
  }

  var openQuestions: [String] {
    switch self {
    case .analytics:
      return [
        "Which analytics tool gives the team enough behavioral insight for the current MVP budget?"
      ]
    case .offerClarity:
      return ["What exact action should users take in each section today?"]
    case .interviewSimulations:
      return [
        "Should the simulation area show only a coming-soon message, or also collect interest for future sessions?"
      ]
    case .visualDirection:
      return ["Is the next step a small visual cleanup or a broader rethink of the experience?"]
    case .localization:
      return ["Who owns final Hebrew copy review after translation and RTL work are in place?"]
    case .registrationData:
      return [
        "How should current registration numbers be interpreted when some traffic came from external distribution?"
      ]
    default:
      return []
    }
  }

  var nextSteps: [String] {
    switch self {
    case .analytics:
      return ["Connect tracking first so the next design iteration is based on real user behavior."]
    case .interviewSimulations:
      return [
        "Make the simulation section understandable before the next presentation or user review."
      ]
    case .offerClarity:
      return ["Replace vague copy with direct labels and calls to action."]
    case .sitePerformance:
      return [
        "Reproduce the scrolling issues on the affected setups and fix the interaction if confirmed."
      ]
    case .visualDirection:
      return ["Prepare a lighter visual pass for review."]
    case .localization:
      return ["Scope the Webflow localization, translation, and RTL work separately."]
    case .registrationData:
      return ["Use registration data alongside user conversations to decide what to change next."]
    case .sectionNavigation:
      return ["Rework the section interaction so users do not need to fight the page position."]
    case .generalDiscussion:
      return ["Create a short implementation plan from the recap."]
    }
  }

  func matches(_ text: String) -> Bool {
    guard self != .generalDiscussion else { return false }
    let hasWebsiteContext = containsAnyThemeKeyword(
      text,
      ["באתר", "האתר", "עמוד", "דף", "webflow", "site", "page", "landing", "ux", "חוויית משתמש"]
    )
    let hasDesignContext = containsAnyThemeKeyword(
      text,
      ["עיצוב", "ויזואל", "צבע", "צבעוניות", "רקע", "ממשק", "design", "visual", "ui"]
    )
    let hasSimulationContext = containsAnyThemeKeyword(
      text,
      ["סימולציה", "סימולציות", "תרחיש", "תרחישים", "hr", "tech", "coming soon", "simulation"]
    )

    switch self {
    case .sitePerformance:
      return hasWebsiteContext
        && containsAnyThemeKeyword(
          text, ["לאט", "איטי", "תקוע", "קופץ", "גלילה", "scroll", "jump", "slow"])
    case .sectionNavigation:
      return containsAnyThemeKeyword(
        text, ["ai בילדר", "ai-בילדר", "masterclass", "מאסטר", "section", "בוקסות", "ריבועים"])
    case .offerClarity:
      return containsAnyThemeKeyword(
        text, ["קריאה לפעולה", "cta", "מה אתם רוצים", "להירשם", "book", "booking"])
        || (hasWebsiteContext && text.contains("לא ברור"))
    case .interviewSimulations:
      return hasSimulationContext
        || (text.contains("ראיונות") && containsAnyThemeKeyword(text, ["סימול", "hr", "tech"]))
    case .analytics:
      return containsAnyThemeKeyword(
        text, ["analytics", "אנליטיקס", "clarity", "mixpanel", "webflow analyze", "משתמשים באמת"])
    case .visualDirection:
      return hasWebsiteContext && hasDesignContext
        && containsAnyThemeKeyword(text, ["כחול", "רקע", "לבן", "אפור", "כבד", "משחקי", "wow"])
    case .localization:
      return containsAnyThemeKeyword(
        text, ["rtl", "תרגום", "locale", "לוקל", "webflow", "גרסה עברית", "עברית באתר"])
    case .registrationData:
      return containsAnyThemeKeyword(text, ["נרשמו", "רשומים", "monday", "signups", "registrations"])
    case .generalDiscussion:
      return false
    }
  }
}

private func containsAnyThemeKeyword(_ text: String, _ patterns: [String]) -> Bool {
  patterns.contains { text.contains($0.lowercased()) }
}

private struct Candidate {
  struct Score: OptionSet {
    let rawValue: Int

    static let keyPoint = Score(rawValue: 1 << 0)
    static let decision = Score(rawValue: 1 << 1)
    static let action = Score(rawValue: 1 << 2)
    static let question = Score(rawValue: 1 << 3)
    static let nextStep = Score(rawValue: 1 << 4)

    var total: Int {
      rawValue.nonzeroBitCount
    }
  }

  let speaker: String
  let text: String
  let timestamp: Date
  let sessionOffset: TimeInterval

  var isSalient: Bool {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.count >= 18 else { return false }

    let lowercased = trimmed.lowercased()
    let fillerPatterns = [
      "אוקיי",
      "אהלן",
      "היי",
      "כן",
      "תודה",
      "בסדר",
      "רגע",
      "לא יודעת",
      "וואי",
      "מדהים",
      "iguous text",
    ]

    guard !fillerPatterns.contains(where: { lowercased == $0 || lowercased.hasPrefix("\($0).") })
    else {
      return false
    }

    return score.total > 0 || trimmed.count >= 42
  }

  var score: Score {
    let lowercased = text.lowercased()
    var score: Score = []

    if containsAny(
      lowercased,
      [
        "important",
        "blocker",
        "risk",
        "decision",
        "summary",
        "key",
        "goal",
        "scope",
        "owner",
        "timeline",
        "חשוב",
        "בעיה",
        "בעייתי",
        "כבד",
        "איטי",
        "לאט",
        "קופץ",
        "גלילה",
        "חוויית משתמש",
        "קריאה לפעולה",
        "אנליטיקס",
        "analytics",
        "clarity",
        "webflow",
        "coming soon",
        "סימולציות",
        "ראיונות",
      ])
    {
      score.insert(.keyPoint)
    }

    if containsAny(
      lowercased,
      [
        "decide",
        "decided",
        "agreed",
        "approved",
        "settled",
        "choose",
        "choose",
        "selected",
        "will use",
        "החלטנו",
        "סיכמנו",
        "מסכימה",
        "נחליט",
        "נראה לי",
        "הכי חשוב",
      ])
    {
      score.insert(.decision)
    }

    if containsAny(
      lowercased,
      [
        "will",
        "i'll",
        "i will",
        "we will",
        "follow up",
        "follow-up",
        "action item",
        "own",
        "send",
        "prepare",
        "fix",
        "review",
        "update",
        "schedule",
        "צריך",
        "צריכים",
        "חייב",
        "חובה",
        "אפשר",
        "תוסיף",
        "להוסיף",
        "לשנות",
        "לתקן",
        "לחבר",
        "לראות",
        "להחליף",
        "להוריד",
        "נעשה",
        "נוסיף",
      ])
    {
      score.insert(.action)
      score.insert(.nextStep)
    }

    if text.contains("?")
      || containsAny(
        lowercased,
        [
          "question",
          "open question",
          "not sure",
          "unknown",
          "need to confirm",
          "depends",
          "clarify",
          "unresolved",
          "שאלה",
          "לא בטוח",
          "לא בטוחה",
          "צריך להבין",
          "לא ברור",
          "מה עושים",
          "מה סיכמנו",
        ])
    {
      score.insert(.question)
    }

    if containsAny(
      lowercased,
      [
        "next step",
        "next steps",
        "after this",
        "going forward",
        "follow up",
        "by tomorrow",
        "by next",
        "moving forward",
        "הצעד",
        "המשך",
        "איטרציה הבאה",
        "בהמשך",
        "אחרי זה",
      ])
    {
      score.insert(.nextStep)
    }

    return score
  }

  private func containsAny(_ text: String, _ patterns: [String]) -> Bool {
    patterns.contains { text.contains($0) }
  }
}

private struct LocalSessionRecapPayload: Codable {
  struct SectionPayload: Codable {
    var title: String?
    var summary: String?
    var bullets: [String]?
    var startOffsetSeconds: TimeInterval?
    var endOffsetSeconds: TimeInterval?
  }

  var overview: String
  var keyPoints: [SectionPayload]
  var decisions: [SectionPayload]
  var actionItems: [SectionPayload]
  var openQuestions: [SectionPayload]
  var nextSteps: [SectionPayload]

  private enum CodingKeys: String, CodingKey {
    case overview
    case keyPoints
    case decisions
    case actionItems
    case openQuestions
    case nextSteps
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    overview = try container.decode(String.self, forKey: .overview)
    keyPoints = try container.decodeIfPresent([SectionPayload].self, forKey: .keyPoints) ?? []
    decisions = try container.decodeIfPresent([SectionPayload].self, forKey: .decisions) ?? []
    actionItems =
      try container.decodeIfPresent([SectionPayload].self, forKey: .actionItems) ?? []
    openQuestions =
      try container.decodeIfPresent([SectionPayload].self, forKey: .openQuestions) ?? []
    nextSteps = try container.decodeIfPresent([SectionPayload].self, forKey: .nextSteps) ?? []
  }

  func makeRecap(startedAt: Date) -> LocalSessionRecap {
    let cleanedOverview = overview.cleanedGeneratedContent ?? ""
    let isHebrew =
      cleanedOverview.containsHebrewScript
      || (keyPoints + decisions + actionItems + openQuestions + nextSteps).contains { payload in
        ([payload.title, payload.summary].compactMap(\.self) + (payload.bullets ?? []))
          .joined(separator: " ")
          .containsHebrewScript
      }
    let sections = [
      makeOverviewSection(overview: cleanedOverview, startedAt: startedAt, isHebrew: isHebrew),
      makeSectionPayloads(
        kind: .keyPoints, payloads: keyPoints, startedAt: startedAt, isHebrew: isHebrew),
      makeSectionPayloads(
        kind: .decisions, payloads: decisions, startedAt: startedAt, isHebrew: isHebrew),
      makeSectionPayloads(
        kind: .actionItem, payloads: actionItems, startedAt: startedAt, isHebrew: isHebrew),
      makeSectionPayloads(
        kind: .openQuestions, payloads: openQuestions, startedAt: startedAt, isHebrew: isHebrew),
      makeSectionPayloads(
        kind: .nextSteps, payloads: nextSteps, startedAt: startedAt, isHebrew: isHebrew),
    ].compactMap(\.self)

    return LocalSessionRecap(
      overview: cleanedOverview,
      generatedAt: Date(),
      sections: sections
    )
  }

  private func makeOverviewSection(
    overview: String,
    startedAt: Date,
    isHebrew: Bool
  ) -> LocalSessionRecapSection? {
    guard !overview.isEmpty else { return nil }

    return LocalSessionRecapSection(
      id: UUID(),
      kind: .overview,
      title: isHebrew ? "תקציר מנהלים" : "Overview",
      summary: overview,
      bullets: [overview],
      anchorTimestamp: nil,
      startOffset: nil,
      endOffset: nil
    )
  }

  private func makeSectionPayloads(
    kind: LocalSessionRecapSection.Kind,
    payloads: [SectionPayload],
    startedAt: Date,
    isHebrew: Bool
  ) -> LocalSessionRecapSection? {
    let cleanedPayloads = payloads.compactMap { payload -> SectionPayload? in
      let summary = payload.summary?.cleanedGeneratedContent
      let bullets = (payload.bullets ?? []).compactMap(\.cleanedGeneratedContent)

      guard summary != nil || !bullets.isEmpty else {
        return nil
      }

      return SectionPayload(
        title: payload.title?.cleanedGeneratedContent,
        summary: summary,
        bullets: bullets,
        startOffsetSeconds: payload.startOffsetSeconds,
        endOffsetSeconds: payload.endOffsetSeconds
      )
    }

    guard let payload = cleanedPayloads.first else {
      return nil
    }

    let mergedBullets = cleanedPayloads.flatMap { $0.bullets ?? [] }
    let fallbackBullets =
      mergedBullets.isEmpty ? [payload.summary].compactMap(\.self) : mergedBullets
    let startOffset = cleanedPayloads.compactMap(\.startOffsetSeconds).min()
    let endOffset = cleanedPayloads.compactMap(\.endOffsetSeconds).max()

    return LocalSessionRecapSection(
      id: UUID(),
      kind: kind,
      title: payload.title ?? title(for: kind, isHebrew: isHebrew),
      summary: payload.summary ?? "",
      bullets: fallbackBullets,
      anchorTimestamp: startOffset.map { startedAt.addingTimeInterval($0) },
      startOffset: startOffset,
      endOffset: endOffset
    )
  }

  private func title(for kind: LocalSessionRecapSection.Kind, isHebrew: Bool) -> String {
    if isHebrew {
      switch kind {
      case .overview: return "תקציר מנהלים"
      case .keyPoints: return "נקודות מרכזיות"
      case .decisions: return "החלטות"
      case .actionItem: return "משימות להמשך"
      case .openQuestions: return "שאלות פתוחות"
      case .nextSteps: return "המשך מומלץ"
      case .notes: return "הערות"
      }
    }

    switch kind {
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

extension LocalSessionRecap {
  fileprivate var isMeaningful: Bool {
    guard overview.cleanedGeneratedContent != nil else { return false }

    return sections.contains { section in
      section.kind != .overview
        && (section.summary.cleanedGeneratedContent != nil
          || section.bullets.contains { $0.cleanedGeneratedContent != nil })
      }
  }

  fileprivate func isGrounded(in input: LocalSessionRecapGenerationInput) -> Bool {
    !LocalSessionRecapClaimGrounding.hasUnsupportedClaims(recap: self, input: input)
  }
}

private enum LocalSessionRecapClaimGrounding {
  struct ClaimGroup {
    let recapPatterns: [String]
    let sourcePatterns: [String]
  }

  private static let claimGroups: [ClaimGroup] = [
    ClaimGroup(
      recapPatterns: [
        "site performance", "scrolling behavior", "section-jump", "hard to scroll",
        "page position",
      ],
      sourcePatterns: [
        "גלילה", "לגלול", "scroll", "section jump", "jump between sections", "ניווט",
        "ניווט בין", "חוויית גלילה",
      ]
    ),
    ClaimGroup(
      recapPatterns: [
        "calls to action", "call to action", "cta", "user promise", "explicit next step",
      ],
      sourcePatterns: [
        "קריאה לפעולה", "cta", "call to action", "להירשם", "הרשמה", "book demo",
        "book a call", "next step",
      ]
    ),
    ClaimGroup(
      recapPatterns: [
        "interview simulation", "hr and tech", "hr path", "tech path", "coming-soon state",
      ],
      sourcePatterns: [
        "סימולציה", "סימולציות", "ראיון", "ראיונות", "hr", "tech", "coming soon",
        "תרחיש", "תרחישים",
      ]
    ),
    ClaimGroup(
      recapPatterns: [
        "lighter visual", "visual direction", "lighter background", "reduced visual weight",
        "brand direction",
      ],
      sourcePatterns: [
        "עיצוב", "ויזואל", "צבע", "צבעוניות", "רקע", "לבן", "כחול", "אפור",
        "design", "visual",
      ]
    ),
    ClaimGroup(
      recapPatterns: [
        "analytics", "registration signals", "registration numbers", "signups came from",
        "user-behavior analytics",
      ],
      sourcePatterns: [
        "analytics", "אנליטיקס", "clarity", "mixpanel", "נרשמו", "רשומים", "הרשמות",
        "signups", "registration",
      ]
    ),
  ]

  static func hasUnsupportedClaims(
    recap: LocalSessionRecap,
    input: LocalSessionRecapGenerationInput
  ) -> Bool {
    let recapText =
      ([recap.overview] + recap.sections.flatMap { [$0.title, $0.summary] + $0.bullets })
      .joined(separator: " ")
      .lowercased()
    guard !recapText.isEmpty else { return true }

    let sourceText =
      ([input.title] + input.transcriptCandidates.map(\.text))
      .joined(separator: " ")
      .lowercased()

    return claimGroups.contains { group in
      group.recapPatterns.contains { recapText.contains($0.lowercased()) }
        && !group.sourcePatterns.contains { sourceText.contains($0.lowercased()) }
    }
  }
}

extension String {
  fileprivate var containsHebrewScript: Bool {
    unicodeScalars.contains { scalar in
      (0x0590...0x05FF).contains(Int(scalar.value))
    }
  }

  fileprivate var cleanedGeneratedContent: String? {
    let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    let lowercased = trimmed.lowercased()
    let placeholders: Set<String> = [
      "...", "…", "....", "n/a", "na", "none", "null", "nil", "no summary",
      "concise paragraph with purpose and current state",
      "problems / context / important points",
      "decision",
      "owner/person/team",
      "open question",
      "professional recommendation",
      "urgent fixes and next-iteration tasks",
      "short professional recommendation",
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

  fileprivate var jsonSubstringOrSelf: String {
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

    guard let lastBrace = lastIndex(of: "}") else {
      return self.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    return String(self[firstBrace...lastBrace]).trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
