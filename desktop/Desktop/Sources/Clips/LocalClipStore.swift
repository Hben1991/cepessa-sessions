import Darwin
import Foundation

final class LocalClipStore {
  private(set) var loadWarnings: [String] = []
  private let fileLayout: LocalClipFileLayout
  private let fileManager: FileManager
  private let encoder: JSONEncoder
  private let decoder: JSONDecoder

  init(fileLayout: LocalClipFileLayout = LocalClipFileLayout(), fileManager: FileManager = .default)
  {
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

  func loadClips() -> [LocalClipManifest] {
    loadWarnings = []
    do {
      try LocalClipFileSafety.validateDirectoryChain(
        to: fileLayout.baseDirectory,
        allowMissingTail: true
      )
    } catch {
      loadWarnings.append(
        "The CLIP library could not be read. Check access to its folder and try again."
      )
      NSLog(
        "LocalClipStore: Refusing unsafe clips root %@ (%@)",
        fileLayout.baseDirectory.path,
        error.localizedDescription
      )
      return []
    }
    var rootStatus = stat()
    guard lstat(fileLayout.baseDirectory.path, &rootStatus) == 0 else {
      guard errno == ENOENT else {
        loadWarnings.append(
          "The CLIP library could not be read. Check access to its folder and try again."
        )
        return []
      }
      return []
    }
    guard (rootStatus.st_mode & S_IFMT) == S_IFDIR else {
      loadWarnings.append(
        "The CLIP library could not be read. Check access to its folder and try again."
      )
      return []
    }

    do {
      let directories = try fileManager.contentsOfDirectory(
        at: fileLayout.baseDirectory,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
      )

      return directories.compactMap { directory in
        do {
          var directoryStatus = stat()
          guard lstat(directory.path, &directoryStatus) == 0,
            (directoryStatus.st_mode & S_IFMT) == S_IFDIR,
            let directoryID = UUID(uuidString: directory.lastPathComponent),
            directory.lastPathComponent == directoryID.uuidString
          else {
            throw LocalClipStorageError.unsafeDirectory(directory)
          }
          let manifestURL = directory.appendingPathComponent("clip.json", isDirectory: false)
          let data = try readManifest(at: manifestURL)
          let clip = try decoder.decode(LocalClipManifest.self, from: data)
          guard clip.id == directoryID else {
            throw LocalClipStorageError.invalidManifest(manifestURL)
          }
          try fileLayout.validateStoredArtifacts(for: directoryID)
          return clip
        } catch {
          loadWarnings.append(
            "A saved CLIP could not be opened. Its original files are still on disk."
          )
          NSLog(
            "LocalClipStore: Skipping corrupt clip at %@ (%@)", directory.path,
            error.localizedDescription)
          return nil
        }
      }
      .sorted { $0.startedAt > $1.startedAt }
    } catch {
      loadWarnings.append(
        "The CLIP library could not be read. Check access to its folder and try again."
      )
      NSLog(
        "LocalClipStore: Failed to read clips directory %@ (%@)", fileLayout.baseDirectory.path,
        error.localizedDescription)
      return []
    }
  }

  func save(_ clip: LocalClipManifest) throws {
    try fileLayout.ensureDirectories(fileManager: fileManager, for: clip.id)
    // Ancillary artifacts may be replaced independently, but the manifest is the durable
    // commit point. A reader must never observe `ready` until transcript and notes exist.
    try writeTranscript(for: clip)
    try writeSafely(Data(clip.postNotes.utf8), to: fileLayout.notesURL(for: clip.id))
    try writeSafely(encoder.encode(clip), to: fileLayout.manifestURL(for: clip.id))
  }

  func clipDirectory(for clipID: UUID) -> URL {
    fileLayout.clipDirectory(for: clipID)
  }

  func videoURL(for clipID: UUID) -> URL {
    fileLayout.videoURL(for: clipID)
  }

  func audioURL(for clipID: UUID) -> URL {
    fileLayout.audioURL(for: clipID)
  }

  private func writeTranscript(for clip: LocalClipManifest) throws {
    let payload: [String: Any] = [
      "id": clip.id.uuidString,
      "title": clip.title,
      "segments": clip.transcriptSegments.map {
        [
          "id": $0.id.uuidString,
          "startOffset": $0.startOffset,
          "endOffset": $0.endOffset,
          "text": $0.text,
        ]
      },
      "text": clip.transcriptText,
    ]
    let data = try JSONSerialization.data(
      withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
    try writeSafely(data, to: fileLayout.transcriptURL(for: clip.id))
  }

  private func readManifest(at url: URL) throws -> Data {
    try LocalClipFileSafety.readRegularFile(at: url)
  }

  private func writeSafely(_ data: Data, to url: URL) throws {
    try LocalClipFileSafety.validateDirectoryChain(
      to: url.deletingLastPathComponent(),
      allowMissingTail: false
    )
    var status = stat()
    if lstat(url.path, &status) == 0 {
      guard (status.st_mode & S_IFMT) == S_IFREG, status.st_nlink == 1 else {
        throw LocalClipStorageError.unsafeArtifact(url)
      }
    } else if errno != ENOENT {
      throw LocalClipStorageError.unsafeArtifact(url)
    }
    try data.write(to: url, options: .atomic)
  }
}
