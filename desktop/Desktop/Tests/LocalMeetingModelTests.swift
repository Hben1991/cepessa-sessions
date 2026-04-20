import Foundation
import XCTest
@testable import Omi_Computer

final class LocalMeetingFileLayoutTests: XCTestCase {
    private var tempRootURL: URL!
    private let fileManager = FileManager.default

    override func setUpWithError() throws {
        tempRootURL = fileManager.temporaryDirectory
            .appendingPathComponent("LocalMeetingModelTests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempRootURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempRootURL {
            try? fileManager.removeItem(at: tempRootURL)
        }
    }

    func testFileLayoutBuildsExpectedPaths() {
        let baseDirectory = tempRootURL.appendingPathComponent("Meetings", isDirectory: true)
        let layout = LocalMeetingFileLayout(baseDirectory: baseDirectory)
        let sessionID = UUID(uuidString: "C7E3E8F0-2E71-4C8F-9B7D-0F1E3F4D5A6B")!

        XCTAssertEqual(layout.sessionsDirectory, baseDirectory.appendingPathComponent("Sessions", isDirectory: true))
        XCTAssertEqual(layout.modelsDirectory, baseDirectory.appendingPathComponent("Models", isDirectory: true))
        XCTAssertEqual(layout.sessionDirectory(for: sessionID), baseDirectory.appendingPathComponent("Sessions", isDirectory: true).appendingPathComponent(sessionID.uuidString, isDirectory: true))
        XCTAssertEqual(layout.metadataURL(for: sessionID), baseDirectory.appendingPathComponent("Sessions", isDirectory: true).appendingPathComponent(sessionID.uuidString, isDirectory: true).appendingPathComponent("session.json", isDirectory: false))
        XCTAssertEqual(layout.micAudioURL(for: sessionID), baseDirectory.appendingPathComponent("Sessions", isDirectory: true).appendingPathComponent(sessionID.uuidString, isDirectory: true).appendingPathComponent("mic.wav", isDirectory: false))
        XCTAssertEqual(layout.systemAudioURL(for: sessionID), baseDirectory.appendingPathComponent("Sessions", isDirectory: true).appendingPathComponent(sessionID.uuidString, isDirectory: true).appendingPathComponent("system.wav", isDirectory: false))
        XCTAssertEqual(layout.mixedAudioURL(for: sessionID), baseDirectory.appendingPathComponent("Sessions", isDirectory: true).appendingPathComponent(sessionID.uuidString, isDirectory: true).appendingPathComponent("mixed.wav", isDirectory: false))
    }

    func testEnsureDirectoriesCreatesSessionAndModelFolders() throws {
        let baseDirectory = tempRootURL.appendingPathComponent("Meetings", isDirectory: true)
        let layout = LocalMeetingFileLayout(baseDirectory: baseDirectory)
        let sessionID = UUID(uuidString: "7AA34D4F-8A9F-4E5F-9D49-4D1D05F8646A")!

        try layout.ensureDirectories(fileManager: fileManager, for: sessionID)

        XCTAssertTrue(fileManager.fileExists(atPath: layout.sessionsDirectory.path))
        XCTAssertTrue(fileManager.fileExists(atPath: layout.modelsDirectory.path))
        XCTAssertTrue(fileManager.fileExists(atPath: layout.modelDirectory().path))
        XCTAssertTrue(fileManager.fileExists(atPath: layout.sessionDirectory(for: sessionID).path))
    }

    func testResolvedHebrewModelURLDefaultsToInstalledModelLocation() {
        let baseDirectory = tempRootURL.appendingPathComponent("Meetings", isDirectory: true)
        let layout = LocalMeetingFileLayout(baseDirectory: baseDirectory)

        let resolved = layout.resolvedHebrewModelURL(fileManager: fileManager)
        let developmentModelURL = URL(
            fileURLWithPath: "/Users/ben/Documents/App/General/__MODELS__/ivrit-ai_whisper-large-v3-turbo-ggml/ggml-model.bin"
        )

        XCTAssertTrue(resolved == layout.modelURL() || resolved == developmentModelURL)
    }
}

final class LocalMeetingSessionStoreTests: XCTestCase {
    private var tempRootURL: URL!
    private let fileManager = FileManager.default

    override func setUpWithError() throws {
        tempRootURL = fileManager.temporaryDirectory
            .appendingPathComponent("LocalMeetingSessionStoreTests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempRootURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempRootURL {
            try? fileManager.removeItem(at: tempRootURL)
        }
    }

