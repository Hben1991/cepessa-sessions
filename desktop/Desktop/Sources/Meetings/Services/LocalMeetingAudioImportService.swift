import AVFoundation
import Foundation
import OSLog

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
  private static let logger = Logger(
    subsystem: "com.cepessa.sessions",
    category: "AudioImport"
  )

  func importAudio(from sourceURL: URL, to destinationWavURL: URL) async throws {
    try await Task.detached(priority: .userInitiated) {
      try convertToCanonicalWav(sourceURL: sourceURL, destinationWavURL: destinationWavURL)
    }.value
  }

  private func convertToCanonicalWav(sourceURL: URL, destinationWavURL: URL) throws {
    let inputFile: AVAudioFile
    do {
      inputFile = try AVAudioFile(forReading: sourceURL)
    } catch {
      logUnderlying(error, stage: "open", sourceURL: sourceURL)
      throw LocalSessionAudioImportError.unsupportedSource(
        "Sessions could not open this audio file. It may be damaged or use an unsupported format. Import another WAV, MP3, or M4A file."
      )
    }
    let inputFormat = inputFile.processingFormat
    guard inputFormat.sampleRate.isFinite, inputFormat.sampleRate > 0 else {
      Self.logger.error(
        "Audio import rejected an invalid sample rate for \(sourceURL.lastPathComponent, privacy: .public)."
      )
      throw LocalSessionAudioImportError.unsupportedSource(
        "Sessions could not open this audio file. It may be damaged or use an unsupported format. Import another WAV, MP3, or M4A file."
      )
    }
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
      Self.logger.error(
        "Audio import could not create a converter for \(sourceURL.lastPathComponent, privacy: .public)."
      )
      throw LocalSessionAudioImportError.unsupportedSource(
        "Sessions could not open this audio file. It may be damaged or use an unsupported format. Import another WAV, MP3, or M4A file."
      )
    }

    let sourceFrameCapacity: AVAudioFrameCount = 4_096
    let outputFrameCapacity = AVAudioFrameCount(
      max(
        1,
        Int(Double(sourceFrameCapacity) * (targetFormat.sampleRate / inputFormat.sampleRate))
          .advanced(by: 64))
    )
    let writer: LocalMeetingWaveFileWriter
    do {
      writer = try LocalMeetingWaveFileWriter(fileURL: destinationWavURL)
    } catch {
      logUnderlying(error, stage: "prepare destination", sourceURL: sourceURL)
      throw LocalSessionAudioImportError.conversionFailed(
        "Sessions could not prepare the imported WAV file. Try importing the audio again."
      )
    }
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
        logUnderlying(readError, stage: "read", sourceURL: sourceURL)
        throw LocalSessionAudioImportError.conversionFailed(
          "Sessions could not finish reading this audio file. It may be damaged. Import another WAV, MP3, or M4A file."
        )
      }
      if let conversionError {
        logUnderlying(conversionError, stage: "convert", sourceURL: sourceURL)
        throw LocalSessionAudioImportError.conversionFailed(
          "Sessions could not finish converting this audio file. Import another WAV, MP3, or M4A file."
        )
      }
      if status == .error {
        Self.logger.error(
          "Audio import conversion failed without an AVFoundation diagnostic for \(sourceURL.lastPathComponent, privacy: .public)."
        )
        throw LocalSessionAudioImportError.conversionFailed(
          "Sessions could not finish converting this audio file. Import another WAV, MP3, or M4A file."
        )
      }

      if outputBuffer.frameLength > 0 {
        let samples = try pcm16Samples(from: outputBuffer)
        do {
          try writer.append(samples: samples)
        } catch {
          logUnderlying(error, stage: "write destination", sourceURL: sourceURL)
          throw LocalSessionAudioImportError.conversionFailed(
            "Sessions could not finish writing the imported WAV file. Try importing the audio again."
          )
        }
      }

      if status == .endOfStream {
        break
      }
    }
  }

  func pcm16Samples(from buffer: AVAudioPCMBuffer) throws -> [Int16] {
    guard let floatChannelData = buffer.floatChannelData else {
      throw LocalSessionAudioImportError.conversionFailed(
        "Sessions could not read the converted audio samples. Import another WAV, MP3, or M4A file."
      )
    }
    let samples = UnsafeBufferPointer(start: floatChannelData[0], count: Int(buffer.frameLength))
    var result: [Int16] = []
    result.reserveCapacity(samples.count)
    for sample in samples {
      guard sample.isFinite else {
        Self.logger.error("Audio import conversion produced a nonfinite sample.")
        throw LocalSessionAudioImportError.conversionFailed(
          "Sessions found invalid sample data while converting this audio file. Import another WAV, MP3, or M4A file."
        )
      }
      let clamped = max(-1.0, min(1.0, sample))
      result.append(Int16((clamped * 32_767.0).rounded()))
    }
    return result
  }

  private func logUnderlying(_ error: Error, stage: String, sourceURL: URL) {
    let diagnostic = String(reflecting: error)
    Self.logger.error(
      "Audio import failed during \(stage, privacy: .public) for \(sourceURL.lastPathComponent, privacy: .public): \(diagnostic, privacy: .public)"
    )
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
