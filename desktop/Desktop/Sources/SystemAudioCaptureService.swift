import AVFoundation
import CoreAudio
import Foundation

/// Service for capturing system audio using Core Audio Taps (macOS 14.4+)
/// Captures all system audio output and converts to 16-bit PCM at 16kHz for transcription
@available(macOS 14.4, *)
class SystemAudioCaptureService: @unchecked Sendable {

  // MARK: - Types

  /// Callback for receiving audio chunks
  typealias AudioChunkHandler = (Data) -> Void

  /// Callback for receiving audio levels (0.0 - 1.0)
  typealias AudioLevelHandler = (Float) -> Void

  enum SystemAudioCaptureError: LocalizedError {
    case tapCreationFailed(OSStatus)
    case aggregateDeviceFailed(OSStatus)
    case ioProcCreationFailed(OSStatus)
    case deviceStartFailed(OSStatus)
    case formatError
    case converterCreationFailed
    case unsupportedOS

    var errorDescription: String? {
      switch self {
      case .tapCreationFailed(let status):
        return "Failed to create process tap: \(status)"
      case .aggregateDeviceFailed(let status):
        return "Failed to create aggregate device: \(status)"
      case .ioProcCreationFailed(let status):
        return "Failed to create IO proc: \(status)"
      case .deviceStartFailed(let status):
        return "Failed to start audio device: \(status)"
      case .formatError:
        return "Failed to get audio format"
      case .converterCreationFailed:
        return "Failed to create audio converter"
      case .unsupportedOS:
        return "System audio capture requires macOS 14.4 or later"
      }
    }
  }

  // MARK: - Properties

  private var tapID: AudioObjectID = kAudioObjectUnknown
  private var aggregateDeviceID: AudioObjectID = kAudioObjectUnknown
  private var ioProcID: AudioDeviceIOProcID?
  private var isCapturing = false
  private var onAudioChunk: AudioChunkHandler?
  private var onAudioLevel: AudioLevelHandler?

  /// Target sample rate for DeepGram
  private let targetSampleRate: Double = 16000

  // Resampling
  private var audioConverter: AVAudioConverter?
  private var inputFormat: AVAudioFormat?
  private var targetFormat: AVAudioFormat?
  private var sourceSampleRate: Double = 0.0
  private let audioLevelDispatchInterval: CFTimeInterval = 1.0 / 15.0
  private var lastAudioLevelDispatchTime: CFAbsoluteTime = 0
  private var lastDispatchedAudioLevel: Float = 0

  // Tap UUID for identification
  private let tapUUID = UUID()

  /// Dedicated queue for CoreAudio device operations (start/stop)
  /// to avoid blocking the main thread on AudioDeviceStart/Stop calls.
  private let audioQueue = DispatchQueue(label: "me.cepessa.systemaudiocapture.device")

  // MARK: - Permission Checking

  /// Check if system audio capture permission is available
  /// Note: Core Audio Taps don't have a preflight API like screen capture.
  /// Permission is granted implicitly on first use, or may require entitlements.
  static func checkPermission() -> Bool {
    // For Core Audio Taps, there's no explicit permission API.
    // The system will prompt when we first try to create a tap.
    // Return true to indicate we can attempt capture.
    return true
  }

  /// Request system audio capture permission
  /// Returns true if permission is available (macOS 14.4+)
  static func requestPermission() async -> Bool {
    // Core Audio Taps permission is handled at capture time
    return true
  }

  // MARK: - Public Methods

