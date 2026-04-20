import Foundation
import Combine

@MainActor
final class MeetingRecorder: ObservableObject {
    enum RecorderError: LocalizedError {
        case microphonePermissionDenied
        case systemAudioUnsupported
        case setupFailed(String)

        var errorDescription: String? {
            switch self {
            case .microphonePermissionDenied:
                return "Microphone permission is required to record meetings."
            case .systemAudioUnsupported:
                return "System audio capture requires macOS 14.4 or later."
            case .setupFailed(let message):
                return message
            }
        }
    }

    @Published private(set) var isRecording = false
    @Published private(set) var micLevel: Double = 0
    @Published private(set) var systemLevel: Double = 0
    @Published private(set) var lastErrorMessage: String?

    private let fileLayout: FileLayout
    private let timer = RecordingTimer.shared
    private let ioQueue = DispatchQueue(label: "me.omi.localmeetings.recorder")

    private var micCaptureService: AudioCaptureService?
    private var systemCaptureService: AnyObject?
    nonisolated(unsafe) private var micWriter: WaveFileWriter?
    nonisolated(unsafe) private var systemWriter: WaveFileWriter?
    nonisolated(unsafe) private var mixedWriter: WaveFileWriter?
    nonisolated(unsafe) private var pendingMicPCM = Data()
    nonisolated(unsafe) private var pendingSystemPCM = Data()
    private var currentSession: MeetingSession?

    init(fileLayout: FileLayout) {
        self.fileLayout = fileLayout
    }

    var formattedDuration: String {
        timer.formattedDuration
    }

    func startRecording(title: String? = nil) async throws -> MeetingSession {
        guard !isRecording else {
            throw RecorderError.setupFailed("A recording is already in progress.")
        }

        let hasMicrophonePermission = AudioCaptureService.checkPermission()
        let isMicrophonePermissionGranted = hasMicrophonePermission ? true : await AudioCaptureService.requestPermission()
        guard isMicrophonePermissionGranted else {
            throw RecorderError.microphonePermissionDenied
        }

        guard #available(macOS 14.4, *) else {
            throw RecorderError.systemAudioUnsupported
        }

        let session = MeetingSession(
            id: UUID(),
            title: title ?? Self.defaultSessionTitle(),
            startedAt: Date(),
            status: .recording,
            segments: [],
            audioArtifacts: .init(
                micFileName: "mic.wav",
                systemFileName: "system.wav",
                mixedFileName: "mixed.wav"
            )
        )

        do {
            try fileLayout.ensureDirectories(for: session.id)
            micWriter = try WaveFileWriter(fileURL: fileLayout.micAudioURL(for: session.id))
            systemWriter = try WaveFileWriter(fileURL: fileLayout.systemAudioURL(for: session.id))
            mixedWriter = try WaveFileWriter(fileURL: fileLayout.mixedAudioURL(for: session.id))
        } catch {
            throw RecorderError.setupFailed("Failed to prepare recording files.")
        }

        currentSession = session
        pendingMicPCM = Data()
        pendingSystemPCM = Data()
        lastErrorMessage = nil

        do {
            let preferredMicDeviceID = AudioCaptureService.findBuiltInMicDeviceID()
            let micCapture = preferredMicDeviceID.map(AudioCaptureService.init(overrideDeviceID:)) ?? AudioCaptureService()
            try await micCapture.startCapture(
                onAudioChunk: { [weak self] data in
                    self?.handleMicChunk(data)
                },
                onAudioLevel: { [weak self] level in
                    Task { @MainActor in
                        self?.micLevel = Double(level)
                    }
                }
            )
            self.micCaptureService = micCapture

            let systemCapture = SystemAudioCaptureService()
            try await systemCapture.startCapture(
                onAudioChunk: { [weak self] data in
                    self?.handleSystemChunk(data)
                },
                onAudioLevel: { [weak self] level in
                    Task { @MainActor in
                        self?.systemLevel = Double(level)
                    }
                }
            )
            self.systemCaptureService = systemCapture
        } catch {
            stopCaptureServices()
            closeWriters()
            currentSession = nil
            throw RecorderError.setupFailed(error.localizedDescription)
        }

        isRecording = true
        timer.restart()
        return session
    }

    func stopRecording() async -> MeetingSession? {
        guard var session = currentSession else { return nil }

        stopCaptureServices()
        timer.stop()

        ioQueue.sync {
            flushPendingMixedAudio()
            closeWriters()
            pendingMicPCM = Data()
            pendingSystemPCM = Data()
        }

        session.status = .transcribing
        currentSession = nil
        isRecording = false
        micLevel = 0
        systemLevel = 0
        return session
    }

    private func stopCaptureServices() {
        micCaptureService?.stopCapture()
        micCaptureService = nil

        if #available(macOS 14.4, *) {
            (systemCaptureService as? SystemAudioCaptureService)?.stopCapture()
        }
        systemCaptureService = nil
    }

    nonisolated private func handleMicChunk(_ data: Data) {
        ioQueue.async { [weak self] in
            guard let self else { return }
            do {
                try self.micWriter?.append(pcm16Data: data)
            } catch {
                Task { @MainActor in
                    self.lastErrorMessage = error.localizedDescription
                }
            }
            self.pendingMicPCM.append(data)
            self.drainMixedAudioIfPossible()
        }
    }

    nonisolated private func handleSystemChunk(_ data: Data) {
        ioQueue.async { [weak self] in
            guard let self else { return }
            do {
                try self.systemWriter?.append(pcm16Data: data)
            } catch {
                Task { @MainActor in
                    self.lastErrorMessage = error.localizedDescription
                }
            }
            self.pendingSystemPCM.append(data)
            self.drainMixedAudioIfPossible()
        }
    }

    nonisolated private func drainMixedAudioIfPossible() {
        let bytesToProcess = min(pendingMicPCM.count, pendingSystemPCM.count)
        guard bytesToProcess >= 2 else { return }

        let evenByteCount = (bytesToProcess / 2) * 2
        let micChunk = pendingMicPCM.prefix(evenByteCount)
        let systemChunk = pendingSystemPCM.prefix(evenByteCount)
        pendingMicPCM.removeFirst(evenByteCount)
        pendingSystemPCM.removeFirst(evenByteCount)

        let mixed = AudioMixer.mixMono(micPCM16: Data(micChunk), systemPCM16: Data(systemChunk))
        try? mixedWriter?.append(pcm16Data: mixed)
    }

    nonisolated private func flushPendingMixedAudio() {
        let bytesToProcess = max(pendingMicPCM.count, pendingSystemPCM.count)
        guard bytesToProcess >= 2 else { return }

        let evenByteCount = (bytesToProcess / 2) * 2
        let micChunk = paddedChunk(from: pendingMicPCM, targetByteCount: evenByteCount)
        let systemChunk = paddedChunk(from: pendingSystemPCM, targetByteCount: evenByteCount)
        let mixed = AudioMixer.mixMono(micPCM16: micChunk, systemPCM16: systemChunk)
        try? mixedWriter?.append(pcm16Data: mixed)
    }

    nonisolated private func paddedChunk(from data: Data, targetByteCount: Int) -> Data {
        if data.count >= targetByteCount {
            return Data(data.prefix(targetByteCount))
        }

        return data + Data(repeating: 0, count: targetByteCount - data.count)
    }

    nonisolated private func closeWriters() {
        try? micWriter?.close()
        try? systemWriter?.close()
        try? mixedWriter?.close()
        micWriter = nil
        systemWriter = nil
        mixedWriter = nil
    }

    private static func defaultSessionTitle() -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return "Meeting \(formatter.string(from: Date()))"
    }
}
