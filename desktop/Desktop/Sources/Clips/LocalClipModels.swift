import Darwin
import Foundation

enum LocalClipStorageError: LocalizedError, Equatable {
  case unsafeDirectory(URL)
  case unsafeArtifact(URL)
  case invalidManifest(URL)

  var errorDescription: String? {
    switch self {
    case .unsafeDirectory:
      return "The CLIP folder is unavailable or unsafe."
    case .unsafeArtifact:
      return "A saved CLIP file is unavailable or unsafe."
    case .invalidManifest:
      return "This CLIP's saved metadata is invalid."
    }
  }
}

enum LocalClipFileSafety {
  static func validateDirectoryChain(to url: URL, allowMissingTail: Bool) throws {
    guard let standardizedURL = LocalStoragePath.checkedFileURL(url) else {
      throw LocalClipStorageError.unsafeDirectory(url)
    }

    var currentURL = URL(fileURLWithPath: "/", isDirectory: true)
    for component in standardizedURL.pathComponents.dropFirst() {
      currentURL.appendPathComponent(component, isDirectory: true)
      var status = stat()
      guard lstat(currentURL.path, &status) == 0 else {
        guard allowMissingTail, errno == ENOENT else {
          throw LocalClipStorageError.unsafeDirectory(currentURL)
        }
        return
      }
      guard (status.st_mode & S_IFMT) == S_IFDIR else {
        throw LocalClipStorageError.unsafeDirectory(currentURL)
      }
    }
  }

  static func validateRegularFile(at url: URL, allowMissing: Bool) throws {
    try validateDirectoryChain(to: url.deletingLastPathComponent(), allowMissingTail: false)
    var pathStatus = stat()
    guard lstat(url.path, &pathStatus) == 0 else {
      guard allowMissing, errno == ENOENT else {
        throw LocalClipStorageError.unsafeArtifact(url)
      }
      return
    }
    guard (pathStatus.st_mode & S_IFMT) == S_IFREG, pathStatus.st_nlink == 1 else {
      throw LocalClipStorageError.unsafeArtifact(url)
    }

    let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    guard descriptor >= 0 else {
      throw LocalClipStorageError.unsafeArtifact(url)
    }
    defer { close(descriptor) }

    var openedStatus = stat()
    guard fstat(descriptor, &openedStatus) == 0,
      (openedStatus.st_mode & S_IFMT) == S_IFREG,
      openedStatus.st_nlink == 1,
      openedStatus.st_dev == pathStatus.st_dev,
      openedStatus.st_ino == pathStatus.st_ino
    else {
      throw LocalClipStorageError.unsafeArtifact(url)
    }
  }

  static func isSafeExistingRegularFile(at url: URL) -> Bool {
    do {
      try validateRegularFile(at: url, allowMissing: false)
      return true
    } catch {
      return false
    }
  }

  static func readRegularFile(at url: URL) throws -> Data {
    try validateDirectoryChain(to: url.deletingLastPathComponent(), allowMissingTail: false)
    var pathStatus = stat()
    guard lstat(url.path, &pathStatus) == 0,
      (pathStatus.st_mode & S_IFMT) == S_IFREG,
      pathStatus.st_nlink == 1
    else {
      throw LocalClipStorageError.unsafeArtifact(url)
    }

    let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    guard descriptor >= 0 else {
      throw LocalClipStorageError.unsafeArtifact(url)
    }
    defer { close(descriptor) }

    var openedStatus = stat()
    guard fstat(descriptor, &openedStatus) == 0,
      (openedStatus.st_mode & S_IFMT) == S_IFREG,
      openedStatus.st_nlink == 1,
      openedStatus.st_dev == pathStatus.st_dev,
      openedStatus.st_ino == pathStatus.st_ino
    else {
      throw LocalClipStorageError.unsafeArtifact(url)
    }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
    return try handle.readToEnd() ?? Data()
  }
}

enum LocalClipStatus: String, Codable, Equatable, Sendable {
  case recording
  case processing
  case ready
  case failed
}

struct LocalClipTranscriptSegment: Identifiable, Codable, Equatable, Sendable {
  let id: UUID
  var startOffset: TimeInterval
  var endOffset: TimeInterval
  var text: String
}

