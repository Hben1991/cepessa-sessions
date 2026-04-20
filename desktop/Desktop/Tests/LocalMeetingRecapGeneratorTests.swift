import Foundation
import XCTest
@testable import Omi_Computer

final class LocalMeetingRecapGeneratorTests: XCTestCase {
    func testDefaultLLMClientFallsBackToLocalGemma4Ollama() {
        let client = LocalSessionRecapGenerator.defaultLLMClient(environment: [:])
        let ollamaClient = client as? LocalSessionOllamaRecapClient

        XCTAssertEqual(ollamaClient?.baseURL.absoluteString, "http://127.0.0.1:11434")
        XCTAssertEqual(ollamaClient?.model, "gemma4:e4b")
    }

    func testDefaultLLMClientHonorsEnvironmentOverrides() {
        let client = LocalSessionRecapGenerator.defaultLLMClient(
            environment: [
                "CEPESSA_OLLAMA_BASE_URL": "http://localhost:22434",
                "CEPESSA_OLLAMA_MODEL": "custom-gemma"
            ]
        )
        let ollamaClient = client as? LocalSessionOllamaRecapClient

        XCTAssertEqual(ollamaClient?.baseURL.absoluteString, "http://localhost:22434")
        XCTAssertEqual(ollamaClient?.model, "custom-gemma")
    }

    func testDeterministicGeneratorBuildsStructuredSections() async {
        let generator = LocalSessionRecapGenerator(llmClient: nil)
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
                    text: "We decided to move the launch to next Thursday and I will send the updated plan tomorrow.",
                    timestamp: startedAt.addingTimeInterval(12)
                ),
                .init(
                    id: UUID(uuidString: "B2049D1F-C9EC-4A48-A213-0BB9AAFE7A02")!,
                    speaker: "Noam",
                    text: "The open question is whether support can review the migration checklist by Monday?",
                    timestamp: startedAt.addingTimeInterval(48)
                )
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
        XCTAssertTrue(recap.sections.contains(where: { $0.kind == .openQuestions && !$0.bullets.isEmpty }))
    }
}
