import Foundation
import Darwin

enum LocalSessionStoreError: LocalizedError, Equatable {
    case unsafeLock(URL)
    case lockTimeout(URL)
    case missingSession(URL)
    case unsafeMetadata(URL)
    case invalidMetadata(URL)
    case unsafeGeneratedCache(URL)
    case editConflict([String])

    var errorDescription: String? {
        switch self {
        case .unsafeLock:
            return "The session lock is unavailable or unsafe."
        case .lockTimeout:
            return "Another process is saving this session. Try again."
        case .missingSession:
            return "This session is no longer available on disk."
        case .unsafeMetadata:
            return "The session metadata is unavailable or unsafe."
        case .invalidMetadata:
            return "This session's saved metadata is invalid."
        case .unsafeGeneratedCache:
            return "A generated session cache is unavailable or unsafe."
        case .editConflict:
            return "This session changed elsewhere. Refresh it and try again."
        }
    }
}

final class LocalSessionStore {
    private(set) var loadWarnings: [String] = []
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
        loadWarnings = []
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

    /// A single-session update must not decode and regenerate the entire library.
    func loadSession(id: UUID) -> LocalSession? {
        for root in [fileLayout.sessionsDirectory, fileLayout.legacySessionsDirectory] {
            let metadata = root.appendingPathComponent(id.uuidString, isDirectory: true)
                .appendingPathComponent("session.json")
            if let data = try? readMetadata(at: metadata),
               let session = try? decoder.decode(LocalSession.self, from: data), session.id == id {
                return session
            }
        }
        return nil
    }

    @discardableResult
    func save(_ session: LocalSession, mergingChangesFrom baseline: LocalSession? = nil) throws -> LocalSession {
        try fileLayout.ensureDirectories(fileManager: fileManager, for: session.id)
        let metadataURL = fileLayout.metadataURL(for: session.id)

        return try withSessionLock(for: session.id) {
            let incomingData = try encoder.encode(session)
            let data: Data
            if let baseline {
                let currentData: Data
                if let currentMetadata = try existingMetadataData(at: metadataURL) {
                    currentData = currentMetadata
                } else if let legacyMetadata = try existingMetadataData(
                    at: fileLayout.legacyMetadataURL(for: session.id))
                {
                    currentData = legacyMetadata
                } else {
                    throw LocalSessionStoreError.missingSession(metadataURL)
                }
                let currentSession: LocalSession
                do {
                    currentSession = try decoder.decode(LocalSession.self, from: currentData)
                } catch {
                    throw LocalSessionStoreError.invalidMetadata(metadataURL)
                }
                guard currentSession.id == session.id else {
                    throw LocalSessionStoreError.invalidMetadata(metadataURL)
                }

                let currentObject = try topLevelJSONObject(currentData, at: metadataURL)
                let currentEncodedObject = try topLevelJSONObject(
                    encoder.encode(currentSession), at: metadataURL)
                let baselineObject = try topLevelJSONObject(
                    encoder.encode(baseline), at: metadataURL)
                let incomingObject = try topLevelJSONObject(incomingData, at: metadataURL)
                let keys = Set(baselineObject.keys).union(incomingObject.keys).sorted()
                let changedKeys = try keys.filter { key in
                    try !jsonValuesEqual(baselineObject[key], incomingObject[key])
                }
                let conflicts = try changedKeys.filter { key in
                    let currentValue = currentEncodedObject[key]
                    let currentDiffersFromBaseline = try !jsonValuesEqual(
                        currentValue, baselineObject[key])
                    let currentDiffersFromIncoming = try !jsonValuesEqual(
                        currentValue, incomingObject[key])
                    return currentDiffersFromBaseline && currentDiffersFromIncoming
                }
                guard conflicts.isEmpty else {
                    throw LocalSessionStoreError.editConflict(conflicts)
                }

                var mergedObject = currentObject
                for key in changedKeys {
                    if let incomingValue = incomingObject[key] {
                        mergedObject[key] = incomingValue
                    } else {
                        mergedObject.removeValue(forKey: key)
                    }
                }
                data = try JSONSerialization.data(
                    withJSONObject: mergedObject,
                    options: [.prettyPrinted, .sortedKeys]
                )
            } else {
                data = incomingData
            }

            try invalidateGeneratedPackages(for: session.id)
            try writeMetadata(data, to: metadataURL)
            let savedSession = try decoder.decode(LocalSession.self, from: data)
            try promptPackageBuilder.writePackage(for: savedSession)
            return savedSession
        }
    }