    func testSaveAndLoadRoundTripPreservesSessionData() throws {
        let layout = LocalMeetingFileLayout(baseDirectory: tempRootURL.appendingPathComponent("Meetings", isDirectory: true))
        let store = LocalMeetingSessionStore(fileLayout: layout)
        let olderSession = makeSession(
            id: UUID(uuidString: "1BDE4D8A-7C44-4C1F-9F73-45A2D6D75D47")!,
            startedAt: Date(timeIntervalSince1970: 100),
            status: .recording,
            title: "Earlier recap",
            segments: [
                .init(id: UUID(uuidString: "F7D3E5BC-771C-4E6E-B0B6-3B2D4D9B2AA1")!, speaker: "Alex", text: "First line", timestamp: Date(timeIntervalSince1970: 110)),
                .init(id: UUID(uuidString: "1A9A0246-6B4A-4E0A-8C37-0B8C7E7A92B2")!, speaker: "Alex", text: "Second line", timestamp: Date(timeIntervalSince1970: 120)),
            ],
            audioArtifacts: .init(micFileName: "mic.wav", systemFileName: "system.wav", mixedFileName: "mixed.wav")
        )
        let newerSession = makeSession(
            id: UUID(uuidString: "B5482A63-B5A6-4F64-8A3B-3BC0F4E0AC48")!,
            startedAt: Date(timeIntervalSince1970: 200),
            status: .transcribing,
            title: "Later recap",
            segments: [],
            audioArtifacts: .empty
        )

        try store.save(olderSession)
        try store.save(newerSession)
        try fileManager.createDirectory(
            at: layout.sessionsDirectory.appendingPathComponent("Stray", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data("ignore me".utf8).write(
            to: layout.sessionsDirectory.appendingPathComponent("notes.txt", isDirectory: false)
        )

        let sessions = store.loadSessions()

        XCTAssertEqual(sessions.map(\.id), [newerSession.id, olderSession.id])
        XCTAssertEqual(sessions.first?.status, .transcribing)
        XCTAssertEqual(sessions.last?.transcriptText, "First line\nSecond line")
        XCTAssertEqual(sessions.last?.audioArtifacts.mixedFileName, "mixed.wav")
        XCTAssertTrue(fileManager.fileExists(atPath: layout.metadataURL(for: olderSession.id).path))
        XCTAssertTrue(fileManager.fileExists(atPath: layout.metadataURL(for: newerSession.id).path))
    }

    func testLoadSessionsSkipsDirectoriesWithoutMetadata() throws {
        let layout = LocalMeetingFileLayout(baseDirectory: tempRootURL.appendingPathComponent("Meetings", isDirectory: true))
        let store = LocalMeetingSessionStore(fileLayout: layout)
        let validSession = makeSession(
            id: UUID(uuidString: "23B0DBB8-1D89-4C7C-87E4-19B8F871B1E6")!,
            startedAt: Date(timeIntervalSince1970: 300),
            status: .ready,
            title: "Valid recap"
        )

        try store.save(validSession)
        try fileManager.createDirectory(
            at: layout.sessionsDirectory.appendingPathComponent("Broken", isDirectory: true),
            withIntermediateDirectories: true
        )

        let sessions = store.loadSessions()

        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?.id, validSession.id)
    }
}

@MainActor
final class LocalMeetingAppModelTests: XCTestCase {
    private var tempRootURL: URL!
    private let fileManager = FileManager.default

    override func setUpWithError() throws {
        tempRootURL = fileManager.temporaryDirectory
            .appendingPathComponent("LocalMeetingAppModelTests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempRootURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempRootURL {
            try? fileManager.removeItem(at: tempRootURL)
        }
    }

    func testDefaultBaseDirectoryPointsAtApplicationSupportMeetings() {
        let model = LocalMeetingAppModel()
        let mirror = Mirror(reflecting: model)

        guard let fileLayout = mirror.descendant("fileLayout") as? LocalMeetingFileLayout else {
            XCTFail("Expected LocalMeetingAppModel to keep its resolved file layout.")
            return
        }

        let expectedBaseDirectory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Cepessa", isDirectory: true)

        XCTAssertEqual(fileLayout.baseDirectory, expectedBaseDirectory)
    }

