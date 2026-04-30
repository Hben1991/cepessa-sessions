import Foundation
import XCTest

@testable import CepessaSessions

final class LocalMeetingRecapGeneratorTests: XCTestCase {
  func testDefaultModelClientFallsBackToLocalModel() {
    let client = LocalSessionRecapGenerator.defaultModelClient()

    XCTAssertNotNil(client as? LocalSessionEmbeddedRecapClient)
  }

  func testDeterministicGeneratorBuildsStructuredSections() async {
    let generator = LocalSessionRecapGenerator(modelClient: nil)
    let startedAt = Date(timeIntervalSince1970: 1_700_000)
    let session = LocalMeetingSession(
      id: UUID(uuidString: "C15A3F3F-208F-4B16-BB45-5E48F85A1A77")!,
      title: "Roadmap review",
      startedAt: startedAt,
      status: .transcribing,
      transcriptSegments: [
        .init(
          id: UUID(uuidString: "2A8B6BE2-D36F-4D71-B0CB-0624CEB1A1A4")!,
          speaker: "Dana",
          text:
            "We decided to move the launch to next Thursday and I will send the updated plan tomorrow.",
          timestamp: startedAt.addingTimeInterval(12)
        ),
        .init(
          id: UUID(uuidString: "B2049D1F-C9EC-4A48-A213-0BB9AAFE7A02")!,
          speaker: "Noam",
          text:
            "The open question is whether support can review the migration checklist by Monday?",
          timestamp: startedAt.addingTimeInterval(48)
        ),
      ],
      attachments: [
        .init(
          id: UUID(uuidString: "E9C75C6E-B804-4893-80DF-C0BE9B6E8C97")!,
          kind: .image,
          source: .floatingBar,
          title: "Launch checklist",
          timestamp: startedAt.addingTimeInterval(30),
          sessionOffset: 30,
          fileName: "checklist.png",
          mimeType: "image/png",
          urlString: "/tmp/checklist.png",
          note: nil
        )
      ],
      captureArtifacts: [],
      audioArtifacts: .empty
    )

    let recap = await generator.generateRecap(for: session)

    XCTAssertFalse(recap.overview.isEmpty)
    XCTAssertEqual(recap.sections.count, 6)
    XCTAssertTrue(recap.sections.contains(where: { $0.kind == .decisions && !$0.bullets.isEmpty }))
    XCTAssertTrue(recap.sections.contains(where: { $0.kind == .actionItem && !$0.bullets.isEmpty }))
    XCTAssertTrue(
      recap.sections.contains(where: { $0.kind == .openQuestions && !$0.bullets.isEmpty }))
  }

  func testDeterministicGeneratorBuildsConcreteHebrewFallbackBrief() async {
    let generator = LocalSessionRecapGenerator(modelClient: nil)
    let startedAt = Date(timeIntervalSince1970: 1_700_500)
    let session = LocalMeetingSession(
      id: UUID(uuidString: "1F0B0C20-C0DD-488B-A4E7-907B649AE8C4")!,
      title: "Hebrew product review",
      startedAt: startedAt,
      status: .ready,
      transcriptSegments: [
        .init(
          id: UUID(uuidString: "11DFA809-5614-4F48-A1B1-310BD11FEB75")!,
          speaker: "Remote speaker",
          text: "אוקיי.",
          timestamp: startedAt
        ),
        .init(
          id: UUID(uuidString: "AC787A31-B79E-47B1-9E28-0C40F4793126")!,
          speaker: "Remote speaker",
          text: "הגלילה באתר זזה לאט וקופצת, וזה פוגע בחוויית המשתמש.",
          timestamp: startedAt.addingTimeInterval(30)
        ),
        .init(
          id: UUID(uuidString: "8D016790-D657-473D-9B25-13E5D3DA2B5D")!,
          speaker: "You",
          text: "אני חושב שיותר חכם לחבר קודם Analytics ולראות איך המשתמשים באמת משתמשים באתר.",
          timestamp: startedAt.addingTimeInterval(60)
        ),
        .init(
          id: UUID(uuidString: "60F13690-B8EC-42E8-ADDF-17D1DCE99460")!,
          speaker: "Remote speaker",
          text: "סיכמנו שהכי חשוב להוסיף coming soon לסימולציות ריאיון.",
          timestamp: startedAt.addingTimeInterval(90)
        ),
      ],
      audioArtifacts: .empty
    )

    let recap = await generator.generateRecap(for: session)
    let markdownSession = LocalMeetingSession(
      id: session.id,
      title: session.title,
      startedAt: session.startedAt,
      status: session.status,
      transcriptSegments: session.transcriptSegments,
      recap: recap,
      audioArtifacts: session.audioArtifacts
    )
    let markdown = LocalSessionRecapMarkdownDocument(session: markdownSession).markdown

    XCTAssertFalse(markdown.contains("No strong key points were extracted"))
    XCTAssertFalse(markdown.contains("Opening line: Remote speaker: אוקיי"))
    XCTAssertFalse(markdown.contains("Remote speaker:"))
    XCTAssertFalse(markdown.contains("You:"))
    XCTAssertTrue(markdown.contains("scrolling behavior"))
    XCTAssertTrue(markdown.contains("analytics"))
    XCTAssertTrue(markdown.contains("coming soon"))
    XCTAssertTrue(markdown.contains("interview simulation"))
    XCTAssertTrue(markdown.contains("## Professional recommendation"))
  }

