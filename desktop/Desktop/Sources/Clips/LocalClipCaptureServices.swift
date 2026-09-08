import AVFoundation
import Darwin
import Foundation

@MainActor
protocol LocalClipAudioRecording: AnyObject {
  func startRecording(title: String?) async throws -> LocalSession
  func stopRecording() async -> LocalSession?
}

extension LocalMeetingRecorder: LocalClipAudioRecording {}

struct LocalClipScreenCaptureStopResult: Equatable, Sendable {
  enum Outcome: Equatable, Sendable {
    case notRunning
    case stopped
    case forcedTermination
    case timedOut
  }

  let outcome: Outcome
  let terminationStatus: Int32?

  var failureMessage: String? {
    switch outcome {
    case .notRunning:
      return "Screen capture ended before the CLIP was stopped."
    case .stopped:
      return nil
    case .forcedTermination:
      return "Screen capture did not finish normally, so Sessions forced it to stop."
    case .timedOut:
      return "Screen capture could not be stopped within the safety limit."
    }
  }
}

@MainActor
protocol LocalClipScreenRecording: AnyObject {
  func startRecording(
    to videoURL: URL,
    onUnexpectedExit: @escaping @MainActor (String) -> Void
  ) throws
  func stopRecording() async -> LocalClipScreenCaptureStopResult
}

@MainActor
final class LocalClipScreenCaptureProcess: LocalClipScreenRecording {
  private let gracefulStopTimeout: TimeInterval
  private let forcedStopTimeout: TimeInterval
  private var process: Process?
  private var generation: UInt = 0
  private var stopRequested = false
  private var unexpectedExitHandler: (@MainActor (String) -> Void)?

  init(gracefulStopTimeout: TimeInterval = 2, forcedStopTimeout: TimeInterval = 1) {
    self.gracefulStopTimeout = gracefulStopTimeout
    self.forcedStopTimeout = forcedStopTimeout
  }

  func startRecording(
    to videoURL: URL,
    onUnexpectedExit: @escaping @MainActor (String) -> Void
  ) throws {
    guard process == nil else {
      throw LocalClipScreenCaptureError.alreadyRunning
    }

    generation &+= 1
    let token = generation
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    process.arguments = ["-v", "-k", "-x", videoURL.path]
    stopRequested = false
    unexpectedExitHandler = onUnexpectedExit
    self.process = process
    process.terminationHandler = { [weak self] terminatedProcess in
      let status = terminatedProcess.terminationStatus
      Task { @MainActor in
        self?.handleTermination(of: terminatedProcess, status: status, token: token)
      }
    }

    do {
      try process.run()
    } catch {
      self.process = nil
      unexpectedExitHandler = nil
      throw LocalClipScreenCaptureError.launchFailed(error.localizedDescription)
    }
  }

  func stopRecording() async -> LocalClipScreenCaptureStopResult {
    guard let process else {
      return LocalClipScreenCaptureStopResult(outcome: .notRunning, terminationStatus: nil)
    }

    stopRequested = true
    if !process.isRunning {
      let status = process.terminationStatus
      clear(process)
      return LocalClipScreenCaptureStopResult(outcome: .notRunning, terminationStatus: status)
    }

    // `screencapture -v` finalizes the movie on SIGINT, the same signal as Control-C.
    process.interrupt()
    if await waitForExit(process, timeout: gracefulStopTimeout) {
      let status = process.terminationStatus
      clear(process)
      return LocalClipScreenCaptureStopResult(outcome: .stopped, terminationStatus: status)
    }

    process.terminate()
    if await waitForExit(process, timeout: forcedStopTimeout) {
      let status = process.terminationStatus
      clear(process)
      return LocalClipScreenCaptureStopResult(
        outcome: .forcedTermination,
        terminationStatus: status
      )
    }

    Darwin.kill(process.processIdentifier, SIGKILL)
    let didExit = await waitForExit(process, timeout: forcedStopTimeout)
    let status = didExit ? process.terminationStatus : nil
    clear(process)
    return LocalClipScreenCaptureStopResult(
      outcome: didExit ? .forcedTermination : .timedOut,
      terminationStatus: status
    )
  }

  private func waitForExit(_ process: Process, timeout: TimeInterval) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while process.isRunning, Date() < deadline {
      try? await Task.sleep(for: .milliseconds(20))
    }
    return !process.isRunning
  }

  private func handleTermination(of process: Process, status: Int32, token: UInt) {
    guard token == generation, self.process === process else { return }
    guard !stopRequested else { return }
    let handler = unexpectedExitHandler
    clear(process)
    handler?(LocalClipScreenCaptureError.unexpectedExit(status).localizedDescription)
  }

  private func clear(_ process: Process) {
    guard self.process === process else { return }
    self.process = nil
    unexpectedExitHandler = nil
    stopRequested = false
  }
}

enum LocalClipScreenCaptureError: LocalizedError, Equatable {
  case alreadyRunning
  case launchFailed(String)
  case unexpectedExit(Int32)

  var errorDescription: String? {
    switch self {
    case .alreadyRunning:
      return "Screen capture is already running."
    case .launchFailed(let detail):
      return "Screen capture could not start. \(detail)"
    case .unexpectedExit(let status):
      return "Screen capture stopped unexpectedly (status \(status))."
    }
  }
}

