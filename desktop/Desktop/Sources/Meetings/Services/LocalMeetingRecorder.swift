import Foundation
import Combine
import CoreAudio

enum LocalMeetingMicrophoneRoute: Equatable {
    case systemDefault
    case builtIn(AudioDeviceID)

    static func initialRoute() -> Self {
        .systemDefault
    }

    static func fallbackRoute(
        builtInMicID: AudioDeviceID?,
        hasAlreadyFallenBack: Bool
    ) -> Self? {
        guard !hasAlreadyFallenBack, let builtInMicID else { return nil }
        return .builtIn(builtInMicID)
    }

    var overrideDeviceID: AudioDeviceID? {
        switch self {
        case .systemDefault:
            return nil
        case .builtIn(let deviceID):
            return deviceID
        }
    }
}

@MainActor
final class LocalMeetingRecorder: ObservableObject {
    private enum MixMode {
        case synchronizedSources
        case microphoneOnly
    }

    enum RecorderError: LocalizedError {
        case microphonePermissionDenied
        case systemAudioUnsupported
        case setupFailed(String)

        var errorDescription: String? {
            switch self {
            case .microphonePermissionDenied:
                return "Microphone permission is required to record sessions."
            case .systemAudioUnsupported:
                return "System audio capture requires macOS 14.4 or later."
            case .setupFailed(let message):
                return message
            }
        }
    }

    @Published private(set) var isRecording = false
    @Published private(set) var isMicrophoneCaptureActive = false
    @Published private(set) var isSystemAudioCaptureActive = false
    @Published private(set) var micLevel: Double = 0
    @Published private(set) var systemLevel: Double = 0
    @Published private(set) var lastErrorMessage: String?

    private let fileLayout: LocalSessionFileLayout
    private let timer = LocalMeetingRecordingTimer.shared
    private let ioQueue = DispatchQueue(label: "me.cepessa.localsessions.recorder")

    private var micCaptureService: LocalMeetingAudioCaptureService?
    private var systemCaptureService: AnyObject?
    nonisolated(unsafe) private var micWriter: LocalMeetingWaveFileWriter?
    nonisolated(unsafe) private var systemWriter: LocalMeetingWaveFileWriter?
    nonisolated(unsafe) private var mixedWriter: LocalMeetingWaveFileWriter?
    nonisolated(unsafe) private var pendingMicPCM = Data()
    nonisolated(unsafe) private var pendingSystemPCM = Data()
    nonisolated(unsafe) private var mixMode: MixMode = .synchronizedSources
    private var currentSession: LocalSession?
    private var hasPerformedSilentMicFallback = false

    init(fileLayout: LocalSessionFileLayout) {
        self.fileLayout = fileLayout
    }

    var formattedDuration: String {
        timer.formattedDuration
    }

