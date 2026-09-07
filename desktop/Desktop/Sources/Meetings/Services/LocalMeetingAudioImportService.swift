import AVFoundation
import Foundation

protocol LocalSessionAudioImporting: Sendable {
  func importAudio(from sourceURL: URL, to destinationWavURL: URL) async throws
}

enum LocalSessionAudioImportError: LocalizedError {
  case unsupportedSource(String)
  case conversionFailed(String)

  var errorDescription: String? {
    switch self {
    case .unsupportedSource(let message), .conversionFailed(let message):
      return message
    }
  }
}

struct LocalSessionAudioImportService: LocalSessionAudioImporting {
  func importAudio(from sourceURL: URL, to destinationWavURL: URL) async throws {
    try await Task.detached(priority: .userInitiated) {
      try convertToCanonicalWav(sourceURL: sourceURL, destinationWavURL: destinationWavURL)
    }.value
  }

  private func convertToCanonicalWav(sourceURL: URL, destinationWavURL: URL) throws {
    let inputFile = try AVAudioFile(forReading: sourceURL)
    let inputFormat = inputFile.processingFormat
    guard
      let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
      )
    else {
      throw LocalSessionAudioImportError.conversionFailed(
        "Could not build the target audio format.")
    }

    guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
      throw LocalSessionAudioImportError.unsupportedSource(
        "Sessions could not convert this recording format."
      )
    }

    let sourceFrameCapacity: AVAudioFrameCount = 4_096
    let outputFrameCapacity = AVAudioFrameCount(
      max(
        1,
        Int(Double(sourceFrameCapacity) * (targetFormat.sampleRate / inputFormat.sampleRate))
          .advanced(by: 64))
    )
    let writer = try LocalMeetingWaveFileWriter(fileURL: destinationWavURL)
    defer { try? writer.close() }

    let inputProvider = LocalSessionAudioImportInputProvider(inputFile: inputFile)

    while true {
      guard
        let outputBuffer = AVAudioPCMBuffer(
          pcmFormat: targetFormat, frameCapacity: outputFrameCapacity)
      else {
        throw LocalSessionAudioImportError.conversionFailed(
          "Could not allocate the converted audio buffer.")
      }

      var conversionError: NSError?
      let status = converter.convert(to: outputBuffer, error: &conversionError) {
        requestedPacketCount, outStatus in
        inputProvider.provide(
          requestedPacketCount: requestedPacketCount,
          outStatus: outStatus
        )
      }

      if let readError = inputProvider.failure {
        throw LocalSessionAudioImportError.conversionFailed(
          "Sessions could not read this recording: \(readError.localizedDescription)"
        )
      }
      if let conversionError {
        throw LocalSessionAudioImportError.conversionFailed(conversionError.localizedDescription)
      }

      if outputBuffer.frameLength > 0 {
        try writer.append(samples: pcm16Samples(from: outputBuffer))
      }

      if status == .endOfStream {
        break
      }
    }
  }

  private func pcm16Samples(from buffer: AVAudioPCMBuffer) -> [Int16] {
    guard let floatChannelData = buffer.floatChannelData else { return [] }
    let samples = UnsafeBufferPointer(start: floatChannelData[0], count: Int(buffer.frameLength))
    return samples.map { sample in
      let scaled = Int((sample * 32_767.0).rounded())
      let clamped = max(Int(Int16.min), min(Int(Int16.max), scaled))
      return Int16(clamped)
    }
  }
}

final class LocalSessionAudioImportInputProvider {
  private let inputFormat: AVAudioFormat
  private let sourceFrameCapacity: AVAudioFrameCount
  private let remainingFrames: () -> AVAudioFramePosition
  private let readFrames: (AVAudioPCMBuffer, AVAudioFrameCount) throws -> Void
  private(set) var reachedEndOfSource = false
  private(set) var failure: Error?

  convenience init(inputFile: AVAudioFile, sourceFrameCapacity: AVAudioFrameCount = 4_096) {
    self.init(
      inputFormat: inputFile.processingFormat,
      sourceFrameCapacity: sourceFrameCapacity,
      remainingFrames: { max(0, inputFile.length - inputFile.framePosition) },
      readFrames: { buffer, frameCount in
        try inputFile.read(into: buffer, frameCount: frameCount)
      }
    )
  }

  init(
    inputFormat: AVAudioFormat,
    sourceFrameCapacity: AVAudioFrameCount = 4_096,
    remainingFrames: @escaping () -> AVAudioFramePosition,
    readFrames: @escaping (AVAudioPCMBuffer, AVAudioFrameCount) throws -> Void
  ) {
    self.inputFormat = inputFormat
    self.sourceFrameCapacity = sourceFrameCapacity
    self.remainingFrames = remainingFrames
    self.readFrames = readFrames
  }

  func provide(
    requestedPacketCount: AVAudioPacketCount,
    outStatus: UnsafeMutablePointer<AVAudioConverterInputStatus>
  ) -> AVAudioBuffer? {
    guard !reachedEndOfSource else {
      outStatus.pointee = .endOfStream
      return nil
    }

    let availableFrames = remainingFrames()
    guard availableFrames > 0 else {
      reachedEndOfSource = true
      outStatus.pointee = .endOfStream
      return nil
    }

    let requestedFrames =
      requestedPacketCount > 0
      ? AVAudioFrameCount(requestedPacketCount)
      : sourceFrameCapacity
    let availableFrameCount = AVAudioFrameCount(
      min(availableFrames, AVAudioFramePosition(sourceFrameCapacity))
    )
    let frameCount = min(
      sourceFrameCapacity,
      min(requestedFrames, availableFrameCount)
    )
    guard frameCount > 0,
      let buffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: frameCount)
    else {
      recordFailure(
        LocalSessionAudioImportError.conversionFailed(
          "Could not allocate the source audio buffer."
        ),
        outStatus: outStatus
      )
      return nil
    }

    do {
      try readFrames(buffer, frameCount)
    } catch {
      recordFailure(error, outStatus: outStatus)
      return nil
    }

    guard buffer.frameLength > 0 else {
      reachedEndOfSource = true
      outStatus.pointee = .endOfStream
      return nil
    }
    outStatus.pointee = .haveData
    return buffer
  }

  private func recordFailure(
    _ error: Error,
    outStatus: UnsafeMutablePointer<AVAudioConverterInputStatus>
  ) {
    failure = error
    reachedEndOfSource = true
    outStatus.pointee = .endOfStream
  }
}
