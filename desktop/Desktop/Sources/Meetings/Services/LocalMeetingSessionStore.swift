import Foundation

final class LocalSessionStore {
    private let fileLayout: LocalSessionFileLayout
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let promptPackageBuilder: LocalSessionPromptPackageBuilder

    init(fileLayout: LocalSessionFileLayout, fileManager: FileManager = .default) {
        self.fileLayout = fileLayout
        self.fileManager = fileManager
        self.promptPackageBuilder = LocalSessionPromptPackageBuilder(
            fileLayout: fileLayout,
            fileManager: fileManager
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    func loadSessions() -> [LocalSession] {
        let currentSessions = loadSessions(in: fileLayout.sessionsDirectory)
        let legacySessions = loadSessions(in: fileLayout.legacySessionsDirectory)

        var sessionsByID: [UUID: LocalSession] = [:]
        for session in currentSessions {
            sessionsByID[session.id] = session
        }

        for session in legacySessions where sessionsByID[session.id] == nil {
            sessionsByID[session.id] = session
        }

        return sessionsByID.values.sorted { $0.startedAt > $1.startedAt }
    }

    func save(_ session: LocalSession) throws {
        try fileLayout.ensureDirectories(fileManager: fileManager, for: session.id)
        let data = try encoder.encode(session)
        try data.write(to: fileLayout.metadataURL(for: session.id), options: .atomic)
        try promptPackageBuilder.writePackage(for: session)
    }

    private func loadSessions(in directory: URL) -> [LocalSession] {
        guard fileManager.fileExists(atPath: directory.path) else {
            return []
        }

        do {
            let sessionDirectories = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )

            return sessionDirectories.compactMap { sessionDirectory -> LocalSession? in
                do {
                    let values = try sessionDirectory.resourceValues(forKeys: [.isDirectoryKey])
                    guard values.isDirectory == true else { return nil }

                    let resolvedMetadataURL = sessionDirectory.appendingPathComponent("session.json", isDirectory: false)
                    guard fileManager.fileExists(atPath: resolvedMetadataURL.path) else { return nil }
                    let data = try Data(contentsOf: resolvedMetadataURL)
                    let session = try decoder.decode(LocalSession.self, from: data)
                    if directory.standardizedFileURL.path == fileLayout.sessionsDirectory.standardizedFileURL.path {
                        try? promptPackageBuilder.writePackage(for: session)
                    }
                    return session
                } catch {
                    NSLog("LocalSessionStore: Skipping corrupt session at %@ (%@)", sessionDirectory.path, error.localizedDescription)
                    return nil
                }
            }
        } catch {
            NSLog("LocalSessionStore: Failed to read sessions directory %@ (%@)", directory.path, error.localizedDescription)
            return []
        }
    }
}

typealias LocalMeetingSessionStore = LocalSessionStore
