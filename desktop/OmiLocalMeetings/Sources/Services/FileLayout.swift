import Foundation

struct FileLayout {
    static let defaultHebrewModelID = "ivrit-ai_whisper-large-v3-turbo-ggml"
    private static let defaultHebrewModelFileName = "ggml-model.bin"
    let baseDirectory: URL

    var sessionsDirectory: URL {
        baseDirectory.appendingPathComponent("Sessions", isDirectory: true)
    }

    var modelsDirectory: URL {
        baseDirectory.appendingPathComponent("Models", isDirectory: true)
    }

    func sessionDirectory(for sessionID: UUID) -> URL {
        sessionsDirectory.appendingPathComponent(sessionID.uuidString, isDirectory: true)
    }

    func modelDirectory(for modelID: String = Self.defaultHebrewModelID) -> URL {
        modelsDirectory.appendingPathComponent(modelID, isDirectory: true)
    }

    func modelURL(
        for modelID: String = Self.defaultHebrewModelID,
        fileName: String = Self.defaultHebrewModelFileName
    ) -> URL {
        modelDirectory(for: modelID).appendingPathComponent(fileName, isDirectory: false)
    }

    func resolvedHebrewModelURL(fileManager: FileManager = .default) -> URL {
        let installedModelURL = modelURL()
        if fileManager.fileExists(atPath: installedModelURL.path) {
            return installedModelURL
        }

        let developmentModelURL = URL(fileURLWithPath: "/Users/ben/Documents/App/General/__MODELS__/ivrit-ai_whisper-large-v3-turbo-ggml/ggml-model.bin")
        if fileManager.fileExists(atPath: developmentModelURL.path) {
            return developmentModelURL
        }

        return installedModelURL
    }

    func metadataURL(for sessionID: UUID) -> URL {
        sessionDirectory(for: sessionID).appendingPathComponent("session.json", isDirectory: false)
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
        }
    }
}
