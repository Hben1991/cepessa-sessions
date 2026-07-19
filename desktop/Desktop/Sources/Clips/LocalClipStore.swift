import Foundation

final class LocalClipStore {
  private let fileLayout: LocalClipFileLayout
  private let fileManager: FileManager
  private let encoder: JSONEncoder
  private let decoder: JSONDecoder

  init(fileLayout: LocalClipFileLayout = LocalClipFileLayout(), fileManager: FileManager = .default) {
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
    guard fileManager.fileExists(atPath: fileLayout.baseDirectory.path) else {
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
          let values = try directory.resourceValues(forKeys: [.isDirectoryKey])
          guard values.isDirectory == true else { return nil }
          let manifestURL = directory.appendingPathComponent("clip.json", isDirectory: false)
          guard fileManager.fileExists(atPath: manifestURL.path) else { return nil }
          let data = try Data(contentsOf: manifestURL)
          return try decoder.decode(LocalClipManifest.self, from: data)
        } catch {
          NSLog("LocalClipStore: Skipping corrupt clip at %@ (%@)", directory.path, error.localizedDescription)
          return nil
        }
      }
      .sorted { $0.startedAt > $1.startedAt }
    } catch {
      NSLog("LocalClipStore: Failed to read clips directory %@ (%@)", fileLayout.baseDirectory.path, error.localizedDescription)
      return []
    }
  }

  func save(_ clip: LocalClipManifest) throws {
    try fileLayout.ensureDirectories(fileManager: fileManager, for: clip.id)
    try encoder.encode(clip).write(to: fileLayout.manifestURL(for: clip.id), options: .atomic)
    try writeTranscript(for: clip)
    try clip.postNotes.write(to: fileLayout.notesURL(for: clip.id), atomically: true, encoding: .utf8)
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
    let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: fileLayout.transcriptURL(for: clip.id), options: .atomic)
  }

}