    func testInitLoadsStoredSessionsNewestFirstAndSelectsTopSession() throws {
        let layout = LocalMeetingFileLayout(baseDirectory: tempRootURL.appendingPathComponent("Meetings", isDirectory: true))
        let store = LocalMeetingSessionStore(fileLayout: layout)
        let olderSession = makeSession(
            id: UUID(uuidString: "B2B8EEAB-2D45-4F7A-9F6D-1F4F4C43B0A2")!,
            startedAt: Date(timeIntervalSince1970: 1000),
            status: .recording,
            title: "Older"
        )
        let newerSession = makeSession(
            id: UUID(uuidString: "2D6291B5-FAF6-4B4E-8A08-DB7E5F3F5A6E")!,
            startedAt: Date(timeIntervalSince1970: 2000),
            status: .ready,
            title: "Newer"
        )

        try store.save(olderSession)
        try store.save(newerSession)

        let model = LocalMeetingAppModel(store: store, fileLayout: layout)

        XCTAssertEqual(model.sessions.map(\.id), [newerSession.id, olderSession.id])
        XCTAssertEqual(model.selectedSessionID, newerSession.id)
        XCTAssertEqual(model.selectedSession?.title, "Newer")
    }

    func testInitNormalizesInterruptedSessionsToFailed() throws {
        let layout = LocalMeetingFileLayout(baseDirectory: tempRootURL.appendingPathComponent("Meetings", isDirectory: true))
        let store = LocalMeetingSessionStore(fileLayout: layout)
        let interruptedRecording = makeSession(
            id: UUID(uuidString: "A22EB5F9-89A0-4A57-B9B6-E08A781F84B0")!,
            startedAt: Date(timeIntervalSince1970: 1_500),
            status: .recording,
            title: "Interrupted recording"
        )
        let interruptedTranscribing = makeSession(
            id: UUID(uuidString: "794EAB53-F0D4-4C9E-B0D4-398EFA7AB4E6")!,
            startedAt: Date(timeIntervalSince1970: 1_600),
            status: .transcribing,
            title: "Interrupted processing"
        )

        try store.save(interruptedRecording)
        try store.save(interruptedTranscribing)

        let model = LocalMeetingAppModel(store: store, fileLayout: layout)

        XCTAssertEqual(model.sessions.map(\.status), [.failed, .failed])

        let persistedStatuses = store.loadSessions().map(\.status)
        XCTAssertEqual(persistedStatuses, [.failed, .failed])
    }

    func testUpsertSessionPersistsStatusTransitionsWithoutDuplicatingRows() throws {
        let layout = LocalMeetingFileLayout(baseDirectory: tempRootURL.appendingPathComponent("Meetings", isDirectory: true))
        let store = LocalMeetingSessionStore(fileLayout: layout)
        let model = LocalMeetingAppModel(store: store, fileLayout: layout)
        let sessionID = UUID(uuidString: "15E3C0CF-0D72-47C9-9E88-4DBF0B7F5A9B")!
        let startedAt = Date(timeIntervalSince1970: 1_700)

        model.upsertSession(
            makeSession(
                id: sessionID,
                startedAt: startedAt,
                status: .recording,
                title: "Lifecycle"
            )
        )
        XCTAssertEqual(model.sessions.count, 1)
        XCTAssertEqual(model.sessions.first?.status, .recording)

        model.upsertSession(
            makeSession(
                id: sessionID,
                startedAt: startedAt,
                status: .transcribing,
                title: "Lifecycle"
            )
        )
        XCTAssertEqual(model.sessions.count, 1)
        XCTAssertEqual(model.sessions.first?.status, .transcribing)

        model.upsertSession(
            makeSession(
                id: sessionID,
                startedAt: startedAt,
                status: .ready,
                title: "Lifecycle",
                segments: [
                    .init(id: UUID(uuidString: "4EB3D6A5-6D07-4A92-9E5F-1D1C5D1D5E6F")!, speaker: "Transcript", text: "Local recap ready", timestamp: startedAt)
                ],
                audioArtifacts: .init(micFileName: "mic.wav", systemFileName: "system.wav", mixedFileName: "mixed.wav")
            )
        )

        XCTAssertEqual(model.sessions.count, 1)
        XCTAssertEqual(model.sessions.first?.status, .ready)
        XCTAssertEqual(model.sessions.first?.transcriptText, "Local recap ready")
        XCTAssertEqual(model.sessions.first?.audioArtifacts.mixedFileName, "mixed.wav")

        let persistedSessions = store.loadSessions()
        XCTAssertEqual(persistedSessions.count, 1)
        XCTAssertEqual(persistedSessions.first?.status, .ready)
        XCTAssertEqual(persistedSessions.first?.audioArtifacts.systemFileName, "system.wav")
    }

