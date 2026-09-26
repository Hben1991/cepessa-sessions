import Foundation
import XCTest

@testable import CepessaSessions

final class LocalMeetingFileLayoutTests: XCTestCase {
  private var tempRootURL: URL!
  private let fileManager = FileManager.default

  override func setUpWithError() throws {
    UserDefaults.standard.removeObject(forKey: "cepessa.sessions.transcriptionSpeedMode")
    UserDefaults.standard.removeObject(forKey: "cepessa.sessions.preferredTranscriptLanguage")
    tempRootURL = fileManager.temporaryDirectory
      .appendingPathComponent("LocalMeetingModelTests-\(UUID().uuidString)", isDirectory: true)
    try fileManager.createDirectory(at: tempRootURL, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    if let tempRootURL {
      try? fileManager.removeItem(at: tempRootURL)
    }
    UserDefaults.standard.removeObject(forKey: "cepessa.sessions.transcriptionSpeedMode")
    UserDefaults.standard.removeObject(forKey: "cepessa.sessions.preferredTranscriptLanguage")
  }

  func testFileLayoutBuildsExpectedPaths() {
    let baseDirectory = tempRootURL.appendingPathComponent("Meetings", isDirectory: true)
    let layout = LocalMeetingFileLayout(baseDirectory: baseDirectory)
    let sessionID = UUID(uuidString: "C7E3E8F0-2E71-4C8F-9B7D-0F1E3F4D5A6B")!

    XCTAssertEqual(
      layout.sessionsDirectory, baseDirectory.appendingPathComponent("Sessions", isDirectory: true))
    XCTAssertEqual(
      layout.modelsDirectory, baseDirectory.appendingPathComponent("Models", isDirectory: true))
    XCTAssertEqual(
      layout.sessionDirectory(for: sessionID),
      baseDirectory.appendingPathComponent("Sessions", isDirectory: true).appendingPathComponent(
        sessionID.uuidString, isDirectory: true))
    XCTAssertEqual(
      layout.metadataURL(for: sessionID),
      baseDirectory.appendingPathComponent("Sessions", isDirectory: true).appendingPathComponent(
        sessionID.uuidString, isDirectory: true
      ).appendingPathComponent("session.json", isDirectory: false))
    XCTAssertEqual(
      layout.micAudioURL(for: sessionID),
      baseDirectory.appendingPathComponent("Sessions", isDirectory: true).appendingPathComponent(
        sessionID.uuidString, isDirectory: true
      ).appendingPathComponent("mic.wav", isDirectory: false))
    XCTAssertEqual(
      layout.systemAudioURL(for: sessionID),
      baseDirectory.appendingPathComponent("Sessions", isDirectory: true).appendingPathComponent(
        sessionID.uuidString, isDirectory: true
      ).appendingPathComponent("system.wav", isDirectory: false))
    XCTAssertEqual(
      layout.mixedAudioURL(for: sessionID),
      baseDirectory.appendingPathComponent("Sessions", isDirectory: true).appendingPathComponent(
        sessionID.uuidString, isDirectory: true
      ).appendingPathComponent("mixed.wav", isDirectory: false))
  }

  func testEnsureDirectoriesCreatesSessionAndModelFolders() throws {
    let baseDirectory = tempRootURL.appendingPathComponent("Meetings", isDirectory: true)
    let layout = LocalMeetingFileLayout(baseDirectory: baseDirectory)
    let sessionID = UUID(uuidString: "7AA34D4F-8A9F-4E5F-9D49-4D1D05F8646A")!

    try layout.ensureDirectories(fileManager: fileManager, for: sessionID)

    XCTAssertTrue(fileManager.fileExists(atPath: layout.sessionsDirectory.path))
    XCTAssertTrue(fileManager.fileExists(atPath: layout.modelsDirectory.path))
    XCTAssertTrue(fileManager.fileExists(atPath: layout.modelDirectory().path))
    XCTAssertTrue(fileManager.fileExists(atPath: layout.sessionDirectory(for: sessionID).path))
  }

  func testResolvedHebrewModelURLDefaultsToInstalledModelLocation() {
    let baseDirectory = tempRootURL.appendingPathComponent("Meetings", isDirectory: true)
    let layout = LocalMeetingFileLayout(
      baseDirectory: baseDirectory,
      compatibleModelSearchRoots: []
    )

    let resolved = layout.resolvedHebrewModelURL(fileManager: fileManager)
    let developmentModelURL = URL(
      fileURLWithPath:
        "/Users/ben/Documents/App/General/__MODELS__/ivrit-ai_whisper-large-v3-turbo-ggml/ggml-model.bin"
    )

    XCTAssertTrue(resolved == layout.modelURL() || resolved == developmentModelURL)
  }

  func testResolvedTranscriptionPlanPrefersInstalledMultilingualModel() throws {
    let baseDirectory = tempRootURL.appendingPathComponent("Meetings", isDirectory: true)
    let layout = LocalMeetingFileLayout(baseDirectory: baseDirectory)
    let multilingualURL = layout.modelURL(for: "ggml-small")

    try fileManager.createDirectory(
      at: multilingualURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try writeValidGGMLFixture(to: multilingualURL)

    let plan = layout.resolvedTranscriptionPlan(
      settings: .init(speedMode: .balanced, languagePreference: .mixed),
      fileManager: fileManager
    )

    XCTAssertEqual(plan.modelURL, multilingualURL)
    XCTAssertEqual(plan.engine, .whisperCpp)
    XCTAssertEqual(plan.language, "auto")
    XCTAssertEqual(plan.modelFlavor, .multilingualFast)
    XCTAssertEqual(plan.speedMode, .balanced)
  }

  func testResolvedTranscriptionPlanPrefersWhisperKitCoreMLModel() throws {
    let baseDirectory = tempRootURL.appendingPathComponent("Meetings", isDirectory: true)
    let layout = LocalMeetingFileLayout(baseDirectory: baseDirectory)
    let whisperKitURL = layout.modelDirectory(
      for: LocalMeetingFileLayout.defaultWhisperKitMultilingualModelID)
    let fallbackURL = layout.modelURL(for: "ggml-small")

    try createWhisperKitModelDirectory(at: whisperKitURL)
    try fileManager.createDirectory(
      at: fallbackURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try writeValidGGMLFixture(to: fallbackURL)

    let plan = layout.resolvedTranscriptionPlan(
      settings: .init(speedMode: .balanced, languagePreference: .mixed),
      fileManager: fileManager
    )

    XCTAssertEqual(plan.modelURL, whisperKitURL)
    XCTAssertEqual(plan.engine, .whisperKit)
    XCTAssertEqual(plan.language, "auto")
    XCTAssertEqual(plan.modelFlavor, .whisperKitMultilingualTurbo)
    XCTAssertEqual(plan.speedMode, .balanced)
  }

  func testHebrewFirstTranscriptionPlanPrefersHebrewWhisperKitModel() throws {
    let baseDirectory = tempRootURL.appendingPathComponent("Meetings", isDirectory: true)
    let layout = LocalMeetingFileLayout(baseDirectory: baseDirectory)
    let hebrewWhisperKitURL = layout.modelDirectory(
      for: LocalMeetingFileLayout.defaultWhisperKitHebrewModelID)
    let multilingualWhisperKitURL = layout.modelDirectory(
      for: LocalMeetingFileLayout.defaultWhisperKitMultilingualModelID)

    try createWhisperKitModelDirectory(at: hebrewWhisperKitURL)
    try createWhisperKitModelDirectory(at: multilingualWhisperKitURL)

    let plan = layout.resolvedTranscriptionPlan(
      settings: .init(speedMode: .balanced, languagePreference: .hebrewFirst),
      fileManager: fileManager
    )

    XCTAssertEqual(plan.modelURL, hebrewWhisperKitURL)
    XCTAssertEqual(plan.engine, .whisperKit)
    XCTAssertEqual(plan.language, "auto")
    XCTAssertEqual(plan.modelFlavor, .whisperKitHebrewTurbo)
    XCTAssertNotNil(plan.prompt)
  }

  func testResolvedTranscriptionPlanKeepsAutoLanguageWhenFallingBackToHebrewModel() throws {
    let baseDirectory = tempRootURL.appendingPathComponent("Meetings", isDirectory: true)
    let layout = LocalMeetingFileLayout(baseDirectory: baseDirectory)
    let hebrewURL = layout.modelURL()

    try fileManager.createDirectory(
      at: hebrewURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try writeValidGGMLFixture(to: hebrewURL)

    let plan = layout.resolvedTranscriptionPlan(
      settings: .init(speedMode: .balanced, languagePreference: .mixed),
      fileManager: fileManager
    )

    XCTAssertEqual(plan.modelURL, hebrewURL)
    XCTAssertEqual(plan.engine, .whisperCpp)
    XCTAssertEqual(plan.language, "auto")
    XCTAssertNil(plan.prompt)
    XCTAssertEqual(plan.modelFlavor, .hebrewTurbo)
    XCTAssertEqual(plan.speedMode, .balanced)
  }

  func testFastDraftPlanPrefersSmallestInstalledModel() throws {
    let baseDirectory = tempRootURL.appendingPathComponent("Meetings", isDirectory: true)
    let layout = LocalMeetingFileLayout(baseDirectory: baseDirectory)
    let smallURL = layout.modelURL(for: "ggml-small")
    let tinyURL = layout.modelURL(for: "ggml-tiny")

    for modelURL in [smallURL, tinyURL] {
      try fileManager.createDirectory(
        at: modelURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try writeValidGGMLFixture(to: modelURL)
    }

    let plan = layout.resolvedTranscriptionPlan(
      settings: .init(speedMode: .fastDraft, languagePreference: .mixed),
      fileManager: fileManager
    )

    XCTAssertEqual(plan.modelURL, tinyURL)
    XCTAssertEqual(plan.engine, .whisperCpp)
    XCTAssertEqual(plan.speedMode, .fastDraft)
  }

  func testLanguagePreferenceHintsDoNotDisableLanguageDetection() throws {
    let baseDirectory = tempRootURL.appendingPathComponent("Meetings", isDirectory: true)
    let layout = LocalMeetingFileLayout(baseDirectory: baseDirectory)
    let multilingualURL = layout.modelURL(for: "ggml-small")

    try fileManager.createDirectory(
      at: multilingualURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try writeValidGGMLFixture(to: multilingualURL)

    let plan = layout.resolvedTranscriptionPlan(
      settings: .init(speedMode: .balanced, languagePreference: .hebrewFirst),
      fileManager: fileManager
    )

    XCTAssertEqual(plan.language, "auto")
    XCTAssertNotNil(plan.prompt)
  }

  func testRecapMarkdownDocumentBuildsReadableSections() {
    let session = makeSession(
      id: UUID(uuidString: "46DD1471-0053-4884-A07E-8ECBCB67D0B5")!,
      startedAt: Date(timeIntervalSince1970: 1_800),
      status: .ready,
      title: "Meeting Markdown",
      segments: [
        .init(
          id: UUID(uuidString: "776A89F1-AD79-4C87-A53B-6087366D0D28")!,
          speaker: "Transcript",
          text: "Original transcript line.",
          timestamp: Date(timeIntervalSince1970: 1_820))
      ]
    )
    var sessionWithRecap = session
    sessionWithRecap.recap = LocalSessionRecap(
      overview: "Readable overview.",
      generatedAt: Date(timeIntervalSince1970: 2_000),
      sections: [
        LocalSessionRecapSection(
          id: UUID(uuidString: "D83E12B6-5DDD-443A-A31B-7998F37642AB")!,
          kind: .actionItem,
          title: "Action items",
          summary: "Follow-ups that need ownership.",
          bullets: ["Send the recording", "Review the recap"],
          anchorTimestamp: nil,
          startOffset: nil,
          endOffset: nil
        )
      ]
    )

    let markdown = LocalSessionRecapMarkdownDocument(session: sessionWithRecap).markdown

    XCTAssertTrue(markdown.contains("# Session Markdown"))
    XCTAssertTrue(markdown.contains("## Overview"))
    XCTAssertTrue(markdown.contains("- Send the recording"))
    XCTAssertFalse(markdown.contains("## Transcript"))
    XCTAssertFalse(markdown.contains("Original transcript line."))

    let transcriptMarkdown = LocalSessionRecapMarkdownDocument.markdown(
      for: sessionWithRecap,
      includeTranscript: true
    )
    XCTAssertTrue(transcriptMarkdown.contains("## Transcript"))
    XCTAssertTrue(transcriptMarkdown.contains("Original transcript line."))
  }

  func testExportTranscriptMarkdownPlacesImageLinksNextToMatchingSegments() throws {
    let startedAt = Date(timeIntervalSince1970: 1_800)
    let segmentID = UUID(uuidString: "B8D1E4AE-8B9B-4F0D-BE5C-8A4A5C6C1A01")!
    let imageURL = tempRootURL.appendingPathComponent("session-screenshot.png")
    try Data([0x89, 0x50, 0x4E, 0x47]).write(to: imageURL)

    let session = makeSession(
      id: UUID(uuidString: "4C5B2B9B-8DB7-4B54-89BB-EE1FA0DD4CE2")!,
      startedAt: startedAt,
      status: .ready,
      title: "Transcript Export",
      segments: [
        .init(
          id: segmentID,
          speaker: "You",
          text: "Here is the screenshot.",
          timestamp: startedAt.addingTimeInterval(6))
      ],
      attachments: [
        .init(
          id: UUID(uuidString: "A31E5D8A-5D7E-4D4B-8C0F-8F5C7E81C1E9")!,
          kind: .image,
          source: .floatingBar,
          title: "Screenshot",
          timestamp: startedAt.addingTimeInterval(12),
          sessionOffset: 12,
          fileName: imageURL.lastPathComponent,
          mimeType: "image/png",
          urlString: imageURL.path,
          note: "Captured during the live session.",
          transcriptSegmentID: segmentID
        )
      ]
    )

    let exportedURL = try LocalSessionRecapExporter().exportTranscriptMarkdown(
      session: session,
      to: tempRootURL
    )
    let markdown = try String(contentsOf: exportedURL, encoding: .utf8)

    XCTAssertTrue(markdown.contains("- [00:06] **You:** Here is the screenshot."))
    XCTAssertTrue(markdown.contains("  - [00:12] ![Screenshot](\(imageURL.absoluteString))"))
    let transcriptRange = try XCTUnwrap(
      markdown.range(of: "- [00:06] **You:** Here is the screenshot."))
    let imageRange = try XCTUnwrap(markdown.range(of: imageURL.absoluteString))
    XCTAssertLessThan(transcriptRange.lowerBound, imageRange.lowerBound)
  }

  func testRecapMarkdownDocumentIncludesSpeakerLabelsWithoutInventingNames() {
    let startedAt = Date(timeIntervalSince1970: 1_850)
    let session = makeSession(
      id: UUID(uuidString: "1F58D50D-66C6-4024-9E30-0E5274FE9DB0")!,
      startedAt: startedAt,
      status: .ready,
      title: "Speaker Context",
      segments: [
        .init(
          id: UUID(uuidString: "AE3B3F99-518F-4416-9221-D8B76B256716")!,
          speaker: "Remote speaker",
          text: "The remote side explains the product demo.",
          timestamp: startedAt.addingTimeInterval(3)),
        .init(
          id: UUID(uuidString: "FF0734B9-E29E-4691-BC25-5FDF4F6F582D")!,
          speaker: "You",
          text: "I ask a follow-up question.",
          timestamp: startedAt.addingTimeInterval(8)),
      ]
    )
    var sessionWithRecap = session
    sessionWithRecap.recap = LocalSessionRecap(
      overview: "The recording captures a product demo discussion.",
      generatedAt: startedAt,
      sections: []
    )

    let markdown = LocalSessionRecapMarkdownDocument(session: sessionWithRecap).markdown

    XCTAssertTrue(markdown.contains("## Speaker context"))
    XCTAssertTrue(markdown.contains("Recorded speaker labels: Remote speaker, You."))
    XCTAssertTrue(markdown.contains("not verified personal names"))
    XCTAssertFalse(markdown.contains("Ben:"))
  }

  func testRecapMarkdownDocumentCanOmitTranscriptForPreview() {
    let session = makeSession(
      id: UUID(uuidString: "26F99059-9893-42C7-B3F0-F91597F0F5C2")!,
      startedAt: Date(timeIntervalSince1970: 1_900),
      status: .ready,
      title: "Preview Markdown",
      segments: [
        .init(
          id: UUID(uuidString: "47D53626-B87D-4655-91DA-95734E6E1623")!,
          speaker: "Transcript",
          text: "Very long transcript line that should stay out of recap previews.",
          timestamp: Date(timeIntervalSince1970: 1_920))
      ]
    )
    var sessionWithRecap = session
    sessionWithRecap.recap = LocalSessionRecap(
      overview: "Preview overview.",
      generatedAt: Date(timeIntervalSince1970: 2_000),
      sections: [
        LocalSessionRecapSection(
          id: UUID(uuidString: "4EBAAC21-8C73-48EE-A581-4E49DBB25701")!,
          kind: .decisions,
          title: "Decisions",
          summary: "Use recap-only rendering for the preview document.",
          bullets: [],
          anchorTimestamp: nil,
          startOffset: nil,
          endOffset: nil
        )
      ]
    )

    let markdown = LocalSessionRecapMarkdownDocument.markdown(
      for: sessionWithRecap, includeTranscript: false)

    XCTAssertTrue(markdown.contains("Preview overview."))
    XCTAssertTrue(markdown.contains("Use recap-only rendering for the preview document."))
    XCTAssertFalse(markdown.contains("## Transcript"))
    XCTAssertFalse(markdown.contains("Very long transcript line"))
  }

  func testRecapMarkdownDocumentPreservesGeneratedHebrewSectionTitles() {
    let session = makeSession(
      id: UUID(uuidString: "517C9FC1-A96E-4214-B15D-782E75DA6215")!,
      startedAt: Date(timeIntervalSince1970: 2_050),
      status: .ready,
      title: "Session 30 Apr 2026 at 12:26",
      segments: [
        .init(
          id: UUID(uuidString: "631B3C73-AB4D-4C3D-A8A9-26F7DC11BBA7")!,
          speaker: "You",
          text: "אני בודק סרטון יוטיוב בעברית.",
          timestamp: Date(timeIntervalSince1970: 2_060))
      ]
    )
    var sessionWithRecap = session
    sessionWithRecap.recap = LocalSessionRecap(
      overview: "המסמך עוסק בסרטון יוטיוב בעברית.",
      generatedAt: Date(timeIntervalSince1970: 2_100),
      sections: [
        LocalSessionRecapSection(
          id: UUID(uuidString: "B0E6F7BD-24D1-4E20-82E3-C214D3D49FE2")!,
          kind: .overview,
          title: "על מה המסמך",
          summary: "המסמך עוסק בסרטון יוטיוב בעברית.",
          bullets: [],
          anchorTimestamp: nil,
          startOffset: nil,
          endOffset: nil
        ),
        LocalSessionRecapSection(
          id: UUID(uuidString: "C7B95D2A-E34E-41DA-8F2D-C5F06A928951")!,
          kind: .keyPoints,
          title: "מה מופיע בסרטון",
          summary: "הסרטון מציג סצנת משחק תפקידים.",
          bullets: ["יש ניסיון התגנבות ותקיפה."],
          anchorTimestamp: nil,
          startOffset: nil,
          endOffset: nil
        ),
        LocalSessionRecapSection(
          id: UUID(uuidString: "B5A3675C-90E1-4F39-9854-769D14797011")!,
          kind: .actionItem,
          title: "מה כדאי לעשות עם זה",
          summary: "להשתמש בתקציר כנושא המסמך.",
          bullets: ["לא להעתיק את שורות הפתיחה של התמלול."],
          anchorTimestamp: nil,
          startOffset: nil,
          endOffset: nil
        ),
      ]
    )

    let markdown = LocalSessionRecapMarkdownDocument.markdown(
      for: sessionWithRecap,
      language: .hebrew,
      includeTranscript: false
    )

    XCTAssertTrue(markdown.contains("## על מה המסמך"))
    XCTAssertTrue(markdown.contains("## מה מופיע בסרטון"))
    XCTAssertTrue(markdown.contains("## מה כדאי לעשות עם זה"))
    XCTAssertFalse(markdown.contains("## סקירה"))
    XCTAssertFalse(markdown.contains("## נקודות מרכזיות"))
    XCTAssertFalse(markdown.contains("## משימות לביצוע"))
  }

  func testRecapMarkdownDocumentRendersHebrewVersionFromHebrewTranscript() {
    let session = makeSession(
      id: UUID(uuidString: "94F0CF37-1B5C-47F4-B204-8A99A7CC81C5")!,
      startedAt: Date(timeIntervalSince1970: 2_100),
      status: .ready,
      title: "Hebrew Recap",
      segments: [
        .init(
          id: UUID(uuidString: "97801AE7-931D-4F48-AE2E-2DB89AF80B85")!,
          speaker: "You",
          text: "אני רוצה לבדוק שהמסמך מסכם את הפגישה.",
          timestamp: Date(timeIntervalSince1970: 2_120)),
        .init(
          id: UUID(uuidString: "43752C97-E62F-4DDE-A0D5-0552EAB91802")!,
          speaker: "You",
          text: "אם יש סיכום זו הצלחה.",
          timestamp: Date(timeIntervalSince1970: 2_124)),
      ]
    )
    var sessionWithEnglishRecap = session
    sessionWithEnglishRecap.recap = LocalSessionRecap(
      overview: "This is an English-only recap.",
      generatedAt: Date(timeIntervalSince1970: 2_200),
      sections: [
        LocalSessionRecapSection(
          id: UUID(uuidString: "B2B75EDB-F4BD-45BD-8D44-13ECA5C9A7C6")!,
          kind: .keyPoints,
          title: "Key points",
          summary: "English summary.",
          bullets: ["English bullet."],
          anchorTimestamp: nil,
          startOffset: nil,
          endOffset: nil
        )
      ]
    )

    let hebrewMarkdown = LocalSessionRecapMarkdownDocument.markdown(
      for: sessionWithEnglishRecap,
      language: .hebrew,
      includeTranscript: false
    )
    let englishMarkdown = LocalSessionRecapMarkdownDocument.markdown(
      for: sessionWithEnglishRecap,
      language: .english,
      includeTranscript: false
    )

    XCTAssertTrue(hebrewMarkdown.contains("## סקירה"))
    XCTAssertTrue(hebrewMarkdown.contains("## נקודות מרכזיות"))
    XCTAssertTrue(hebrewMarkdown.contains("## המלצה מקצועית"))
    XCTAssertTrue(hebrewMarkdown.contains("פגישה") || hebrewMarkdown.contains("שיחה"))
    XCTAssertFalse(hebrewMarkdown.contains("אני רוצה לבדוק שהמסמך מסכם את הפגישה."))
    XCTAssertFalse(hebrewMarkdown.contains("This is an English-only recap."))
    XCTAssertTrue(englishMarkdown.contains("## Overview"))
    XCTAssertFalse(englishMarkdown.contains("This is an English-only recap."))
  }

  func testRecapMarkdownDocumentPrefersHebrewForHebrewSessions() {
    let startedAt = Date(timeIntervalSince1970: 2_350)
    var session = makeSession(
      id: UUID(uuidString: "4E67EDC0-E85E-4C10-8BB7-DCAC01BE590D")!,
      startedAt: startedAt,
      status: .ready,
      title: "Session 15 May 2026 at 14:12",
      segments: [
        LocalMeetingTranscriptSegment(
          id: UUID(uuidString: "6C3B68F0-4155-494F-85A4-F31AAFE63C6A")!,
          speaker: "Remote speaker",
          text: "בואו נדבר רגע על התקציב של העסק ועל הדשבורד שבעל העסק צריך לראות.",
          timestamp: startedAt
        )
      ]
    )
    session.recap = LocalSessionRecap(
      overview: "The meeting focused on business planning.",
      generatedAt: startedAt,
      sections: []
    )

    XCTAssertEqual(LocalSessionRecapMarkdownDocument.preferredLanguage(for: session), .hebrew)
  }

  func testEnglishDocumentDoesNotReuseStoredHebrewMarkdownBody() {
    let startedAt = Date(timeIntervalSince1970: 2_380)
    var session = makeSession(
      id: UUID(uuidString: "E04651DB-DA6A-4F16-9714-713A22414C2E")!,
      startedAt: startedAt,
      status: .ready,
      title: "Session 15 May 2026 at 14:12",
      segments: [
        LocalMeetingTranscriptSegment(
          id: UUID(uuidString: "380302C0-1755-49E3-92C5-45EE348A4B02")!,
          speaker: "Remote speaker",
          text: "דיברנו על הרעיון של המוצר, הסוכן העסקי והדשבורד שבעל העסק צריך לראות.",
          timestamp: startedAt
        )
      ]
    )
    session.recap = LocalSessionRecap(
      overview: "הפגישה התמקדה בסוכן עסקי ודשבורד.",
      generatedAt: startedAt,
      sections: []
    )
    session.documentMarkdown = """
      # סוכן עסקי ודשבורד

      ## נקודות מרכזיות

      זה גוף מסמך בעברית בלבד.
      """

    let englishMarkdown = LocalSessionRecapMarkdownDocument.markdown(
      for: session,
      language: .english,
      includeTranscript: false
    )

    XCTAssertTrue(englishMarkdown.hasPrefix("# Product Direction, Business Agent, and Dashboard"))
    XCTAssertTrue(englishMarkdown.contains("## Key points"))
    XCTAssertTrue(englishMarkdown.contains("business owner"))
    XCTAssertFalse(englishMarkdown.contains("זה גוף מסמך בעברית בלבד"))
  }

  func testRecapMarkdownDocumentUsesTopicTitleForGenericSessionName() {
    let session = makeSession(
      id: UUID(uuidString: "5B1D8FEB-AE89-4F6C-9C6E-3867AE44E3D5")!,
      startedAt: Date(timeIntervalSince1970: 2_400),
      status: .ready,
      title: "Session 29 Apr 2026 at 11:11",
      segments: []
    )
    var sessionWithRecap = session
    sessionWithRecap.recap = LocalSessionRecap(
      overview:
        "The session focused on scrolling issues, analytics, and interview simulation UX.",
      generatedAt: Date(timeIntervalSince1970: 2_500),
      sections: []
    )

    let markdown = LocalSessionRecapMarkdownDocument.markdown(
      for: sessionWithRecap,
      language: .english,
      includeTranscript: false
    )

    XCTAssertTrue(
      markdown.hasPrefix("# Urgent Website Fixes, Analytics, and Interview Simulations"))
    XCTAssertFalse(markdown.hasPrefix("# Session 29 Apr 2026 at 11:11"))
  }

  func testRecapMarkdownDocumentUsesSpecificHebrewTopicTitleForGenericSessionName() {
    let session = makeSession(
      id: UUID(uuidString: "6336F7D9-88A1-48A6-8C7A-ED90FD00FD78")!,
      startedAt: Date(timeIntervalSince1970: 2_600),
      status: .ready,
      title: "Session 29 Apr 2026 at 11:11",
      segments: []
    )
    var sessionWithRecap = session
    sessionWithRecap.recap = LocalSessionRecap(
      overview: "הפגישה עסקה בגלילה באתר, אנליטיקס וסימולציות ריאיון.",
      generatedAt: Date(timeIntervalSince1970: 2_700),
      sections: []
    )

    let markdown = LocalSessionRecapMarkdownDocument.markdown(
      for: sessionWithRecap,
      language: .hebrew,
      includeTranscript: false
    )

    XCTAssertTrue(markdown.hasPrefix("# תיקוני אתר דחופים, אנליטיקס וסימולציות ריאיון"))
    XCTAssertFalse(markdown.hasPrefix("# Session 29 Apr 2026 at 11:11"))
  }

  func testRecapMarkdownDocumentPrioritizesBusinessAgentTitleOverWebsiteSignals() {
    let startedAt = Date(timeIntervalSince1970: 2_720)
    let session = makeSession(
      id: UUID(uuidString: "6CCB8CE3-F998-4056-AE75-8E98B9760DF0")!,
      startedAt: startedAt,
      status: .ready,
      title: "Session 15 May 2026 at 14:12",
      segments: [
        LocalMeetingTranscriptSegment(
          id: UUID(uuidString: "4A282843-A064-4FE6-A543-633929BDAA18")!,
          speaker: "You",
          text: "דיברנו על מוצר של סוכן עסקי, דשבורד לבעל העסק, וגם על האתר ו-Webflow.",
          timestamp: startedAt
        )
      ]
    )

    let title = LocalSessionRecapMarkdownDocument.title(for: session, language: .hebrew)

    XCTAssertEqual(title, "כיוון מוצר, סוכן עסקי ודשבורד")
  }

  func testExistingAudioURLFallsBackToLegacyMixedTrack() throws {
    let baseDirectory = tempRootURL.appendingPathComponent("Meetings", isDirectory: true)
    let layout = LocalMeetingFileLayout(baseDirectory: baseDirectory)
    let sessionID = UUID(uuidString: "86B5F6AB-F5B1-4C74-BB4D-0F8739B5EDE0")!
    let legacyAudioURL = layout.legacySessionDirectory(for: sessionID).appendingPathComponent(
      "mixed.wav", isDirectory: false)

    try fileManager.createDirectory(
      at: legacyAudioURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try writeMonoPCM16Wav(
      to: legacyAudioURL,
      samples: Array(repeating: 1_000, count: 16_000)
    )

    let resolved = layout.existingAudioURL(
      for: sessionID,
      artifacts: .init(micFileName: nil, systemFileName: nil, mixedFileName: "mixed.wav"),
      fileManager: fileManager
    )

    XCTAssertEqual(resolved, legacyAudioURL)
  }

  private func createWhisperKitModelDirectory(at url: URL) throws {
    try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
    for component in ["AudioEncoder.mlmodelc", "TextDecoder.mlmodelc", "MelSpectrogram.mlmodelc"] {
      try fileManager.createDirectory(
        at: url.appendingPathComponent(component, isDirectory: true),
        withIntermediateDirectories: true
      )
      try Data([0x01]).write(
        to: url.appendingPathComponent(component, isDirectory: true)
          .appendingPathComponent("model.espresso.net", isDirectory: false)
      )
    }
  }
}

final class LocalMeetingSessionStoreTests: XCTestCase {
  private var tempRootURL: URL!
  private let fileManager = FileManager.default

  override func setUpWithError() throws {
    tempRootURL = fileManager.temporaryDirectory
      .appendingPathComponent(
        "LocalMeetingSessionStoreTests-\(UUID().uuidString)", isDirectory: true)
    try fileManager.createDirectory(at: tempRootURL, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    if let tempRootURL {
      try? fileManager.removeItem(at: tempRootURL)
    }
  }

  func testSaveAndLoadRoundTripPreservesSessionData() throws {
    let layout = LocalMeetingFileLayout(
      baseDirectory: tempRootURL.appendingPathComponent("Meetings", isDirectory: true))
    let store = LocalMeetingSessionStore(fileLayout: layout)
    var olderSession = makeSession(
      id: UUID(uuidString: "1BDE4D8A-7C44-4C1F-9F73-45A2D6D75D47")!,
      startedAt: Date(timeIntervalSince1970: 100),
      status: .recording,
      title: "Earlier recap",
      segments: [
        .init(
          id: UUID(uuidString: "F7D3E5BC-771C-4E6E-B0B6-3B2D4D9B2AA1")!, speaker: "Alex",
          text: "First line", timestamp: Date(timeIntervalSince1970: 110)),
        .init(
          id: UUID(uuidString: "1A9A0246-6B4A-4E0A-8C37-0B8C7E7A92B2")!, speaker: "Alex",
          text: "Second line", timestamp: Date(timeIntervalSince1970: 120)),
      ],
      audioArtifacts: .init(
        micFileName: "mic.wav", systemFileName: "system.wav", mixedFileName: "mixed.wav")
    )
    olderSession.contentClassification = LocalSessionContentClassification(
      type: .voiceNote,
      confidence: 0.84,
      rationale: "Single-speaker dictated update.",
      generatedAt: Date(timeIntervalSince1970: 125)
    )
    let newerSession = makeSession(
      id: UUID(uuidString: "B5482A63-B5A6-4F64-8A3B-3BC0F4E0AC48")!,
      startedAt: Date(timeIntervalSince1970: 200),
      status: .transcribing,
      title: "Later recap",
      segments: [],
      audioArtifacts: .empty
    )

    try store.save(olderSession)
    try store.save(newerSession)
    try fileManager.createDirectory(
      at: layout.sessionsDirectory.appendingPathComponent("Stray", isDirectory: true),
      withIntermediateDirectories: true
    )
    try Data("ignore me".utf8).write(
      to: layout.sessionsDirectory.appendingPathComponent("notes.txt", isDirectory: false)
    )

    let sessions = store.loadSessions()

    XCTAssertEqual(sessions.map(\.id), [newerSession.id, olderSession.id])
    XCTAssertEqual(sessions.first?.status, .transcribing)
    XCTAssertEqual(sessions.last?.transcriptText, "First line\nSecond line")
    XCTAssertEqual(sessions.last?.audioArtifacts.mixedFileName, "mixed.wav")
    XCTAssertEqual(sessions.last?.contentClassification?.type, .voiceNote)
    XCTAssertTrue(fileManager.fileExists(atPath: layout.metadataURL(for: olderSession.id).path))
    XCTAssertTrue(fileManager.fileExists(atPath: layout.metadataURL(for: newerSession.id).path))

    let promptPackageMarkdown = try String(
      contentsOf: layout.promptPackageMarkdownURL(for: olderSession.id),
      encoding: .utf8
    )
    XCTAssertTrue(promptPackageMarkdown.contains("- Content type: Voice note"))
    XCTAssertTrue(
      promptPackageMarkdown.contains("- Classification rationale: Single-speaker dictated update."))

    let promptPackageData = try Data(contentsOf: layout.promptPackageJSONURL(for: olderSession.id))
    let promptPackageObject = try XCTUnwrap(
      JSONSerialization.jsonObject(with: promptPackageData) as? [String: Any]
    )
    let classificationObject = try XCTUnwrap(
      promptPackageObject["contentClassification"] as? [String: Any]
    )
    XCTAssertEqual(classificationObject["type"] as? String, "voiceNote")
  }

  func testLoadSessionsSkipsDirectoriesWithoutMetadata() throws {
    let layout = LocalMeetingFileLayout(
      baseDirectory: tempRootURL.appendingPathComponent("Meetings", isDirectory: true))
    let store = LocalMeetingSessionStore(fileLayout: layout)
    let validSession = makeSession(
      id: UUID(uuidString: "23B0DBB8-1D89-4C7C-87E4-19B8F871B1E6")!,
      startedAt: Date(timeIntervalSince1970: 300),
      status: .ready,
      title: "Valid recap"
    )

    try store.save(validSession)
    try fileManager.createDirectory(
      at: layout.sessionsDirectory.appendingPathComponent("Broken", isDirectory: true),
      withIntermediateDirectories: true
    )

    let sessions = store.loadSessions()

    XCTAssertEqual(sessions.count, 1)
    XCTAssertEqual(sessions.first?.id, validSession.id)
  }
}

@MainActor
final class LocalMeetingAppModelTests: XCTestCase {
  private var tempRootURL: URL!
  private let fileManager = FileManager.default

  override func setUpWithError() throws {
    tempRootURL = fileManager.temporaryDirectory
      .appendingPathComponent("LocalMeetingAppModelTests-\(UUID().uuidString)", isDirectory: true)
    try fileManager.createDirectory(at: tempRootURL, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    if let tempRootURL {
      try? fileManager.removeItem(at: tempRootURL)
    }
  }

  func testProductionBaseDirectoryPointsAtApplicationSupportCepessa() {
    let expectedBaseDirectory = fileManager.urls(
      for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Cepessa", isDirectory: true)

    XCTAssertEqual(LocalSessionStorageRoot.productionBaseDirectory, expectedBaseDirectory)
  }

  func testDefaultBaseDirectoryIsIsolatedDuringTests() {
    let resolvedBaseDirectory = LocalSessionStorageRoot.defaultBaseDirectory
    let expectedPrefix = fileManager.temporaryDirectory.appendingPathComponent(
      "CepessaSessionsTests-\(ProcessInfo.processInfo.processIdentifier)",
      isDirectory: true
    )

    XCTAssertEqual(resolvedBaseDirectory, expectedPrefix)
    XCTAssertNotEqual(resolvedBaseDirectory, LocalSessionStorageRoot.productionBaseDirectory)
  }

  func testInitLoadsStoredSessionsNewestFirstAndSelectsTopSession() throws {
    let layout = LocalMeetingFileLayout(
      baseDirectory: tempRootURL.appendingPathComponent("Meetings", isDirectory: true))
    let store = LocalMeetingSessionStore(fileLayout: layout)
    let olderSession = makeSession(
      id: UUID(uuidString: "B2B8EEAB-2D45-4F7A-9F6D-1F4F4C43B0A2")!,
      startedAt: Date(timeIntervalSince1970: 1000),
      status: .recording,
      title: "Older"
    )
    let newerSession = makeSession(
      id: UUID(uuidString: "2D6291B5-FAF6-4B4E-8A08-DB7E5F3F5A6E")!,
      startedAt: Date(timeIntervalSince1970: 2000),
      status: .ready,
      title: "Newer"
    )

    try store.save(olderSession)
    try store.save(newerSession)

    let model = LocalMeetingAppModel(store: store, fileLayout: layout)

    XCTAssertEqual(model.sessions.map(\.id), [newerSession.id, olderSession.id])
    XCTAssertEqual(model.selectedSessionID, newerSession.id)
    XCTAssertEqual(model.selectedSession?.title, "Newer")
  }

  @MainActor
  func testSpeakerRenameNeverLeaksIntoPersistedSessionAndUndoRestoresEvidenceLabel() throws {
    let layout = LocalMeetingFileLayout(
      baseDirectory: tempRootURL.appendingPathComponent("Meetings", isDirectory: true))
    let store = LocalMeetingSessionStore(fileLayout: layout)
    let sessionID = UUID()
    let speakerID = "stable-speaker-1"
    var session = makeSession(
      id: sessionID,
      startedAt: Date(timeIntervalSince1970: 2_500),
      status: .ready,
      title: "Base title",
      segments: [
        .init(
          id: UUID(),
          speaker: "Speaker 1",
          text: "Original evidence words.",
          timestamp: Date(timeIntervalSince1970: 2_501),
          endTimestamp: Date(timeIntervalSince1970: 2_502),
          speakerID: speakerID,
          source: .system,
          identityStatus: .anonymous
        )
      ]
    )
    session.transcriptionEvidence = .init(
      runID: "run-1",
      revision: 1,
      disposition: .ready,
      contentHash: "immutable-content-hash",
      parentContentHash: nil,
      runFileName: "missing-test-envelope.json",
      outboxFileName: "outbox.json",
      issues: []
    )
    try store.save(session)
    let model = LocalMeetingAppModel(store: store, fileLayout: layout)

    XCTAssertTrue(model.renameSpeaker(speakerID: speakerID, to: "Maya"))
    XCTAssertEqual(model.selectedSession?.transcriptSegments.first?.speaker, "Maya")
    XCTAssertTrue(model.updateSessionTitle("Updated title"))

    let afterTitleSave = try XCTUnwrap(store.loadSessions().first)
    XCTAssertEqual(afterTitleSave.title, "Updated title")
    XCTAssertEqual(afterTitleSave.transcriptSegments.first?.speaker, "Speaker 1")
    XCTAssertEqual(afterTitleSave.transcriptSegments.first?.identityStatus, .anonymous)

    XCTAssertTrue(model.undoLatestSpeakerRename(speakerID: speakerID))
    XCTAssertEqual(model.selectedSession?.transcriptSegments.first?.speaker, "Speaker 1")
    XCTAssertEqual(model.selectedSession?.transcriptSegments.first?.identityStatus, .anonymous)
    XCTAssertEqual(store.loadSessions().first?.transcriptSegments.first?.speaker, "Speaker 1")
  }

  func testInitNormalizesInterruptedSessionsToFailed() throws {
    let layout = LocalMeetingFileLayout(
      baseDirectory: tempRootURL.appendingPathComponent("Meetings", isDirectory: true))
    let store = LocalMeetingSessionStore(fileLayout: layout)
    let interruptedRecording = makeSession(
      id: UUID(uuidString: "A22EB5F9-89A0-4A57-B9B6-E08A781F84B0")!,
      startedAt: Date(timeIntervalSince1970: 1_500),
      status: .recording,
      title: "Interrupted recording"
    )
    let interruptedTranscribing = makeSession(
      id: UUID(uuidString: "794EAB53-F0D4-4C9E-B0D4-398EFA7AB4E6")!,
      startedAt: Date(timeIntervalSince1970: 1_600),
      status: .transcribing,
      title: "Interrupted processing"
    )

    try store.save(interruptedRecording)
    try store.save(interruptedTranscribing)

    let model = LocalMeetingAppModel(store: store, fileLayout: layout)

    XCTAssertEqual(model.sessions.map(\.status), [.failed, .failed])

    let persistedStatuses = store.loadSessions().map(\.status)
    XCTAssertEqual(persistedStatuses, [.failed, .failed])
  }

  func testCanRetranscribeUsesCachedAudioAvailability() throws {
    let layout = LocalMeetingFileLayout(
      baseDirectory: tempRootURL.appendingPathComponent("Meetings", isDirectory: true))
    let store = LocalMeetingSessionStore(fileLayout: layout)
    let sessionID = UUID(uuidString: "B75E1812-7C50-4D22-9B26-0F4C68742B1D")!
    let session = makeSession(
      id: sessionID,
      startedAt: Date(timeIntervalSince1970: 1_750),
      status: .failed,
      title: "Recoverable",
      audioArtifacts: .init(micFileName: nil, systemFileName: nil, mixedFileName: "mixed.wav")
    )
    let audioURL = layout.mixedAudioURL(for: sessionID)
    try fileManager.createDirectory(
      at: audioURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try writeMonoPCM16Wav(
      to: audioURL,
      samples: Array(repeating: 1_000, count: 16_000)
    )
    try store.save(session)

    let model = LocalMeetingAppModel(store: store, fileLayout: layout)
    guard let loadedSession = model.sessions.first else {
      XCTFail("Expected stored session to load.")
      return
    }

    XCTAssertTrue(model.canRetranscribe(loadedSession))

    try fileManager.removeItem(at: audioURL)

    XCTAssertTrue(model.canRetranscribe(loadedSession))
  }

  func testAudioAvailabilityCacheRefreshesWhenSessionIsUpserted() throws {
    let layout = LocalMeetingFileLayout(
      baseDirectory: tempRootURL.appendingPathComponent("Meetings", isDirectory: true))
    let store = LocalMeetingSessionStore(fileLayout: layout)
    let model = LocalMeetingAppModel(store: store, fileLayout: layout)
    let sessionID = UUID(uuidString: "E1B98A60-594B-4E6B-9058-F27E29BC70F6")!
    let session = makeSession(
      id: sessionID,
      startedAt: Date(timeIntervalSince1970: 1_760),
      status: .failed,
      title: "Audio arrives later",
      audioArtifacts: .init(micFileName: nil, systemFileName: nil, mixedFileName: "mixed.wav")
    )

    let insertedSession = model.upsertSession(session)
    XCTAssertFalse(model.canRetranscribe(insertedSession))

    let audioURL = layout.mixedAudioURL(for: sessionID)
    try fileManager.createDirectory(
      at: audioURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try writeMonoPCM16Wav(
      to: audioURL,
      samples: Array(repeating: 1_000, count: 16_000)
    )

    let refreshedSession = model.upsertSession(session)

    XCTAssertTrue(model.canRetranscribe(refreshedSession))
  }

  func testUpsertSessionPersistsStatusTransitionsWithoutDuplicatingRows() throws {
    let layout = LocalMeetingFileLayout(
      baseDirectory: tempRootURL.appendingPathComponent("Meetings", isDirectory: true))
    let store = LocalMeetingSessionStore(fileLayout: layout)
    let model = LocalMeetingAppModel(store: store, fileLayout: layout)
    let sessionID = UUID(uuidString: "15E3C0CF-0D72-47C9-9E88-4DBF0B7F5A9B")!
    let startedAt = Date(timeIntervalSince1970: 1_700)

    model.upsertSession(
      makeSession(
        id: sessionID,
        startedAt: startedAt,
        status: .recording,
        title: "Lifecycle"
      )
    )
    XCTAssertEqual(model.sessions.count, 1)
    XCTAssertEqual(model.sessions.first?.status, .recording)

    model.upsertSession(
      makeSession(
        id: sessionID,
        startedAt: startedAt,
        status: .transcribing,
        title: "Lifecycle"
      )
    )
    XCTAssertEqual(model.sessions.count, 1)
    XCTAssertEqual(model.sessions.first?.status, .transcribing)

    model.upsertSession(
      makeSession(
        id: sessionID,
        startedAt: startedAt,
        status: .ready,
        title: "Lifecycle",
        segments: [
          .init(
            id: UUID(uuidString: "4EB3D6A5-6D07-4A92-9E5F-1D1C5D1D5E6F")!, speaker: "Transcript",
            text: "Local recap ready", timestamp: startedAt)
        ],
        audioArtifacts: .init(
          micFileName: "mic.wav", systemFileName: "system.wav", mixedFileName: "mixed.wav")
      )
    )

    XCTAssertEqual(model.sessions.count, 1)
    XCTAssertEqual(model.sessions.first?.status, .ready)
    XCTAssertEqual(model.sessions.first?.transcriptText, "Local recap ready")
    XCTAssertEqual(model.sessions.first?.audioArtifacts.mixedFileName, "mixed.wav")

    let persistedSessions = store.loadSessions()
    XCTAssertEqual(persistedSessions.count, 1)
    XCTAssertEqual(persistedSessions.first?.status, .ready)
    XCTAssertEqual(persistedSessions.first?.audioArtifacts.systemFileName, "system.wav")
  }

  func testUpsertSessionMergesLiveArtifactsIntoStaleRecorderSnapshots() throws {
    let layout = LocalMeetingFileLayout(
      baseDirectory: tempRootURL.appendingPathComponent("Meetings", isDirectory: true))
    let store = LocalMeetingSessionStore(fileLayout: layout)
    let model = LocalMeetingAppModel(store: store, fileLayout: layout)
    let sessionID = UUID(uuidString: "7D97F13B-6C1C-4C7D-9F3D-5A6B3C5C0F42")!
    let startedAt = Date(timeIntervalSince1970: 2_500)

    model.upsertSession(
      makeSession(
        id: sessionID,
        startedAt: startedAt,
        status: .recording,
        title: "Lifecycle"
      )
    )
    model.selectSession(id: sessionID)

    let attachment = model.addScreenshotAttachment(
      title: "Live screenshot",
      timestamp: startedAt.addingTimeInterval(12),
      sessionOffset: 12,
      fileName: "live.png",
      urlString: "/tmp/live.png"
    )
    let captureArtifact = model.addCaptureArtifact(
      title: "Live capture",
      capturedAt: startedAt.addingTimeInterval(12),
      sessionOffset: 12,
      attachmentIDs: [attachment?.id].compactMap { $0 }
    )

    let staleTranscribingSnapshot = makeSession(
      id: sessionID,
      startedAt: startedAt,
      status: .transcribing,
      title: "Lifecycle"
    )
    let mergedTranscribingSession = model.upsertSession(staleTranscribingSnapshot)

    XCTAssertEqual(mergedTranscribingSession.status, .transcribing)
    XCTAssertEqual(mergedTranscribingSession.attachments.count, 1)
    XCTAssertEqual(mergedTranscribingSession.captureArtifacts.count, 1)
    XCTAssertEqual(mergedTranscribingSession.attachments.first?.id, attachment?.id)
    XCTAssertEqual(mergedTranscribingSession.captureArtifacts.first?.id, captureArtifact?.id)

    let finalizedSnapshot = makeSession(
      id: sessionID,
      startedAt: startedAt,
      status: .ready,
      title: "Lifecycle",
      segments: [
        .init(
          id: UUID(uuidString: "2CF51E9A-6AA2-4F71-8B83-1F3C9A9B71D6")!,
          speaker: "Transcript",
          text: "The live attachment survived the finalize path.",
          timestamp: startedAt.addingTimeInterval(30)
        )
      ],
      audioArtifacts: .init(micFileName: "mic.wav", systemFileName: nil, mixedFileName: "mixed.wav")
    )
    let mergedFinalSession = model.upsertSession(finalizedSnapshot)

    XCTAssertEqual(mergedFinalSession.status, .ready)
    XCTAssertEqual(mergedFinalSession.attachments.count, 1)
    XCTAssertEqual(mergedFinalSession.captureArtifacts.count, 1)
    XCTAssertEqual(
      mergedFinalSession.transcriptText, "The live attachment survived the finalize path.")

    let persistedSessions = store.loadSessions()
    XCTAssertEqual(persistedSessions.first?.attachments.count, 1)
    XCTAssertEqual(persistedSessions.first?.captureArtifacts.count, 1)
    XCTAssertEqual(
      persistedSessions.first?.transcriptText, "The live attachment survived the finalize path.")
  }

  func testSelectionIsClearedWhenSelectedSessionIsRemoved() {
    let layout = LocalMeetingFileLayout(
      baseDirectory: tempRootURL.appendingPathComponent("Meetings", isDirectory: true))
    let model = LocalMeetingAppModel(
      store: LocalMeetingSessionStore(fileLayout: layout), fileLayout: layout)
    let selectedSession = makeSession(
      id: UUID(uuidString: "1AC8A5F0-4E5A-40CE-B44D-1F1C9A2A18C1")!,
      startedAt: Date(timeIntervalSince1970: 10),
      status: .ready,
      title: "Selected"
    )
    let remainingSession = makeSession(
      id: UUID(uuidString: "B8C6A5E7-99C8-47A2-BE0B-0B65EE5F0A4B")!,
      startedAt: Date(timeIntervalSince1970: 20),
      status: .ready,
      title: "Remaining"
    )

    model.sessions = [selectedSession, remainingSession]
    model.selectSession(id: selectedSession.id)

    model.sessions = [remainingSession]

    XCTAssertNil(model.selectedSessionID)
  }

  func testLoadSampleSessionsSelectsNewestSample() {
    let layout = LocalMeetingFileLayout(
      baseDirectory: tempRootURL.appendingPathComponent("Meetings", isDirectory: true))
    let model = LocalMeetingAppModel(
      store: LocalMeetingSessionStore(fileLayout: layout), fileLayout: layout)

    model.loadSampleSessions()

    XCTAssertEqual(model.sessions.count, LocalMeetingSession.sampleSessions.count)
    XCTAssertEqual(
      model.sessions.first,
      LocalMeetingSession.sampleSessions.max(by: { $0.startedAt < $1.startedAt }))
    XCTAssertEqual(model.selectedSessionID, model.sessions.first?.id)
  }

  func testAddScreenshotAttachmentPersistsTimestampedArtifact() throws {
    let layout = LocalMeetingFileLayout(
      baseDirectory: tempRootURL.appendingPathComponent("Meetings", isDirectory: true))
    let store = LocalMeetingSessionStore(fileLayout: layout)
    let model = LocalMeetingAppModel(store: store, fileLayout: layout)
    let session = makeSession(
      id: UUID(uuidString: "4A79808D-5227-47C2-AED6-6DF5C9C79A10")!,
      startedAt: Date(timeIntervalSince1970: 2_400),
      status: .recording,
      title: "Attachment lifecycle"
    )

    model.upsertSession(session)
    model.selectSession(id: session.id)

    let attachment = model.addScreenshotAttachment(
      title: "Roadmap capture",
      timestamp: session.startedAt.addingTimeInterval(42),
      sessionOffset: 42,
      fileName: "roadmap.png",
      urlString: "/tmp/roadmap.png"
    )
    let artifact = model.addCaptureArtifact(
      title: "Captured roadmap",
      capturedAt: session.startedAt.addingTimeInterval(42),
      sessionOffset: 42,
      attachmentIDs: [attachment?.id].compactMap { $0 }
    )

    XCTAssertNotNil(attachment)
    XCTAssertNotNil(artifact)
    XCTAssertEqual(model.selectedSession?.attachments.count, 1)
    XCTAssertEqual(model.selectedSession?.captureArtifacts.count, 1)
    XCTAssertEqual(model.selectedSession?.attachments.first?.sessionOffset, 42)
  }

  func testTranscriptTimelineConnectsTimestampedScreenshotToContainingSegment() throws {
    let startedAt = Date(timeIntervalSince1970: 4_800)
    let segmentID = UUID(uuidString: "9775D8FB-6911-4B16-A6BB-9BC60B3450BC")!
    let attachmentID = UUID(uuidString: "A253F96B-23F3-46D7-8BF3-AFD7A2336F4B")!
    let artifactID = UUID(uuidString: "D9F05AF7-674B-4C11-8739-F6655C0F4A3F")!
    var session = makeSession(
      id: UUID(uuidString: "41EAAAD7-20E9-4443-8D61-D8A77009BF17")!,
      startedAt: startedAt,
      status: .ready,
      title: "Shot review",
      segments: [
        .init(
          id: UUID(uuidString: "6524EBD6-B264-471D-B6A4-7EAD42F77692")!,
          speaker: "You",
          text: "Opening note.",
          timestamp: startedAt.addingTimeInterval(2),
          endTimestamp: startedAt.addingTimeInterval(6)
        ),
        .init(
          id: segmentID,
          speaker: "You",
          text: "The way we are framing this shot is particularly interesting.",
          timestamp: startedAt.addingTimeInterval(10),
          endTimestamp: startedAt.addingTimeInterval(18)
        ),
      ]
    )
    session.attachments = [
      LocalSessionAttachment(
        id: attachmentID,
        kind: .image,
        source: .floatingBar,
        title: "Frame reference",
        timestamp: startedAt.addingTimeInterval(12),
        sessionOffset: 12,
        fileName: "frame.png",
        mimeType: "image/png",
        urlString: "/tmp/frame.png",
        note: "Captured during review.",
        transcriptSegmentID: nil
      )
    ]
    session.captureArtifacts = [
      LocalSessionCaptureArtifact(
        id: artifactID,
        kind: .screenCapture,
        title: "Frame reference",
        capturedAt: startedAt.addingTimeInterval(12),
        sessionOffset: 12,
        attachmentIDs: [attachmentID],
        notes: "Captured during review.",
        transcriptSegmentID: nil
      )
    ]

    session.anchorTimelineContextToTranscriptSegments()

    XCTAssertEqual(session.attachments.first?.transcriptSegmentID, segmentID)
    XCTAssertEqual(session.captureArtifacts.first?.transcriptSegmentID, segmentID)
    let timelineItem = try XCTUnwrap(session.transcriptTimelineItems.first { $0.id == segmentID })
    XCTAssertEqual(timelineItem.attachments.map(\.id), [attachmentID])
    XCTAssertEqual(timelineItem.captureArtifacts.map(\.id), [artifactID])
  }

  func testLoadStoredSessionsIgnoresCorruptSessionsAndKeepsValidOnes() throws {
    let layout = LocalMeetingFileLayout(
      baseDirectory: tempRootURL.appendingPathComponent("Meetings", isDirectory: true))
    let store = LocalMeetingSessionStore(fileLayout: layout)
    let validSession = makeSession(
      id: UUID(uuidString: "A87F33E4-4B5A-4D60-A6AE-5E1A4CE0468D")!,
      startedAt: Date(timeIntervalSince1970: 3_100),
      status: .ready,
      title: "Valid session"
    )

    try store.save(validSession)

    let corruptSessionDirectory = layout.sessionsDirectory.appendingPathComponent(
      "Corrupt", isDirectory: true)
    try fileManager.createDirectory(at: corruptSessionDirectory, withIntermediateDirectories: true)
    try Data("{ not valid json".utf8).write(
      to: corruptSessionDirectory.appendingPathComponent("session.json", isDirectory: false)
    )

    let sessions = store.loadSessions()

    XCTAssertEqual(sessions.count, 1)
    XCTAssertEqual(sessions.first?.id, validSession.id)
  }

  // Retained as historical coverage for the retired automatic recap pipeline.

  func testRetranscribeExistingSessionUsesSavedMixedAudio() async throws {
    let layout = LocalMeetingFileLayout(
      baseDirectory: tempRootURL.appendingPathComponent("Meetings", isDirectory: true))
    let store = LocalMeetingSessionStore(fileLayout: layout)
    let sessionID = UUID(uuidString: "D76D1B41-8124-4E8C-9386-8439786151B0")!
    let originalSession = makeSession(
      id: sessionID,
      startedAt: Date(timeIntervalSince1970: 4_000),
      status: .failed,
      title: "Retry me",
      audioArtifacts: .init(micFileName: nil, systemFileName: nil, mixedFileName: "mixed.wav")
    )
    try store.save(originalSession)
    try fileManager.createDirectory(
      at: layout.sessionDirectory(for: sessionID),
      withIntermediateDirectories: true
    )
    try writeMonoPCM16Wav(
      to: layout.mixedAudioURL(for: sessionID),
      samples: Array(repeating: 1_000, count: 64_000)
    )

    let transcriptionService = StubLocalSessionTranscriptionService(
      result: LocalSessionTranscriptionResult(
        text: "Recovered transcript",
        detectedLanguage: "he",
        segments: [
          .init(startTime: 0, endTime: 4, text: "Recovered transcript")
        ],
        modelPath: "/tmp/model.bin"
      )
    )
    let model = LocalMeetingAppModel(
      store: store,
      fileLayout: layout,
      transcriptionService: transcriptionService
    )

    model.retranscribeSession(id: sessionID)

    await waitUntil("retranscription finishes") {
      model.selectedSession?.transcriptText == "Recovered transcript" && !model.isTranscribing
    }

    XCTAssertEqual(model.selectedSessionID, sessionID)
    XCTAssertEqual(model.selectedSession?.status, .failed)
    XCTAssertEqual(model.selectedSession?.transcriptionEvidence?.disposition, .degraded)
    XCTAssertTrue(model.processingQueue.isEmpty)
    XCTAssertEqual(transcriptionService.receivedAudioURLs, [layout.mixedAudioURL(for: sessionID)])
  }

  func testRetranscriptionDoesNotClaimSpeakerSeparationWithoutDiarization() async throws {
    let layout = LocalMeetingFileLayout(
      baseDirectory: tempRootURL.appendingPathComponent("Meetings", isDirectory: true))
    let store = LocalMeetingSessionStore(fileLayout: layout)
    let sessionID = UUID(uuidString: "D4D4363B-7693-4EAA-A9F4-CB82636FD1B7")!
    let originalSession = makeSession(
      id: sessionID,
      startedAt: Date(timeIntervalSince1970: 4_200),
      status: .failed,
      title: "Speaker recovery",
      audioArtifacts: .init(
        micFileName: "mic.wav",
        micTranscriptFileName: "mic-transcript.wav",
        systemFileName: "system.wav",
        mixedFileName: "mixed.wav"
      )
    )
    try store.save(originalSession)
    try fileManager.createDirectory(
      at: layout.sessionDirectory(for: sessionID),
      withIntermediateDirectories: true
    )
    try writeMonoPCM16Wav(
      to: layout.micAudioURL(for: sessionID),
      samples: makeDominantSourceSamples(firstSecondAmplitude: 12_000, secondSecondAmplitude: 120)
    )
    try writeMonoPCM16Wav(
      to: layout.micTranscriptAudioURL(for: sessionID),
      samples: makeDominantSourceSamples(firstSecondAmplitude: 12_000, secondSecondAmplitude: 120)
    )
    try writeMonoPCM16Wav(
      to: layout.systemAudioURL(for: sessionID),
      samples: makeDominantSourceSamples(firstSecondAmplitude: 120, secondSecondAmplitude: 12_000)
    )
    try writeMonoPCM16Wav(
      to: layout.mixedAudioURL(for: sessionID),
      samples: makeDominantSourceSamples(firstSecondAmplitude: 8_000, secondSecondAmplitude: 8_000)
    )

    let transcriptionService = StubLocalSessionTranscriptionService(
      result: LocalSessionTranscriptionResult(
        text: "Local speaker. Remote speaker.",
        detectedLanguage: "en",
        segments: [
          .init(startTime: 0.1, endTime: 0.8, text: "Local speaker."),
          .init(startTime: 1.1, endTime: 1.8, text: "Remote speaker."),
        ],
        modelPath: "/tmp/model.bin"
      )
    )
    let model = LocalMeetingAppModel(
      store: store,
      fileLayout: layout,
      transcriptionService: transcriptionService
    )

    model.retranscribeSession(id: sessionID)

    await waitUntil("fallback transcript is applied") {
      model.selectedSession?.transcriptSegments.count == 2 && !model.isTranscribing
    }

    XCTAssertEqual(
      model.selectedSession?.transcriptSegments.map(\.speaker),
      ["Microphone speaker", "Microphone speaker"]
    )
    XCTAssertEqual(model.selectedSession?.status, .failed)
    XCTAssertEqual(model.selectedSession?.transcriptionEvidence?.disposition, .degraded)
  }

  // Retained as historical coverage for the removed document-chat surface.

  func testStoredDocumentChatClearsStaleLocalModelUnavailableError() throws {
    let layout = LocalMeetingFileLayout(
      baseDirectory: tempRootURL.appendingPathComponent("Meetings", isDirectory: true))
    let store = LocalMeetingSessionStore(fileLayout: layout)
    let sessionID = UUID(uuidString: "54D6E78C-B469-4A87-8769-BF9372D120E2")!
    var session = makeSession(
      id: sessionID,
      startedAt: Date(timeIntervalSince1970: 6_500),
      status: .ready,
      title: "Stale chat state"
    )
    session.documentChat = LocalSessionDocumentChat(
      messages: [
        .init(
          id: UUID(uuidString: "B1976B5B-10E7-40F8-8B49-A9B2B9577B5B")!,
          role: .assistant,
          text: "I could not produce a clean document edit from the local model.",
          createdAt: Date(timeIntervalSince1970: 6_510)
        )
      ],
      pendingProposal: nil,
      undoSnapshot: nil,
      status: .failed,
      errorMessage: "Local model is unavailable.",
      createdAt: Date(timeIntervalSince1970: 6_505),
      updatedAt: Date(timeIntervalSince1970: 6_515)
    )
    try store.save(session)

    let model = LocalMeetingAppModel(store: store, fileLayout: layout)

    XCTAssertEqual(model.selectedSession?.documentChat.status, .idle)
    XCTAssertNil(model.selectedSession?.documentChat.errorMessage)
    XCTAssertTrue(model.selectedSession?.documentChat.messages.isEmpty == true)
  }

  func testStoredDocumentChatClearsStaleTranscriptCopyAnswer() throws {
    let layout = LocalMeetingFileLayout(
      baseDirectory: tempRootURL.appendingPathComponent("Meetings", isDirectory: true))
    let store = LocalMeetingSessionStore(fileLayout: layout)
    let sessionID = UUID(uuidString: "8E10F51A-ED0F-4C59-AAB9-33863D109920")!
    var session = makeSession(
      id: sessionID,
      startedAt: Date(timeIntervalSince1970: 6_600),
      status: .ready,
      title: "Session 30 Apr 2026 at 12:26"
    )
    session.documentChat = LocalSessionDocumentChat(
      messages: [
        .init(
          id: UUID(uuidString: "FCF948A0-773D-45D5-9E12-3733747FB243")!,
          role: .user,
          text: "על מה המסמך",
          createdAt: Date(timeIntervalSince1970: 6_610)
        ),
        .init(
          id: UUID(uuidString: "21120AAC-EB6D-43CC-9455-F3E1C2955753")!,
          role: .assistant,
          text:
            "המסמך עוסק בועכשיו אני למשל לוקח סרטון, בואו ניקח איזה סרטון ההיסטוריה שראיתי ביוטיוב, אני רוצה משהו בעברית",
          createdAt: Date(timeIntervalSince1970: 6_612)
        ),
      ],
      pendingProposal: nil,
      undoSnapshot: nil,
      status: .idle,
      errorMessage: nil,
      createdAt: Date(timeIntervalSince1970: 6_605),
      updatedAt: Date(timeIntervalSince1970: 6_615)
    )
    try store.save(session)

    let model = LocalMeetingAppModel(store: store, fileLayout: layout)

    XCTAssertEqual(model.selectedSession?.documentChat.messages.map(\.role), [.user])
  }

  func testStoredDocumentChatClearsStaleInstructionEchoPendingProposal() throws {
    let layout = LocalMeetingFileLayout(
      baseDirectory: tempRootURL.appendingPathComponent("Meetings", isDirectory: true))
    let store = LocalMeetingSessionStore(fileLayout: layout)
    let sessionID = UUID(uuidString: "0F4C87FE-F94D-48C1-BE23-A7F207C80679")!
    var session = makeSession(
      id: sessionID,
      startedAt: Date(timeIntervalSince1970: 6_650),
      status: .ready,
      title: "Session 30 Apr 2026 at 12:26"
    )
    session.documentChat = LocalSessionDocumentChat(
      messages: [
        .init(
          id: UUID(uuidString: "A671554B-6E9E-4845-BD86-3E6DA99E6C2E")!,
          role: .user,
          text: "תוסיף את התמלול בסוף המסמך. תרשום את זה כמו סיפור.",
          createdAt: Date(timeIntervalSince1970: 6_660)
        ),
        .init(
          id: UUID(uuidString: "82EE4AE7-C105-4688-80E5-B38A6A91D7DB")!,
          role: .assistant,
          text: "Preview ready: הוספתי פסקת המשך בסוף המסמך.",
          createdAt: Date(timeIntervalSince1970: 6_662)
        ),
      ],
      pendingProposal: LocalSessionDocumentEditProposal(
        assistantMessage: "הוספתי פסקת המשך בסוף המסמך.",
        recapPatch: LocalSessionDocumentRecapPatch(
          overview: nil,
          sections: [
            .init(
              kind: .notes,
              title: "המשך המסמך",
              summary: "תוסיף את התמלול בסוף המסמך",
              bullets: []
            )
          ]
        ),
        transcriptPatches: [],
        speakerRenames: [],
        warnings: []
      ),
      undoSnapshot: nil,
      status: .idle,
      errorMessage: nil,
      createdAt: Date(timeIntervalSince1970: 6_655),
      updatedAt: Date(timeIntervalSince1970: 6_665)
    )
    try store.save(session)

    let model = LocalMeetingAppModel(store: store, fileLayout: layout)

    XCTAssertNil(model.selectedSession?.documentChat.pendingProposal)
    XCTAssertEqual(model.selectedSession?.documentChat.messages.map(\.role), [.user])
  }

  func testStoredSessionRemovesAppliedAppendInstructionSectionFromRecap() throws {
    let layout = LocalMeetingFileLayout(
      baseDirectory: tempRootURL.appendingPathComponent("Meetings", isDirectory: true))
    let store = LocalMeetingSessionStore(fileLayout: layout)
    let sessionID = UUID(uuidString: "D9AC5C8E-BF10-4C9F-BE26-8D5A64D64963")!
    var session = makeSession(
      id: sessionID,
      startedAt: Date(timeIntervalSince1970: 6_700),
      status: .ready,
      title: "קטע מלייב של מורה מבוכים ערוץ דונקי"
    )
    session.recap = LocalSessionRecap(
      overview: "המסמך עוסק בסרטון יוטיוב בעברית.",
      generatedAt: Date(timeIntervalSince1970: 6_705),
      sections: [
        LocalSessionRecapSection(
          id: UUID(uuidString: "41D23D1A-A631-4674-BC05-B33026389864")!,
          kind: .keyPoints,
          title: "מה מופיע בסרטון",
          summary: "הרגעים והפרטים המרכזיים מתוך הסרטון.",
          bullets: ["ניסיון התגנבות", "חץ שפוגע בעץ"],
          anchorTimestamp: nil,
          startOffset: nil,
          endOffset: nil
        ),
        LocalSessionRecapSection(
          id: UUID(uuidString: "E79122EF-BB0E-45AA-89F0-F3BD6EF8F030")!,
          kind: .notes,
          title: "תוסיף את התמלול בצורה של סיפור למסמך",
          summary: "סעיף נוסף במסמך שמתייחס להוסיף את התמלול בצורה של סיפור למסמך.",
          bullets: [
            "להוסיף למסמך התייחסות לתמלול בצורה של סיפור.",
            "להשתמש בסעיף הזה כנקודת המשך לעבודה על המסמך.",
          ],
          anchorTimestamp: nil,
          startOffset: nil,
          endOffset: nil
        ),
      ]
    )
    session.documentChat = LocalSessionDocumentChat(
      messages: [
        .init(
          id: UUID(uuidString: "225132E9-E1E7-4F94-A65A-927BC1749D8D")!,
          role: .user,
          text: "תוסיף את התמלול בסוף המסמך. תרשום את זה כמו ספר",
          createdAt: Date(timeIntervalSince1970: 6_710)
        ),
        .init(
          id: UUID(uuidString: "99BE15C9-49B5-42DC-A257-95646AD100DE")!,
          role: .assistant,
          text: "Preview ready: הוספתי פסקת המשך בסוף המסמך.",
          createdAt: Date(timeIntervalSince1970: 6_712)
        ),
      ],
      pendingProposal: nil,
      undoSnapshot: nil,
      status: .idle,
      errorMessage: nil,
      createdAt: Date(timeIntervalSince1970: 6_708),
      updatedAt: Date(timeIntervalSince1970: 6_715)
    )
    try store.save(session)

    let model = LocalMeetingAppModel(store: store, fileLayout: layout)

    let reloadedSections = model.selectedSession?.recap.sections ?? []
    XCTAssertEqual(reloadedSections.map(\.title), ["מה מופיע בסרטון"])
    XCTAssertFalse(
      LocalSessionRecapMarkdownDocument(session: model.selectedSession!).markdown.contains(
        "תוסיף את התמלול")
    )
    XCTAssertEqual(model.selectedSession?.documentChat.messages.map(\.role), [.user])
  }

  func testStoredHebrewVideoRecapMigratesStaleTemplateTitles() throws {
    let layout = LocalMeetingFileLayout(
      baseDirectory: tempRootURL.appendingPathComponent("Meetings", isDirectory: true))
    let store = LocalMeetingSessionStore(fileLayout: layout)
    let sessionID = UUID(uuidString: "8E10F51A-ED0F-4C59-AAB9-33863D109920")!
    var session = makeSession(
      id: sessionID,
      startedAt: Date(timeIntervalSince1970: 6_700),
      status: .ready,
      title: "Session 30 Apr 2026 at 12:26"
    )
    session.recap = LocalSessionRecap(
      overview:
        "המסמך עוסק בסרטון יוטיוב בעברית, כנראה לייב של מורה מבוכים מערוץ דונקי.",
      generatedAt: Date(timeIntervalSince1970: 6_710),
      sections: [
        LocalSessionRecapSection(
          id: UUID(uuidString: "95124BBD-5D66-49E4-9F7C-F4F7D218F7B5")!,
          kind: .overview,
          title: "Overview",
          summary:
            "המסמך עוסק בסרטון יוטיוב בעברית, כנראה לייב של מורה מבוכים מערוץ דונקי.",
          bullets: [],
          anchorTimestamp: nil,
          startOffset: nil,
          endOffset: nil
        ),
        LocalSessionRecapSection(
          id: UUID(uuidString: "F01F2A50-5997-4794-8923-D681382495D8")!,
          kind: .keyPoints,
          title: "Commentary highlights",
          summary: "Important moments and observations from the commentary.",
          bullets: ["ההקלטה מתחילה בבחירת סרטון מהיסטוריית יוטיוב."],
          anchorTimestamp: nil,
          startOffset: nil,
          endOffset: nil
        ),
        LocalSessionRecapSection(
          id: UUID(uuidString: "D909460D-8341-4C00-8C2E-9402DE0C36C7")!,
          kind: .actionItem,
          title: "Follow-up from commentary",
          summary: "Follow-up work created by the observed video or screen context.",
          bullets: [
            "אם מטרת המסמך היא ניתוח הסרטון, לחדד אילו רגעים מתוך הסצנה חשובים להמשך.",
            "אם מטרת המסמך היא בדיקת המערכת, לוודא שהסיכום מתאר את נושא הסרטון ולא מעתיק את שורות הפתיחה של התמלול.",
          ],
          anchorTimestamp: nil,
          startOffset: nil,
          endOffset: nil
        ),
        LocalSessionRecapSection(
          id: UUID(uuidString: "AFBB8D83-18C4-46F2-9421-C95F215482B3")!,
          kind: .openQuestions,
          title: "Open questions",
          summary: "Questions that still need confirmation.",
          bullets: [
            "האם צריך לסכם את תוכן הסרטון עצמו או רק לבדוק שהמערכת מבינה הקלטת אודיו חיצונית?"
          ],
          anchorTimestamp: nil,
          startOffset: nil,
          endOffset: nil
        ),
      ]
    )
    try store.save(session)

    let model = LocalMeetingAppModel(store: store, fileLayout: layout)
    let markdown = LocalSessionRecapMarkdownDocument.markdown(
      for: try XCTUnwrap(model.selectedSession),
      language: .hebrew
    )

    XCTAssertTrue(markdown.contains("## על מה המסמך"))
    XCTAssertTrue(markdown.contains("## מה מופיע בסרטון"))
    XCTAssertFalse(markdown.contains("## Overview"))
    XCTAssertFalse(markdown.contains("## Commentary highlights"))
    XCTAssertFalse(markdown.contains("Follow-up work created by the observed video"))
    XCTAssertFalse(markdown.contains("אם מטרת המסמך"))
    XCTAssertFalse(markdown.contains("האם צריך לסכם את תוכן הסרטון"))
  }

  func testStoredSessionClearsGenericFallbackRecapWhenTranscriptIsMissing() throws {
    let layout = LocalMeetingFileLayout(
      baseDirectory: tempRootURL.appendingPathComponent("Meetings", isDirectory: true))
    let store = LocalMeetingSessionStore(fileLayout: layout)
    let sessionID = UUID(uuidString: "9565368D-4581-4FF8-B6B3-1990300C473E")!
    var session = makeSession(
      id: sessionID,
      startedAt: Date(timeIntervalSince1970: 6_750),
      status: .ready,
      title: "Session 30 Apr 2026 at 14:52"
    )
    _ = session.addCaptureArtifact(
      title: "Screen context",
      capturedAt: Date(timeIntervalSince1970: 6_755),
      sessionOffset: 2
    )
    session.recap = LocalSessionRecap(
      overview:
        "The source material captured the main areas that need follow-up. The brief focuses on the work, context, and follow-up supported by the source material.",
      generatedAt: Date(timeIntervalSince1970: 6_760),
      sections: [
        LocalSessionRecapSection(
          id: UUID(uuidString: "19E3D839-86BF-40CB-AD07-42DF511BA88A")!,
          kind: .keyPoints,
          title: "Key details",
          summary: "Important moments and observations from the commentary.",
          bullets: [],
          anchorTimestamp: nil,
          startOffset: nil,
          endOffset: nil
        ),
        LocalSessionRecapSection(
          id: UUID(uuidString: "EB15B6C9-8F2B-42C1-996F-F2E0068C8D5C")!,
          kind: .actionItem,
          title: "Tasks or follow-up",
          summary: "Follow-up work created by the observed video or screen context.",
          bullets: [],
          anchorTimestamp: nil,
          startOffset: nil,
          endOffset: nil
        ),
      ]
    )
    try store.save(session)

    let model = LocalMeetingAppModel(store: store, fileLayout: layout)

    XCTAssertEqual(model.selectedSession?.recap, .empty)
    XCTAssertEqual(model.selectedSession?.captureArtifacts.count, 1)
    let reloaded = try XCTUnwrap(store.loadSessions().first { $0.id == sessionID })
    XCTAssertEqual(reloaded.recap, .empty)
    XCTAssertEqual(reloaded.captureArtifacts.count, 1)
  }

  func testStoredHebrewTitleNoteMigratesToSessionTitle() throws {
    let layout = LocalMeetingFileLayout(
      baseDirectory: tempRootURL.appendingPathComponent("Meetings", isDirectory: true))
    let store = LocalMeetingSessionStore(fileLayout: layout)
    let sessionID = UUID(uuidString: "8E10F51A-ED0F-4C59-AAB9-33863D109920")!
    var session = makeSession(
      id: sessionID,
      startedAt: Date(timeIntervalSince1970: 6_800),
      status: .ready,
      title: "Session 30 Apr 2026 at 12:26"
    )
    session.recap = LocalSessionRecap(
      overview: "המסמך עוסק בסרטון יוטיוב בעברית.",
      generatedAt: Date(timeIntervalSince1970: 6_810),
      sections: [
        LocalSessionRecapSection(
          id: UUID(uuidString: "59C96C8C-A8EA-420E-8B9C-90CC3655EF92")!,
          kind: .notes,
          title: "תעדכן את הכותרת - קטע מלייב של מורה מבוכים ערוץ דונקי",
          summary:
            "סעיף נוסף במסמך שמתייחס לתעדכן את הכותרת - קטע מלייב של מורה מבוכים ערוץ דונקי.",
          bullets: [
            "להוסיף למסמך התייחסות לתעדכן את הכותרת - קטע מלייב של מורה מבוכים ערוץ דונקי."
          ],
          anchorTimestamp: nil,
          startOffset: nil,
          endOffset: nil
        )
      ]
    )
    try store.save(session)

    let model = LocalMeetingAppModel(store: store, fileLayout: layout)

    XCTAssertEqual(model.selectedSession?.title, "קטע מלייב של מורה מבוכים ערוץ דונקי")
    XCTAssertNil(model.selectedSession?.recap.section(kind: .notes))
  }

  // Retained as historical coverage for the retired automatic recap repair pipeline.

  func testInitRemovesRepeatedShortTranscriptGlitchesFromStoredSession() throws {
    let layout = LocalMeetingFileLayout(
      baseDirectory: tempRootURL.appendingPathComponent("Meetings", isDirectory: true))
    let store = LocalMeetingSessionStore(fileLayout: layout)
    let startedAt = Date(timeIntervalSince1970: 7_200)
    let repeatedSegments = (0..<24).map { index in
      LocalMeetingTranscriptSegment(
        id: UUID(),
        speaker: index.isMultiple(of: 3) ? "Remote speaker" : "Speaker 1",
        text: "סבבה?",
        timestamp: startedAt.addingTimeInterval(Double(index) * 0.25)
      )
    }
    let session = makeSession(
      id: UUID(uuidString: "A9C34F50-90F0-44DF-8F6C-263535C8FA9F")!,
      startedAt: startedAt,
      status: .ready,
      title: "Noisy transcript",
      segments: repeatedSegments + [
        .init(
          id: UUID(uuidString: "4E9B9D51-0812-4E8E-BBC8-5B3078135C6C")!,
          speaker: "You",
          text: "אתה אמור לראות את זה רץ במסמך בחלון פה.",
          timestamp: startedAt.addingTimeInterval(14)
        )
      ]
    )
    try store.save(session)

    let model = LocalMeetingAppModel(store: store, fileLayout: layout)
    let cleaned = try XCTUnwrap(model.selectedSession)
    let repeatedCount = cleaned.transcriptSegments.filter { $0.text == "סבבה?" }.count

    XCTAssertLessThanOrEqual(repeatedCount, 3)
    XCTAssertTrue(cleaned.transcriptText.contains("אתה אמור לראות את זה"))
    XCTAssertLessThan(cleaned.transcriptSegments.count, session.transcriptSegments.count)
  }

}

@MainActor
private final class StubLocalSessionTranscriptionService: @unchecked Sendable,
  LocalSessionTranscribing
{
  let result: LocalSessionTranscriptionResult
  private(set) var receivedAudioURLs: [URL] = []
  private(set) var receivedModelURLs: [URL] = []
  private(set) var receivedLanguages: [String] = []

  init(result: LocalSessionTranscriptionResult) {
    self.result = result
  }

  func warmUp(modelURL: URL) async {}

  func transcribe(
    wavURL: URL,
    modelURL: URL,
    language: String,
    prompt: String?,
    translateToEnglish: Bool,
    onProgress: (@Sendable (LocalSessionTranscriptionProgress) async -> Void)?
  ) async throws -> LocalSessionTranscriptionResult {
    receivedAudioURLs.append(wavURL)
    receivedModelURLs.append(modelURL)
    receivedLanguages.append(language)
    return result
  }
}

@MainActor
private final class StubLocalSessionAudioImportService: @unchecked Sendable,
  LocalSessionAudioImporting
{
  private(set) var importedDestinations: [URL] = []

  func importAudio(from sourceURL: URL, to destinationWavURL: URL) async throws {
    importedDestinations.append(destinationWavURL)
    let wavData = Data([
      0x52, 0x49, 0x46, 0x46, 0x24, 0x00, 0x00, 0x00,
      0x57, 0x41, 0x56, 0x45, 0x66, 0x6D, 0x74, 0x20,
      0x10, 0x00, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00,
      0x80, 0x3E, 0x00, 0x00, 0x00, 0x7D, 0x00, 0x00,
      0x02, 0x00, 0x10, 0x00, 0x64, 0x61, 0x74, 0x61,
      0x00, 0x00, 0x00, 0x00,
    ])
    try wavData.write(to: destinationWavURL)
  }
}


@MainActor
private func waitUntil(
  _ description: String,
  timeoutNanoseconds: UInt64 = 1_000_000_000,
  condition: @escaping @MainActor () -> Bool
) async {
  let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
  while !condition() {
    if DispatchTime.now().uptimeNanoseconds >= deadline {
      XCTFail("Timed out waiting for \(description)")
      return
    }
    await Task.yield()
  }
}

@MainActor
final class LocalSessionAppModelTests: XCTestCase {
  func testUpdateSessionTitleTrimsAndPersistsSelectedSession() throws {
    let sessionID = UUID(uuidString: "A68B8C34-7E52-4F32-9D9D-2C3A6A0E4B1A")!
    let tempRootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
      "LocalSessionAppModelTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tempRootURL) }
    let layout = LocalMeetingFileLayout(
      baseDirectory: tempRootURL.appendingPathComponent("Meetings", isDirectory: true))
    let store = LocalMeetingSessionStore(fileLayout: layout)
    try store.save(
      makeSession(
        id: sessionID,
        startedAt: Date(timeIntervalSince1970: 1_000),
        status: .ready,
        title: "Weekly sync"
      )
    )
    let model = LocalMeetingAppModel(store: store, fileLayout: layout)

    model.selectSession(id: sessionID)

    XCTAssertTrue(model.updateSessionTitle("  Strategy review  ", for: sessionID))
    XCTAssertEqual(model.selectedSession?.title, "Strategy review")
  }
}

private func makeSession(
  id: UUID,
  startedAt: Date,
  status: LocalMeetingSessionStatus,
  title: String,
  segments: [LocalMeetingTranscriptSegment] = [],
  attachments: [LocalMeetingAttachment] = [],
  captureArtifacts: [LocalMeetingCaptureArtifact] = [],
  audioArtifacts: LocalMeetingAudioArtifacts = .empty
) -> LocalMeetingSession {
  LocalMeetingSession(
    id: id,
    title: title,
    startedAt: startedAt,
    status: status,
    transcriptSegments: segments,
    attachments: attachments,
    captureArtifacts: captureArtifacts,
    audioArtifacts: audioArtifacts
  )
}

private func makeDominantSourceSamples(
  firstSecondAmplitude: Int16,
  secondSecondAmplitude: Int16,
  sampleRate: Int = 16_000
) -> [Int16] {
  let first = Array(repeating: firstSecondAmplitude, count: sampleRate)
  let second = Array(repeating: secondSecondAmplitude, count: sampleRate)
  return first + second
}

private func writeMonoPCM16Wav(to url: URL, samples: [Int16], sampleRate: Int = 16_000) throws {
  var data = Data()
  let byteRate = sampleRate * 2
  let blockAlign: UInt16 = 2
  let dataByteCount = samples.count * 2
  appendASCII("RIFF", to: &data)
  appendUInt32LE(UInt32(36 + dataByteCount), to: &data)
  appendASCII("WAVE", to: &data)
  appendASCII("fmt ", to: &data)
  appendUInt32LE(16, to: &data)
  appendUInt16LE(1, to: &data)
  appendUInt16LE(1, to: &data)
  appendUInt32LE(UInt32(sampleRate), to: &data)
  appendUInt32LE(UInt32(byteRate), to: &data)
  appendUInt16LE(blockAlign, to: &data)
  appendUInt16LE(16, to: &data)
  appendASCII("data", to: &data)
  appendUInt32LE(UInt32(dataByteCount), to: &data)
  for sample in samples {
    appendUInt16LE(UInt16(bitPattern: sample), to: &data)
  }
  try data.write(to: url)
}

private func writeValidGGMLFixture(to url: URL) throws {
  try Data([0x6c, 0x6d, 0x67, 0x67, 0x01]).write(to: url)
}

private func appendASCII(_ string: String, to data: inout Data) {
  data.append(contentsOf: string.utf8)
}

private func appendUInt16LE(_ value: UInt16, to data: inout Data) {
  data.append(UInt8(value & 0x00FF))
  data.append(UInt8((value & 0xFF00) >> 8))
}

private func appendUInt32LE(_ value: UInt32, to data: inout Data) {
  data.append(UInt8(value & 0x0000_00FF))
  data.append(UInt8((value & 0x0000_FF00) >> 8))
  data.append(UInt8((value & 0x00FF_0000) >> 16))
  data.append(UInt8((value & 0xFF00_0000) >> 24))
}

// MARK: - Legacy segments

final class LocalSessionLegacySegmentDecodingTests: XCTestCase {
  private func decode(_ json: String) throws -> [LocalSessionTranscriptSegment] {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode([LocalSessionTranscriptSegment].self, from: Data(json.utf8))
  }

  /// Recordings from before segment ids existed must load, and load the same
  /// way every time, instead of making the whole session unreadable.
  func testSegmentsWithoutIdsGetStableDistinctIds() throws {
    let json = """
      [
        {"speaker": "Speaker 1", "text": "שלום", "timestamp": "2026-08-20T18:40:48Z"},
        {"speaker": "Speaker 1", "text": "Hello again", "timestamp": "2026-08-20T18:40:52Z"}
      ]
      """
    let first = try decode(json)
    let second = try decode(json)

    XCTAssertEqual(first.map(\.id), second.map(\.id))
    XCTAssertNotEqual(first[0].id, first[1].id)
    XCTAssertEqual(first[0].text, "שלום")
  }

  /// The earliest format stored "MM:SS" offsets instead of dates. They load as
  /// dates from the session start, with stable ids, instead of breaking it.
  func testOffsetTimestampsFromTheEarliestFormatLoad() throws {
    let json = """
      {
        "id": "D8305BE9-F769-472B-9D6C-E13434AA3820",
        "title": "Session 20 Aug 2026 at 21:40",
        "startedAt": "2026-08-20T18:40:48Z",
        "status": "failed",
        "audioArtifacts": {},
        "transcriptSegments": [
          {"speaker": "Speaker 1", "text": "בוקר טוב", "timestamp": "00:05"},
          {"speaker": "Speaker 2", "text": "Morning", "timestamp": "1:02:03"}
        ]
      }
      """
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let first = try decoder.decode(LocalSession.self, from: Data(json.utf8))
    let again = try decoder.decode(LocalSession.self, from: Data(json.utf8))

    XCTAssertEqual(first.transcriptSegments.count, 2)
    XCTAssertEqual(
      first.transcriptSegments[0].timestamp.timeIntervalSince(first.startedAt), 5, accuracy: 0.001)
    XCTAssertEqual(
      first.transcriptSegments[1].timestamp.timeIntervalSince(first.startedAt), 3723,
      accuracy: 0.001)
    XCTAssertEqual(first.transcriptSegments.map(\.id), again.transcriptSegments.map(\.id))
    XCTAssertNotEqual(first.transcriptSegments[0].id, first.transcriptSegments[1].id)
  }

  func testAStoredIdIsAlwaysKept() throws {
    let id = UUID()
    let segments = try decode(
      """
      [{"id": "\(id.uuidString)", "speaker": "A", "text": "x", "timestamp": "2026-08-20T18:40:48Z"}]
      """)
    XCTAssertEqual(segments.first?.id, id)
  }
}
