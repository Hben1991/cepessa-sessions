import Foundation
import XCTest
@testable import Omi_Computer

final class CepessaSessionFloatingAttachmentDeckTests: XCTestCase {
    func testBuildUsesNewestThreeAttachmentsAndTracksOverflow() {
        let startedAt = Date(timeIntervalSince1970: 1_700_100_000)
        let session = LocalSession(
            id: UUID(uuidString: "0A0B0C0D-0000-4000-8000-000000000001")!,
            title: "Session",
            startedAt: startedAt,
            status: .recording,
            transcriptSegments: [],
            recap: .empty,
            attachments: [
                attachment(id: "10000000-0000-4000-8000-000000000001", title: "Oldest", seconds: 5),
                attachment(id: "10000000-0000-4000-8000-000000000002", title: "Second", seconds: 20),
                attachment(id: "10000000-0000-4000-8000-000000000003", title: "Third", seconds: 35),
                attachment(id: "10000000-0000-4000-8000-000000000004", title: "Newest", seconds: 55),
            ],
            captureArtifacts: [],
            audioArtifacts: .empty
        )

        let deck = CepessaSessionFloatingAttachmentDeck.build(from: session)

        XCTAssertEqual(deck.previews.map(\.title), ["Newest", "Third", "Second"])
        XCTAssertEqual(deck.overflowCount, 1)
    }

    func testBuildKeepsPreviewForAttachmentsWithoutLocalFiles() {
        let startedAt = Date(timeIntervalSince1970: 1_700_100_000)
        let session = LocalSession(
            id: UUID(uuidString: "0A0B0C0D-0000-4000-8000-000000000002")!,
            title: "Session",
            startedAt: startedAt,
            status: .recording,
            transcriptSegments: [],
            recap: .empty,
            attachments: [
                LocalSessionAttachment(
                    id: UUID(uuidString: "20000000-0000-4000-8000-000000000001")!,
                    kind: .file,
                    source: .imported,
                    title: "Remote brief",
                    timestamp: startedAt.addingTimeInterval(15),
                    sessionOffset: 15,
                    fileName: "brief.pdf",
                    mimeType: "application/pdf",
                    urlString: "https://example.com/brief.pdf",
                    note: nil
                )
            ],
            captureArtifacts: [],
            audioArtifacts: .empty
        )

        let deck = CepessaSessionFloatingAttachmentDeck.build(from: session)

        XCTAssertEqual(deck.previews.count, 1)
        XCTAssertEqual(deck.previews.first?.title, "Remote brief")
        XCTAssertNil(deck.previews.first?.fileURL)
        XCTAssertEqual(deck.overflowCount, 0)
    }

    private func attachment(id: String, title: String, seconds: TimeInterval) -> LocalSessionAttachment {
        LocalSessionAttachment(
            id: UUID(uuidString: id)!,
            kind: .image,
            source: .floatingBar,
            title: title,
            timestamp: Date(timeIntervalSince1970: 1_700_100_000).addingTimeInterval(seconds),
            sessionOffset: seconds,
            fileName: "\(title).png",
            mimeType: "image/png",
            urlString: "/tmp/\(title).png",
            note: nil
        )
    }
}
