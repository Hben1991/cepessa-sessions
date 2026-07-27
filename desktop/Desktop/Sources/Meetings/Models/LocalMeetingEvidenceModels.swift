import CoreFoundation
import CryptoKit
import Foundation

enum LocalSessionEvidenceDisposition: String, Codable, Equatable, Sendable {
  case ready
  case degraded
  case failed
}

enum LocalSessionAudioSourceKind: String, Codable, CaseIterable, Equatable, Sendable {
  case microphone
  case system
  case mixed
}

enum LocalSessionSourceIntegrity: String, Codable, Equatable, Sendable {
  case available
  case missing
  case empty
  case invalid
  case truncated
  case intentionallyMuted
}

enum LocalSessionDiarizationStatus: String, Codable, Equatable, Sendable {
  case available
  case unavailable
  case failed
}

enum LocalSessionSpeakerIdentityStatus: String, Codable, Equatable, Sendable {
  case anonymous
  case confirmed
  case unavailable
}

enum LocalSessionTimestampProvenance: String, Codable, Equatable, Sendable {
  case asr
  case unavailable
}

enum LocalSessionTranscriptUncertainty: String, Codable, Equatable, Sendable {
  case low
  case medium
  case high
}

struct LocalSessionTranscriptionEvidenceSummary: Codable, Equatable, Sendable {
  let runID: String
  let revision: Int
  let disposition: LocalSessionEvidenceDisposition
  let contentHash: String
  let parentContentHash: String?
  let runFileName: String
  let outboxFileName: String
  let issues: [String]
}

struct LocalSessionEvidenceModelV1: Codable, Equatable, Sendable {
  let identifier: String
  let modelBasename: String?
}

struct LocalSessionEvidenceRunV1: Codable, Equatable, Sendable {
  let id: String
  let createdAt: Date
  let completedAt: Date
  let disposition: LocalSessionEvidenceDisposition
  let engine: LocalSessionTranscriptionEngineKind
  let model: LocalSessionEvidenceModelV1
  let requestedLanguage: String
  let detectedLanguages: [String]
  let diarizationStatus: LocalSessionDiarizationStatus
  let issues: [String]
}

struct LocalSessionEvidenceSourceV1: Codable, Equatable, Sendable {
  let id: String
  let kind: LocalSessionAudioSourceKind
  let fileName: String
  let role: String
  let integrity: LocalSessionSourceIntegrity
  let durationSeconds: TimeInterval?
  let sha256: String?
  let issues: [String]
}

struct LocalSessionEvidenceSpeakerV1: Codable, Equatable, Sendable {
  let id: String
  let label: String
  let kind: String
  let identityStatus: LocalSessionSpeakerIdentityStatus
  let confidence: Double?
}

struct LocalSessionEvidenceSegmentV1: Codable, Equatable, Sendable {
  let id: String
  let sourceID: String
  let speakerID: String
  let rawASRText: String
  let activeText: String
  let startSeconds: TimeInterval
  let endSeconds: TimeInterval
  let timestampProvenance: LocalSessionTimestampProvenance
  let isTimed: Bool
  let confidence: Double?
  let uncertainty: [String]
  let language: String?

  enum CodingKeys: String, CodingKey {
    case id
    case sourceID = "sourceId"
    case speakerID = "speakerId"
    case rawASRText
    case activeText
    case startSeconds
    case endSeconds
    case timestampProvenance
    case isTimed
    case confidence
    case uncertainty
    case language
  }
}

struct MeetingEvidenceTranscriptByteOffsetV1: Codable, Equatable, Sendable {
  let segmentID: String
  let utf8Start: Int
  let utf8Length: Int

  enum CodingKeys: String, CodingKey {
    case segmentID = "segmentId"
    case utf8Start
    case utf8Length
  }
}

struct MeetingEvidenceTranscriptV1: Codable, Equatable, Sendable {
  let renderedText: String
  let byteOffsets: [MeetingEvidenceTranscriptByteOffsetV1]
}

struct MeetingEvidenceSessionV1: Codable, Equatable, Sendable {
  let id: String
  let title: String
  let startedAt: Date
  let status: LocalSessionStatus
}

struct MeetingEvidenceQualityV1: Codable, Equatable, Sendable {
  let isComplete: Bool
  let speechCoverage: Double?
  let hasVerifiableTimestamps: Bool
  let sourceSeparationPreserved: Bool
  let diarization: String
  let issues: [String]
}