    private func withSessionLock<T>(for sessionID: UUID, _ body: () throws -> T) throws -> T {
        let sessionDirectory = fileLayout.sessionDirectory(for: sessionID)
        try validateDirectory(fileLayout.sessionsDirectory)
        try validateDirectory(sessionDirectory)

        let lockURL = sessionDirectory.appendingPathComponent(".session.lock", isDirectory: false)
        let flags = O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW
        let descriptor = open(lockURL.path, flags, mode_t(0o600))
        guard descriptor >= 0 else {
            throw LocalSessionStoreError.unsafeLock(lockURL)
        }
        defer { close(descriptor) }

        var lockStatus = stat()
        guard fstat(descriptor, &lockStatus) == 0,
            (lockStatus.st_mode & S_IFMT) == S_IFREG,
            lockStatus.st_nlink == 1
        else {
            throw LocalSessionStoreError.unsafeLock(lockURL)
        }

        let deadline = DispatchTime.now().uptimeNanoseconds + 1_000_000_000
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            let errorNumber = errno
            guard errorNumber == EAGAIN || errorNumber == EWOULDBLOCK else {
                throw LocalSessionStoreError.unsafeLock(lockURL)
            }
            guard DispatchTime.now().uptimeNanoseconds < deadline else {
                throw LocalSessionStoreError.lockTimeout(lockURL)
            }
            usleep(10_000)
        }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try body()
    }

    private func repairCurrentPackage(for sessionID: UUID) throws -> LocalSession {
        try withSessionLock(for: sessionID) {
            let metadataURL = fileLayout.metadataURL(for: sessionID)
            guard let metadataData = try existingMetadataData(at: metadataURL) else {
                throw LocalSessionStoreError.missingSession(metadataURL)
            }

            let latestSession: LocalSession
            do {
                latestSession = try decoder.decode(LocalSession.self, from: metadataData)
            } catch {
                throw LocalSessionStoreError.invalidMetadata(metadataURL)
            }
            guard latestSession.id == sessionID else {
                throw LocalSessionStoreError.invalidMetadata(metadataURL)
            }

            try promptPackageBuilder.writePackage(for: latestSession)
            return latestSession
        }
    }

    private func invalidateGeneratedPackages(for sessionID: UUID) throws {
        let exportsDirectory = fileLayout.exportsDirectory(for: sessionID)
        var exportsStatus = stat()
        guard lstat(exportsDirectory.path, &exportsStatus) == 0 else {
            guard errno == ENOENT else {
                throw LocalSessionStoreError.unsafeGeneratedCache(exportsDirectory)
            }
            return
        }
        guard (exportsStatus.st_mode & S_IFMT) == S_IFDIR else {
            throw LocalSessionStoreError.unsafeGeneratedCache(exportsDirectory)
        }

        let generatedPackageURLs = [
            fileLayout.promptPackageMarkdownURL(for: sessionID),
            fileLayout.promptPackageJSONURL(for: sessionID),
        ]
        for packageURL in generatedPackageURLs {
            var packageStatus = stat()
            guard lstat(packageURL.path, &packageStatus) == 0 else {
                guard errno == ENOENT else {
                    throw LocalSessionStoreError.unsafeGeneratedCache(packageURL)
                }
                continue
            }
            guard (packageStatus.st_mode & S_IFMT) == S_IFREG, packageStatus.st_nlink == 1 else {
                throw LocalSessionStoreError.unsafeGeneratedCache(packageURL)
            }
            guard unlink(packageURL.path) == 0 else {
                throw LocalSessionStoreError.unsafeGeneratedCache(packageURL)
            }
        }
    }

    private func validateDirectory(_ url: URL) throws {
        var directoryStatus = stat()
        guard lstat(url.path, &directoryStatus) == 0,
            (directoryStatus.st_mode & S_IFMT) == S_IFDIR
        else {
            throw LocalSessionStoreError.unsafeLock(url)
        }
    }

    private func readMetadata(at url: URL) throws -> Data {
        var metadataStatus = stat()
        guard lstat(url.path, &metadataStatus) == 0,
            (metadataStatus.st_mode & S_IFMT) == S_IFREG,
            metadataStatus.st_nlink == 1
        else {
            throw LocalSessionStoreError.unsafeMetadata(url)
        }

        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw LocalSessionStoreError.unsafeMetadata(url)
        }
        defer { close(descriptor) }

        var openedStatus = stat()
        guard fstat(descriptor, &openedStatus) == 0,
            (openedStatus.st_mode & S_IFMT) == S_IFREG,
            openedStatus.st_nlink == 1
        else {
            throw LocalSessionStoreError.unsafeMetadata(url)
        }

        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        return try handle.readToEnd() ?? Data()
    }

    private func existingMetadataData(at url: URL) throws -> Data? {
        var metadataStatus = stat()
        guard lstat(url.path, &metadataStatus) == 0 else {
            guard errno == ENOENT else {
                throw LocalSessionStoreError.unsafeMetadata(url)
            }
            return nil
        }
        return try readMetadata(at: url)
    }

    private func writeMetadata(_ data: Data, to url: URL) throws {
        var metadataStatus = stat()
        if lstat(url.path, &metadataStatus) == 0 {
            guard (metadataStatus.st_mode & S_IFMT) == S_IFREG, metadataStatus.st_nlink == 1 else {
                throw LocalSessionStoreError.unsafeMetadata(url)
            }
        } else if errno != ENOENT {
            throw LocalSessionStoreError.unsafeMetadata(url)
        }
        try data.write(to: url, options: .atomic)
    }

    private func topLevelJSONObject(_ data: Data, at url: URL) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LocalSessionStoreError.invalidMetadata(url)
        }
        return object
    }

    private func jsonValuesEqual(_ lhs: Any?, _ rhs: Any?) throws -> Bool {
        let lhsData = try canonicalJSONData(lhs)
        let rhsData = try canonicalJSONData(rhs)
        return lhsData == rhsData
    }

    private func canonicalJSONData(_ value: Any?) throws -> Data? {
        guard let value else { return nil }
        return try JSONSerialization.data(
            withJSONObject: value,
            options: [.sortedKeys, .fragmentsAllowed]
        )
    }

    private func loadSessions(in directory: URL) -> [LocalSession] {
        var directoryStatus = stat()
        guard lstat(directory.path, &directoryStatus) == 0 else {
            let errorNumber = errno
            guard errorNumber == ENOENT else {
                loadWarnings.append(
                    "The session library could not be read. Check access to its folder and try again."
                )
                NSLog(
                    "LocalSessionStore: Refusing unsafe sessions directory %@ (%d)",
                    directory.path,
                    errorNumber
                )
            }
            return []
        }
        guard (directoryStatus.st_mode & S_IFMT) == S_IFDIR else {
            loadWarnings.append(
                "The session library could not be read. Check access to its folder and try again."
            )
            NSLog("LocalSessionStore: Refusing non-directory sessions root %@", directory.path)
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
                    var sessionDirectoryStatus = stat()
                    guard lstat(sessionDirectory.path, &sessionDirectoryStatus) == 0,
                        (sessionDirectoryStatus.st_mode & S_IFMT) == S_IFDIR,
                        let directoryID = UUID(uuidString: sessionDirectory.lastPathComponent)
                    else {
                        throw LocalSessionStoreError.unsafeMetadata(
                            sessionDirectory.appendingPathComponent("session.json", isDirectory: false)
                        )
                    }

                    let resolvedMetadataURL = sessionDirectory.appendingPathComponent("session.json", isDirectory: false)
                    let data = try readMetadata(at: resolvedMetadataURL)
                    let session = try decoder.decode(LocalSession.self, from: data)
                    guard session.id == directoryID else {
                        throw LocalSessionStoreError.invalidMetadata(resolvedMetadataURL)
                    }
                    if directory.standardizedFileURL.path == fileLayout.sessionsDirectory.standardizedFileURL.path {
                        do {
                            return try repairCurrentPackage(for: session.id)
                        } catch {
                            loadWarnings.append(
                                "A saved session loaded, but its generated package could not be refreshed."
                            )
                            NSLog(
                                "LocalSessionStore: Loaded session %@ without refreshing its generated package (%@)",
                                session.id.uuidString,
                                error.localizedDescription
                            )
                            return session
                        }
                    }
                    return session
                } catch {
                    loadWarnings.append("A saved session could not be opened. Its original files are still on disk.")
                    NSLog("LocalSessionStore: Skipping corrupt session at %@ (%@)", sessionDirectory.path, error.localizedDescription)
                    return nil
                }
            }
        } catch {
            loadWarnings.append("The session library could not be read. Check access to its folder and try again.")
            NSLog("LocalSessionStore: Failed to read sessions directory %@ (%@)", directory.path, error.localizedDescription)
            return []
        }
    }
}

typealias LocalMeetingSessionStore = LocalSessionStore