  func testEmbeddedRecapPromptCompactsLongTranscriptAndRepeatsJSONInstruction() async throws {
    let languageModel = CapturingLanguageModel(
      response: """
        {"overview":"Compact overview.","keyPoints":[],"decisions":[],"actionItems":[],"openQuestions":[],"nextSteps":[]}
        """
    )
    let client = LocalSessionEmbeddedRecapClient(languageModel: languageModel)
    let generator = LocalSessionRecapGenerator(modelClient: client)
    let startedAt = Date(timeIntervalSince1970: 1_800_000)
    let longText = String(
      repeating: "This is a long transcript line with details and repeated context. ", count: 35)
    let segments = (0..<260).map { index in
      LocalMeetingTranscriptSegment(
        id: UUID(),
        speaker: index.isMultiple(of: 2) ? "Dana" : "Noam",
        text: "\(index): \(longText)",
        timestamp: startedAt.addingTimeInterval(TimeInterval(index * 4))
      )
    }
    var session = LocalMeetingSession(
      id: UUID(),
      title: "Long planning call",
      startedAt: startedAt,
      status: .ready,
      transcriptSegments: segments,
      audioArtifacts: .empty
    )
    session.contentClassification = .init(
      type: .meeting,
      confidence: 0.88,
      rationale: "Planning call with multiple speakers.",
      generatedAt: startedAt.addingTimeInterval(20)
    )

    _ = await generator.generateRecap(for: session)

    let prompt = try XCTUnwrap(languageModel.lastPrompt)
    XCTAssertLessThan(prompt.count, 35_000)
    XCTAssertTrue(prompt.contains("middle transcript segments omitted"))
    XCTAssertTrue(prompt.contains("Clean the transcript before summarizing it"))
    XCTAssertTrue(prompt.contains("urgent fixes from next-iteration improvements"))
    XCTAssertTrue(prompt.contains("short professional recommendation"))
    XCTAssertTrue(prompt.contains("Extract the relevant meeting brief"))
    let transcriptRange = try XCTUnwrap(prompt.range(of: "Transcript:"))
    let finalInstructionRange = try XCTUnwrap(
      prompt.range(of: "Final instruction: Return only valid JSON", options: .backwards))
    XCTAssertGreaterThan(finalInstructionRange.lowerBound, transcriptRange.lowerBound)
  }

  func testEmbeddedRecapPromptRequestsPeopleProjectAndAntiHallucinationGuardrails() async throws {
    let languageModel = CapturingLanguageModel(
      response: """
        {"overview":"Compact overview.","keyPoints":[],"decisions":[],"actionItems":[],"openQuestions":[],"nextSteps":[]}
        """
    )
    let generator = LocalSessionRecapGenerator(
      modelClient: LocalSessionEmbeddedRecapClient(languageModel: languageModel)
    )
    let startedAt = Date(timeIntervalSince1970: 1_810_000)
    var session = LocalMeetingSession(
      id: UUID(uuidString: "FE497144-2448-45D7-9DA8-3AA8E4C6C1E4")!,
      title: "Project Atlas planning",
      startedAt: startedAt,
      status: .ready,
      transcriptSegments: [
        .init(
          id: UUID(uuidString: "7C68433E-FDA8-42FC-B120-DB9CA7D93B6D")!,
          speaker: "Dana",
          text: "Maya owns the launch checklist for Project Atlas.",
          timestamp: startedAt.addingTimeInterval(12)
        )
      ],
      audioArtifacts: .empty
    )
    session.contentClassification = .init(
      type: .meeting,
      confidence: 0.88,
      rationale: "Planning call with multiple speakers.",
      generatedAt: startedAt.addingTimeInterval(20)
    )

    _ = await generator.generateRecap(for: session)

    let prompt = try XCTUnwrap(languageModel.lastPrompt)
    XCTAssertTrue(prompt.contains("Extract project, client, or product names"))
    XCTAssertTrue(prompt.contains("compact people lens inline"))
    XCTAssertTrue(prompt.contains("who owns work"))
    XCTAssertTrue(prompt.contains("Do not infer real attendee names from generic speaker labels"))
    XCTAssertTrue(
      prompt.contains("Do not invent project names, roles, attendees, or responsibilities"))
    XCTAssertTrue(prompt.contains("Owner/person/team"))
  }

