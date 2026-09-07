import Foundation

enum MicrophoneCaptureFrameType: UInt8 {
  case hello = 1
  case status = 2
  case pcm = 3
  case level = 4
  case failure = 5
}

struct MicrophoneCaptureFrame: Equatable {
  let type: MicrophoneCaptureFrameType
  let payload: Data
}

struct MicrophoneCaptureFrameDecoder {
  private(set) var buffer = Data()
  private let maximumPayloadSize = 1_048_576

  mutating func append(_ data: Data) throws -> [MicrophoneCaptureFrame] {
    buffer.append(data)
    var frames: [MicrophoneCaptureFrame] = []
    while buffer.count >= 5 {
      guard let type = MicrophoneCaptureFrameType(rawValue: buffer[0]) else {
        throw MicrophoneCaptureProcessError.invalidProtocol("unknown frame type")
      }
      let length = buffer[1..<5].enumerated().reduce(UInt32(0)) {
        $0 | (UInt32($1.element) << UInt32($1.offset * 8))
      }
      guard length <= maximumPayloadSize else {
        throw MicrophoneCaptureProcessError.invalidProtocol("oversized frame")
      }
      let end = 5 + Int(length)
      guard buffer.count >= end else { break }
      frames.append(.init(type: type, payload: buffer.subdata(in: 5..<end)))
      buffer.removeSubrange(0..<end)
    }
    return frames
  }
}

enum MicrophoneCaptureProcessError: LocalizedError, Equatable {
  case helperNotFound
  case launchFailed(String)
  case handshakeTimedOut
  case firstAudioTimedOut
  case invalidProtocol(String)
  case helperFailed(String)
  case helperExited(Int32)

  var errorDescription: String? {
    switch self {
    case .helperNotFound:
      return "The microphone capture helper is missing. Reinstall Sessions and try again."
    case .launchFailed(let detail):
      return "The microphone helper could not start: \(detail)"
    case .handshakeTimedOut:
      return "The microphone helper did not respond in time. Recording was not started."
    case .firstAudioTimedOut:
      return
        "Live meeting capture has no usable audio input. Check the selected microphone and try again."
    case .invalidProtocol(let detail):
      return "The microphone helper returned invalid data: \(detail)"
    case .helperFailed(let detail):
      return detail
    case .helperExited(let status):
      return "The microphone helper exited unexpectedly (\(status))."
    }
  }
}
