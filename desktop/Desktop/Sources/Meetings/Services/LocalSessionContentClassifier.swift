import Foundation

protocol LocalSessionContentClassifying: Sendable {
  func classifyContent(for session: LocalSession) async -> LocalSessionContentClassification
}

struct LocalSessionContentClassificationInput: Sendable {
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
  let hasSystemAudio: Bool
}

protocol LocalSessionContentClassificationModelProviding: Sendable {
  func classifyContent(
    for input: LocalSessionContentClassificationInput
  ) async throws -> LocalSessionContentClassification
}

struct LocalSessionContentClassifier: LocalSessionContentClassifying {
  private let modelClient: (any LocalSessionContentClassificationModelProviding)?
  private let fallback = LocalSessionDeterministicContentClassifier()

  init(
    modelClient: (any LocalSessionContentClassificationModelProviding)? = Self.defaultModelClient()
  ) {
    self.modelClient = modelClient
  }

  func classifyContent(for session: LocalSession) async -> LocalSessionContentClassification {
    let input = Self.makeInput(from: session)

    if let modelClient {
      do {
        let classification = try await modelClient.classifyContent(for: input)
        if classification.isUsable {
          return classification
        }
      } catch {
        // Fall through to the deterministic classifier.
      }
    }

    return fallback.classifyContent(for: input)
  }

  static func defaultModelClient() -> (any LocalSessionContentClassificationModelProviding)? {
    LocalSessionEmbeddedContentClassificationClient()
  }

  private static func makeInput(from session: LocalSession) -> LocalSessionContentClassificationInput {
    let transcriptCandidates = session.transcriptSegments.map { segment in
      LocalSessionContentClassificationInput.TranscriptCandidate(
        speaker: segment.speaker,
        text: segment.text,
        timestamp: segment.timestamp,
        sessionOffset: max(0, segment.timestamp.timeIntervalSince(session.startedAt))
      )
    }
    let hasSystemAudio =
      session.audioArtifacts.systemFileName != nil
      || session.transcriptSegments.contains {
        $0.speaker.localizedCaseInsensitiveContains("system")
      }

    return LocalSessionContentClassificationInput(
      sessionID: session.id,
      title: session.title,
      startedAt: session.startedAt,
      transcriptCandidates: transcriptCandidates,
      attachmentCount: session.attachments.count,
      captureArtifactCount: session.captureArtifacts.count,
      hasSystemAudio: hasSystemAudio
    )
  }
}

