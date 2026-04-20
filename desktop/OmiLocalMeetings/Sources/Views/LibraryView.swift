import SwiftUI

struct LibraryView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            if model.sessions.isEmpty {
                emptyState
            } else {
                sessionList
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Library")
                .font(.system(size: 20, weight: .semibold))

            Text("Local meetings stay on this Mac.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("No sessions yet")
                .font(.system(size: 14, weight: .semibold))

            Text("Record a meeting to populate the library.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var sessionList: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(model.sessions) { session in
                    Button {
                        model.selectSession(id: session.id)
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(session.title)
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(.primary)

                                Text(session.startedAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            }

                            Spacer(minLength: 0)

                            Text(statusLabel(for: session.status))
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(statusColor(for: session.status))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(statusColor(for: session.status).opacity(0.14), in: Capsule())
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(model.selectedSessionID == session.id ? Color.primary.opacity(0.08) : Color.secondary.opacity(0.08))
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
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
}
