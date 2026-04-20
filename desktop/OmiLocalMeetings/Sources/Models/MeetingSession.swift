import Foundation

enum MeetingSessionStatus: String, Codable, Equatable {
    case recording
    case transcribing
    case ready
    case failed
}

struct MeetingAudioArtifacts: Codable, Equatable {
    var micFileName: String?
    var systemFileName: String?
    var mixedFileName: String?

    static let empty = MeetingAudioArtifacts(
        micFileName: nil,
        systemFileName: nil,
        mixedFileName: nil
    )
}

struct MeetingSession: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    var startedAt: Date
    var status: MeetingSessionStatus
    var segments: [TranscriptSegment]
    var audioArtifacts: MeetingAudioArtifacts

    var transcriptText: String {
        segments.map(\.text).joined(separator: "\n")
    }

    static let sampleSessions: [MeetingSession] = [
        MeetingSession(
            id: UUID(uuidString: "2E5AE0E5-8B3B-4C2E-9FAF-3C7E7A0C8A11")!,
            title: "Weekly sync",
            startedAt: Date(timeIntervalSince1970: 1_742_680_200),
            status: .ready,
            segments: [
                TranscriptSegment(
                    id: UUID(uuidString: "9BC64E75-9BC2-4386-862A-8A2D7F8D9D51")!,
                    speaker: "Maya",
                    text: "Let's keep this focused on blockers and next steps.",
                    timestamp: Date(timeIntervalSince1970: 1_742_680_260)
                ),
                TranscriptSegment(
                    id: UUID(uuidString: "D4AAE4FB-2E22-4E82-88B4-1A4B10B13F5E")!,
                    speaker: "Noam",
                    text: "I can own the follow-up and send a summary today.",
                    timestamp: Date(timeIntervalSince1970: 1_742_680_320)
                )
            ],
            audioArtifacts: .empty
        ),
        MeetingSession(
            id: UUID(uuidString: "D9280F3A-4D57-4C18-80D2-2B5DB2C0D4D2")!,
            title: "Product review",
            startedAt: Date(timeIntervalSince1970: 1_742_594_400),
            status: .ready,
            segments: [
                TranscriptSegment(
                    id: UUID(uuidString: "B3F9B4AD-9E5E-48A2-97F7-1E5A1F80E3FD")!,
                    speaker: "Dana",
                    text: "The local recorder should stay simple and dependable.",
                    timestamp: Date(timeIntervalSince1970: 1_742_594_460)
                )
            ],
            audioArtifacts: .empty
        )
    ]
}