struct LocalSessionEmbeddedContentClassificationClient:
  LocalSessionContentClassificationModelProviding, Sendable
{
  let languageModel: any LocalSessionLanguageModelGenerating
  var maxTokens: Int = 180

  init(
    languageModel: any LocalSessionLanguageModelGenerating = EmbeddedLocalLanguageModel.shared,
    maxTokens: Int = 180
  ) {
    self.languageModel = languageModel
    self.maxTokens = maxTokens
  }

  func classifyContent(
    for input: LocalSessionContentClassificationInput
  ) async throws -> LocalSessionContentClassification {
    let rawResponse = try await languageModel.generateText(
      prompt: Self.prompt(for: input),
      maxTokens: maxTokens
    )
    let jsonString = rawResponse.classificationJSONSubstringOrSelf
    let payloadData = jsonString.data(using: .utf8) ?? Data()
    let payload = try JSONDecoder().decode(LocalSessionContentClassificationPayload.self, from: payloadData)
    return payload.makeClassification()
  }

  private static func prompt(for input: LocalSessionContentClassificationInput) -> String {
    """
    Classify this transcript before any recap is written.

    Choose exactly one type:
    - meeting: a meeting, call, sync, planning discussion, interview, or multi-person work conversation.
    - voiceNote: a dictated message, personal voice memo, reminder, quick update, or one-speaker note.
    - videoCommentary: narration/commentary over a video, screen recording, demo, lecture, clip, or captured system audio.
    - generalTranscript: any other transcript that should not be forced into meeting structure.

    Return only valid JSON. No markdown. No commentary.
    JSON shape:
    {"type":"meeting|voiceNote|videoCommentary|generalTranscript","confidence":0.0,"rationale":"short reason grounded in transcript evidence"}

    Session title: \(input.title)
    Attachment count: \(input.attachmentCount)
    Capture artifact count: \(input.captureArtifactCount)
    Has system audio: \(input.hasSystemAudio ? "true" : "false")

    Transcript:
    \(transcriptContext(for: input))

    Final instruction: Return only the JSON object. Do not write the brief yet.
    """
  }

  private static func transcriptContext(for input: LocalSessionContentClassificationInput) -> String {
    let candidates = input.transcriptCandidates
    let maxSegments = 45
    let selectedCandidates =
      candidates.count > maxSegments
      ? Array(candidates.prefix(30)) + Array(candidates.suffix(15))
      : candidates

    var lines = selectedCandidates.map { candidate in
      let offset = String(format: "%.1f", candidate.sessionOffset)
      let text = candidate.text
        .replacingOccurrences(of: "\n", with: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
      let clipped = text.count > 220 ? "\(text.prefix(220))..." : text
      return "[\(offset)s] \(candidate.speaker): \(clipped)"
    }

    if candidates.count > selectedCandidates.count {
      lines.insert(
        "[\(candidates.count - selectedCandidates.count) middle transcript segments omitted.]",
        at: min(30, lines.count)
      )
    }

    return lines.joined(separator: "\n")
  }
}

private struct LocalSessionContentClassificationPayload: Codable {
  var type: LocalSessionContentType
  var confidence: Double
  var rationale: String

  func makeClassification() -> LocalSessionContentClassification {
    LocalSessionContentClassification(
      type: type,
      confidence: confidence,
      rationale: rationale
    )
  }
}

private struct LocalSessionDeterministicContentClassifier {
  func classifyContent(
    for input: LocalSessionContentClassificationInput
  ) -> LocalSessionContentClassification {
    let corpus = ([input.title] + input.transcriptCandidates.map(\.text))
      .joined(separator: " ")
      .lowercased()
    let speakers = meaningfulSpeakers(from: input.transcriptCandidates)
    let speakerCount = speakers.count

    let videoScore =
      (input.hasSystemAudio ? 3 : 0)
      + (input.captureArtifactCount > 0 ? 1 : 0)
      + score(
        corpus,
        patterns: [
          "video", "screen", "screen recording", "demo", "clip", "watch", "on screen",
          "system audio", "narrator", "recording", "lecture", "סרטון", "מסך", "הקלטת מסך",
        ])
    let meetingScore =
      (speakerCount >= 2 ? 2 : 0)
      + score(
        corpus,
        patterns: [
          "meeting", "sync", "call", "agenda", "participants", "decision", "decided",
          "action item", "owner", "we agreed", "follow up", "פגישה", "שיחה", "סיכמנו",
          "החלטנו", "משימות",
        ])
    let voiceNoteScore =
      (speakerCount <= 1 ? 1 : 0)
      + score(
        corpus,
        patterns: [
          "voice note", "voice memo", "message", "tell ", "send ", "remind", "reminder",
          "quick update", "note to self", "תזכורת", "הודעה", "תשלח", "תגיד", "תזכיר",
        ])

    if videoScore >= 3 && videoScore >= meetingScore && videoScore >= voiceNoteScore {
      return classification(
        .videoCommentary,
        confidence: min(0.92, 0.68 + Double(videoScore) * 0.04),
        rationale: "Detected screen/video or system-audio signals in the transcript context."
      )
    }

    if meetingScore >= 3 && meetingScore >= voiceNoteScore {
      return classification(
        .meeting,
        confidence: min(0.9, 0.62 + Double(meetingScore) * 0.05),
        rationale: "Detected meeting-style discussion signals such as multiple speakers, decisions, or follow-up work."
      )
    }

    if voiceNoteScore >= 3 {
      return classification(
        .voiceNote,
        confidence: min(0.88, 0.62 + Double(voiceNoteScore) * 0.05),
        rationale: "Detected a single-speaker message, reminder, or dictated update."
      )
    }

    return classification(
      .generalTranscript,
      confidence: 0.55,
      rationale: "No strong meeting, voice-note, or video-commentary signal was detected."
    )
  }

  private func classification(
    _ type: LocalSessionContentType,
    confidence: Double,
    rationale: String
  ) -> LocalSessionContentClassification {
    LocalSessionContentClassification(
      type: type,
      confidence: confidence,
      rationale: rationale
    )
  }

  private func meaningfulSpeakers(
    from candidates: [LocalSessionContentClassificationInput.TranscriptCandidate]
  ) -> Set<String> {
    Set(candidates.compactMap { candidate in
      let speaker = candidate.speaker.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !speaker.isEmpty else { return nil }
      let lowercased = speaker.lowercased()
      let genericLabels: Set<String> = [
        "speaker", "speaker 1", "speaker 2", "you", "transcript", "unknown",
        "remote speaker", "local speaker", "microphone", "mic", "system audio",
      ]
      guard !genericLabels.contains(lowercased) else { return nil }
      guard !lowercased.hasPrefix("speaker ") else { return nil }
      return speaker
    })
  }

  private func score(_ corpus: String, patterns: [String]) -> Int {
    patterns.reduce(0) { partialResult, pattern in
      partialResult + (corpus.contains(pattern.lowercased()) ? 1 : 0)
    }
  }
}

extension LocalSessionContentClassification {
  fileprivate var isUsable: Bool {
    !rationale.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && confidence > 0
  }
}

extension String {
  fileprivate var classificationJSONSubstringOrSelf: String {
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

    return trimmed
  }
}
