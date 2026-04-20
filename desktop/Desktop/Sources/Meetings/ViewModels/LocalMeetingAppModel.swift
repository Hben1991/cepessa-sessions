import Foundation
import SwiftUI
import Combine

@MainActor
final class LocalSessionAppModel: ObservableObject {
    @Published var sessions: [LocalSession] {
        didSet {
            reconcileSelection()
        }
    }
    @Published var selectedSessionID: LocalSession.ID?
    @Published private(set) var isRecording = false
    @Published private(set) var isTranscribing = false
    @Published private(set) var isGeneratingRecap = false
    @Published private(set) var isMicrophoneCaptureActive = false
    @Published private(set) var isSystemAudioCaptureActive = false
    @Published private(set) var micLevel: Double = 0
    @Published private(set) var systemLevel: Double = 0
    @Published private(set) var recordingDurationText = LocalMeetingRecordingTimer.shared.formattedDuration
    @Published private(set) var recorderErrorMessage: String?
    @Published private(set) var processingStatusTitle: String?
    @Published private(set) var processingStatusDetail: String?
    @Published private(set) var processingProgress: Double?

    private let fileLayout: LocalSessionFileLayout
    private let store: LocalSessionStore?
    private let recorder: LocalMeetingRecorder
    private let transcriptionService: any LocalSessionTranscribing
    private let recapGenerator: any LocalSessionRecapGenerating
    private let audioImportService: any LocalSessionAudioImporting
    private var activeRecapSessionIDs: Set<LocalSession.ID> = []
    private var cancellables: Set<AnyCancellable> = []

    init(
        sessions: [LocalSession] = [],
        store: LocalSessionStore? = nil,
        fileLayout: LocalSessionFileLayout? = nil,
        transcriptionService: any LocalSessionTranscribing = LocalMeetingTranscriptionService(),
        recapGenerator: any LocalSessionRecapGenerating = LocalSessionRecapGenerator(),
        audioImportService: any LocalSessionAudioImporting = LocalSessionAudioImportService()
    ) {
        let resolvedFileLayout = fileLayout ?? LocalSessionFileLayout(baseDirectory: Self.defaultBaseDirectory)
        let resolvedStore = store ?? LocalSessionStore(fileLayout: resolvedFileLayout)
        self.sessions = sessions
        self.fileLayout = resolvedFileLayout
        self.store = resolvedStore
        self.recorder = LocalMeetingRecorder(fileLayout: resolvedFileLayout)
        self.transcriptionService = transcriptionService
        self.recapGenerator = recapGenerator
        self.audioImportService = audioImportService
        self.selectedSessionID = nil
        bindRecorder()
        loadStoredSessions()
    }

    var selectedSession: LocalSession? {
        guard let selectedSessionID else { return nil }
        return sessions.first { $0.id == selectedSessionID }
    }

    func loadEmptySessions() {
        sessions = []
        selectedSessionID = nil
    }

    func loadSampleSessions() {
        sessions = LocalSession.sampleSessions.sorted { $0.startedAt > $1.startedAt }
        selectedSessionID = sessions.first?.id
    }

    func loadStoredSessions() {
        guard let store else { return }

        let storedSessions = store.loadSessions()
        let normalizedSessions = storedSessions.map(normalizedStoredSession(_:))
        sessions = normalizedSessions

        for (storedSession, normalizedSession) in zip(storedSessions, normalizedSessions)
        where storedSession != normalizedSession {
            do {
                try store.save(normalizedSession)
            } catch {
                recorderErrorMessage = "Failed to recover an interrupted session. \(error.localizedDescription)"
            }
        }

        if selectedSessionID == nil {
            selectedSessionID = sessions.first?.id
        }
    }

