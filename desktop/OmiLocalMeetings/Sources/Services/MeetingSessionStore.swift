import Foundation

final class MeetingSessionStore {
    private let fileLayout: FileLayout
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(fileLayout: FileLayout, fileManager: FileManager = .default) {
        self.fileLayout = fileLayout
        self.fileManager = fileManager

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    func loadSessions() throws -> [MeetingSession] {
        guard fileManager.fileExists(atPath: fileLayout.sessionsDirectory.path) else {
            return []
        }

        let sessionDirectories = try fileManager.contentsOfDirectory(
            at: fileLayout.sessionsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        let sessions = try sessionDirectories.compactMap { directory -> MeetingSession? in
            let values = try directory.resourceValues(forKeys: [.isDirectoryKey])
            guard values.isDirectory == true else { return nil }

            let metadataURL = directory.appendingPathComponent("session.json", isDirectory: false)
            guard fileManager.fileExists(atPath: metadataURL.path) else { return nil }
            let data = try Data(contentsOf: metadataURL)
            return try decoder.decode(MeetingSession.self, from: data)
        }

        return sessions.sorted { $0.startedAt > $1.startedAt }
    }

    func save(_ session: MeetingSession) throws {
        try fileLayout.ensureDirectories(fileManager: fileManager, for: session.id)
        let data = try encoder.encode(session)
        try data.write(to: fileLayout.metadataURL(for: session.id), options: .atomic)
    }
}
