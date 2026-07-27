import Foundation

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
    try fileManager.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
    if let clipID {
      try fileManager.createDirectory(
        at: clipDirectory(for: clipID), withIntermediateDirectories: true)
    }
  }
}
