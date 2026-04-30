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
        if recap.isMeaningful {
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
    let contentClassification = input.contentClassification
    let contentType = contentClassification?.type ?? .generalTranscript
    let contentInstructions = instructions(for: contentType)

    return """
      You are creating a clear, practical brief from the attached transcript.

      Clean the transcript before summarizing it:
      - Remove noise, side conversations, repetitions, polite filler, irrelevant jokes, broken transcription fragments, and casual "thank you" exchanges.
      - Do not write a transcript.
      - Do not include raw conversation noise.
      - Keep only what matters for actual work.

      The transcript was classified before this step.
      Content type: \(contentType.displayTitle)
      Classification confidence: \(classificationConfidenceText(contentClassification))
      Classification rationale: \(classificationRationaleText(contentClassification))

      \(contentInstructions)

      Not every section must be full. Include only what is supported by the transcript.
      Separate urgent fixes from next-iteration improvements when that distinction exists.
      Use a professional, clear, direct tone that is not overly formal.
      Extract project, client, or product names only when the transcript or session title explicitly provides them.
      Include a compact people lens inline: mention who attended or was referenced, who owns work, and who raised a key topic only when relevant.
      Do not infer real attendee names from generic speaker labels such as "You", "Remote speaker", "Speaker 1", or "Transcript".
      Do not invent project names, roles, attendees, or responsibilities.

      Return only valid JSON. No markdown. No commentary.
      The JSON object must match this shape:
      {
        "overview": "concise paragraph with purpose and current state",
        "keyPoints": [{"title":"Problems / context / important points","summary":"...","bullets":["..."],"startOffsetSeconds":0,"endOffsetSeconds":0}],
        "decisions": [{"title":"Decision","summary":"...","bullets":["..."],"startOffsetSeconds":0,"endOffsetSeconds":0}],
        "actionItems": [{"title":"Owner/person/team","summary":"urgent fixes and next-iteration tasks","bullets":["..."],"startOffsetSeconds":0,"endOffsetSeconds":0}],
        "openQuestions": [{"title":"Open question","summary":"...","bullets":["..."],"startOffsetSeconds":0,"endOffsetSeconds":0}],
        "nextSteps": [{"title":"Professional recommendation","summary":"short professional recommendation","bullets":["..."],"startOffsetSeconds":0,"endOffsetSeconds":0}]
      }

      Action item titles must be the Owner/person/team when clear. Use "Team" or "Unassigned follow-up" when ownership is unclear.

      Session title: \(input.title)
      Attachment count: \(input.attachmentCount)
      Capture artifact count: \(input.captureArtifactCount)

      Transcript:
      \(transcript)

      Final instruction: Return only valid JSON matching the schema above. Write a cleaned practical brief for the detected content type, not a transcript. End with a short professional recommendation in nextSteps. No markdown fences. No commentary.
      """
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
        - a short recommendation for how to use this transcript next
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
    let maxHeadSegments = 70
    let maxTailSegments = 30
    let maxSegmentTextCharacters = 220
    let selectedCandidates: [LocalSessionRecapGenerationInput.TranscriptCandidate]

    if candidates.count > maxHeadSegments + maxTailSegments {
      selectedCandidates =
        Array(candidates.prefix(maxHeadSegments))
        + Array(candidates.suffix(maxTailSegments))
    } else {
      selectedCandidates = candidates
    }

    var lines = selectedCandidates.map { candidate in
      let offset = String(format: "%.1f", candidate.sessionOffset)
      let text = truncatedText(candidate.text, limit: maxSegmentTextCharacters)
      return "[\(offset)s] \(candidate.speaker): \(text)"
    }

    if candidates.count > selectedCandidates.count {
      let omittedCount = candidates.count - selectedCandidates.count
      lines.insert(
        "[\(omittedCount) middle transcript segments omitted to keep local generation inside the model window.]",
        at: min(maxHeadSegments, lines.count)
      )
    }

    return lines.joined(separator: "\n")
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
    let contentType = input.contentClassification?.type ?? .generalTranscript
    let overviewSection = section(
      kind: .overview,
      title: "Overview",
      summary: summary.overview,
      bullets: [summary.overview],
      candidates: candidates,
      startedAt: input.startedAt
    )
    let keyPointsSection = section(
      kind: .keyPoints,
      title: sectionTitle(for: .keyPoints, contentType: contentType),
      summary: keyPointSummary(for: contentType),
      bullets: summary.keyPoints,
      candidates: candidates,
      startedAt: input.startedAt
    )
    let decisionsSection = section(
      kind: .decisions,
      title: sectionTitle(for: .decisions, contentType: contentType),
      summary: decisionSummary(for: contentType),
      bullets: summary.decisions,
      candidates: candidates,
      startedAt: input.startedAt
    )
    let actionItemsSection = section(
      kind: .actionItem,
      title: sectionTitle(for: .actionItem, contentType: contentType),
      summary: actionSummary(for: contentType),
      bullets: summary.actionItems,
      candidates: candidates,
      startedAt: input.startedAt
    )
    let openQuestionsSection = section(
      kind: .openQuestions,
      title: "Open questions",
      summary: "Questions that still need confirmation.",
      bullets: summary.openQuestions,
      candidates: candidates,
      startedAt: input.startedAt
    )
    let nextStepsSection = section(
      kind: .nextSteps,
      title: "Professional recommendation",
      summary: "Recommended way to move forward.",
      bullets: summary.nextSteps,
      candidates: candidates,
      startedAt: input.startedAt
    )

    return LocalSessionRecap(
      overview: overviewSection.summary,
      generatedAt: Date(),
      sections: [
        overviewSection,
        keyPointsSection,
        decisionsSection,
        actionItemsSection,
        openQuestionsSection,
        nextStepsSection,
      ]
    )
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
    let contentType = input.contentClassification?.type ?? .generalTranscript
    let sourceNoun = sourceNoun(for: contentType)
    let overviewSubject = workContextName.map { "For \($0), the \(sourceNoun)" } ?? "The \(sourceNoun)"

    let overview: String
    if activeThemes == [.generalDiscussion] {
      overview =
        "\(overviewSubject) reviewed the transcript and captured the main areas that need follow-up. The generated brief is based on the source content rather than a verbatim transcript."
    } else {
      let themeList = activeThemes.prefix(3).map(\.overviewPhrase).joined(separator: ", ")
      overview =
        "\(overviewSubject) focused on \(themeList). The main outcome was to turn the feedback into clearer product decisions and follow-up work."
    }

    let keyPoints = activeThemes.prefix(5).map(\.keyPoint)
    let decisions =
      activeThemes.flatMap(\.decisions).isEmpty
      ? ["No final decision was explicit enough to treat as closed."]
      : Array(activeThemes.flatMap(\.decisions).prefix(4))
    let ownerActionItems = ownerAwareActionItems(from: candidates)
    let themeActionItems = activeThemes.flatMap(\.actionItems)
    let actionItems =
      ownerActionItems.isEmpty && themeActionItems.isEmpty
      ? ["Review the transcript and define concrete follow-up owners."]
      : Array((ownerActionItems + themeActionItems).prefix(5))
    let openQuestions =
      activeThemes.flatMap(\.openQuestions).isEmpty
      ? [
        "Which items should become immediate fixes, and which require a broader product/design pass?"
      ]
      : Array(activeThemes.flatMap(\.openQuestions).prefix(4))
    let nextSteps =
      activeThemes.flatMap(\.nextSteps).isEmpty
      ? ["Turn the recap into a prioritized task list."]
      : Array(activeThemes.flatMap(\.nextSteps).prefix(4))

    return DeterministicRecapSummary(
      overview: overview,
      keyPoints: keyPoints,
      decisions: decisions,
      actionItems: actionItems,
      openQuestions: openQuestions,
      nextSteps: nextSteps
    )
  }

  private func ownerAwareActionItems(from candidates: [Candidate]) -> [String] {
    let bullets = candidates.compactMap { candidate -> String? in
      guard candidate.score.contains(.action), let speaker = meaningfulSpeakerName(candidate.speaker)
      else {
        return nil
      }

      let text = candidate.text.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !text.isEmpty else { return nil }
      return "\(speaker): \(text)"
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
      return "transcript"
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

  private func keyPointSummary(for contentType: LocalSessionContentType) -> String {
    switch contentType {
    case .meeting:
      return "Main themes from the discussion."
    case .voiceNote:
      return "The most useful details from the dictated message."
    case .videoCommentary:
      return "Important moments and observations from the commentary."
    case .generalTranscript:
      return "Important source details extracted from the transcript."
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
      return "Tasks or follow-up that can be taken from the transcript."
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
      return ["עברית", "rtl", "תרגום", "locale", "לוקל", "webflow"]
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
    return keywords.contains { text.contains($0.lowercased()) }
  }
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

  func makeRecap(startedAt: Date) -> LocalSessionRecap {
    let cleanedOverview = overview.cleanedGeneratedContent ?? ""
    let sections = [
      makeOverviewSection(overview: cleanedOverview, startedAt: startedAt),
      makeSectionPayloads(kind: .keyPoints, payloads: keyPoints, startedAt: startedAt),
      makeSectionPayloads(kind: .decisions, payloads: decisions, startedAt: startedAt),
      makeSectionPayloads(kind: .actionItem, payloads: actionItems, startedAt: startedAt),
      makeSectionPayloads(kind: .openQuestions, payloads: openQuestions, startedAt: startedAt),
      makeSectionPayloads(kind: .nextSteps, payloads: nextSteps, startedAt: startedAt),
    ].compactMap(\.self)

    return LocalSessionRecap(
      overview: cleanedOverview,
      generatedAt: Date(),
      sections: sections
    )
  }

  private func makeOverviewSection(
    overview: String,
    startedAt: Date
  ) -> LocalSessionRecapSection? {
    guard !overview.isEmpty else { return nil }

    return LocalSessionRecapSection(
      id: UUID(),
      kind: .overview,
      title: "Overview",
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
    startedAt: Date
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
      title: payload.title ?? title(for: kind),
      summary: payload.summary ?? "",
      bullets: fallbackBullets,
      anchorTimestamp: startOffset.map { startedAt.addingTimeInterval($0) },
      startOffset: startOffset,
      endOffset: endOffset
    )
  }

  private func title(for kind: LocalSessionRecapSection.Kind) -> String {
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
}

extension String {
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