    func testUpsertSessionMergesLiveArtifactsIntoStaleRecorderSnapshots() throws {
        let layout = LocalMeetingFileLayout(baseDirectory: tempRootURL.appendingPathComponent("Meetings", isDirectory: true))
        let store = LocalMeetingSessionStore(fileLayout: layout)
        let model = LocalMeetingAppModel(store: store, fileLayout: layout)
        let sessionID = UUID(uuidString: "7D97F13B-6C1C-4C7D-9F3D-5A6B3C5C0F42")!
        let startedAt = Date(timeIntervalSince1970: 2_500)

        model.upsertSession(
            makeSession(
                id: sessionID,
                startedAt: startedAt,
                status: .recording,
                title: "Lifecycle"
            )
        )
        model.selectSession(id: sessionID)

        let attachment = model.addScreenshotAttachment(
            title: "Live screenshot",
            timestamp: startedAt.addingTimeInterval(12),
            sessionOffset: 12,
            fileName: "live.png",
            urlString: "/tmp/live.png"
        )
        let captureArtifact = model.addCaptureArtifact(
            title: "Live capture",
            capturedAt: startedAt.addingTimeInterval(12),
            sessionOffset: 12,
            attachmentIDs: [attachment?.id].compactMap { $0 }
        )

        let staleTranscribingSnapshot = makeSession(
            id: sessionID,
            startedAt: startedAt,
            status: .transcribing,
            title: "Lifecycle"
        )
        let mergedTranscribingSession = model.upsertSession(staleTranscribingSnapshot)

        XCTAssertEqual(mergedTranscribingSession.status, .transcribing)
        XCTAssertEqual(mergedTranscribingSession.attachments.count, 1)
        XCTAssertEqual(mergedTranscribingSession.captureArtifacts.count, 1)
        XCTAssertEqual(mergedTranscribingSession.attachments.first?.id, attachment?.id)
        XCTAssertEqual(mergedTranscribingSession.captureArtifacts.first?.id, captureArtifact?.id)

        let finalizedSnapshot = makeSession(
            id: sessionID,
            startedAt: startedAt,
            status: .ready,
            title: "Lifecycle",
            segments: [
                .init(
                    id: UUID(uuidString: "2CF51E9A-6AA2-4F71-8B83-1F3C9A9B71D6")!,
                    speaker: "Transcript",
                    text: "The live attachment survived the finalize path.",
                    timestamp: startedAt.addingTimeInterval(30)
                )
            ],
            audioArtifacts: .init(micFileName: "mic.wav", systemFileName: nil, mixedFileName: "mixed.wav")
        )
        let mergedFinalSession = model.upsertSession(finalizedSnapshot)

        XCTAssertEqual(mergedFinalSession.status, .ready)
        XCTAssertEqual(mergedFinalSession.attachments.count, 1)
        XCTAssertEqual(mergedFinalSession.captureArtifacts.count, 1)
        XCTAssertEqual(mergedFinalSession.transcriptText, "The live attachment survived the finalize path.")

        let persistedSessions = store.loadSessions()
        XCTAssertEqual(persistedSessions.first?.attachments.count, 1)
        XCTAssertEqual(persistedSessions.first?.captureArtifacts.count, 1)
        XCTAssertEqual(persistedSessions.first?.transcriptText, "The live attachment survived the finalize path.")
    }

    func testSelectionIsClearedWhenSelectedSessionIsRemoved() {
        let layout = LocalMeetingFileLayout(baseDirectory: tempRootURL.appendingPathComponent("Meetings", isDirectory: true))
        let model = LocalMeetingAppModel(store: LocalMeetingSessionStore(fileLayout: layout), fileLayout: layout)
        let selectedSession = makeSession(
            id: UUID(uuidString: "1AC8A5F0-4E5A-40CE-B44D-1F1C9A2A18C1")!,
            startedAt: Date(timeIntervalSince1970: 10),
            status: .ready,
            title: "Selected"
        )
        let remainingSession = makeSession(
            id: UUID(uuidString: "B8C6A5E7-99C8-47A2-BE0B-0B65EE5F0A4B")!,
            startedAt: Date(timeIntervalSince1970: 20),
            status: .ready,
            title: "Remaining"
        )

        model.sessions = [selectedSession, remainingSession]
        model.selectSession(id: selectedSession.id)

        model.sessions = [remainingSession]

        XCTAssertNil(model.selectedSessionID)
    }