  func testContentClassifierUsesModelJsonBeforeRecapGeneration() async throws {
    let languageModel = CapturingLanguageModel(
      response: """
        {"type":"voiceNote","confidence":0.86,"rationale":"Single-speaker dictated message with a clear recipient intent."}
        """
    )
    let classifier = LocalSessionContentClassifier(
      modelClient: LocalSessionEmbeddedContentClassificationClient(languageModel: languageModel)
    )
    let startedAt = Date(timeIntervalSince1970: 1_815_000)
    let session = LocalMeetingSession(
      id: UUID(uuidString: "3D71C331-A2F2-4823-A035-961574AE7F3D")!,
      title: "Voice memo",
      startedAt: startedAt,
      status: .ready,
      transcriptSegments: [
        .init(
          id: UUID(uuidString: "88F24B03-3E4C-4D11-BB76-B6AB9B70C467")!,
          speaker: "Speaker 1",
          text: "Send Noam a quick message that the export is ready and I will check it tomorrow.",
          timestamp: startedAt.addingTimeInterval(6)
        )
      ],
      audioArtifacts: .empty
    )

    let classification = await classifier.classifyContent(for: session)

    XCTAssertEqual(classification.type, .voiceNote)
    XCTAssertEqual(classification.confidence, 0.86, accuracy: 0.001)
    XCTAssertTrue(classification.rationale.contains("Single-speaker"))
    let prompt = try XCTUnwrap(languageModel.lastPrompt)
    XCTAssertTrue(prompt.contains("meeting"))
    XCTAssertTrue(prompt.contains("voiceNote"))
    XCTAssertTrue(prompt.contains("videoCommentary"))
    XCTAssertTrue(prompt.contains("generalTranscript"))
  }

  func testContentClassifierFallsBackToVideoCommentaryFromSystemAudioContext() async {
    let classifier = LocalSessionContentClassifier(modelClient: nil)
    let startedAt = Date(timeIntervalSince1970: 1_816_000)
    let session = LocalMeetingSession(
      id: UUID(uuidString: "0BE46856-508D-45C6-A5E0-5D24BB6F69AD")!,
      title: "Screen recording notes",
      startedAt: startedAt,
      status: .ready,
      transcriptSegments: [
        .init(
          id: UUID(uuidString: "E32D31EC-F426-4C81-A12D-B537DA51C149")!,
          speaker: "System audio",
          text:
            "The video shows the onboarding screen and the narrator says the button is confusing.",
          timestamp: startedAt.addingTimeInterval(4)
        )
      ],
      audioArtifacts: .init(
        micFileName: "mic.wav", systemFileName: "system.wav", mixedFileName: "mixed.wav")
    )

    let classification = await classifier.classifyContent(for: session)

    XCTAssertEqual(classification.type, .videoCommentary)
    XCTAssertGreaterThanOrEqual(classification.confidence, 0.7)
  }

