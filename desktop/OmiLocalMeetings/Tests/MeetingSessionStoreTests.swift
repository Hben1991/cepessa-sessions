import XCTest
@testable import OmiLocalMeetings

final class MeetingSessionStoreTests: XCTestCase {
    func testFileLayoutProducesStablePathsForSessionArtifacts() throws {
        let baseDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let layout = FileLayout(baseDirectory: baseDirectory)
        let sessionID = UUID(uuidString: "4EE95D1E-3A60-4C5C-8A24-1716C8EA73C0")!

        XCTAssertEqual(layout.sessionsDirectory, baseDirectory.appendingPathComponent("Sessions", isDirectory: true))
        XCTAssertEqual(layout.sessionDirectory(for: sessionID), layout.sessionsDirectory.appendingPathComponent(sessionID.uuidString, isDirectory: true))
        XCTAssertEqual(layout.metadataURL(for: sessionID), layout.sessionDirectory(for: sessionID).appendingPathComponent("session.json", isDirectory: false))
        XCTAssertEqual(layout.micAudioURL(for: sessionID).lastPathComponent, "mic.wav")
        XCTAssertEqual(layout.systemAudioURL(for: sessionID).lastPathComponent, "system.wav")
        XCTAssertEqual(layout.mixedAudioURL(for: sessionID).lastPathComponent, "mixed.wav")
    }

    func testSavingAndLoadingSessionsPreservesStatusAndArtifactNames() throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        let layout = FileLayout(baseDirectory: tempRoot)
        let store = MeetingSessionStore(fileLayout: layout)

        let session = MeetingSession(
            id: UUID(uuidString: "80B1CC3E-0B95-45C2-8611-F72D5C478AAB")!,
            title: "Design review",
            startedAt: Date(timeIntervalSince1970: 1_742_900_000),
            status: .transcribing,
            segments: [],
            audioArtifacts: .init(
                micFileName: "mic.wav",
                systemFileName: "system.wav",
                mixedFileName: "mixed.wav"
            )
        )

        try store.save(session)
        let loaded = try store.loadSessions()

        XCTAssertEqual(loaded, [session])
    }

    func testLoadingSessionsSortsNewestFirst() throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        let layout = FileLayout(baseDirectory: tempRoot)
        let store = MeetingSessionStore(fileLayout: layout)

        let older = MeetingSession(
            id: UUID(uuidString: "89EE9E13-5B0C-4D82-B2F7-2A8E814F3A3D")!,
            title: "Older",
            startedAt: Date(timeIntervalSince1970: 1_742_800_000),
            status: .ready,
            segments: [],
            audioArtifacts: .empty
        )
        let newer = MeetingSession(
            id: UUID(uuidString: "31CC8872-BB47-4851-B111-BEA2223E18F1")!,
            title: "Newer",
            startedAt: Date(timeIntervalSince1970: 1_742_900_000),
            status: .failed,
            segments: [],
            audioArtifacts: .empty
        )

        try store.save(older)
        try store.save(newer)

        XCTAssertEqual(try store.loadSessions().map(\.id), [newer.id, older.id])
    }
}