    func testLoadSampleSessionsSelectsNewestSample() {
        let layout = LocalMeetingFileLayout(baseDirectory: tempRootURL.appendingPathComponent("Meetings", isDirectory: true))
        let model = LocalMeetingAppModel(store: LocalMeetingSessionStore(fileLayout: layout), fileLayout: layout)

        model.loadSampleSessions()

        XCTAssertEqual(model.sessions.count, LocalMeetingSession.sampleSessions.count)
        XCTAssertEqual(model.sessions.first, LocalMeetingSession.sampleSessions.max(by: { $0.startedAt < $1.startedAt }))
        XCTAssertEqual(model.selectedSessionID, model.sessions.first?.id)
    }

    func testAddScreenshotAttachmentPersistsTimestampedArtifact() throws {
        let layout = LocalMeetingFileLayout(baseDirectory: tempRootURL.appendingPathComponent("Meetings", isDirectory: true))
        let store = LocalMeetingSessionStore(fileLayout: layout)
        let model = LocalMeetingAppModel(store: store, fileLayout: layout)
        let session = makeSession(
            id: UUID(uuidString: "4A79808D-5227-47C2-AED6-6DF5C9C79A10")!,
            startedAt: Date(timeIntervalSince1970: 2_400),
            status: .recording,
            title: "Attachment lifecycle"
        )

        model.upsertSession(session)
        model.selectSession(id: session.id)

        let attachment = model.addScreenshotAttachment(
            title: "Roadmap capture",
            timestamp: session.startedAt.addingTimeInterval(42),
            sessionOffset: 42,
            fileName: "roadmap.png",
            urlString: "/tmp/roadmap.png"
        )
        let artifact = model.addCaptureArtifact(
            title: "Captured roadmap",
            capturedAt: session.startedAt.addingTimeInterval(42),
            sessionOffset: 42,
            attachmentIDs: [attachment?.id].compactMap { $0 }
        )

        XCTAssertNotNil(attachment)
        XCTAssertNotNil(artifact)
        XCTAssertEqual(model.selectedSession?.attachments.count, 1)
        XCTAssertEqual(model.selectedSession?.captureArtifacts.count, 1)
        XCTAssertEqual(model.selectedSession?.attachments.first?.sessionOffset, 42)
    }

    func testLoadStoredSessionsIgnoresCorruptSessionsAndKeepsValidOnes() throws {
        let layout = LocalMeetingFileLayout(baseDirectory: tempRootURL.appendingPathComponent("Meetings", isDirectory: true))
        let store = LocalMeetingSessionStore(fileLayout: layout)
        let validSession = makeSession(
            id: UUID(uuidString: "A87F33E4-4B5A-4D60-A6AE-5E1A4CE0468D")!,
            startedAt: Date(timeIntervalSince1970: 3_100),
            status: .ready,
            title: "Valid session"
        )

        try store.save(validSession)

        let corruptSessionDirectory = layout.sessionsDirectory.appendingPathComponent("Corrupt", isDirectory: true)
        try fileManager.createDirectory(at: corruptSessionDirectory, withIntermediateDirectories: true)
        try Data("{ not valid json".utf8).write(
            to: corruptSessionDirectory.appendingPathComponent("session.json", isDirectory: false)
        )

        let sessions = store.loadSessions()

        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?.id, validSession.id)
    }

