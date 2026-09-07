import Combine
import Foundation

/// Serializes ownership of local capture across Sessions and CLIPS.
///
/// Callers acquire a lease synchronously, before creating a `Task` or awaiting permission.
/// The lease token prevents a late completion from changing or releasing a newer capture.
@MainActor
final class LocalCaptureLifecycle: ObservableObject {
  enum Kind: String, Equatable, Sendable {
    case session
    case clip

    var displayName: String {
      switch self {
      case .session:
        return "session"
      case .clip:
        return "CLIP"
      }
    }
  }

  struct Lease: Equatable, Sendable {
    let kind: Kind
    fileprivate let token: UUID
  }

  enum Phase: Equatable, Sendable {
    case idle
    case starting(Lease)
    case recording(Lease)
    case stopping(Lease)

    var lease: Lease? {
      switch self {
      case .idle:
        return nil
      case .starting(let lease), .recording(let lease), .stopping(let lease):
        return lease
      }
    }
  }

  enum LifecycleError: LocalizedError, Equatable {
    case captureInProgress(Kind)

    var errorDescription: String? {
      switch self {
      case .captureInProgress(let kind):
        return "Finish the active \(kind.displayName) capture before starting another recording."
      }
    }
  }

  @Published private(set) var phase: Phase = .idle

  var isBusy: Bool {
    phase != .idle
  }

  var activeKind: Kind? {
    phase.lease?.kind
  }

  @discardableResult
  func beginCapture(_ kind: Kind) throws -> Lease {
    guard phase == .idle else {
      throw LifecycleError.captureInProgress(phase.lease?.kind ?? kind)
    }

    let lease = Lease(kind: kind, token: UUID())
    phase = .starting(lease)
    return lease
  }

  /// Returns false for a stale lease or a capture already moving to stop.
  @discardableResult
  func markRecording(_ lease: Lease) -> Bool {
    guard phase == .starting(lease) else { return false }
    phase = .recording(lease)
    return true
  }

  /// Starting captures can be stopped during permission or device setup.
  @discardableResult
  func beginStopping(_ lease: Lease) -> Bool {
    guard phase == .starting(lease) || phase == .recording(lease) else { return false }
    phase = .stopping(lease)
    return true
  }

  /// Releases only the matching generation. Late cleanup cannot clear a newer capture.
  @discardableResult
  func finishCapture(_ lease: Lease) -> Bool {
    guard phase.lease == lease else { return false }
    phase = .idle
    return true
  }
}
