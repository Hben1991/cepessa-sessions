import Foundation

struct TranscriptSegment: Identifiable, Codable, Equatable {
    let id: UUID
    var speaker: String
    var text: String
    var timestamp: Date
}
