import Foundation

enum RewindMode: String, CaseIterable, Identifiable {
    case screenHistory = "screenHistory"
    case meetings = "meetings"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .screenHistory:
            return "Screen History"
        case .meetings:
            return "Meetings"
        }
    }

    var subtitle: String {
        switch self {
        case .screenHistory:
            return "Browse captured screens"
        case .meetings:
            return "Meetings workspace"
        }
    }

    var symbol: String {
        switch self {
        case .screenHistory:
            return "clock.arrow.circlepath"
        case .meetings:
            return "person.2.wave.2"
        }
    }
}
