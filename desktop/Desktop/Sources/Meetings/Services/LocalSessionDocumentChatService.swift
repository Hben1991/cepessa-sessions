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
    let rawResponse = try await languageModel.generateText(
      prompt: Self.prompt(for: request),
      maxTokens: maxTokens
    )
    return Self.decodeProposal(from: rawResponse)
  }

  private static func prompt(for request: LocalSessionDocumentChatRequest) -> String {
    let session = request.session
    let markdown = LocalSessionRecapMarkdownDocument(session: session).markdown
    let transcript = session.transcriptSegments.map { segment in
      let offset = max(0, segment.timestamp.timeIntervalSince(session.startedAt))
      return "[segmentID=\(segment.id.uuidString) offset=\(String(format: "%.1f", offset))s speaker=\(segment.speaker)] \(segment.text)"
    }
    .joined(separator: "\n")

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
      - Propose edits only. The user must apply them in the app.
      - The structured session is the source of truth, not the rendered Markdown.
      - You may replace recap overview and recap sections.
      - You may rename speakers/participants across transcript segments.
      - You may correct transcript text only with targeted transcriptPatches by segmentID.
      - Do not rewrite the whole transcript. If asked for broad transcript rewriting, warn and propose only explicit point corrections.
      - Use empty arrays and null recapPatch when there are no edits.

      Session title: \(session.title)
      Started at: \(session.startedAt.formatted(date: .complete, time: .complete))

      Markdown preview:
      \(markdown)

      Transcript with stable segment IDs:
      \(transcript)

      Recent chat:
      \(chatHistory)

      User request:
      \(request.userMessage)
      """
  }

  static func decodeProposal(from rawResponse: String) -> LocalSessionDocumentEditProposal {
    let jsonString = rawResponse.jsonObjectSubstringOrSelf
    let data = jsonString.data(using: .utf8) ?? Data()

    do {
      let payload = try JSONDecoder().decode(LocalSessionDocumentEditProposalPayload.self, from: data)
      return payload.makeProposal()
    } catch {
      let fallback = rawResponse.trimmingCharacters(in: .whitespacesAndNewlines)
      return LocalSessionDocumentEditProposal(
        assistantMessage: fallback.isEmpty
          ? "I could not read a valid edit proposal from the local model."
          : fallback,
        recapPatch: nil,
        transcriptPatches: [],
        speakerRenames: [],
        warnings: ["The local model returned invalid JSON, so no editable changes are pending."]
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
    var kind: LocalSessionRecapSection.Kind?
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
    let sections = (recapPatch?.sections ?? []).compactMap { section
      -> LocalSessionDocumentRecapPatch.SectionReplacement? in
      guard let kind = section.kind else { return nil }
      return LocalSessionDocumentRecapPatch.SectionReplacement(
        kind: kind,
        title: section.title ?? kind.displayTitle,
        summary: section.summary ?? "",
        bullets: section.bullets ?? []
      )
    }

    let recap =
      recapPatch == nil
      ? nil
      : LocalSessionDocumentRecapPatch(overview: recapPatch?.overview, sections: sections)

    let transcriptEdits = (transcriptPatches ?? []).compactMap { patch
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

    let renames = (speakerRenames ?? []).compactMap { rename
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
      assistantMessage: assistantMessage?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
      recapPatch: recap,
      transcriptPatches: transcriptEdits,
      speakerRenames: renames,
      warnings: warnings ?? []
    )
  }
}

private extension String {
  var jsonObjectSubstringOrSelf: String {
    guard let firstBrace = firstIndex(of: "{"),
      let lastBrace = lastIndex(of: "}"),
      firstBrace <= lastBrace
    else {
      return trimmingCharacters(in: .whitespacesAndNewlines)
    }

    return String(self[firstBrace...lastBrace]).trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