    func startRecording(title: String? = nil) async throws -> LocalSession {
        guard !isRecording else {
            throw RecorderError.setupFailed("A recording is already in progress.")
        }

        let hasMicrophonePermission = LocalMeetingAudioCaptureService.checkPermission()
        let isMicrophonePermissionGranted = hasMicrophonePermission ? true : await LocalMeetingAudioCaptureService.requestPermission()
        guard isMicrophonePermissionGranted else {
            throw RecorderError.microphonePermissionDenied
        }

        let session = LocalSession(
            id: UUID(),
            title: title ?? Self.defaultSessionTitle(),
            startedAt: Date(),
            status: .recording,
            transcriptSegments: [],
            recap: .empty,
            attachments: [],
            captureArtifacts: [],
            audioArtifacts: .init(
                micFileName: "mic.wav",
                systemFileName: "system.wav",
                mixedFileName: "mixed.wav"
            )
        )

        do {
            try fileLayout.ensureDirectories(for: session.id)
            micWriter = try LocalMeetingWaveFileWriter(fileURL: fileLayout.micAudioURL(for: session.id))
            systemWriter = try LocalMeetingWaveFileWriter(fileURL: fileLayout.systemAudioURL(for: session.id))
            mixedWriter = try LocalMeetingWaveFileWriter(fileURL: fileLayout.mixedAudioURL(for: session.id))
        } catch {
            throw RecorderError.setupFailed("Failed to prepare recording files.")
        }

        currentSession = session
        pendingMicPCM = Data()
        pendingSystemPCM = Data()
        mixMode = .synchronizedSources
        hasPerformedSilentMicFallback = false
        lastErrorMessage = nil

        do {
            try await startMicrophoneCapture(route: .initialRoute())

            if #available(macOS 14.4, *) {
                let systemCapture = LocalMeetingSystemAudioCaptureService()
                do {
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
                    self.isSystemAudioCaptureActive = true
                } catch {
                    systemCaptureService = nil
                    switchToMicrophoneOnlyMode(
                        warningMessage: "System audio unavailable; recording microphone only. \(error.localizedDescription)"
                    )
                }
            } else {
                systemCaptureService = nil
                switchToMicrophoneOnlyMode(
                    warningMessage: "System audio unavailable on this macOS version; recording microphone only."
                )
            }
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

    private func startMicrophoneCapture(route: LocalMeetingMicrophoneRoute) async throws {
        let micCapture: LocalMeetingAudioCaptureService
        if let overrideDeviceID = route.overrideDeviceID {
            micCapture = LocalMeetingAudioCaptureService(overrideDeviceID: overrideDeviceID)
        } else {
            micCapture = LocalMeetingAudioCaptureService()
        }

        micCapture.onSilentMicDetected = { [weak self] in
            Task { @MainActor in
                await self?.handleSilentMicFallback()
            }
        }

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
        self.isMicrophoneCaptureActive = true
    }

    private func handleSilentMicFallback() async {
        guard currentSession != nil else { return }

        guard let route = LocalMeetingMicrophoneRoute.fallbackRoute(
            builtInMicID: LocalMeetingAudioCaptureService.findBuiltInMicDeviceID(),
            hasAlreadyFallenBack: hasPerformedSilentMicFallback
        ) else {
            return
        }

        hasPerformedSilentMicFallback = true
        micCaptureService?.stopCapture()
        micCaptureService = nil

        do {
            try await startMicrophoneCapture(route: route)
            lastErrorMessage =
              "The selected microphone returned silence, so Sessions switched to the Mac microphone."
        } catch {
            isMicrophoneCaptureActive = false
            lastErrorMessage =
              "Sessions could not recover microphone capture automatically. \(error.localizedDescription)"
        }
    }

    func stopRecording() async -> LocalSession? {
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
        hasPerformedSilentMicFallback = false
        isRecording = false
        isMicrophoneCaptureActive = false
        isSystemAudioCaptureActive = false
        micLevel = 0
        systemLevel = 0
        return session
    }

    private func stopCaptureServices() {
        micCaptureService?.stopCapture()
        micCaptureService = nil
        isMicrophoneCaptureActive = false

        if #available(macOS 14.4, *) {
            (systemCaptureService as? LocalMeetingSystemAudioCaptureService)?.stopCapture()
        }
        systemCaptureService = nil
        isSystemAudioCaptureActive = false
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
            switch self.mixMode {
            case .microphoneOnly:
                try? self.mixedWriter?.append(pcm16Data: data)
            case .synchronizedSources:
                self.pendingMicPCM.append(data)
                self.drainMixedAudioIfPossible()
            }
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
            guard self.mixMode == .synchronizedSources else { return }
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

        let mixed = LocalMeetingAudioMixer.mixMono(micPCM16: Data(micChunk), systemPCM16: Data(systemChunk))
        try? mixedWriter?.append(pcm16Data: mixed)
    }

    nonisolated private func flushPendingMixedAudio() {
        guard mixMode == .synchronizedSources else {
            pendingMicPCM = Data()
            pendingSystemPCM = Data()
            return
        }

        let bytesToProcess = max(pendingMicPCM.count, pendingSystemPCM.count)
        guard bytesToProcess >= 2 else { return }

        let evenByteCount = (bytesToProcess / 2) * 2
        let micChunk = paddedChunk(from: pendingMicPCM, targetByteCount: evenByteCount)
        let systemChunk = paddedChunk(from: pendingSystemPCM, targetByteCount: evenByteCount)
        let mixed = LocalMeetingAudioMixer.mixMono(micPCM16: micChunk, systemPCM16: systemChunk)
        try? mixedWriter?.append(pcm16Data: mixed)
    }

    nonisolated private func paddedChunk(from data: Data, targetByteCount: Int) -> Data {
        if data.count >= targetByteCount {
            return Data(data.prefix(targetByteCount))
        }

        return data + Data(repeating: 0, count: targetByteCount - data.count)
    }

    private func switchToMicrophoneOnlyMode(warningMessage: String) {
        ioQueue.sync {
            if mixMode == .microphoneOnly { return }

            if !pendingMicPCM.isEmpty {
                try? mixedWriter?.append(pcm16Data: pendingMicPCM)
            }

            pendingMicPCM = Data()
            pendingSystemPCM = Data()
            mixMode = .microphoneOnly
        }

        systemLevel = 0
        isSystemAudioCaptureActive = false
        lastErrorMessage = warningMessage
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
        return "Session \(formatter.string(from: Date()))"
    }
}