struct LocalClipManifest: Identifiable, Codable, Equatable, Sendable {
  let id: UUID
  var title: String
  var startedAt: Date
  var endedAt: Date?
  var status: LocalClipStatus
  var intent: String?
  var videoFileName: String
  var audioFileName: String?
  var transcriptFileName: String
  var notesFileName: String
  var transcriptSegments: [LocalClipTranscriptSegment]
  var postNotes: String
  var errorMessage: String?

  var duration: TimeInterval {
    (endedAt ?? Date()).timeIntervalSince(startedAt)
  }

  var transcriptText: String {
    transcriptSegments.map(\.text).joined(separator: "\n")
  }
}

struct LocalClipFileLayout {
  let baseDirectory: URL

  init(baseDirectory: URL = Self.defaultBaseDirectory) {
    self.baseDirectory = baseDirectory
  }

  static var defaultBaseDirectory: URL {
    LocalSessionStorageRoot.defaultBaseDirectory
      .appendingPathComponent("Clips", isDirectory: true)
  }

  func clipDirectory(for clipID: UUID) -> URL {
    baseDirectory.appendingPathComponent(clipID.uuidString, isDirectory: true)
  }

  func manifestURL(for clipID: UUID) -> URL {
    clipDirectory(for: clipID).appendingPathComponent("clip.json", isDirectory: false)
  }

  func videoURL(for clipID: UUID) -> URL {
    clipDirectory(for: clipID).appendingPathComponent("clip-video.mov", isDirectory: false)
  }

  func audioURL(for clipID: UUID) -> URL {
    clipDirectory(for: clipID).appendingPathComponent("clip-audio.wav", isDirectory: false)
  }

  func transcriptURL(for clipID: UUID) -> URL {
    clipDirectory(for: clipID).appendingPathComponent("transcript.json", isDirectory: false)
  }

  func notesURL(for clipID: UUID) -> URL {
    clipDirectory(for: clipID).appendingPathComponent("notes.md", isDirectory: false)
  }

  func ensureDirectories(fileManager: FileManager = .default, for clipID: UUID? = nil) throws {
    try ensureSafeDirectory(baseDirectory, fileManager: fileManager, createIntermediates: true)
    guard let clipID else { return }

    try ensureSafeDirectory(
      clipDirectory(for: clipID),
      fileManager: fileManager,
      createIntermediates: false
    )
    for artifactURL in [
      manifestURL(for: clipID),
      videoURL(for: clipID),
      audioURL(for: clipID),
      transcriptURL(for: clipID),
      notesURL(for: clipID),
    ] {
      try LocalClipFileSafety.validateRegularFile(at: artifactURL, allowMissing: true)
    }
  }

  func validateStoredArtifacts(for clipID: UUID) throws {
    for artifactURL in [
      manifestURL(for: clipID),
      videoURL(for: clipID),
      audioURL(for: clipID),
      transcriptURL(for: clipID),
      notesURL(for: clipID),
    ] {
      try LocalClipFileSafety.validateRegularFile(at: artifactURL, allowMissing: true)
    }
  }

  func safeExistingVideoURL(for clipID: UUID) -> URL? {
    let url = videoURL(for: clipID)
    return LocalClipFileSafety.isSafeExistingRegularFile(at: url) ? url : nil
  }

  func safeExistingAudioURL(for clipID: UUID) -> URL? {
    let url = audioURL(for: clipID)
    return LocalClipFileSafety.isSafeExistingRegularFile(at: url) ? url : nil
  }

  private func ensureSafeDirectory(
    _ url: URL,
    fileManager: FileManager,
    createIntermediates: Bool
  ) throws {
    try LocalClipFileSafety.validateDirectoryChain(to: url, allowMissingTail: true)
    var status = stat()
    if lstat(url.path, &status) != 0 {
      guard errno == ENOENT else { throw LocalClipStorageError.unsafeDirectory(url) }
      try fileManager.createDirectory(
        at: url,
        withIntermediateDirectories: createIntermediates
      )
    }
    try LocalClipFileSafety.validateDirectoryChain(to: url, allowMissingTail: false)
  }

}
