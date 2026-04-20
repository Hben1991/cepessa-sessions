import Foundation
import SwiftUI
import Combine

@MainActor
final class AppModel: ObservableObject {
    @Published var sessions: [MeetingSession] {
        didSet {
            reconcileSelection()
        }
    }
    @Published var selectedSessionID: MeetingSession.ID?
    @Published private(set) var isRecording = false
    @Published private(set) var isTranscribing = false
    @Published private(set) var micLevel: Double = 0
    @Published private(set) var systemLevel: Double = 0
    @Published private(set) var recordingDurationText = RecordingTimer.shared.formattedDuration
    @Published private(set) var recorderErrorMessage: String?

    private let fileLayout: FileLayout
    private let store: MeetingSessionStore?
    private let recorder: MeetingRecorder
    private let transcriptionService: HebrewTranscriptionService
    private var cancellables: Set<AnyCancellable> = []

    init(
        sessions: [MeetingSession] = [],
        store: MeetingSessionStore? = nil,
        fileLayout: FileLayout? = nil,
        transcriptionService: HebrewTranscriptionService = HebrewTranscriptionService()
    ) {
        let resolvedFileLayout = fileLayout ?? FileLayout(baseDirectory: Self.defaultBaseDirectory)
        let resolvedStore = store ?? MeetingSessionStore(fileLayout: resolvedFileLayout)
        self.sessions = sessions
        self.fileLayout = resolvedFileLayout
        self.store = resolvedStore
        self.recorder = MeetingRecorder(fileLayout: resolvedFileLayout)
        self.transcriptionService = transcriptionService
        self.selectedSessionID = nil
        bindRecorder()
    }

    var selectedSession: MeetingSession? {
        guard let selectedSessionID else { return nil }
        return sessions.first { $0.id == selectedSessionID }
    }

    func loadEmptySessions() {
        sessions = []
        selectedSessionID = nil
    }

    func loadSampleSessions() {
        sessions = MeetingSession.sampleSessions.sorted { $0.startedAt > $1.startedAt }
        selectedSessionID = sessions.first?.id
    }

    func loadStoredSessions() {
        guard let store else { return }

        do {
            sessions = try store.loadSessions()
            if selectedSessionID == nil {
                selectedSessionID = sessions.first?.id
            }
        } catch {
            sessions = []
            selectedSessionID = nil
        }
    }

    func upsertSession(_ session: MeetingSession) {
        if let existingIndex = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[existingIndex] = session
        } else {
            sessions.append(session)
        }

        sessions.sort { $0.startedAt > $1.startedAt }
        try? store?.save(session)
    }

    func selectSession(id: MeetingSession.ID) {
        guard sessions.contains(where: { $0.id == id }) else {
            selectedSessionID = nil
            return
        }

        selectedSessionID = id
    }

    func clearSelection() {
        selectedSessionID = nil
    }

    private func reconcileSelection() {
        guard let currentSelectionID = selectedSessionID else { return }
        if !sessions.contains(where: { $0.id == currentSelectionID }) {
            selectedSessionID = nil
        }
    }

    func toggleRecording() {
        if isRecording {
            Task { await stopRecording() }
        } else {
            Task { await startRecording() }
        }
    }

    private func startRecording() async {
        do {
            let session = try await recorder.startRecording()
            recorderErrorMessage = nil
            upsertSession(session)
            selectedSessionID = session.id
        } catch {
            recorderErrorMessage = error.localizedDescription
        }
    }

    private func stopRecording() async {
        if let session = await recorder.stopRecording() {
            upsertSession(session)
            selectedSessionID = session.id
            await transcribe(session)
        }
    }

    private func bindRecorder() {
        recorder.$isRecording
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.isRecording = $0 }
            .store(in: &cancellables)

        recorder.$micLevel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.micLevel = $0 }
            .store(in: &cancellables)

        recorder.$systemLevel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.systemLevel = $0 }
            .store(in: &cancellables)

        recorder.$lastErrorMessage
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.recorderErrorMessage = $0 }
            .store(in: &cancellables)

        RecordingTimer.shared.$duration
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.recordingDurationText = RecordingTimer.shared.formattedDuration
            }
            .store(in: &cancellables)
    }

    private func transcribe(_ session: MeetingSession) async {
        var updatedSession = session
        isTranscribing = true
        recorderErrorMessage = nil

        let mixedAudioURL = fileLayout.mixedAudioURL(for: session.id)
        let modelURL = fileLayout.resolvedHebrewModelURL()

        do {
            let result = try await transcriptionService.transcribe(
                wavURL: mixedAudioURL,
                modelURL: modelURL,
                language: "he"
            )

            updatedSession.status = .ready
            updatedSession.segments = transcriptSegments(from: result, session: session)
            upsertSession(updatedSession)
        } catch {
            updatedSession.status = .failed
            upsertSession(updatedSession)
            recorderErrorMessage = error.localizedDescription
        }

        isTranscribing = false
    }

    private func transcriptSegments(
        from result: HebrewTranscriptionResult,
        session: MeetingSession
    ) -> [TranscriptSegment] {
        if !result.segments.isEmpty {
            return result.segments.map { segment in
                TranscriptSegment(
                    id: UUID(),
                    speaker: "Transcript",
                    text: segment.text,
                    timestamp: session.startedAt.addingTimeInterval(segment.startTime)
                )
            }
        }

        let transcriptText = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcriptText.isEmpty else {
            return []
        }

        return [
            TranscriptSegment(
                id: UUID(),
                speaker: "Transcript",
                text: transcriptText,
                timestamp: session.startedAt
            )
        ]
    }

    private static var defaultBaseDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OmiLocalMeetings", isDirectory: true)
    }
}