  func testEmbeddedRecapPromptUsesVoiceNoteInstructions() async throws {
    let languageModel = CapturingLanguageModel(
      response: """
        {"overview":"Message overview.","keyPoints":[],"decisions":[],"actionItems":[],"openQuestions":[],"nextSteps":[]}
        """
    )
    let generator = LocalSessionRecapGenerator(
      modelClient: LocalSessionEmbeddedRecapClient(languageModel: languageModel)
    )
    let startedAt = Date(timeIntervalSince1970: 1_817_000)
    var session = LocalMeetingSession(
      id: UUID(uuidString: "483E1205-E849-4D08-A7C0-2AF2E0922858")!,
      title: "Message for Dana",
      startedAt: startedAt,
      status: .ready,
      transcriptSegments: [
        .init(
          id: UUID(uuidString: "7F7685AF-D431-4B8B-B656-873A288B99B6")!,
          speaker: "Speaker 1",
          text: "Tell Dana that I approved the copy and ask her to upload the final assets.",
          timestamp: startedAt.addingTimeInterval(3)
        )
      ],
      audioArtifacts: .empty
    )
    session.contentClassification = .init(
      type: .voiceNote,
      confidence: 0.91,
      rationale: "Single speaker dictated a message.",
      generatedAt: startedAt.addingTimeInterval(5)
    )

    _ = await generator.generateRecap(for: session)

    let prompt = try XCTUnwrap(languageModel.lastPrompt)
    XCTAssertTrue(prompt.contains("voice note or dictated message"))
    XCTAssertTrue(prompt.contains("Do not force meeting sections"))
    XCTAssertTrue(prompt.contains("Content type: Voice note"))
    XCTAssertFalse(prompt.contains("meeting purpose"))
  }

  func testDeterministicFallbackCreatesOwnerAwareActionItemsForNamedSpeakers() async {
    let generator = LocalSessionRecapGenerator(modelClient: nil)
    let startedAt = Date(timeIntervalSince1970: 1_820_000)
    let session = LocalMeetingSession(
      id: UUID(uuidString: "5F85F4E3-7E75-4B34-B47D-9011B6B97D8D")!,
      title: "Roadmap review",
      startedAt: startedAt,
      status: .ready,
      transcriptSegments: [
        .init(
          id: UUID(uuidString: "A2C8F589-3592-49A3-BDA7-F7B86251AF88")!,
          speaker: "Dana",
          text: "I will send the launch checklist tomorrow.",
          timestamp: startedAt.addingTimeInterval(10)
        ),
        .init(
          id: UUID(uuidString: "4663CA4A-B56F-427D-8C5C-C1B07F3DC289")!,
          speaker: "Noam",
          text: "I will review analytics before the next iteration.",
          timestamp: startedAt.addingTimeInterval(24)
        ),
      ],
      audioArtifacts: .empty
    )

    let recap = await generator.generateRecap(for: session)
    let actionItems = recap.section(kind: .actionItem)?.bullets ?? []

    XCTAssertTrue(
      actionItems.contains(where: { $0.contains("Dana:") && $0.contains("launch checklist") }))
    XCTAssertTrue(
      actionItems.contains(where: { $0.contains("Noam:") && $0.contains("analytics") }))
  }

  func testDeterministicFallbackDoesNotTreatGenericSpeakerLabelsAsPeople() async {
    let generator = LocalSessionRecapGenerator(modelClient: nil)
    let startedAt = Date(timeIntervalSince1970: 1_830_000)
    let session = LocalMeetingSession(
      id: UUID(uuidString: "EF788E1B-B85B-4D80-A8E9-958F81A3486D")!,
      title: "Session 2026-04-30",
      startedAt: startedAt,
      status: .ready,
      transcriptSegments: [
        .init(
          id: UUID(uuidString: "802C5D8B-E744-41F1-B5E4-E709BC0BC88C")!,
          speaker: "Remote speaker",
          text: "We will fix the slow scrolling before the next review.",
          timestamp: startedAt.addingTimeInterval(10)
        ),
        .init(
          id: UUID(uuidString: "4CD269C9-F3B1-4FA2-B745-D4E33E286489")!,
          speaker: "Speaker 1",
          text: "I will update the analytics setup.",
          timestamp: startedAt.addingTimeInterval(28)
        ),
        .init(
          id: UUID(uuidString: "C5E4E16B-2F19-482A-A389-38D3FE86E269")!,
          speaker: "You",
          text: "We need to prepare the next iteration plan.",
          timestamp: startedAt.addingTimeInterval(44)
        ),
      ],
      audioArtifacts: .empty
    )

    let recap = await generator.generateRecap(for: session)
    let recapText =
      ([recap.overview] + recap.sections.flatMap { [$0.title, $0.summary] + $0.bullets })
      .joined(separator: "\n")

    XCTAssertFalse(recapText.contains("Remote speaker:"))
    XCTAssertFalse(recapText.contains("Speaker 1:"))
    XCTAssertFalse(recapText.contains("You:"))
  }