struct MeetingEvidenceEnvelopeV1: Codable, Equatable, Sendable {
  let schemaVersion: String
  let evidenceID: String
  let sourceRef: String
  let revision: Int
  let parentContentHash: String?
  let contentHash: String
  let session: MeetingEvidenceSessionV1
  let run: LocalSessionEvidenceRunV1
  let sources: [LocalSessionEvidenceSourceV1]
  let speakers: [LocalSessionEvidenceSpeakerV1]
  let segments: [LocalSessionEvidenceSegmentV1]
  let transcript: MeetingEvidenceTranscriptV1
  let quality: MeetingEvidenceQualityV1

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

struct MeetingEvidenceHashPayloadV1: Codable, Equatable, Sendable {
  let schemaVersion: String
  let evidenceID: String
  let sourceRef: String
  let revision: Int
  let parentContentHash: String?
  let session: MeetingEvidenceSessionV1
  let run: LocalSessionEvidenceRunV1
  let sources: [LocalSessionEvidenceSourceV1]
  let speakers: [LocalSessionEvidenceSpeakerV1]
  let segments: [LocalSessionEvidenceSegmentV1]
  let transcript: MeetingEvidenceTranscriptV1
  let quality: MeetingEvidenceQualityV1

  init(envelope: MeetingEvidenceEnvelopeV1) {
    schemaVersion = envelope.schemaVersion
    evidenceID = envelope.evidenceID
    sourceRef = envelope.sourceRef
    revision = envelope.revision
    parentContentHash = envelope.parentContentHash
    session = envelope.session
    run = envelope.run
    sources = envelope.sources
    speakers = envelope.speakers
    segments = envelope.segments
    transcript = envelope.transcript
    quality = envelope.quality
  }

  init(
    schemaVersion: String,
    evidenceID: String,
    sourceRef: String,
    revision: Int,
    parentContentHash: String?,
    session: MeetingEvidenceSessionV1,
    run: LocalSessionEvidenceRunV1,
    sources: [LocalSessionEvidenceSourceV1],
    speakers: [LocalSessionEvidenceSpeakerV1],
    segments: [LocalSessionEvidenceSegmentV1],
    transcript: MeetingEvidenceTranscriptV1,
    quality: MeetingEvidenceQualityV1
  ) {
    self.schemaVersion = schemaVersion
    self.evidenceID = evidenceID
    self.sourceRef = sourceRef
    self.revision = revision
    self.parentContentHash = parentContentHash
    self.session = session
    self.run = run
    self.sources = sources
    self.speakers = speakers
    self.segments = segments
    self.transcript = transcript
    self.quality = quality
  }

  enum CodingKeys: String, CodingKey {
    case schemaVersion
    case evidenceID = "evidenceId"
    case sourceRef
    case revision
    case parentContentHash
    case session
    case run
    case sources
    case speakers
    case segments
    case transcript
    case quality
  }
}

struct MeetingEvidenceOutboxEventV1: Codable, Equatable, Sendable {
  let schemaVersion: String
  let eventID: String
  let evidenceID: String
  let sourceRef: String
  let revision: Int
  let contentHash: String
  let createdAt: Date
  let envelopeFileName: String

  enum CodingKeys: String, CodingKey {
    case schemaVersion
    case eventID = "eventId"
    case evidenceID = "evidenceId"
    case sourceRef
    case revision
    case contentHash
    case createdAt
    case envelopeFileName
  }
}

enum LocalSessionStableID {
  static func string(namespace: String, components: [String]) -> String {
    uuid(namespace: namespace, components: components).uuidString.lowercased()
  }

  static func uuid(namespace: String, components: [String]) -> UUID {
    let input = ([namespace] + components).joined(separator: "\u{001f}")
    let digest = SHA256.hash(data: Data(input.utf8))
    var bytes = Array(digest.prefix(16))
    bytes[6] = (bytes[6] & 0x0f) | 0x50
    bytes[8] = (bytes[8] & 0x3f) | 0x80
    return UUID(
      uuid: (
        bytes[0], bytes[1], bytes[2], bytes[3],
        bytes[4], bytes[5], bytes[6], bytes[7],
        bytes[8], bytes[9], bytes[10], bytes[11],
        bytes[12], bytes[13], bytes[14], bytes[15]
      ))
  }

