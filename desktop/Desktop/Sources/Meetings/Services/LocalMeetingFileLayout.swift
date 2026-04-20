import Foundation

struct LocalSessionFileLayout {
    static let defaultHebrewModelID = "ivrit-ai_whisper-large-v3-turbo-ggml"
    private static let defaultHebrewModelFileName = "ggml-model.bin"
    private static let legacyRootName = "Omi Computer"
    private static let legacySessionsRootName = "Meetings"
    private static let currentRootName = "Cepessa"

    let baseDirectory: URL

    private static var currentBaseDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Self.currentRootName, isDirectory: true)
    }

    static var legacyBaseDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Self.legacyRootName, isDirectory: true)
            .appendingPathComponent(Self.legacySessionsRootName, isDirectory: true)
    }

    var sessionsDirectory: URL {
        baseDirectory.appendingPathComponent("Sessions", isDirectory: true)
    }

    var modelsDirectory: URL {
        baseDirectory.appendingPathComponent("Models", isDirectory: true)
    }

    var legacySessionsDirectory: URL {
        resolvedLegacyBaseDirectory.appendingPathComponent("Sessions", isDirectory: true)
    }

    var legacyModelsDirectory: URL {
        resolvedLegacyBaseDirectory.appendingPathComponent("Models", isDirectory: true)
    }

    func sessionDirectory(for sessionID: UUID) -> URL {
        sessionsDirectory.appendingPathComponent(sessionID.uuidString, isDirectory: true)
    }

    func legacySessionDirectory(for sessionID: UUID) -> URL {
        legacySessionsDirectory.appendingPathComponent(sessionID.uuidString, isDirectory: true)
    }

    func modelDirectory(for modelID: String = Self.defaultHebrewModelID) -> URL {
        modelsDirectory.appendingPathComponent(modelID, isDirectory: true)
    }

    func legacyModelDirectory(for modelID: String = Self.defaultHebrewModelID) -> URL {
        legacyModelsDirectory.appendingPathComponent(modelID, isDirectory: true)
    }

    private var resolvedLegacyBaseDirectory: URL {
        let standardizedCurrent = baseDirectory.standardizedFileURL.path
        let standardizedDefault = Self.currentBaseDirectory.standardizedFileURL.path

        if standardizedCurrent == standardizedDefault {
            return Self.legacyBaseDirectory
        }

        return baseDirectory.appendingPathComponent("LegacyMeetings", isDirectory: true)
    }

    func modelURL(
        for modelID: String = Self.defaultHebrewModelID,
        fileName: String = Self.defaultHebrewModelFileName
    ) -> URL {
        modelDirectory(for: modelID).appendingPathComponent(fileName, isDirectory: false)
    }

    func legacyModelURL(
        for modelID: String = Self.defaultHebrewModelID,
        fileName: String = Self.defaultHebrewModelFileName
    ) -> URL {
        legacyModelDirectory(for: modelID).appendingPathComponent(fileName, isDirectory: false)
    }

    func resolvedHebrewModelURL(fileManager: FileManager = .default) -> URL {
        let installedModelURL = modelURL()
        if fileManager.fileExists(atPath: installedModelURL.path) {
            return installedModelURL
        }

        let legacyModelURL = legacyModelURL()
        if fileManager.fileExists(atPath: legacyModelURL.path) {
            return legacyModelURL
        }

        let developmentModelURL = URL(
            fileURLWithPath: "/Users/ben/Documents/App/General/__MODELS__/ivrit-ai_whisper-large-v3-turbo-ggml/ggml-model.bin"
        )
        if fileManager.fileExists(atPath: developmentModelURL.path) {
            return developmentModelURL
        }

        return installedModelURL
    }

    func metadataURL(for sessionID: UUID) -> URL {
        sessionDirectory(for: sessionID).appendingPathComponent("session.json", isDirectory: false)
    }

    func attachmentsDirectory(for sessionID: UUID) -> URL {
        sessionDirectory(for: sessionID).appendingPathComponent("Attachments", isDirectory: true)
    }

    func exportsDirectory(for sessionID: UUID) -> URL {
        sessionDirectory(for: sessionID).appendingPathComponent("Exports", isDirectory: true)
    }

    func promptPackageMarkdownURL(for sessionID: UUID) -> URL {
        exportsDirectory(for: sessionID).appendingPathComponent("session-package.md", isDirectory: false)
    }

    func promptPackageJSONURL(for sessionID: UUID) -> URL {
        exportsDirectory(for: sessionID).appendingPathComponent("session-package.json", isDirectory: false)
    }

    func legacyMetadataURL(for sessionID: UUID) -> URL {
        legacySessionDirectory(for: sessionID).appendingPathComponent("session.json", isDirectory: false)
    }

    func micAudioURL(for sessionID: UUID) -> URL {
        sessionDirectory(for: sessionID).appendingPathComponent("mic.wav", isDirectory: false)
    }

    func systemAudioURL(for sessionID: UUID) -> URL {
        sessionDirectory(for: sessionID).appendingPathComponent("system.wav", isDirectory: false)
    }

    func mixedAudioURL(for sessionID: UUID) -> URL {
        sessionDirectory(for: sessionID).appendingPathComponent("mixed.wav", isDirectory: false)
    }

    func ensureDirectories(fileManager: FileManager = .default, for sessionID: UUID? = nil) throws {
        try fileManager.createDirectory(at: sessionsDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: modelDirectory(), withIntermediateDirectories: true)

        if let sessionID {
            try fileManager.createDirectory(at: sessionDirectory(for: sessionID), withIntermediateDirectories: true)
            try fileManager.createDirectory(at: attachmentsDirectory(for: sessionID), withIntermediateDirectories: true)
            try fileManager.createDirectory(at: exportsDirectory(for: sessionID), withIntermediateDirectories: true)
        }
    }
}

typealias LocalMeetingFileLayout = LocalSessionFileLayout