    func testImportExistingRecordingMakesTranscriptAvailableBeforeRecapFinishes() async throws {
        let layout = LocalMeetingFileLayout(baseDirectory: tempRootURL.appendingPathComponent("Meetings", isDirectory: true))
        let store = LocalMeetingSessionStore(fileLayout: layout)
        let sourceURL = tempRootURL.appendingPathComponent("Imported.m4a", isDirectory: false)
        try Data("original-audio".utf8).write(to: sourceURL)

        let transcriptionService = StubLocalSessionTranscriptionService(
            result: LocalSessionTranscriptionResult(
                text: "Imported transcript",
                detectedLanguage: "he",
                segments: [
                    .init(startTime: 0, endTime: 5, text: "Imported transcript")
                ],
                modelPath: "/tmp/model.bin"
            )
        )
        let recapGenerator = BlockingRecapGenerator()
        let importService = StubLocalSessionAudioImportService()
        let model = LocalMeetingAppModel(
            store: store,
            fileLayout: layout,
            transcriptionService: transcriptionService,
            recapGenerator: recapGenerator,
            audioImportService: importService
        )

        await model.importExistingRecording(from: sourceURL, title: "Imported sync")

        XCTAssertFalse(model.isTranscribing)
        XCTAssertTrue(model.isGeneratingRecap)
        XCTAssertEqual(model.processingStatusTitle, "Generating recap")
        XCTAssertEqual(model.selectedSession?.title, "Imported sync")
        XCTAssertEqual(model.selectedSession?.status, .ready)
        XCTAssertEqual(model.selectedSession?.transcriptText, "Imported transcript")
        XCTAssertEqual(model.selectedSession?.audioArtifacts.mixedFileName, "mixed.wav")
        XCTAssertTrue(importService.importedDestinations.contains(layout.mixedAudioURL(for: try XCTUnwrap(model.selectedSession?.id))))
        XCTAssertEqual(transcriptionService.receivedAudioURLs.count, 1)

        recapGenerator.finish(
            with: LocalSessionRecap(
                overview: "Imported overview",
                generatedAt: Date(timeIntervalSince1970: 55),
                sections: []
            )
        )

        await waitUntil("recap generation finishes") {
            !model.isGeneratingRecap
        }

        XCTAssertEqual(model.selectedSession?.recap.overview, "Imported overview")
        XCTAssertNil(model.processingStatusTitle)
    }
}

@MainActor
private final class StubLocalSessionTranscriptionService: @unchecked Sendable, LocalSessionTranscribing {
    let result: LocalSessionTranscriptionResult
    private(set) var receivedAudioURLs: [URL] = []

    init(result: LocalSessionTranscriptionResult) {
        self.result = result
    }

    func transcribe(
        wavURL: URL,
        modelURL: URL,
        language: String,
        prompt: String?,
        translateToEnglish: Bool,
        onProgress: (@Sendable (LocalSessionTranscriptionProgress) async -> Void)?
    ) async throws -> LocalSessionTranscriptionResult {
        receivedAudioURLs.append(wavURL)
        return result
    }
}

@MainActor
private final class BlockingRecapGenerator: @unchecked Sendable, LocalSessionRecapGenerating {
    private var continuation: CheckedContinuation<LocalSessionRecap, Never>?
    private var pendingRecap: LocalSessionRecap?

    func generateRecap(for session: LocalSession) async -> LocalSessionRecap {
        if let pendingRecap {
            self.pendingRecap = nil
            return pendingRecap
        }

        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func finish(with recap: LocalSessionRecap) {
        if let continuation {
            self.continuation = nil
            continuation.resume(returning: recap)
        } else {
            pendingRecap = recap
        }
    }
}

@MainActor
private final class StubLocalSessionAudioImportService: @unchecked Sendable, LocalSessionAudioImporting {
    private(set) var importedDestinations: [URL] = []

    func importAudio(from sourceURL: URL, to destinationWavURL: URL) async throws {
        importedDestinations.append(destinationWavURL)
        let wavData = Data([
            0x52, 0x49, 0x46, 0x46, 0x24, 0x00, 0x00, 0x00,
            0x57, 0x41, 0x56, 0x45, 0x66, 0x6D, 0x74, 0x20,
            0x10, 0x00, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00,
            0x80, 0x3E, 0x00, 0x00, 0x00, 0x7D, 0x00, 0x00,
            0x02, 0x00, 0x10, 0x00, 0x64, 0x61, 0x74, 0x61,
            0x00, 0x00, 0x00, 0x00
        ])
        try wavData.write(to: destinationWavURL)
    }
}

@MainActor
private func waitUntil(
    _ description: String,
    timeoutNanoseconds: UInt64 = 1_000_000_000,
    condition: @escaping @MainActor () -> Bool
) async {
    let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
    while !condition() {
        if DispatchTime.now().uptimeNanoseconds >= deadline {
            XCTFail("Timed out waiting for \(description)")
            return
        }
        await Task.yield()
    }
}

private func makeSession(
    id: UUID,
    startedAt: Date,
    status: LocalMeetingSessionStatus,
    title: String,
    segments: [LocalMeetingTranscriptSegment] = [],
    audioArtifacts: LocalMeetingAudioArtifacts = .empty
) -> LocalMeetingSession {
    LocalMeetingSession(
        id: id,
        title: title,
        startedAt: startedAt,
        status: status,
        transcriptSegments: segments,
        audioArtifacts: audioArtifacts
    )
}
