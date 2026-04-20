import SwiftUI

struct RecorderView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            recorderCard
            levelCard
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Recorder")
                .font(.system(size: 20, weight: .semibold))

            Text("Minimal local capture shell.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }

    private var recorderCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Circle()
                    .fill(statusColor.opacity(0.85))
                    .frame(width: 12, height: 12)

                Text(statusTitle)
                    .font(.system(size: 14, weight: .semibold))
            }

            Text(statusDescription)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            if model.isTranscribing {
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Processing the recording on-device")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.primary)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.orange.opacity(0.12))
                )
            } else {
                Button(model.isRecording ? "Stop recording" : "Start recording") {
                    model.toggleRecording()
                }
                .buttonStyle(.borderedProminent)
                .tint(model.isRecording ? .red : .black)
            }

            if let recorderErrorMessage = model.recorderErrorMessage {
                Text(recorderErrorMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var statusTitle: String {
        if model.isRecording {
            return "Recording now"
        }

        if model.isTranscribing {
            return "Transcribing locally"
        }

        return "Ready to record"
    }

    private var statusDescription: String {
        if model.isRecording {
            return model.recordingDurationText
        }

        if model.isTranscribing {
            return "The meeting audio has been saved. Hebrew transcription is running on this Mac now."
        }

        return "Microphone and system audio will be captured locally."
    }

    private var statusColor: Color {
        if model.isRecording {
            return .red
        }

        if model.isTranscribing {
            return .orange
        }

        return .gray
    }

    private var levelCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            levelRow(label: "Mic", value: model.micLevel)
            levelRow(label: "System", value: model.systemLevel)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func levelRow(label: String, value: Double) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label)
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                Text("\(Int(value * 100))%")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 999)
                        .fill(Color.secondary.opacity(0.15))
                    RoundedRectangle(cornerRadius: 999)
                        .fill(Color.primary.opacity(0.75))
                        .frame(width: max(8, proxy.size.width * value))
                }
            }
            .frame(height: 10)
        }
    }
}
