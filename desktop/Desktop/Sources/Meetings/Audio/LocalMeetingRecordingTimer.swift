import Foundation

@MainActor
final class LocalMeetingRecordingTimer: ObservableObject {
    static let shared = LocalMeetingRecordingTimer()

    @Published private(set) var duration: TimeInterval = 0

    private var timer: Timer?
    private var startTime: Date?

    private init() {}

    func start() {
        startTime = Date()
        duration = 0

        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self, let start = self.startTime else { return }
                self.duration = Date().timeIntervalSince(start)
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        startTime = nil
    }

    func reset() {
        stop()
        duration = 0
    }

    func restart() {
        stop()
        start()
    }

    var formattedDuration: String {
        let total = Int(duration)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }
}