  static func sha256(_ text: String) -> String {
    SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
  }
}

enum MeetingEvidenceCanonicalizer {
  /// JSON numbers in meeting evidence are deliberately bounded so quantization
  /// remains exactly representable as an Int64 in every supported consumer.
  static let numericScale: Int64 = 1_000_000
  static let maximumCanonicalNumber = 1_000_000_000.0

  static func canonicalData(payload: MeetingEvidenceHashPayloadV1) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    let encoded = try encoder.encode(payload)
    let object = try JSONSerialization.jsonObject(with: encoded)
    return try canonicalData(jsonValue: object)
  }

  static func canonicalData(envelopeData: Data) throws -> Data {
    guard var object = try JSONSerialization.jsonObject(with: envelopeData) as? [String: Any] else {
      throw CocoaError(.coderReadCorrupt)
    }
    guard object.removeValue(forKey: "contentHash") != nil else {
      throw CocoaError(.coderValueNotFound)
    }
    return try canonicalData(jsonValue: object)
  }

  static func contentHash(payload: MeetingEvidenceHashPayloadV1) throws -> String {
    try contentHash(canonicalData: canonicalData(payload: payload))
  }

  static func contentHash(envelopeData: Data) throws -> String {
    try contentHash(canonicalData: canonicalData(envelopeData: envelopeData))
  }

  private static func contentHash(canonicalData: Data) -> String {
    SHA256.hash(data: canonicalData).map { String(format: "%02x", $0) }.joined()
  }

  private static func canonicalData(jsonValue: Any) throws -> Data {
    let normalized = try normalizedJSONValue(jsonValue)
    return try JSONSerialization.data(
      withJSONObject: normalized,
      options: [.sortedKeys, .withoutEscapingSlashes]
    )
  }

  private static func normalizedJSONValue(_ value: Any) throws -> Any {
    if value is NSNull || value is String {
      return value
    }
    if let number = value as? NSNumber {
      if CFGetTypeID(number) == CFBooleanGetTypeID() {
        return number.boolValue
      }
      return try canonicalNumberString(number.doubleValue)
    }
    if let boolean = value as? Bool {
      return boolean
    }
    if let array = value as? [Any] {
      return try array.map(normalizedJSONValue)
    }
    if let dictionary = value as? [String: Any] {
      return try dictionary.mapValues(normalizedJSONValue)
    }
    throw CocoaError(.coderInvalidValue)
  }

  /// Canonicalizes every evidence number using integer micro-units:
  /// `q = floor(value * 1_000_000 + 0.5)`.
  ///
  /// This intentionally avoids language- and libc-dependent decimal formatter
  /// rounding. Evidence numbers are nonnegative and bounded before hashing.
  static func canonicalNumberString(_ value: Double) throws -> String {
    guard value.isFinite, value >= 0, value <= maximumCanonicalNumber else {
      throw CocoaError(.coderInvalidValue)
    }

    let quantized = Int64(floor(value * Double(numericScale) + 0.5))
    let whole = quantized / numericScale
    let remainder = quantized % numericScale
    guard remainder != 0 else {
      return String(whole)
    }

    var fraction = String(remainder)
    fraction = String(repeating: "0", count: 6 - fraction.count) + fraction
    while fraction.last == "0" {
      fraction.removeLast()
    }
    return "\(whole).\(fraction)"
  }
}

enum MeetingEvidenceTranscriptRenderer {
  static func render(
    segments: [LocalSessionEvidenceSegmentV1],
    speakers: [LocalSessionEvidenceSpeakerV1]
  ) -> MeetingEvidenceTranscriptV1 {
    let labels = Dictionary(uniqueKeysWithValues: speakers.map { ($0.id, $0.label) })
    var renderedText = ""
    var offsets: [MeetingEvidenceTranscriptByteOffsetV1] = []

    for segment in segments {
      let line = "\(labels[segment.speakerID] ?? "Speaker"): \(segment.activeText)\n"
      let prefix = "\(labels[segment.speakerID] ?? "Speaker"): "
      let start = renderedText.utf8.count + prefix.utf8.count
      renderedText += line
      offsets.append(
        .init(segmentID: segment.id, utf8Start: start, utf8Length: segment.activeText.utf8.count)
      )
    }

    return .init(renderedText: renderedText, byteOffsets: offsets)
  }
}
