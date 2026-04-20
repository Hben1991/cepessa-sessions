import Foundation
import XCTest
@testable import Omi_Computer

final class LocalMeetingPromptPackageTests: XCTestCase {
    private var tempRootURL: URL!
    private let fileManager = FileManager.default

    override func setUpWithError() throws {
        tempRootURL = fileManager.temporaryDirectory
            .appendingPathComponent("LocalMeetingPromptPackageTests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempRootURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempRootURL {
            try? fileManager.removeItem(at: tempRootURL)
        }
    }

    func testSavingSessionGeneratesMarkdownAndJSONPromptPackage() throws {
        let layout = LocalMeetingFileLayout(baseDirectory: tempRootURL.appendingPathComponent("Cepessa", isDirectory: true))
        let store = LocalMeetingSessionStore(fileLayout: layout)
        let sessionID = UUID(uuidString: "B0C1D2E3-F4A5-46B7-88C9-001122334455")!
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let session = LocalSession(
            id: sessionID,
            title: "Session Product Review",
            startedAt: startedAt,
            status: .ready,
            transcriptSegments: [
                .init(
                    id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
                    speaker: "Transcript",
                    text: "We agreed to ship the export package next.",
                    timestamp: startedAt.addingTimeInterval(45)
                )
            ],
            recap: LocalSessionRecap(
                overview: "A short decision-focused recap.",
                generatedAt: startedAt.addingTimeInterval(60),
                sections: [
                    .init(
                        id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
                        kind: .decisions,
                        title: "Decisions",
                        summary: "Ship the export package first.",
                        bullets: ["Export transcript, recap, and attachments together."],
                        anchorTimestamp: startedAt.addingTimeInterval(45),
                        startOffset: 45,
                        endOffset: 55
                    )
                ]
            ),
            attachments: [
                .init(
                    id: UUID(uuidString: "99999999-8888-7777-6666-555555555555")!,
                    kind: .file,
                    source: .imported,
                    title: "PRD",
                    timestamp: startedAt.addingTimeInterval(32),
                    sessionOffset: 32,
                    fileName: "prd.pdf",
                    mimeType: "application/pdf",
                    urlString: layout.attachmentsDirectory(for: sessionID).appendingPathComponent("prd.pdf").path,
                    note: "Imported during review."
                )
            ],
            captureArtifacts: [
                .init(
                    id: UUID(uuidString: "12345678-90AB-CDEF-1234-567890ABCDEF")!,
                    kind: .note,
                    title: "PRD reference",
                    capturedAt: startedAt.addingTimeInterval(32),
                    sessionOffset: 32,
                    attachmentIDs: [UUID(uuidString: "99999999-8888-7777-6666-555555555555")!],
                    notes: "Discussed while deciding the rollout order."
                )
            ],
            audioArtifacts: .init(
                micFileName: "mic.wav",
                systemFileName: "system.wav",
                mixedFileName: "mixed.wav"
            )
        )

        try store.save(session)

        let markdownURL = layout.promptPackageMarkdownURL(for: sessionID)
        let jsonURL = layout.promptPackageJSONURL(for: sessionID)

        XCTAssertTrue(fileManager.fileExists(atPath: markdownURL.path))
        XCTAssertTrue(fileManager.fileExists(atPath: jsonURL.path))

        let markdown = try String(contentsOf: markdownURL, encoding: .utf8)
        XCTAssertTrue(markdown.contains("Reusable AI Prompt"))
        XCTAssertTrue(markdown.contains("Session Product Review"))
        XCTAssertTrue(markdown.contains("We agreed to ship the export package next."))
        XCTAssertTrue(markdown.contains("prd.pdf"))

        let jsonObject = try JSONSerialization.jsonObject(with: Data(contentsOf: jsonURL)) as? [String: Any]
        XCTAssertEqual(jsonObject?["title"] as? String, "Session Product Review")
        XCTAssertEqual((jsonObject?["attachments"] as? [[String: Any]])?.count, 1)
    }
}
