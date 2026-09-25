import Foundation

/// Reads finished-session evidence from the Sessions outbox and verifies it.
///
/// The outbox is append-only: Sessions writes one immutable envelope per
/// evidence revision (`<event id>.json`) and never rewrites one in place. A
/// reader therefore needs no lock; it lists the directory, verifies each
/// envelope against its own content hash, and picks one revision per
/// recording the way Sessions itself does: the newest ready revision, so a
/// failed "Transcribe Again" never hides a good transcript, or the newest
/// revision when none is ready yet.
///
/// Nothing here writes, moves or deletes a file.
public struct SessionsOutboxReader: Sendable {
  public enum Rejection: Error, Equatable, Sendable {
    /// Not a regular file (a link, a directory) or larger than the limit.
    case unsafeFile
    case unreadable
    case unsupportedSchema(String)
    /// The stored hash does not match the canonical bytes.
    case contentHashMismatch
  }

  public struct RejectedFile: Equatable, Sendable {
    public let fileName: String
    public let reason: Rejection

    public init(fileName: String, reason: Rejection) {
      self.fileName = fileName
      self.reason = reason
    }
  }

  public struct Snapshot: Equatable, Sendable {
    /// One verified revision per recording (see the type's notes), newest
    /// recording first.
    public let evidence: [SessionsEvidence]
    /// Files that were skipped, with the reason. Never silently dropped.
    public let rejected: [RejectedFile]

    public init(evidence: [SessionsEvidence], rejected: [RejectedFile]) {
      self.evidence = evidence
      self.rejected = rejected
    }
  }

  /// Envelopes carry a full transcript; anything past this is not ours.
  public static let maximumEnvelopeBytes = 64 * 1024 * 1024

  public let outboxDirectory: URL

  public init(baseDirectory: URL = SessionsHandoff.defaultBaseDirectory) {
    self.outboxDirectory = baseDirectory.appendingPathComponent(
      SessionsHandoff.outboxDirectoryName, isDirectory: true)
  }

  /// Lists the outbox. A missing outbox is an empty snapshot, not an error.
  public func snapshot() throws -> Snapshot {
    let fileManager = FileManager.default
    guard fileManager.fileExists(atPath: outboxDirectory.path) else {
      return Snapshot(evidence: [], rejected: [])
    }

    let entries = try fileManager.contentsOfDirectory(
      at: outboxDirectory,
      includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
      options: [.skipsHiddenFiles]
    )
    .filter { $0.pathExtension == "json" }
    .sorted { $0.lastPathComponent < $1.lastPathComponent }

    // Every run has its own evidence ID; the recording is the session.
    var chosen: [String: SessionsEvidence] = [:]
    var rejected: [RejectedFile] = []

    for url in entries {
      switch Result(catching: { try evidence(at: url) }) {
      case .success(let evidence):
        let recording = evidence.session.id.lowercased()
        if let current = chosen[recording], !Self.isPreferred(evidence, over: current) {
          continue
        }
        chosen[recording] = evidence
      case .failure(let error):
        rejected.append(
          RejectedFile(
            fileName: url.lastPathComponent,
            reason: (error as? Rejection) ?? .unreadable))
      }
    }

    let ordered = chosen.values.sorted { $0.session.startedAt > $1.session.startedAt }
    return Snapshot(evidence: ordered, rejected: rejected)
  }

  /// Decodes and verifies one envelope.
  public func evidence(at url: URL) throws -> SessionsEvidence {
    let values = try? url.resourceValues(forKeys: [
      .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
    ])
    guard values?.isSymbolicLink != true, values?.isRegularFile == true,
      (values?.fileSize ?? .max) <= Self.maximumEnvelopeBytes
    else {
      throw Rejection.unsafeFile
    }

    let data: Data
    do {
      data = try Data(contentsOf: url, options: [.mappedIfSafe])
    } catch {
      throw Rejection.unreadable
    }
    return try Self.verifiedEvidence(from: data)
  }

  /// Decodes an envelope and checks its schema and content hash.
  public static func verifiedEvidence(from data: Data) throws -> SessionsEvidence {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let evidence: SessionsEvidence
    do {
      evidence = try decoder.decode(SessionsEvidence.self, from: data)
    } catch {
      throw Rejection.unreadable
    }
    guard evidence.schemaVersion == SessionsHandoff.schemaVersion else {
      throw Rejection.unsupportedSchema(evidence.schemaVersion)
    }
    guard
      let hash = try? SessionsEvidenceCanonicalizer.contentHash(envelopeData: data),
      hash == evidence.contentHash
    else {
      throw Rejection.contentHashMismatch
    }
    return evidence
  }

  static func isPreferred(_ candidate: SessionsEvidence, over current: SessionsEvidence) -> Bool {
    let candidateIsReady = candidate.run.disposition == "ready"
    if candidateIsReady != (current.run.disposition == "ready") {
      return candidateIsReady
    }
    if candidate.revision != current.revision {
      return candidate.revision > current.revision
    }
    return candidate.run.completedAt > current.run.completedAt
  }
}
