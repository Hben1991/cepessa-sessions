import Foundation

/// Where Sessions leaves finished-session evidence for other apps.
public enum SessionsHandoff {
  /// The envelope schema this library understands.
  public static let schemaVersion = "meeting-evidence/v1"
  /// Directory, under the Sessions base directory, holding one immutable
  /// envelope per published evidence revision.
  public static let outboxDirectoryName = "MeetingEvidenceOutbox"

  /// `~/Library/Application Support/Cepessa`, shared by Sessions and Cepessa.
  public static var defaultBaseDirectory: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library", isDirectory: true)
      .appendingPathComponent("Application Support", isDirectory: true)
      .appendingPathComponent("Cepessa", isDirectory: true)
  }
}

/// A finished (or honestly failed) transcription of one Sessions recording, as
/// published to the outbox. A read model: every field mirrors
/// `meeting-evidence/v1`, and enumerations are kept as strings so a newer
/// writer never makes an older reader fail.
public struct SessionsEvidence: Decodable, Equatable, Sendable {
  public let schemaVersion: String
  /// Stable per recording; revisions of the same recording share it.
  public let evidenceID: String
  public let sourceRef: String
  /// Increases each time the recording is transcribed again.
  public let revision: Int
  public let parentContentHash: String?
  /// SHA-256 of the canonical envelope. Verified by `SessionsOutboxReader`.
  public let contentHash: String
  public let session: Session
  public let run: Run
  public let sources: [Source]
  public let speakers: [Speaker]
  public let segments: [Segment]
  public let transcript: Transcript
  public let quality: Quality

  public struct Session: Decodable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let startedAt: Date
    /// `recording`, `transcribing`, `ready` or `failed`.
    public let status: String
  }

  public struct Run: Decodable, Equatable, Sendable {
    public let id: String
    public let createdAt: Date
    public let completedAt: Date
    /// `ready`, `degraded` or `failed`.
    public let disposition: String
    public let engine: String
    public let model: Model
    public let requestedLanguage: String
    public let detectedLanguages: [String]
    public let diarizationStatus: String
    public let issues: [String]

    public struct Model: Decodable, Equatable, Sendable {
      public let identifier: String
      public let modelBasename: String?
    }
  }

  public struct Source: Decodable, Equatable, Sendable {
    public let id: String
    /// `microphone`, `system`, `mixed` or `imported`.
    public let kind: String
    public let fileName: String
    public let role: String
    public let integrity: String
    public let durationSeconds: Double?
    public let sha256: String?
    public let issues: [String]
  }

  public struct Speaker: Decodable, Equatable, Sendable {
    public let id: String
    public let label: String
    public let kind: String
    public let identityStatus: String
    public let confidence: Double?
  }

  public struct Segment: Decodable, Equatable, Sendable {
    public let id: String
    public let sourceID: String
    public let speakerID: String
    /// The words as the recognizer produced them.
    public let rawASRText: String
    /// The words after the owner's local corrections. Prefer this.
    public let activeText: String
    public let startSeconds: Double
    public let endSeconds: Double
    public let isTimed: Bool
    public let confidence: Double?
    public let language: String?

    enum CodingKeys: String, CodingKey {
      case id
      case sourceID = "sourceId"
      case speakerID = "speakerId"
      case rawASRText
      case activeText
      case startSeconds
      case endSeconds
      case isTimed
      case confidence
      case language
    }
  }

  public struct Transcript: Decodable, Equatable, Sendable {
    /// `Speaker: words` lines in segment order.
    public let renderedText: String
  }

  public struct Quality: Decodable, Equatable, Sendable {
    /// True only when coverage and timing were verified against the audio.
    public let isComplete: Bool
    public let speechCoverage: Double?
    public let hasVerifiableTimestamps: Bool
    public let sourceSeparationPreserved: Bool
    public let diarization: String
    public let issues: [String]
  }

  /// The run produced words and did not fail. Check `quality.isComplete`
  /// before treating the text as a full record of the recording.
  public var isUsable: Bool {
    run.disposition != "failed" && !segments.isEmpty
  }

  enum CodingKeys: String, CodingKey {
    case schemaVersion
    case evidenceID = "evidenceId"
    case sourceRef
    case revision
    case parentContentHash
    case contentHash
    case session
    case run
    case sources
    case speakers
    case segments
    case transcript
    case quality
  }
}