enum LocalClipVideoValidator {
  static func failureReason(for url: URL, fileManager: FileManager = .default) async -> String? {
    guard fileManager.fileExists(atPath: url.path) else {
      return
        "CLIP capture did not produce a video file. Grant Screen Recording access and try again."
    }
    guard LocalClipFileSafety.isSafeExistingRegularFile(at: url) else {
      return "CLIP capture produced an unsafe video file. Record the CLIP again."
    }
    guard
      let attributes = try? fileManager.attributesOfItem(atPath: url.path),
      let size = attributes[.size] as? NSNumber,
      size.int64Value > 0
    else {
      return "CLIP capture produced an empty video file. Record the CLIP again."
    }

    let asset = AVURLAsset(url: url)
    guard
      let isPlayable = try? await asset.load(.isPlayable),
      let duration = try? await asset.load(.duration).seconds,
      isPlayable,
      duration.isFinite,
      duration > 0
    else {
      return "CLIP capture produced a video that cannot be played. Record the CLIP again."
    }
    guard
      let videoTrack = try? await asset.loadTracks(withMediaType: .video).first,
      let naturalSize = try? await videoTrack.load(.naturalSize),
      let preferredTransform = try? await videoTrack.load(.preferredTransform)
    else {
      return "CLIP capture produced a movie without a usable video track. Record the CLIP again."
    }
    let transformedSize = naturalSize.applying(preferredTransform)
    guard transformedSize.width.isFinite,
      transformedSize.height.isFinite,
      abs(transformedSize.width) > 0,
      abs(transformedSize.height) > 0
    else {
      return "CLIP capture produced a movie without usable video dimensions. Record the CLIP again."
    }
    return nil
  }
}

enum LocalClipAudioValidator {
  static func failureReason(for url: URL, fileManager: FileManager = .default) -> String? {
    guard fileManager.fileExists(atPath: url.path) else {
      return "CLIP video was saved, but no audio file was available for transcription."
    }
    guard let data = try? LocalClipFileSafety.readRegularFile(at: url), data.count >= 44 else {
      return "CLIP video was saved, but its audio file is empty or unreadable."
    }
    guard data[0..<4] == Data("RIFF".utf8), data[8..<12] == Data("WAVE".utf8) else {
      return "CLIP video was saved, but its audio file is not a valid WAV recording."
    }
    return dataChunkFailureReason(data: data)
  }

  static func duration(for url: URL, fileManager: FileManager = .default) -> TimeInterval? {
    guard failureReason(for: url, fileManager: fileManager) == nil,
      let data = try? LocalClipFileSafety.readRegularFile(at: url),
      data.count >= 44
    else {
      return nil
    }
    let byteRate = data[28..<32].withUnsafeBytes {
      $0.loadUnaligned(as: UInt32.self).littleEndian
    }
    guard byteRate > 0 else { return nil }

    var offset = 12
    while offset + 8 <= data.count {
      let chunkSize = data[(offset + 4)..<(offset + 8)].withUnsafeBytes {
        $0.loadUnaligned(as: UInt32.self).littleEndian
      }
      if data[offset..<(offset + 4)] == Data("data".utf8) {
        let duration = Double(chunkSize) / Double(byteRate)
        return duration.isFinite && duration > 0 ? duration : nil
      }
      let paddedSize = Int(chunkSize) + (chunkSize.isMultiple(of: 2) ? 0 : 1)
      guard paddedSize <= data.count - offset - 8 else { return nil }
      offset += 8 + paddedSize
    }
    return nil
  }

  private static func dataChunkFailureReason(data: Data) -> String? {
    var offset = 12
    var chunksInspected = 0
    while offset + 8 <= data.count, chunksInspected < 64 {
      let chunkID = data[offset..<(offset + 4)]
      let chunkSize = data[(offset + 4)..<(offset + 8)].withUnsafeBytes {
        $0.loadUnaligned(as: UInt32.self).littleEndian
      }
      let payloadStart = offset + 8
      guard Int(chunkSize) <= data.count - payloadStart else {
        return "CLIP video was saved, but its audio file is truncated."
      }
      if chunkID == Data("data".utf8) {
        return chunkSize > 0
          ? nil
          : "CLIP video was saved, but its audio recording contains no samples."
      }
      let paddedSize = Int(chunkSize) + (chunkSize.isMultiple(of: 2) ? 0 : 1)
      guard paddedSize <= data.count - payloadStart else {
        return "CLIP video was saved, but its audio file is truncated."
      }
      offset = payloadStart + paddedSize
      chunksInspected += 1
    }
    return "CLIP video was saved, but its audio file has no usable sample data."
  }
}

enum LocalClipTranscriptValidator {
  static func usableSegments(
    from transcriptionSegments: [LocalSessionTranscriptionSegment],
    audioDuration: TimeInterval,
    endTolerance: TimeInterval = 0.25
  ) -> [LocalClipTranscriptSegment] {
    guard audioDuration.isFinite, audioDuration > 0 else { return [] }
    return transcriptionSegments.compactMap { segment in
      let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
      guard
        !text.isEmpty,
        segment.startTime.isFinite,
        segment.endTime.isFinite,
        segment.startTime >= 0,
        segment.endTime > segment.startTime,
        segment.endTime <= audioDuration + endTolerance
      else {
        return nil
      }
      return LocalClipTranscriptSegment(
        id: UUID(),
        startOffset: segment.startTime,
        endOffset: segment.endTime,
        text: text
      )
    }
  }

  static func hasUsableSegments(
    _ segments: [LocalClipTranscriptSegment],
    audioDuration: TimeInterval,
    endTolerance: TimeInterval = 0.25
  ) -> Bool {
    guard audioDuration.isFinite, audioDuration > 0 else { return false }
    return segments.contains { segment in
      !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && segment.startOffset.isFinite
        && segment.endOffset.isFinite
        && segment.startOffset >= 0
        && segment.endOffset > segment.startOffset
        && segment.endOffset <= audioDuration + endTolerance
    }
  }
}