  /// Start capturing system audio
  /// - Parameters:
  ///   - onAudioChunk: Callback receiving 16-bit PCM audio data chunks at 16kHz mono
  ///   - onAudioLevel: Optional callback receiving normalized audio level (0.0 - 1.0)
  func startCapture(
    onAudioChunk: @escaping AudioChunkHandler, onAudioLevel: AudioLevelHandler? = nil
  ) async throws {
    guard !isCapturing else {
      localMeetingLog("SystemAudioCapture: Already capturing")
      return
    }

    self.onAudioChunk = onAudioChunk
    self.onAudioLevel = onAudioLevel
    self.lastAudioLevelDispatchTime = 0
    self.lastDispatchedAudioLevel = 0

    // All CoreAudio HAL calls (CreateTap, CreateAggregateDevice, AudioDeviceStart) are
    // synchronous IPC to coreaudiod via mach_msg. After wake from sleep the daemon can
    // take seconds to respond, blocking the caller. Dispatch the entire setup to audioQueue,
    // mirroring the pattern already used in stopCapture().
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      audioQueue.async { [weak self] in
        guard let self else {
          continuation.resume()
          return
        }
        do {
          try self.startCaptureOnQueue()
          continuation.resume()
        } catch {
          continuation.resume(throwing: error)
        }
      }
    }
  }

  /// Performs all blocking CoreAudio HAL setup. Must be called on audioQueue, not the main thread.
  private func startCaptureOnQueue() throws {
    // 1. Create a mono tap for all system audio. The transcript master is mono, so asking
    // CoreAudio to perform the channel mixdown avoids losing a planar stereo buffer before
    // the samples reach our converter.
    let tapDescription = CATapDescription(monoGlobalTapButExcludeProcesses: [])
    tapDescription.uuid = tapUUID
    tapDescription.name = "Cepessa System Audio Tap"
    tapDescription.muteBehavior = .unmuted  // Don't mute playback

    // 2. Create the process tap
    var status = AudioHardwareCreateProcessTap(tapDescription, &tapID)
    guard status == noErr else {
      throw SystemAudioCaptureError.tapCreationFailed(status)
    }
    localMeetingLog("SystemAudioCapture: Created tap with ID \(tapID)")

    // 3. Create aggregate device with tap
    //
    // IMPORTANT: drift compensation is enabled per-tap via kAudioSubTapDriftCompensationKey.
    // Without it, the aggregate device's clock can drift relative to the real output device,
    // and the system resamples on every IO cycle to compensate. That resampling produces
    // periodic crackling/artifacts in *all* system audio playback (music, calls, etc.) even
    // though we're only reading from the tap. Enabling drift compensation tells CoreAudio
    // to reconcile clocks at the sub-tap level, eliminating the artifacts.
    // CoreAudio expects a CFNumber here ("non-zero value indicates that drift compensation
    // is enabled" — see <CoreAudio/AudioHardware.h>), not a CFBoolean.
    let aggregateDescription: [String: Any] = [
      kAudioAggregateDeviceNameKey as String: "Cepessa System Audio Tap Device",
      kAudioAggregateDeviceUIDKey as String: "cepessa.systemaudio.\(tapUUID.uuidString)",
      kAudioAggregateDeviceIsPrivateKey as String: true,
      kAudioAggregateDeviceTapListKey as String: [
        [
          kAudioSubTapUIDKey as String: tapUUID.uuidString,
          kAudioSubTapDriftCompensationKey as String: NSNumber(value: 1),
          kAudioSubTapDriftCompensationQualityKey as String:
            NSNumber(value: kAudioAggregateDriftCompensationMaxQuality),
        ]
      ],
      kAudioAggregateDeviceTapAutoStartKey as String: true,
    ]

    status = AudioHardwareCreateAggregateDevice(
      aggregateDescription as CFDictionary, &aggregateDeviceID)
    guard status == noErr else {
      cleanupTap()
      throw SystemAudioCaptureError.aggregateDeviceFailed(status)
    }
    localMeetingLog("SystemAudioCapture: Created aggregate device with ID \(aggregateDeviceID)")

    // 4. Read the authoritative tap format. The aggregate device can expose a different
    // generic input-stream layout; kAudioTapPropertyFormat is the format of the buffers
    // delivered for this tap through the aggregate device.
    guard let format = getTapFormat(for: tapID) else {
      cleanup()
      throw SystemAudioCaptureError.formatError
    }

    sourceSampleRate = format.mSampleRate
    localMeetingLog(
      "SystemAudioCapture: Source format - \(format.mSampleRate)Hz, \(format.mChannelsPerFrame) channels, \(format.mBitsPerChannel) bits"
    )

    // 5. Create AVAudioFormat for conversion. Process taps deliver Float32 PCM. Because the
    // tap itself performs mono mixdown, the converter always receives a populated mono plane.
    guard format.mFormatID == kAudioFormatLinearPCM,
      format.mBitsPerChannel == 32,
      format.mFormatFlags & kAudioFormatFlagIsFloat != 0
    else {
      cleanup()
      throw SystemAudioCaptureError.formatError
    }

    guard
      let inputFmt = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: format.mSampleRate,
        channels: 1,
        interleaved: false
      )
    else {
      cleanup()
      throw SystemAudioCaptureError.formatError
    }
    self.inputFormat = inputFmt

    // Target format: 16kHz mono Float32 (we'll convert to Int16 manually)
    guard
      let targetFmt = AVAudioFormat(
        standardFormatWithSampleRate: targetSampleRate,
        channels: 1
      )
    else {
      cleanup()
      throw SystemAudioCaptureError.converterCreationFailed
    }
    self.targetFormat = targetFmt

    // Create audio converter for resampling
    guard let converter = AVAudioConverter(from: inputFmt, to: targetFmt) else {
      cleanup()
      throw SystemAudioCaptureError.converterCreationFailed
    }
    self.audioConverter = converter

    // 6. Create IO proc for audio callbacks
    status = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateDeviceID, nil) {
      [weak self] inNow, inInputData, inInputTime, outOutputData, inOutputTime in
      self?.handleAudioInput(inInputData, timestamp: inInputTime)
    }

    guard status == noErr else {
      cleanup()
      throw SystemAudioCaptureError.ioProcCreationFailed(status)
    }

    // 7. Start the device
    status = AudioDeviceStart(aggregateDeviceID, ioProcID)
    guard status == noErr else {
      cleanup()
      throw SystemAudioCaptureError.deviceStartFailed(status)
    }

    isCapturing = true
    localMeetingLog("SystemAudioCapture: Started capturing system audio")
  }

  /// Stop capturing system audio
  func stopCapture() {
    guard isCapturing else { return }
    isCapturing = false
    onAudioChunk = nil
    onAudioLevel = nil

    // Capture values for background cleanup to avoid blocking main thread.
    // Keep the converter/format/sample-rate state alive until AudioDeviceStop returns:
    // CoreAudio can deliver one final IO callback while the stop is in flight.
    let procID = self.ioProcID
    let aggDevID = self.aggregateDeviceID
    let tID = self.tapID

    self.ioProcID = nil
    self.aggregateDeviceID = kAudioObjectUnknown
    self.tapID = kAudioObjectUnknown
    self.lastAudioLevelDispatchTime = 0
    self.lastDispatchedAudioLevel = 0

    // AudioDeviceStop can block — run off main thread
    audioQueue.async { [self] in
      if let procID = procID, aggDevID != kAudioObjectUnknown {
        AudioDeviceStop(aggDevID, procID)
        AudioDeviceDestroyIOProcID(aggDevID, procID)
      }
      if aggDevID != kAudioObjectUnknown {
        AudioHardwareDestroyAggregateDevice(aggDevID)
      }
      if tID != kAudioObjectUnknown {
        AudioHardwareDestroyProcessTap(tID)
      }

      self.audioConverter = nil
      self.inputFormat = nil
      self.targetFormat = nil
      self.sourceSampleRate = 0.0
    }

    localMeetingLog("SystemAudioCapture: Stopped capturing")
  }

  /// Check if currently capturing
  var capturing: Bool {
    return isCapturing
  }

  // MARK: - Private Methods

  static func outputFrameCapacity(
    inputFrameCount: UInt32,
    sourceSampleRate: Double,
    targetSampleRate: Double
  ) -> AVAudioFrameCount? {
    guard inputFrameCount > 0,
      sourceSampleRate.isFinite,
      sourceSampleRate > 0,
      targetSampleRate.isFinite,
      targetSampleRate > 0
    else { return nil }

    let convertedFrameCount = ceil(Double(inputFrameCount) * targetSampleRate / sourceSampleRate)
    guard convertedFrameCount.isFinite,
      convertedFrameCount > 0,
      convertedFrameCount <= Double(UInt32.max)
    else { return nil }

    return AVAudioFrameCount(convertedFrameCount)
  }

  /// Read the format of the process tap itself. Apple documents this as the exact format
  /// exposed by any aggregate device containing the tap.
  private func getTapFormat(for tapID: AudioObjectID) -> AudioStreamBasicDescription? {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioTapPropertyFormat,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )

    var format = AudioStreamBasicDescription()
    var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)

    let status = AudioObjectGetPropertyData(
      tapID,
      &address,
      0,
      nil,
      &size,
      &format
    )

    return status == noErr ? format : nil
  }

  static func downmixFloat32Buffers(
    _ buffers: [[Float]],
    channelsPerBuffer: [Int]
  ) -> [Float]? {
    guard !buffers.isEmpty, buffers.count == channelsPerBuffer.count else { return nil }

    var frameCount: Int?
    var totalChannelCount = 0
    for (samples, channelCount) in zip(buffers, channelsPerBuffer) {
      guard channelCount > 0, samples.count >= channelCount else { return nil }
      let bufferFrameCount = samples.count / channelCount
      frameCount = min(frameCount ?? bufferFrameCount, bufferFrameCount)
      totalChannelCount += channelCount
    }

    guard let frameCount, frameCount > 0, totalChannelCount > 0 else { return nil }

    var monoSamples = [Float](repeating: 0, count: frameCount)
    for frameIndex in 0..<frameCount {
      var sum: Float = 0
      for (samples, channelCount) in zip(buffers, channelsPerBuffer) {
        let frameOffset = frameIndex * channelCount
        for channelIndex in 0..<channelCount {
          sum += samples[frameOffset + channelIndex]
        }
      }
      monoSamples[frameIndex] = sum / Float(totalChannelCount)
    }

    return monoSamples
  }

  private static func monoSamples(
    from inputData: UnsafePointer<AudioBufferList>
  ) -> [Float]? {
    let mutableInputData = UnsafeMutablePointer(mutating: inputData)
    let audioBuffers = UnsafeMutableAudioBufferListPointer(mutableInputData)
    var buffers: [[Float]] = []
    var channelsPerBuffer: [Int] = []
    buffers.reserveCapacity(audioBuffers.count)
    channelsPerBuffer.reserveCapacity(audioBuffers.count)

    for buffer in audioBuffers {
      let channelCount = Int(buffer.mNumberChannels)
      guard channelCount > 0,
        let data = buffer.mData,
        buffer.mDataByteSize >= MemoryLayout<Float32>.size
      else { continue }

      let sampleCount = Int(buffer.mDataByteSize) / MemoryLayout<Float32>.size
      let samples = UnsafeBufferPointer(
        start: data.assumingMemoryBound(to: Float32.self),
        count: sampleCount
      )
      buffers.append(Array(samples))
      channelsPerBuffer.append(channelCount)
    }

    return downmixFloat32Buffers(buffers, channelsPerBuffer: channelsPerBuffer)
  }

  /// Handle incoming audio data from the tap
  private func handleAudioInput(
    _ inputData: UnsafePointer<AudioBufferList>?, timestamp: UnsafePointer<AudioTimeStamp>?
  ) {
    guard isCapturing,
      let inputData,
      let converter = audioConverter,
      let targetFmt = targetFormat,
      let inputFmt = inputFormat
    else { return }

    guard let monoSamples = Self.monoSamples(from: inputData), !monoSamples.isEmpty else { return }
    let frameCount = AVAudioFrameCount(monoSamples.count)

    // Create input AVAudioPCMBuffer
    guard
      let inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFmt, frameCapacity: frameCount)
    else { return }

    inputBuffer.frameLength = frameCount

    guard let destination = inputBuffer.floatChannelData?[0] else { return }
    monoSamples.withUnsafeBufferPointer { source in
      destination.update(from: source.baseAddress!, count: monoSamples.count)
    }

    // Calculate output frame count based on sample rate conversion
    guard
      let outputFrameCapacity = Self.outputFrameCapacity(
        inputFrameCount: frameCount,
        sourceSampleRate: sourceSampleRate,
        targetSampleRate: targetSampleRate
      )
    else { return }
    guard
      let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFmt, frameCapacity: outputFrameCapacity)
    else { return }

    // Convert using input block pattern
    var error: NSError?
    var hasConsumedInput = false

    let inputBlock: AVAudioConverterInputBlock = { inNumPackets, outStatus in
      if hasConsumedInput {
        outStatus.pointee = .noDataNow
        return nil
      }
      hasConsumedInput = true
      outStatus.pointee = .haveData
      return inputBuffer
    }

    converter.convert(to: outputBuffer, error: &error, withInputFrom: inputBlock)

    if let error = error {
      localMeetingLogError("SystemAudioCapture: Conversion error", error: error)
      return
    }

    // Convert Float32 to Int16 (linear16 PCM for DeepGram)
    guard let channelData = outputBuffer.floatChannelData?[0] else { return }

    let processedFrameLength = Int(outputBuffer.frameLength)
    var pcmData = [Int16]()
    pcmData.reserveCapacity(processedFrameLength)

    for i in 0..<processedFrameLength {
      let sample = channelData[i]
      // Clamp and convert to Int16 range (-32768 to 32767)
      let pcmSample = Int16(max(-32768, min(32767, sample * 32767)))
      pcmData.append(pcmSample)
    }

    // Convert to Data
    let byteData = pcmData.withUnsafeBufferPointer { buffer in
      return Data(buffer: buffer)
    }

    // Calculate and report audio level (RMS normalized to 0.0 - 1.0)
    if let levelHandler = onAudioLevel, !pcmData.isEmpty {
      let sumOfSquares: Float = pcmData.reduce(0.0) { acc, sample in
        let normalized = Float(sample) / 32767.0
        return acc + normalized * normalized
      }
      let rms = sqrt(sumOfSquares / Float(pcmData.count))
      // Clamp to 0.0 - 1.0 range
      let level = min(Float(1.0), max(Float(0.0), rms))
      if shouldDispatchAudioLevel(level) {
        DispatchQueue.main.async {
          levelHandler(level)
        }
      }
    }

    // Send to callback
    onAudioChunk?(byteData)
  }

  private func shouldDispatchAudioLevel(_ level: Float) -> Bool {
    let now = CFAbsoluteTimeGetCurrent()
    let isFirstDispatch = lastAudioLevelDispatchTime == 0
    let didReachInterval = now - lastAudioLevelDispatchTime >= audioLevelDispatchInterval
    let didStartFromSilence = lastDispatchedAudioLevel == 0 && level > 0.05
    let didReturnToSilence = lastDispatchedAudioLevel > 0 && level == 0

    guard isFirstDispatch || didReachInterval || didStartFromSilence || didReturnToSilence else {
      return false
    }

    lastAudioLevelDispatchTime = now
    lastDispatchedAudioLevel = level
    return true
  }

  /// Clean up tap resources
  private func cleanupTap() {
    if tapID != kAudioObjectUnknown {
      AudioHardwareDestroyProcessTap(tapID)
      tapID = kAudioObjectUnknown
    }
  }

  /// Clean up all resources
  private func cleanup() {
    if let procID = ioProcID, aggregateDeviceID != kAudioObjectUnknown {
      AudioDeviceStop(aggregateDeviceID, procID)
      AudioDeviceDestroyIOProcID(aggregateDeviceID, procID)
      ioProcID = nil
    }

    if aggregateDeviceID != kAudioObjectUnknown {
      AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
      aggregateDeviceID = kAudioObjectUnknown
    }

    cleanupTap()

    audioConverter = nil
    inputFormat = nil
    targetFormat = nil
    sourceSampleRate = 0.0
  }

  deinit {
    // Use sync in deinit to ensure cleanup completes before deallocation
    let procID = self.ioProcID
    let aggDevID = self.aggregateDeviceID
    let tID = self.tapID
    if procID != nil || aggDevID != kAudioObjectUnknown || tID != kAudioObjectUnknown {
      audioQueue.sync {
        if let procID = procID, aggDevID != kAudioObjectUnknown {
          AudioDeviceStop(aggDevID, procID)
          AudioDeviceDestroyIOProcID(aggDevID, procID)
        }
        if aggDevID != kAudioObjectUnknown {
          AudioHardwareDestroyAggregateDevice(aggDevID)
        }
        if tID != kAudioObjectUnknown {
          AudioHardwareDestroyProcessTap(tID)
        }
      }
    }
  }
}