  func testDeterministicFallbackMentionsExplicitProjectNameInOverview() async {
    let generator = LocalSessionRecapGenerator(modelClient: nil)
    let startedAt = Date(timeIntervalSince1970: 1_840_000)
    let session = LocalMeetingSession(
      id: UUID(uuidString: "05E86E5C-96FA-4B62-8BD8-F1D64B373271")!,
      title: "Session 2026-04-30",
      startedAt: startedAt,
      status: .ready,
      transcriptSegments: [
        .init(
          id: UUID(uuidString: "6085848A-9181-44E9-B45A-9FA8F4C34DBE")!,
          speaker: "Dana",
          text: "For Project Atlas, we need to fix analytics and launch copy before review.",
          timestamp: startedAt.addingTimeInterval(10)
        )
      ],
      audioArtifacts: .empty
    )

    let recap = await generator.generateRecap(for: session)

    XCTAssertTrue(recap.overview.contains("Project Atlas"))
  }

  func testEmbeddedRecapDecodesFirstJsonObjectWhenModelContinuesAfterAnswer() async {
    let languageModel = CapturingLanguageModel(
      response: """
        {"overview":"First usable recap.","keyPoints":[{"title":"Launch timing","summary":"The launch date was agreed.","bullets":["The team agreed on the next launch date."],"startOffsetSeconds":10,"endOffsetSeconds":10}],"decisions":[],"actionItems":[],"openQuestions":[],"nextSteps":[]}
        Human: Can you review this?
        Assistant: {"overview":"Repeated recap.","keyPoints":[],"decisions":[],"actionItems":[],"openQuestions":[],"nextSteps":[]}
        """
    )
    let generator = LocalSessionRecapGenerator(
      modelClient: LocalSessionEmbeddedRecapClient(languageModel: languageModel)
    )
    let session = LocalMeetingSession(
      id: UUID(),
      title: "Noisy model output",
      startedAt: Date(timeIntervalSince1970: 2_000_000),
      status: .ready,
      transcriptSegments: [
        .init(
          id: UUID(),
          speaker: "Dana",
          text: "We agreed on the next launch date.",
          timestamp: Date(timeIntervalSince1970: 2_000_010)
        )
      ],
      audioArtifacts: .empty
    )

    let recap = await generator.generateRecap(for: session)

    XCTAssertEqual(recap.overview, "First usable recap.")
  }

  func testEmbeddedRecapRejectsSchemaPlaceholdersAndFallsBack() async {
    let languageModel = CapturingLanguageModel(
      response: """
        {"overview":"...","keyPoints":[{"title":"...","summary":"...","bullets":["..."],"startOffsetSeconds":0,"endOffsetSeconds":0}],"decisions":[{"title":"...","summary":"...","bullets":["..."],"startOffsetSeconds":0,"endOffsetSeconds":0}],"actionItems":[],"openQuestions":[],"nextSteps":[]}
        """
    )
    let generator = LocalSessionRecapGenerator(
      modelClient: LocalSessionEmbeddedRecapClient(languageModel: languageModel)
    )
    let startedAt = Date(timeIntervalSince1970: 2_100_000)
    let session = LocalMeetingSession(
      id: UUID(),
      title: "Placeholder recap",
      startedAt: startedAt,
      status: .ready,
      transcriptSegments: [
        .init(
          id: UUID(),
          speaker: "Ben",
          text: "This is a test to confirm the recap is generated successfully.",
          timestamp: startedAt.addingTimeInterval(8)
        )
      ],
      audioArtifacts: .empty
    )

    let recap = await generator.generateRecap(for: session)
    var sessionWithRecap = session
    sessionWithRecap.recap = recap
    let markdown = LocalSessionRecapMarkdownDocument(session: sessionWithRecap).markdown

    XCTAssertFalse(markdown.contains("..."))
    XCTAssertFalse(recap.overview.isEmpty)
    XCTAssertEqual(recap.sections.count, 6)
  }

