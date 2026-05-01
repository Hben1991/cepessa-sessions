import Foundation
import XCTest

@testable import CepessaSessions

final class LocalMeetingRecapGeneratorTests: XCTestCase {
  func testDefaultModelClientFallsBackToLocalModel() {
    let client = LocalSessionRecapGenerator.defaultModelClient()

    XCTAssertNotNil(client as? LocalSessionEmbeddedRecapClient)
  }

  func testEmbeddedLocalModelTimeoutScalesWithDocumentPromptSize() {
    let shortTimeout = EmbeddedLocalLanguageModel.timeoutSeconds(
      prompt: "Return JSON.",
      maxTokens: 32
    )
    let longTimeout = EmbeddedLocalLanguageModel.timeoutSeconds(
      prompt: String(repeating: "Detailed document context. ", count: 1_600),
      maxTokens: 900
    )

    XCTAssertGreaterThanOrEqual(shortTimeout, 30)
    XCTAssertGreaterThan(longTimeout, shortTimeout)
    XCTAssertLessThanOrEqual(longTimeout, 90)
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
    XCTAssertGreaterThanOrEqual(recap.sections.count, 4)
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

  func testContentClassifierDoesNotTreatBareSystemAudioAsVideoCommentary() async {
    let classifier = LocalSessionContentClassifier(modelClient: nil)
    let startedAt = Date(timeIntervalSince1970: 1_816_500)
    let session = LocalMeetingSession(
      id: UUID(uuidString: "99444D84-1F49-4F22-A585-A44F6D9FBE65")!,
      title: "Session 2026-04-29",
      startedAt: startedAt,
      status: .ready,
      transcriptSegments: [
        .init(
          id: UUID(uuidString: "A28F3A5E-9B7A-412C-AD5C-C3783825F270")!,
          speaker: "local model",
          text: "אני רוצה לראות באמת שהוא מסכם את המסמך.",
          timestamp: startedAt.addingTimeInterval(2)
        )
      ],
      audioArtifacts: .init(
        micFileName: "mic.wav",
        systemFileName: "system.wav",
        mixedFileName: "mixed.wav"
      )
    )

    let classification = await classifier.classifyContent(for: session)

    XCTAssertNotEqual(classification.type, .videoCommentary)
    XCTAssertEqual(classification.type, .generalTranscript)
  }

  func testContentClassifierTreatsHebrewYoutubeSystemAudioAsVideoCommentary() async {
    let classifier = LocalSessionContentClassifier(modelClient: nil)
    let startedAt = Date(timeIntervalSince1970: 1_816_700)
    let session = LocalMeetingSession(
      id: UUID(uuidString: "7E394154-B14B-4D4A-A71E-8C85EE05E06B")!,
      title: "Session 30 Apr 2026 at 12:26",
      startedAt: startedAt,
      status: .ready,
      transcriptSegments: [
        .init(
          id: UUID(uuidString: "4BA0F1D4-F5A6-4730-9682-23ED70435932")!,
          speaker: "You",
          text: "ועכשיו אני למשל לוקח סרטון, בואו ניקח איזה סרטון",
          timestamp: startedAt
        ),
        .init(
          id: UUID(uuidString: "3C1F92EF-278D-4221-87AB-D9F2950094D7")!,
          speaker: "You",
          text: "ההיסטוריה שראיתי ביוטיוב, אני רוצה משהו בעברית.",
          timestamp: startedAt.addingTimeInterval(4)
        ),
        .init(
          id: UUID(uuidString: "6C023377-27BD-4B3A-A5E3-15020F88B5F0")!,
          speaker: "Remote speaker",
          text: "זה הלייב של מורה מבוכים של ערוץ דונקי.",
          timestamp: startedAt.addingTimeInterval(8)
        ),
      ],
      audioArtifacts: .init(
        micFileName: "mic.wav",
        systemFileName: "system.wav",
        mixedFileName: "mixed.wav"
      )
    )

    let classification = await classifier.classifyContent(for: session)

    XCTAssertEqual(classification.type, .videoCommentary)
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
    XCTAssertFalse(recap.sections.isEmpty)
    XCTAssertFalse(recap.sections.contains(where: { $0.bullets.contains("...") }))
  }

  func testDeterministicFallbackWritesHebrewBriefForHebrewGeneralTranscript() async {
    let generator = LocalSessionRecapGenerator(modelClient: nil)
    let startedAt = Date(timeIntervalSince1970: 2_150_000)
    var session = LocalMeetingSession(
      id: UUID(uuidString: "8AFC4AFF-1E45-4FF0-AD89-7EE8C4506253")!,
      title: "Session 29 Apr 2026 at 13:38",
      startedAt: startedAt,
      status: .ready,
      transcriptSegments: [
        .init(
          id: UUID(uuidString: "AC2D1353-B53B-4C96-A781-FE1CB55A7702")!,
          speaker: "local model",
          text: "אוקיי, אני עושה כרגע בדיקה.",
          timestamp: startedAt
        ),
        .init(
          id: UUID(uuidString: "B3DF2F80-5062-4EBE-8794-243B71E5B550")!,
          speaker: "local model",
          text: "אני רוצה לראות באמת שהוא מסכם את המסמך.",
          timestamp: startedAt.addingTimeInterval(2)
        ),
        .init(
          id: UUID(uuidString: "8EBE6D8D-C1D2-4178-AC4A-6EF7EAE76966")!,
          speaker: "local model",
          text: "במידה והוא מסכם את המסמך הייתי רוצה שהוא יציין שזה הצלחה.",
          timestamp: startedAt.addingTimeInterval(6)
        ),
      ],
      audioArtifacts: .empty
    )
    session.contentClassification = .init(
      type: .generalTranscript,
      confidence: 0.62,
      rationale: "Single-speaker Hebrew test note.",
      generatedAt: startedAt.addingTimeInterval(10)
    )

    let recap = await generator.generateRecap(for: session)
    let recapText =
      ([recap.overview] + recap.sections.flatMap { [$0.title, $0.summary] + $0.bullets })
      .joined(separator: "\n")

    XCTAssertTrue(recapText.contains("בדיק"))
    XCTAssertTrue(recapText.contains("מסכם את המסמך"))
    XCTAssertTrue(recapText.contains("הצלחה"))
    XCTAssertFalse(recapText.contains("video commentary"))
    XCTAssertFalse(recapText.contains("source material"))
  }

  func testDeterministicFallbackWritesHebrewVideoBriefForYoutubeRoleplayCapture() async {
    let generator = LocalSessionRecapGenerator(modelClient: nil)
    let startedAt = Date(timeIntervalSince1970: 2_155_000)
    var session = LocalMeetingSession(
      id: UUID(uuidString: "E565E77E-F203-42B2-A14F-96CD3E23CE66")!,
      title: "Session 30 Apr 2026 at 12:26",
      startedAt: startedAt,
      status: .ready,
      transcriptSegments: [
        .init(
          id: UUID(uuidString: "88C0D952-9A72-49D0-8741-EC23E3D4454A")!,
          speaker: "You",
          text: "ועכשיו אני למשל לוקח סרטון, בואו ניקח איזה סרטון.",
          timestamp: startedAt
        ),
        .init(
          id: UUID(uuidString: "66A13A6F-7CA7-4A69-B72D-B42A92D5D35D")!,
          speaker: "You",
          text: "ההיסטוריה שראיתי ביוטיוב, אני רוצה משהו בעברית.",
          timestamp: startedAt.addingTimeInterval(3)
        ),
        .init(
          id: UUID(uuidString: "326204B6-E96F-44E5-A141-73249B4799D5")!,
          speaker: "Remote speaker",
          text: "זה הלייב של מורה מבוכים של ערוץ דונקי.",
          timestamp: startedAt.addingTimeInterval(8)
        ),
        .init(
          id: UUID(uuidString: "3B665E6C-6686-4BC0-8C89-52F1D3184376")!,
          speaker: "Remote speaker",
          text: "את מצליחה להתחבא מאחורי השיח ולתקוף אותו.",
          timestamp: startedAt.addingTimeInterval(16)
        ),
        .init(
          id: UUID(uuidString: "849E3A90-D358-4E53-8E4F-C8C9DC13D048")!,
          speaker: "Remote speaker",
          text: "החץ חולף ליד האוזן שלו ופוגע בגזע העץ המושחת שמאחוריו.",
          timestamp: startedAt.addingTimeInterval(24)
        ),
      ],
      audioArtifacts: .init(
        micFileName: "mic.wav",
        systemFileName: "system.wav",
        mixedFileName: "mixed.wav"
      )
    )
    session.contentClassification = .init(
      type: .videoCommentary,
      confidence: 0.8,
      rationale: "Detected Hebrew YouTube video commentary.",
      generatedAt: startedAt.addingTimeInterval(30)
    )

    let recap = await generator.generateRecap(for: session)
    let combined =
      ([recap.overview] + recap.sections.flatMap { [$0.title, $0.summary] + $0.bullets })
      .joined(separator: "\n")

    XCTAssertTrue(combined.contains("יוטיוב") || combined.contains("מורה מבוכים"))
    XCTAssertTrue(combined.contains("סרטון"))
    XCTAssertFalse(combined.contains("Hebrew localization"))
    XCTAssertFalse(combined.contains("RTL"))
    XCTAssertFalse(combined.contains("בואו ניקח איזה סרטון ההיסטוריה"))
  }

  func testDeterministicFallbackKeepsHebrewVideoBriefCompactWhenNoActionWasGiven() async {
    let generator = LocalSessionRecapGenerator(modelClient: nil)
    let startedAt = Date(timeIntervalSince1970: 2_156_000)
    var session = LocalMeetingSession(
      id: UUID(uuidString: "F3BB68FA-91DD-4EFA-8422-E02F4B8C63E0")!,
      title: "Session 30 Apr 2026 at 12:26",
      startedAt: startedAt,
      status: .ready,
      transcriptSegments: [
        .init(
          id: UUID(uuidString: "47CD9F8C-F19B-4875-B39D-D6D977B7E534")!,
          speaker: "You",
          text: "ועכשיו אני למשל לוקח סרטון מההיסטוריה שראיתי ביוטיוב.",
          timestamp: startedAt
        ),
        .init(
          id: UUID(uuidString: "258F992A-AEE8-43C2-A600-4E26F5C98768")!,
          speaker: "Remote speaker",
          text: "זה הלייב של מורה מבוכים של ערוץ דונקי.",
          timestamp: startedAt.addingTimeInterval(6)
        ),
        .init(
          id: UUID(uuidString: "25682734-6F81-41F0-83D3-A642249EBBBE")!,
          speaker: "Remote speaker",
          text: "החץ מחטיא ופוגע בעץ המושחת שמאחוריו.",
          timestamp: startedAt.addingTimeInterval(14)
        ),
      ],
      audioArtifacts: .init(
        micFileName: "mic.wav",
        systemFileName: "system.wav",
        mixedFileName: "mixed.wav"
      )
    )
    session.contentClassification = .init(
      type: .videoCommentary,
      confidence: 0.8,
      rationale: "Hebrew YouTube capture.",
      generatedAt: startedAt.addingTimeInterval(20)
    )

    let recap = await generator.generateRecap(for: session)
    let text = ([recap.overview] + recap.sections.flatMap { [$0.title, $0.summary] + $0.bullets })
      .joined(separator: "\n")

    XCTAssertLessThanOrEqual(recap.sections.filter { $0.kind != .overview }.count, 2)
    XCTAssertNil(recap.section(kind: .actionItem))
    XCTAssertNil(recap.section(kind: .openQuestions))
    XCTAssertFalse(text.contains("אם מטרת המסמך"))
    XCTAssertFalse(text.contains("שאלות שנותרו"))
  }

  func testHebrewMarkdownPresentationRebuildsSpecificBriefFromHebrewTranscript() {
    let startedAt = Date(timeIntervalSince1970: 2_160_000)
    var session = LocalMeetingSession(
      id: UUID(uuidString: "8AFC4AFF-1E45-4FF0-AD89-7EE8C4506253")!,
      title: "Session 29 Apr 2026 at 13:38",
      startedAt: startedAt,
      status: .ready,
      transcriptSegments: [
        .init(
          id: UUID(uuidString: "AC2D1353-B53B-4C96-A781-FE1CB55A7702")!,
          speaker: "local model",
          text: "אני רוצה לראות באמת שהוא מסכם את המסמך.",
          timestamp: startedAt
        ),
        .init(
          id: UUID(uuidString: "8EBE6D8D-C1D2-4178-AC4A-6EF7EAE76966")!,
          speaker: "local model",
          text: "במידה והוא מסכם את המסמך הייתי רוצה שהוא יציין שזה הצלחה.",
          timestamp: startedAt.addingTimeInterval(4)
        ),
      ],
      audioArtifacts: .empty
    )
    session.contentClassification = .init(
      type: .videoCommentary,
      confidence: 0.8,
      rationale: "Legacy false positive.",
      generatedAt: startedAt.addingTimeInterval(8)
    )
    session.recap = LocalSessionRecap(
      overview: "The video commentary captured the main areas that need follow-up.",
      generatedAt: startedAt,
      sections: []
    )

    let markdown = LocalSessionRecapMarkdownDocument.markdown(for: session, language: .hebrew)

    XCTAssertTrue(markdown.contains("בדיקת סיכום"))
    XCTAssertTrue(markdown.contains("מסכם את המסמך"))
    XCTAssertTrue(markdown.contains("הצלחה"))
    XCTAssertFalse(markdown.contains("סרטון"))
    XCTAssertFalse(markdown.contains("video commentary"))
  }

  func testHebrewMarkdownPresentationRebuildsYoutubeRoleplayBriefFromStaleEnglishRecap() {
    let startedAt = Date(timeIntervalSince1970: 2_165_000)
    var session = LocalMeetingSession(
      id: UUID(uuidString: "8E10F51A-ED0F-4C59-AAB9-33863D109920")!,
      title: "Session 30 Apr 2026 at 12:26",
      startedAt: startedAt,
      status: .ready,
      transcriptSegments: [
        .init(
          id: UUID(uuidString: "86981B77-9708-4413-BB92-855AFB7B83A0")!,
          speaker: "You",
          text: "ועכשיו אני למשל לוקח סרטון, בואו ניקח איזה סרטון.",
          timestamp: startedAt
        ),
        .init(
          id: UUID(uuidString: "047A0E7C-917E-47F3-A9BD-3B21B58D16AF")!,
          speaker: "You",
          text: "ההיסטוריה שראיתי ביוטיוב, אני רוצה משהו בעברית.",
          timestamp: startedAt.addingTimeInterval(4)
        ),
        .init(
          id: UUID(uuidString: "042AF46D-A33C-4B8E-890C-24F76F4068A1")!,
          speaker: "Remote speaker",
          text: "זה הלייב של מורה מבוכים של ערוץ דונקי.",
          timestamp: startedAt.addingTimeInterval(8)
        ),
        .init(
          id: UUID(uuidString: "A7834791-578E-4D34-A290-4B63F068FEE8")!,
          speaker: "Remote speaker",
          text: "את מצליחה להתחבא מאחורי השיח ולתקוף אותו.",
          timestamp: startedAt.addingTimeInterval(16)
        ),
      ],
      audioArtifacts: .empty
    )
    session.recap = LocalSessionRecap(
      overview: "The source material focused on Hebrew localization and RTL support.",
      generatedAt: startedAt,
      sections: []
    )

    let markdown = LocalSessionRecapMarkdownDocument.markdown(for: session, language: .hebrew)

    XCTAssertTrue(markdown.contains("יוטיוב") || markdown.contains("מורה מבוכים"))
    XCTAssertTrue(markdown.contains("סרטון"))
    XCTAssertFalse(markdown.contains("RTL"))
    XCTAssertFalse(markdown.contains("לוקליזציה"))
    XCTAssertFalse(markdown.contains("בואו ניקח איזה סרטון ההיסטוריה"))
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
    XCTAssertEqual(proposal.sourceCitations.first?.segmentID, session.transcriptSegments.first?.id)
    XCTAssertTrue(proposal.sourceCitations.first?.excerpt.contains("conversation rating") ?? false)
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

  func testDocumentChatFallsBackToHebrewEndParagraphPatchWhenTextIsProvided() async throws {
    let client = LocalSessionDocumentChatClient(
      languageModel: CapturingLanguageModel(response: "not json")
    )
    let startedAt = Date(timeIntervalSince1970: 2_310_000)
    let session = LocalMeetingSession(
      id: UUID(uuidString: "1EC606AB-C8D5-46DE-A7B2-4CBAD3DF016C")!,
      title: "Hebrew append fallback",
      startedAt: startedAt,
      status: .ready,
      transcriptSegments: [],
      audioArtifacts: .empty
    )

    let proposal = try await client.sendMessage(
      LocalSessionDocumentChatRequest(
        session: session,
        userMessage: "תוסיף בסוף המסמך: הדמויות ממשיכות לנוע בזהירות בתוך היער."
      )
    )

    XCTAssertTrue(proposal.hasEdits)
    XCTAssertEqual(proposal.recapPatch?.sections.first?.kind, .notes)
    XCTAssertEqual(proposal.recapPatch?.sections.first?.title, "המשך המסמך")
    XCTAssertEqual(
      proposal.recapPatch?.sections.first?.summary,
      "הדמויות ממשיכות לנוע בזהירות בתוך היער."
    )
    XCTAssertTrue(proposal.recapPatch?.sections.first?.bullets.isEmpty ?? false)
  }

  func testDocumentChatDoesNotWriteHebrewAppendInstructionAsDocumentContent() async throws {
    let client = LocalSessionDocumentChatClient(
      languageModel: CapturingLanguageModel(response: "not json")
    )
    let startedAt = Date(timeIntervalSince1970: 2_315_000)
    let session = LocalMeetingSession(
      id: UUID(uuidString: "87D6A0FE-69E6-412A-BAF1-848D118B25E1")!,
      title: "Missing append content",
      startedAt: startedAt,
      status: .ready,
      transcriptSegments: [],
      audioArtifacts: .empty
    )

    let proposal = try await client.sendMessage(
      LocalSessionDocumentChatRequest(
        session: session,
        userMessage: "תוסיף את המלל בסוף המסמך. תרשום את זה כמו ספר."
      )
    )

    XCTAssertFalse(proposal.hasEdits)
    XCTAssertNil(proposal.recapPatch)
    XCTAssertTrue(proposal.assistantMessage.contains("איזה מלל"))
    XCTAssertFalse(proposal.assistantMessage.contains("עדכנתי את המסמך"))
  }

  func testDocumentChatBuildsHebrewStoryContinuationFromTranscriptAppendRequest() async throws {
    let client = LocalSessionDocumentChatClient(
      languageModel: CapturingLanguageModel(response: "not json")
    )
    let startedAt = Date(timeIntervalSince1970: 2_316_000)
    let session = LocalMeetingSession(
      id: UUID(uuidString: "42326B44-D613-4946-B36C-4917BEE9112F")!,
      title: "מבוכים ודרקונים",
      startedAt: startedAt,
      status: .ready,
      transcriptSegments: [
        .init(
          id: UUID(uuidString: "92892174-B574-472F-AE50-84AEBC4253D7")!,
          speaker: "You",
          text: "ניסיון התגנבות ותקיפה, גלגולי קובייה, חץ שמחטיא ופוגע בעץ מושחת.",
          timestamp: startedAt.addingTimeInterval(6)
        ),
        .init(
          id: UUID(uuidString: "C83E9F20-052E-4D94-AE62-88C62B0A8F30")!,
          speaker: "You",
          text: "מריק, מיכאל והמכשפה נשארים מול איום שממשיך להסתבך סביב היער.",
          timestamp: startedAt.addingTimeInterval(24)
        ),
      ],
      audioArtifacts: .empty
    )

    let proposal = try await client.sendMessage(
      LocalSessionDocumentChatRequest(
        session: session,
        userMessage: "תוסיף את התמלול בסוף המסמך. תרשום את זה כמו סיפור."
      )
    )

    let section = try XCTUnwrap(proposal.recapPatch?.sections.first)
    XCTAssertTrue(proposal.hasEdits)
    XCTAssertEqual(section.kind, .notes)
    XCTAssertEqual(section.title, "המשך הסיפור")
    XCTAssertTrue(section.summary.contains("מריק"))
    XCTAssertTrue(section.summary.contains("מיכאל"))
    XCTAssertTrue(section.summary.contains("המכשפה"))
    XCTAssertFalse(section.summary.contains("תוסיף"))
    XCTAssertFalse(section.summary.contains("תרשום"))
    XCTAssertFalse(section.summary.contains("התמלול בסוף המסמך"))
    XCTAssertEqual(proposal.sourceCitations.first?.segmentID, session.transcriptSegments.first?.id)
  }

  func testDocumentChatRejectsModelEchoOfHebrewAppendInstruction() async throws {
    let client = LocalSessionDocumentChatClient(
      languageModel: CapturingLanguageModel(
        response: """
          {
            "assistantMessage":"הוספתי פסקת המשך בסוף המסמך.",
            "recapPatch":{
              "overview":null,
              "sections":[
                {"kind":"notes","title":"המשך המסמך","summary":"תוסיף את התמלול בסוף המסמך","bullets":[]}
              ]
            },
            "transcriptPatches":[],
            "speakerRenames":[],
            "warnings":[]
          }
          """
      )
    )
    let startedAt = Date(timeIntervalSince1970: 2_317_000)
    let session = LocalMeetingSession(
      id: UUID(uuidString: "9595C3AF-2D96-428E-A61E-AB39D2962765")!,
      title: "מבוכים ודרקונים",
      startedAt: startedAt,
      status: .ready,
      transcriptSegments: [
        .init(
          id: UUID(uuidString: "59F2E8EE-86BF-485D-85E1-C248FC154375")!,
          speaker: "You",
          text: "מריק ומיכאל ממשיכים להתקדם ביער בזמן שהמכשפה אורבת להם.",
          timestamp: startedAt.addingTimeInterval(6)
        )
      ],
      audioArtifacts: .empty
    )

    let proposal = try await client.sendMessage(
      LocalSessionDocumentChatRequest(
        session: session,
        userMessage: "תוסיף את התמלול בסוף המסמך. תרשום את זה כמו סיפור."
      )
    )

    let section = try XCTUnwrap(proposal.recapPatch?.sections.first)
    XCTAssertEqual(section.title, "המשך הסיפור")
    XCTAssertTrue(section.summary.contains("מריק"))
    XCTAssertFalse(section.summary.contains("תוסיף"))
    XCTAssertFalse(section.summary.contains("התמלול בסוף המסמך"))
  }

  func testDocumentChatTreatsHebrewConciseStyleRequestAsDocumentEditWhenModelReturnsNoPatch()
    async throws
  {
    let client = LocalSessionDocumentChatClient(
      languageModel: CapturingLanguageModel(
        response: """
          {"assistantMessage":"קיצרתי וכתבתי מחדש.","recapPatch":null,"transcriptPatches":[],"speakerRenames":[],"warnings":[]}
          """
      )
    )
    let startedAt = Date(timeIntervalSince1970: 2_320_000)
    var session = LocalMeetingSession(
      id: UUID(uuidString: "52F2BEE2-508B-4885-94DB-99064D6B761C")!,
      title: "Hebrew style edit",
      startedAt: startedAt,
      status: .ready,
      transcriptSegments: [
        .init(
          id: UUID(uuidString: "206BC240-3C3A-4D0B-A8A7-C77F16D85743")!,
          speaker: "You",
          text: "אני בודק שהסיכום יהיה קצר וברוח ההקלטה עצמה.",
          timestamp: startedAt
        )
      ],
      audioArtifacts: .empty
    )
    session.recap = LocalSessionRecap(
      overview: "זהו סיכום ארוך מדי שמפרט מעבר למה שנדרש מההקלטה עצמה.",
      generatedAt: startedAt,
      sections: []
    )

    let proposal = try await client.sendMessage(
      LocalSessionDocumentChatRequest(
        session: session,
        userMessage: "תקצר ותכתוב ברוח ההקלטה עצמה"
      )
    )

    XCTAssertTrue(proposal.hasEdits)
    XCTAssertNotNil(proposal.recapPatch)
    XCTAssertTrue(proposal.assistantMessage.contains("קיצרתי"))
  }

  func testDocumentChatTreatsHebrewTitleRequestAsTitlePatchWhenModelReturnsInvalidJson()
    async throws
  {
    let client = LocalSessionDocumentChatClient(
      languageModel: CapturingLanguageModel(response: "not json")
    )
    let startedAt = Date(timeIntervalSince1970: 2_330_000)
    let session = LocalMeetingSession(
      id: UUID(uuidString: "6E6B8369-DDF4-4421-A2F8-3D7A58863023")!,
      title: "Session 30 Apr 2026 at 12:26",
      startedAt: startedAt,
      status: .ready,
      transcriptSegments: [],
      audioArtifacts: .empty
    )

    let proposal = try await client.sendMessage(
      LocalSessionDocumentChatRequest(
        session: session,
        userMessage: "תעדכן את הכותרת - קטע מלייב של מורה מבוכים ערוץ דונקי"
      )
    )

    XCTAssertTrue(proposal.hasEdits)
    XCTAssertEqual(proposal.sessionTitle, "קטע מלייב של מורה מבוכים ערוץ דונקי")
    XCTAssertNil(proposal.recapPatch)
  }

  func testDocumentChatFallbackWarningHidesRawLocalModelLoaderFailure() async throws {
    let client = LocalSessionDocumentChatClient(
      languageModel: ThrowingMessageLanguageModel(
        message: """
          dyld[98025]: Library not loaded: @rpath/llama.framework/Versions/Current/llama
            Referenced from: /private/tmp/CepessaLocalModelRunner
          """
      )
    )
    let startedAt = Date(timeIntervalSince1970: 2_340_000)
    let session = LocalMeetingSession(
      id: UUID(uuidString: "8B87E819-BF54-4119-8A70-DAE55EE5B3E5")!,
      title: "Session 30 Apr 2026 at 12:26",
      startedAt: startedAt,
      status: .ready,
      transcriptSegments: [
        .init(
          id: UUID(uuidString: "FBB0D060-5574-4721-9EAA-5C919166C4B1")!,
          speaker: "You",
          text: "The title should describe the session cleanly.",
          timestamp: startedAt
        )
      ],
      audioArtifacts: .empty
    )

    let proposal = try await client.sendMessage(
      LocalSessionDocumentChatRequest(
        session: session,
        userMessage: "Update the title - QA agent check"
      )
    )

    let warning = try XCTUnwrap(proposal.warnings.first)
    XCTAssertEqual(
      warning, "Used deterministic fallback because the local model response was unavailable.")
    XCTAssertFalse(warning.contains("dyld"))
    XCTAssertFalse(warning.contains("@rpath"))
    XCTAssertFalse(warning.contains("/private/tmp"))
  }

  func testDocumentChatFallsBackToHebrewQuestionAnswerWhenModelReturnsInvalidJson() async throws {
    let client = LocalSessionDocumentChatClient(
      languageModel: CapturingLanguageModel(response: "not json")
    )
    let startedAt = Date(timeIntervalSince1970: 2_350_000)
    var session = LocalMeetingSession(
      id: UUID(uuidString: "8AFC4AFF-1E45-4FF0-AD89-7EE8C4506253")!,
      title: "Session 29 Apr 2026 at 13:38",
      startedAt: startedAt,
      status: .ready,
      transcriptSegments: [
        .init(
          id: UUID(uuidString: "AC2D1353-B53B-4C96-A781-FE1CB55A7702")!,
          speaker: "local model",
          text: "אוקיי, אני עושה כרגע בדיקה.",
          timestamp: startedAt
        ),
        .init(
          id: UUID(uuidString: "B3DF2F80-5062-4EBE-8794-243B71E5B550")!,
          speaker: "local model",
          text: "אני רוצה לראות באמת שהוא מסכם את המסמך.",
          timestamp: startedAt.addingTimeInterval(2)
        ),
      ],
      audioArtifacts: .empty
    )
    session.recap = LocalSessionRecap(
      overview: "המסמך עוסק בבדיקת סיכום של המודל המקומי.",
      generatedAt: startedAt,
      sections: []
    )

    let proposal = try await client.sendMessage(
      LocalSessionDocumentChatRequest(
        session: session,
        userMessage: "על מה המסמך?"
      )
    )

    XCTAssertFalse(proposal.hasEdits)
    XCTAssertTrue(proposal.assistantMessage.contains("המסמך"))
    XCTAssertTrue(proposal.assistantMessage.contains("מסכם"))
    XCTAssertFalse(proposal.assistantMessage.contains("clean document edit"))
  }

  func testDocumentChatHebrewAboutQuestionSummarizesVideoInsteadOfRepeatingOpeningTranscript()
    async throws
  {
    let client = LocalSessionDocumentChatClient(
      languageModel: CapturingLanguageModel(response: "not json")
    )
    let startedAt = Date(timeIntervalSince1970: 2_360_000)
    var session = LocalMeetingSession(
      id: UUID(uuidString: "8E10F51A-ED0F-4C59-AAB9-33863D109920")!,
      title: "Session 30 Apr 2026 at 12:26",
      startedAt: startedAt,
      status: .ready,
      transcriptSegments: [
        .init(
          id: UUID(uuidString: "9D9D9F87-0812-48E6-8D7E-FF726105C237")!,
          speaker: "You",
          text: "ועכשיו אני למשל לוקח סרטון, בואו ניקח איזה סרטון",
          timestamp: startedAt
        ),
        .init(
          id: UUID(uuidString: "4B8171B0-6745-40D5-8E61-20C6D792C27F")!,
          speaker: "You",
          text: "ההיסטוריה שראיתי ביוטיוב, אני רוצה משהו בעברית.",
          timestamp: startedAt.addingTimeInterval(4)
        ),
        .init(
          id: UUID(uuidString: "6E7F4EC1-E5CC-4C01-9B97-CFEC1EA34397")!,
          speaker: "Remote speaker",
          text: "זה הלייב של מורה מבוכים של ערוץ דונקי.",
          timestamp: startedAt.addingTimeInterval(8)
        ),
        .init(
          id: UUID(uuidString: "89D77003-6F52-43E0-87E3-D5DF73FB0B4A")!,
          speaker: "Remote speaker",
          text: "את מצליחה להתחבא מאחורי השיח ולתקוף אותו.",
          timestamp: startedAt.addingTimeInterval(18)
        ),
      ],
      audioArtifacts: .empty
    )
    session.recap = LocalSessionRecap(
      overview: "The video commentary captured the main areas that need follow-up.",
      generatedAt: startedAt,
      sections: []
    )

    let proposal = try await client.sendMessage(
      LocalSessionDocumentChatRequest(
        session: session,
        userMessage: "על מה המסמך"
      )
    )

    XCTAssertFalse(proposal.hasEdits)
    XCTAssertTrue(proposal.assistantMessage.contains("יוטיוב") || proposal.assistantMessage.contains("מורה מבוכים"))
    XCTAssertTrue(proposal.assistantMessage.contains("סרטון"))
    XCTAssertFalse(proposal.assistantMessage.contains("בואו ניקח איזה סרטון"))
    XCTAssertFalse(proposal.assistantMessage.contains("ההיסטוריה שראיתי"))
  }

  func testDocumentChatCoercesSchemaLiteralSectionKindFromLocalModel() async throws {
    let client = LocalSessionDocumentChatClient(
      languageModel: CapturingLanguageModel(
        response: """
          {
            "assistantMessage": "I updated the action items.",
            "recapPatch": {
              "overview": null,
              "sections": [
                {
                  "kind": "keyPoints|decisions|actionItem|openQuestions|nextSteps|notes|overview",
                  "title": "Review conversation rating",
                  "summary": "Review the conversation rating and decide what changes next.",
                  "bullets": ["Review the conversation rating.", "Decide what changes next."]
                }
              ]
            },
            "transcriptPatches": [],
            "speakerRenames": [],
            "warnings": []
          }
          """
      )
    )
    let startedAt = Date(timeIntervalSince1970: 2_400_000)
    let session = LocalMeetingSession(
      id: UUID(uuidString: "74A2F030-BB53-4C2A-B0B1-95E2FBA69BD5")!,
      title: "Action fallback",
      startedAt: startedAt,
      status: .ready,
      transcriptSegments: [
        .init(
          id: UUID(uuidString: "64C58049-72D6-42BE-B319-A6CD60B5083D")!,
          speaker: "Ben",
          text: "We need to review the conversation rating and decide what changes next.",
          timestamp: startedAt.addingTimeInterval(12)
        )
      ],
      audioArtifacts: .empty
    )

    let proposal = try await client.sendMessage(
      LocalSessionDocumentChatRequest(
        session: session,
        userMessage: "Turn this into action items."
      )
    )

    XCTAssertTrue(proposal.hasEdits)
    XCTAssertEqual(proposal.recapPatch?.sections.first?.kind, .actionItem)
    XCTAssertEqual(proposal.recapPatch?.sections.first?.title, "Review conversation rating")
    XCTAssertEqual(
      proposal.recapPatch?.sections.first?.bullets.first,
      "Review the conversation rating."
    )
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

private struct ThrowingMessageLanguageModel: LocalSessionLanguageModelGenerating {
  let message: String

  func generateText(prompt: String, maxTokens: Int) async throws -> String {
    throw MessageError(message: message)
  }

  private struct MessageError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
  }
}
