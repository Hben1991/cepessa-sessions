import SwiftUI

struct SessionDetailView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            if let session = model.selectedSession {
                sessionDetail(session)
            } else {
                emptyState
            }

            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Session Detail")
                .font(.system(size: 20, weight: .semibold))

            Text("Transcript-first detail pane.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }

    private func sessionDetail(_ session: MeetingSession) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(session.title)
                    .font(.system(size: 24, weight: .bold))

                Text(session.startedAt.formatted(date: .complete, time: .shortened))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)

                Text(statusLabel(for: session.status))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(statusColor(for: session.status))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(statusColor(for: session.status).opacity(0.14), in: Capsule())
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Transcript")
                    .font(.system(size: 13, weight: .semibold))

                if session.status == .transcribing {
                    Text("Transcribing locally. The transcript will appear here when processing finishes.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                } else if session.status == .failed {
                    Text("Transcription failed. The raw meeting audio is still available in the saved session folder.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                } else if session.segments.isEmpty {
                    Text("No transcript segments yet.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(session.segments) { segment in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(segment.speaker)
                                .font(.system(size: 12, weight: .semibold))
                            Text(segment.text)
                                .font(.system(size: 13))
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color.secondary.opacity(0.08))
                        )
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func statusLabel(for status: MeetingSessionStatus) -> String {
        switch status {
        case .recording:
            return "Recording"
        case .transcribing:
            return "Transcribing"
        case .ready:
            return "Ready"
        case .failed:
            return "Failed"
        }
    }

    private func statusColor(for status: MeetingSessionStatus) -> Color {
        switch status {
        case .recording:
            return .red
        case .transcribing:
            return .orange
        case .ready:
            return .green
        case .failed:
            return .secondary
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Nothing selected")
                .font(.system(size: 16, weight: .semibold))

            Text("Pick a session from the library to see its transcript.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