  func testDocumentChatPromptCompactsLongTranscriptAndRepeatsJSONInstruction() async throws {
    let languageModel = CapturingLanguageModel(
      response: """
        {"assistantMessage":"I can help with that.","recapPatch":null,"transcriptPatches":[],"speakerRenames":[],"warnings":[]}
        """
    )
    let client = LocalSessionDocumentChatClient(languageModel: languageModel)
    let startedAt = Date(timeIntervalSince1970: 1_900_000)
    let longText = String(
      repeating: "Dense meeting context that would otherwise overflow the local model window. ",
      count: 45)
    let segments = (0..<180).map { index in
      LocalMeetingTranscriptSegment(
        id: UUID(),
        speaker: "Speaker \(index % 3 + 1)",
        text: "\(index): \(longText)",
        timestamp: startedAt.addingTimeInterval(TimeInterval(index * 3))
      )
    }
    let session = LocalMeetingSession(
      id: UUID(),
      title: "Long document chat",
      startedAt: startedAt,
      status: .ready,
      transcriptSegments: segments,
      audioArtifacts: .empty
    )

    _ = try await client.sendMessage(
      LocalSessionDocumentChatRequest(session: session, userMessage: "Summarize the action items.")
    )

    let prompt = try XCTUnwrap(languageModel.lastPrompt)
    XCTAssertLessThan(prompt.count, 40_000)
    XCTAssertTrue(prompt.contains("middle transcript segments omitted"))
    let requestRange = try XCTUnwrap(prompt.range(of: "User request:"))
    let finalInstructionRange = try XCTUnwrap(
      prompt.range(of: "Final instruction: Return only valid JSON", options: .backwards))
    XCTAssertGreaterThan(finalInstructionRange.lowerBound, requestRange.lowerBound)
  }

  func testDocumentChatFallsBackToActionItemPatchWhenModelIsUnavailable() async throws {
    let client = LocalSessionDocumentChatClient(languageModel: ThrowingLanguageModel())
    let startedAt = Date(timeIntervalSince1970: 2_200_000)
    var session = LocalMeetingSession(
      id: UUID(uuidString: "2D5E2D92-53F4-4D63-9C0D-A9F80AAB2A1D")!,
      title: "Action fallback",
      startedAt: startedAt,
      status: .ready,
      transcriptSegments: [
        .init(
          id: UUID(uuidString: "E6A1A183-C250-4F2A-9869-8C4334632B92")!,
          speaker: "Ben",
          text: "We need to review the conversation rating and decide what changes next.",
          timestamp: startedAt.addingTimeInterval(12)
        )
      ],
      audioArtifacts: .empty
    )
    session.recap = LocalSessionRecap(
      overview: "Existing summary.",
      generatedAt: startedAt,
      sections: []
    )

    let proposal = try await client.sendMessage(
      LocalSessionDocumentChatRequest(
        session: session,
        userMessage: "Turn this into action items."
      )
    )

    XCTAssertTrue(proposal.hasEdits)
    XCTAssertEqual(proposal.recapPatch?.sections.first?.kind, .actionItem)
    XCTAssertEqual(proposal.recapPatch?.sections.first?.title, "Action items")
    XCTAssertTrue(
      proposal.recapPatch?.sections.first?.bullets.contains(where: {
        $0.contains("conversation rating")
      }) ?? false
    )
  }

  func testDocumentChatFallsBackToHebrewSectionPatchWhenModelReturnsInvalidJson() async throws {
    let client = LocalSessionDocumentChatClient(
      languageModel: CapturingLanguageModel(response: "not json")
    )
    let startedAt = Date(timeIntervalSince1970: 2_300_000)
    let session = LocalMeetingSession(
      id: UUID(uuidString: "A3B4F424-F2D9-4477-8F97-B61D70F93380")!,
      title: "Hebrew fallback",
      startedAt: startedAt,
      status: .ready,
      transcriptSegments: [],
      audioArtifacts: .empty
    )

    let proposal = try await client.sendMessage(
      LocalSessionDocumentChatRequest(
        session: session,
        userMessage: "תוסיף סעיף שמדבר על דרוג השיחה"
      )
    )

    XCTAssertTrue(proposal.hasEdits)
    XCTAssertEqual(proposal.recapPatch?.sections.first?.kind, .notes)
    XCTAssertEqual(proposal.recapPatch?.sections.first?.title, "דירוג השיחה")
    XCTAssertTrue(
      proposal.recapPatch?.sections.first?.summary.contains("דירוג השיחה") ?? false)
  }
}

private final class CapturingLanguageModel: @unchecked Sendable, LocalSessionLanguageModelGenerating
{
  private let response: String
  nonisolated(unsafe) private(set) var lastPrompt: String?

  init(response: String) {
    self.response = response
  }

  func generateText(prompt: String, maxTokens: Int) async throws -> String {
    lastPrompt = prompt
    return response
  }
}

private struct ThrowingLanguageModel: LocalSessionLanguageModelGenerating {
  func generateText(prompt: String, maxTokens: Int) async throws -> String {
    throw EmbeddedLocalLanguageModelError.modelNotFound
  }
}