    @discardableResult
    func upsertSession(_ session: LocalSession) -> LocalSession {
        let mergedSession = mergedSession(from: session)

        if let existingIndex = sessions.firstIndex(where: { $0.id == mergedSession.id }) {
            sessions[existingIndex] = mergedSession
        } else {
            sessions.append(mergedSession)
        }

        sessions.sort { $0.startedAt > $1.startedAt }

        do {
            try store?.save(mergedSession)
        } catch {
            recorderErrorMessage = "Failed to save this session locally. \(error.localizedDescription)"
        }

        return mergedSession
    }

    func selectSession(id: LocalSession.ID) {
        guard sessions.contains(where: { $0.id == id }) else {
            selectedSessionID = nil
            return
        }

        selectedSessionID = id
    }

    func clearSelection() {
        selectedSessionID = nil
    }

    var isProcessingSession: Bool {
        isTranscribing || isGeneratingRecap
    }

    func isGeneratingRecap(for sessionID: LocalSession.ID) -> Bool {
        activeRecapSessionIDs.contains(sessionID)
    }

    private func reconcileSelection() {
        guard let currentSelectionID = selectedSessionID else { return }
        if !sessions.contains(where: { $0.id == currentSelectionID }) {
            selectedSessionID = nil
        }
    }

    private func normalizedStoredSession(_ session: LocalSession) -> LocalSession {
        var normalizedSession = session

        switch normalizedSession.status {
        case .recording, .transcribing:
            normalizedSession.status = .failed
        case .ready, .failed:
            break
        }

        return normalizedSession
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
            recorderErrorMessage = recorder.lastErrorMessage
            upsertSession(session)
            selectedSessionID = session.id
        } catch {
            recorderErrorMessage = error.localizedDescription
        }
    }

    private func stopRecording() async {
        if let session = await recorder.stopRecording() {
            let mergedSession = upsertSession(session)
            selectedSessionID = mergedSession.id
            await transcribe(mergedSession)
        }
    }

    func importExistingRecording(from sourceURL: URL, title: String? = nil) async {
        let sessionID = UUID()
        let startedAt = importedRecordingDate(for: sourceURL)
        let resolvedTitle = normalizedImportedTitle(title, sourceURL: sourceURL)
        var session = LocalSession(
            id: sessionID,
            title: resolvedTitle,
            startedAt: startedAt,
            status: .transcribing,
            transcriptSegments: [],
            audioArtifacts: .init(
                micFileName: nil,
                systemFileName: nil,
                mixedFileName: "mixed.wav"
            )
        )

        session = upsertSession(session)
        selectedSessionID = session.id

        let destinationURL = fileLayout.mixedAudioURL(for: session.id)

        do {
            setProcessingState(
                title: "Importing audio",
                detail: "Normalizing the selected recording into the local transcript pipeline.",
                progress: 0.02
            )
            try fileLayout.ensureDirectories(for: session.id)
            try await audioImportService.importAudio(from: sourceURL, to: destinationURL)
            recorderErrorMessage = nil
            await transcribe(session, audioURL: destinationURL)
        } catch {
            recorderErrorMessage = error.localizedDescription
            _ = mutateSession(id: session.id) { currentSession in
                currentSession.status = .failed
            }
            if isGeneratingRecap {
                setRecapProcessingState()
            } else {
                clearProcessingState()
            }
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

        recorder.$isMicrophoneCaptureActive
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.isMicrophoneCaptureActive = $0 }
            .store(in: &cancellables)

        recorder.$isSystemAudioCaptureActive
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.isSystemAudioCaptureActive = $0 }
            .store(in: &cancellables)

        recorder.$systemLevel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.systemLevel = $0 }
            .store(in: &cancellables)

        recorder.$lastErrorMessage
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.recorderErrorMessage = $0 }
            .store(in: &cancellables)

        LocalMeetingRecordingTimer.shared.$duration
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.recordingDurationText = LocalMeetingRecordingTimer.shared.formattedDuration
            }
            .store(in: &cancellables)
    }

    private func transcribe(_ session: LocalSession, audioURL: URL? = nil) async {
        var updatedSession = session
        isTranscribing = true
        setProcessingState(
            title: "Preparing audio",
            detail: "Reading the local mixed master for transcription.",
            progress: 0.03
        )

        let mixedAudioURL = audioURL ?? fileLayout.mixedAudioURL(for: session.id)
        let modelURL = fileLayout.resolvedHebrewModelURL()

        do {
            let result = try await transcriptionService.transcribe(
                wavURL: mixedAudioURL,
                modelURL: modelURL,
                language: "he",
                prompt: nil,
                translateToEnglish: false,
                onProgress: { [weak self] update in
                    guard let self else { return }
                    await self.applyTranscriptionProgress(update)
                }
            )

            updatedSession.status = .ready
            updatedSession.transcriptSegments = transcriptSegments(from: result, session: session)
            let transcriptReadySession = upsertSession(updatedSession)
            isTranscribing = false
            beginRecapGeneration(for: transcriptReadySession)
            return
        } catch {
            updatedSession.status = .failed
            upsertSession(updatedSession)
            recorderErrorMessage = error.localizedDescription
        }

        isTranscribing = false
        if !isGeneratingRecap {
            clearProcessingState()
        }
    }

    private func applyTranscriptionProgress(_ update: LocalSessionTranscriptionProgress) {
        switch update.stage {
        case .decodingAudio:
            setProcessingState(
                title: "Preparing audio",
                detail: "Decoding the local WAV file before transcription starts.",
                progress: 0.05
            )
        case .loadingModel:
            setProcessingState(
                title: "Loading model",
                detail: "Warming up the on-device Hebrew model in memory.",
                progress: 0.12
            )
        case .transcribing(let percent):
            let normalizedProgress = 0.12 + (Double(percent) / 100.0 * 0.72)
            setProcessingState(
                title: "Transcribing \(percent)%",
                detail: "Running accurate on-device speech recognition. This is the slow part.",
                progress: normalizedProgress
            )
        case .extractingSegments:
            setProcessingState(
                title: "Finalizing transcript",
                detail: "Turning decoded speech into timestamped transcript segments.",
                progress: 0.86
            )
        }
    }

    private func setProcessingState(title: String, detail: String, progress: Double?) {
        processingStatusTitle = title
        processingStatusDetail = detail
        processingProgress = progress.map { max(0, min($0, 1)) }
    }

    private func clearProcessingState() {
        processingStatusTitle = nil
        processingStatusDetail = nil
        processingProgress = nil
    }

    private func beginRecapGeneration(for session: LocalSession) {
        activeRecapSessionIDs.insert(session.id)
        isGeneratingRecap = !activeRecapSessionIDs.isEmpty
        setRecapProcessingState()

        Task { [weak self] in
            guard let self else { return }
            let recap = await self.recapGenerator.generateRecap(for: session)
            _ = self.mutateSession(id: session.id) { currentSession in
                currentSession.status = .ready
                currentSession.recap = recap
            }
            self.finishRecapGeneration(for: session.id)
        }
    }

    private func finishRecapGeneration(for sessionID: LocalSession.ID) {
        activeRecapSessionIDs.remove(sessionID)
        isGeneratingRecap = !activeRecapSessionIDs.isEmpty

        if isGeneratingRecap {
            setRecapProcessingState()
        } else if !isTranscribing {
            clearProcessingState()
        }
    }

    private func setRecapProcessingState() {
        let title = activeRecapSessionIDs.count > 1 ? "Generating recaps" : "Generating recap"
        let detail = "Running the local recap model over the transcript and captured context."
        setProcessingState(title: title, detail: detail, progress: nil)
    }

    private func transcriptSegments(
        from result: LocalMeetingTranscriptionResult,
        session: LocalSession
    ) -> [LocalSessionTranscriptSegment] {
        if !result.segments.isEmpty {
            return result.segments.map { segment in
                LocalSessionTranscriptSegment(
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
            LocalSessionTranscriptSegment(
                id: UUID(),
                speaker: "Transcript",
                text: transcriptText,
                timestamp: session.startedAt
            )
        ]
    }

    private static var defaultBaseDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Cepessa", isDirectory: true)
    }

    private func normalizedImportedTitle(_ title: String?, sourceURL: URL) -> String {
        if let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            return title
        }

        return sourceURL.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "_", with: " ")
    }

    private func importedRecordingDate(for sourceURL: URL) -> Date {
        let values = try? sourceURL.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey])
        return values?.contentModificationDate ?? values?.creationDate ?? Date()
    }

    @discardableResult
    func addAttachment(
        _ attachment: LocalSessionAttachment,
        to sessionID: LocalSession.ID? = nil
    ) -> LocalSessionAttachment? {
        guard mutateSession(id: sessionID, { session in
            session.addAttachment(attachment)
        }) != nil else {
            return nil
        }

        return attachment
    }

    @discardableResult
    func addScreenshotAttachment(
        to sessionID: LocalSession.ID? = nil,
        title: String,
        timestamp: Date = Date(),
        sessionOffset: TimeInterval? = nil,
        fileName: String? = nil,
        mimeType: String = "image/png",
        urlString: String? = nil,
        note: String? = nil
    ) -> LocalSessionAttachment? {
        let attachment = LocalSessionAttachment(
            id: UUID(),
            kind: .image,
            source: .manual,
            title: title,
            timestamp: timestamp,
            sessionOffset: sessionOffset,
            fileName: fileName,
            mimeType: mimeType,
            urlString: urlString,
            note: note
        )

        return addAttachment(attachment, to: sessionID)
    }

    @discardableResult
    func addDocumentAttachment(
        to sessionID: LocalSession.ID? = nil,
        title: String,
        timestamp: Date = Date(),
        sessionOffset: TimeInterval? = nil,
        fileName: String? = nil,
        mimeType: String = "application/pdf",
        urlString: String? = nil,
        note: String? = nil
    ) -> LocalSessionAttachment? {
        let attachment = LocalSessionAttachment(
            id: UUID(),
            kind: .file,
            source: .manual,
            title: title,
            timestamp: timestamp,
            sessionOffset: sessionOffset,
            fileName: fileName,
            mimeType: mimeType,
            urlString: urlString,
            note: note
        )

        return addAttachment(attachment, to: sessionID)
    }

    @discardableResult
    func addCaptureArtifact(
        to sessionID: LocalSession.ID? = nil,
        title: String,
        capturedAt: Date = Date(),
        sessionOffset: TimeInterval? = nil,
        attachmentIDs: [UUID] = [],
        notes: String? = nil
    ) -> LocalSessionCaptureArtifact? {
        let captureArtifact = LocalSessionCaptureArtifact(
            id: UUID(),
            kind: .floatingBarCapture,
            title: title,
            capturedAt: capturedAt,
            sessionOffset: sessionOffset,
            attachmentIDs: attachmentIDs,
            notes: notes
        )

        guard mutateSession(id: sessionID, { session in
            session.captureArtifacts.append(captureArtifact)
        }) != nil else {
            return nil
        }

        return captureArtifact
    }

    func updateAttachmentAnchor(
        attachmentID: UUID,
        in sessionID: LocalSession.ID? = nil,
        timestamp: Date,
        sessionOffset: TimeInterval?
    ) -> Bool {
        let resolvedSessionID = sessionID ?? selectedSessionID
        guard let resolvedSessionID,
              let index = sessions.firstIndex(where: { $0.id == resolvedSessionID }) else {
            return false
        }

        var session = sessions[index]
        guard let attachmentIndex = session.attachments.firstIndex(where: { $0.id == attachmentID }) else {
            return false
        }

        session.attachments[attachmentIndex].timestamp = timestamp
        session.attachments[attachmentIndex].sessionOffset = sessionOffset
        upsertSession(session)
        return true
    }

    @discardableResult
    private func mutateSession(
        id sessionID: LocalSession.ID? = nil,
        _ mutate: (inout LocalSession) -> Void
    ) -> LocalSession? {
        let resolvedSessionID = sessionID ?? selectedSessionID
        guard let resolvedSessionID,
              let index = sessions.firstIndex(where: { $0.id == resolvedSessionID }) else {
            return nil
        }

        var session = sessions[index]
        mutate(&session)
        upsertSession(session)
        return session
    }

    func sessionFolderURL(for sessionID: LocalSession.ID? = nil) -> URL? {
        let resolvedSessionID = sessionID ?? selectedSessionID
        guard let resolvedSessionID else { return nil }
        return fileLayout.sessionDirectory(for: resolvedSessionID)
    }

    func promptPackageMarkdownURL(for sessionID: LocalSession.ID? = nil) -> URL? {
        let resolvedSessionID = sessionID ?? selectedSessionID
        guard let resolvedSessionID else { return nil }
        return fileLayout.promptPackageMarkdownURL(for: resolvedSessionID)
    }

    func promptPackageJSONURL(for sessionID: LocalSession.ID? = nil) -> URL? {
        let resolvedSessionID = sessionID ?? selectedSessionID
        guard let resolvedSessionID else { return nil }
        return fileLayout.promptPackageJSONURL(for: resolvedSessionID)
    }

    private func mergedSession(from incomingSession: LocalSession) -> LocalSession {
        guard let existingSession = sessions.first(where: { $0.id == incomingSession.id }) else {
            return incomingSession
        }

        var mergedSession = incomingSession
        mergedSession.title = incomingSession.title.isEmpty ? existingSession.title : incomingSession.title
        mergedSession.transcriptSegments = incomingSession.transcriptSegments.isEmpty
            ? existingSession.transcriptSegments
            : incomingSession.transcriptSegments
        mergedSession.recap = incomingSession.recap == .empty ? existingSession.recap : incomingSession.recap
        mergedSession.attachments = mergeAttachments(existingSession.attachments, incomingSession.attachments)
        mergedSession.captureArtifacts = mergeCaptureArtifacts(
            existingSession.captureArtifacts,
            incomingSession.captureArtifacts
        )
        mergedSession.audioArtifacts = LocalSessionAudioArtifacts(
            micFileName: incomingSession.audioArtifacts.micFileName ?? existingSession.audioArtifacts.micFileName,
            systemFileName: incomingSession.audioArtifacts.systemFileName ?? existingSession.audioArtifacts.systemFileName,
            mixedFileName: incomingSession.audioArtifacts.mixedFileName ?? existingSession.audioArtifacts.mixedFileName
        )

        return mergedSession
    }

    private func mergeAttachments(
        _ existing: [LocalSessionAttachment],
        _ incoming: [LocalSessionAttachment]
    ) -> [LocalSessionAttachment] {
        guard !existing.isEmpty else { return incoming }
        guard !incoming.isEmpty else { return existing }

        var attachmentsByID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
        for attachment in incoming {
            attachmentsByID[attachment.id] = attachment
        }

        return existing.compactMap { attachmentsByID[$0.id] } + incoming.filter { attachment in
            !existing.contains(where: { $0.id == attachment.id })
        }
    }

    private func mergeCaptureArtifacts(
        _ existing: [LocalSessionCaptureArtifact],
        _ incoming: [LocalSessionCaptureArtifact]
    ) -> [LocalSessionCaptureArtifact] {
        guard !existing.isEmpty else { return incoming }
        guard !incoming.isEmpty else { return existing }

        var artifactsByID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
        for artifact in incoming {
            artifactsByID[artifact.id] = artifact
        }

        return existing.compactMap { artifactsByID[$0.id] } + incoming.filter { artifact in
            !existing.contains(where: { $0.id == artifact.id })
        }
    }
}

typealias LocalMeetingAppModel = LocalSessionAppModel
