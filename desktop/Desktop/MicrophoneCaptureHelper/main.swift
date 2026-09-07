import AVFoundation
import CoreAudio
import Darwin
import Foundation

private enum FrameType: UInt8 {
  case hello = 1
  case status = 2
  case pcm = 3
  case level = 4
  case failure = 5
}

private let output = FileHandle.standardOutput
private let writeQueue = DispatchQueue(label: "me.cepessa.microphone-helper.writer")

private func emit(_ type: FrameType, _ payload: Data = Data()) {
  var frame = Data([type.rawValue])
  var length = UInt32(payload.count).littleEndian
  withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
  frame.append(payload)
  writeQueue.sync { try? output.write(contentsOf: frame) }
}

private func fail(_ message: String) -> Never {
  emit(.failure, Data(message.utf8))
  exit(2)
}

private func normalizedPeak(_ data: Data) -> Float {
  guard data.count >= 2 else { return 0 }
  var peak = 0
  data.withUnsafeBytes { bytes in
    for offset in stride(from: 0, through: bytes.count - 2, by: 2) {
      let sample = Int(bytes.loadUnaligned(fromByteOffset: offset, as: Int16.self).littleEndian)
      peak = max(peak, abs(sample))
    }
  }
  return min(1, Float(peak) / Float(Int16.max))
}

private func defaultInputDeviceID() -> AudioDeviceID? {
  var deviceID = kAudioObjectUnknown
  var size = UInt32(MemoryLayout<AudioDeviceID>.size)
  var address = AudioObjectPropertyAddress(
    mSelector: kAudioHardwarePropertyDefaultInputDevice,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain
  )
  guard
    AudioObjectGetPropertyData(
      AudioObjectID(kAudioObjectSystemObject),
      &address,
      0,
      nil,
      &size,
      &deviceID
    ) == noErr, deviceID != kAudioObjectUnknown
  else {
    return nil
  }
  return deviceID
}

private func deviceString(
  _ deviceID: AudioDeviceID,
  selector: AudioObjectPropertySelector
) -> String? {
  var address = AudioObjectPropertyAddress(
    mSelector: selector,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain
  )
  var value: Unmanaged<CFString>?
  var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
  guard
    AudioObjectGetPropertyData(
      deviceID,
      &address,
      0,
      nil,
      &size,
      &value
    ) == noErr
  else {
    return nil
  }
  return value?.takeUnretainedValue() as String?
}

private func deviceTransport(_ deviceID: AudioDeviceID) -> UInt32? {
  var address = AudioObjectPropertyAddress(
    mSelector: kAudioDevicePropertyTransportType,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain
  )
  var value: UInt32 = 0
  var size = UInt32(MemoryLayout<UInt32>.size)
  guard
    AudioObjectGetPropertyData(
      deviceID,
      &address,
      0,
      nil,
      &size,
      &value
    ) == noErr
  else {
    return nil
  }
  return value
}

private final class DirectDeviceCapture {
  enum CaptureError: LocalizedError {
    case missingFormat
    case converterCreationFailed
    case ioProcCreationFailed(OSStatus)
    case deviceStartFailed(OSStatus)

    var errorDescription: String? {
      switch self {
      case .missingFormat:
        return "The selected input has no usable stream format."
      case .converterCreationFailed:
        return "The selected input format could not be converted."
      case .ioProcCreationFailed(let status):
        return "The input callback could not be created (\(status))."
      case .deviceStartFailed(let status):
        return "The input device could not start (\(status))."
      }
    }
  }

  private let deviceID: AudioDeviceID
  private let targetSampleRate = 16_000.0
  private var ioProcID: AudioDeviceIOProcID?
  private var converter: AVAudioConverter?
  private var inputFormat: AVAudioFormat?
  private var targetFormat: AVAudioFormat?
  private var detectedSampleRate = 0.0
  private let stateLock = NSLock()
  private var running = false

  init(deviceID: AudioDeviceID) {
    self.deviceID = deviceID
  }

  func start() throws {
    guard var streamFormat = streamFormat(),
      streamFormat.mSampleRate > 0,
      streamFormat.mChannelsPerFrame > 0,
      streamFormat.mBytesPerFrame > 0,
      let inputFormat = AVAudioFormat(streamDescription: &streamFormat)
    else {
      throw CaptureError.missingFormat
    }
    detectedSampleRate = streamFormat.mSampleRate
    guard
      let targetFormat = AVAudioFormat(
        standardFormatWithSampleRate: targetSampleRate,
        channels: 1
      ), let converter = AVAudioConverter(from: inputFormat, to: targetFormat)
    else {
      throw CaptureError.converterCreationFailed
    }
    self.inputFormat = inputFormat
    self.targetFormat = targetFormat
    self.converter = converter

    var procID: AudioDeviceIOProcID?
    let createStatus = AudioDeviceCreateIOProcIDWithBlock(&procID, deviceID, nil) {
      [weak self] _, inputData, _, _, _ in
      self?.handle(inputData)
    }
    guard createStatus == noErr, let procID else {
      throw CaptureError.ioProcCreationFailed(createStatus)
    }
    ioProcID = procID
    stateLock.withLock { running = true }
    let startStatus = AudioDeviceStart(deviceID, procID)
    guard startStatus == noErr else {
      stateLock.withLock { running = false }
      AudioDeviceDestroyIOProcID(deviceID, procID)
      ioProcID = nil
      throw CaptureError.deviceStartFailed(startStatus)
    }
  }

  func stop() {
    stateLock.withLock { running = false }
    guard let procID = ioProcID else { return }
    AudioDeviceStop(deviceID, procID)
    AudioDeviceDestroyIOProcID(deviceID, procID)
    ioProcID = nil
    converter = nil
    inputFormat = nil
    targetFormat = nil
  }

  private func streamFormat() -> AudioStreamBasicDescription? {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyStreamFormat,
      mScope: kAudioDevicePropertyScopeInput,
      mElement: kAudioObjectPropertyElementMain
    )
    var format = AudioStreamBasicDescription()
    var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    guard
      AudioObjectGetPropertyData(
        deviceID,
        &address,
        0,
        nil,
        &size,
        &format
      ) == noErr
    else {
      return nil
    }
    return format
  }

  private func handle(_ inputData: UnsafePointer<AudioBufferList>?) {
    guard stateLock.withLock({ running }),
      let inputData,
      let converter,
      let inputFormat,
      let targetFormat
    else {
      return
    }

    let buffers = UnsafeMutableAudioBufferListPointer(
      UnsafeMutablePointer(mutating: inputData)
    )
    guard let source = buffers.first(where: { $0.mData != nil && $0.mDataByteSize > 0 }) else {
      return
    }
    let bytesPerFrame = Int(inputFormat.streamDescription.pointee.mBytesPerFrame)
    guard bytesPerFrame > 0 else { return }
    let frameCount = Int(source.mDataByteSize) / bytesPerFrame
    guard frameCount > 0,
      let inputBuffer = AVAudioPCMBuffer(
        pcmFormat: inputFormat,
        frameCapacity: AVAudioFrameCount(frameCount)
      )
    else {
      return
    }
    inputBuffer.frameLength = AVAudioFrameCount(frameCount)

    let destinationBuffers = UnsafeMutableAudioBufferListPointer(inputBuffer.mutableAudioBufferList)
    guard destinationBuffers.count == buffers.count else { return }
    for index in buffers.indices {
      let sourceBuffer = buffers[index]
      guard let sourceData = sourceBuffer.mData,
        let destinationData = destinationBuffers[index].mData,
        sourceBuffer.mDataByteSize <= destinationBuffers[index].mDataByteSize
      else {
        return
      }
      memcpy(destinationData, sourceData, Int(sourceBuffer.mDataByteSize))
      destinationBuffers[index].mDataByteSize = sourceBuffer.mDataByteSize
    }

    let outputCapacity = AVAudioFrameCount(
      ceil(Double(frameCount) * targetSampleRate / detectedSampleRate)
    )
    guard outputCapacity > 0,
      let outputBuffer = AVAudioPCMBuffer(
        pcmFormat: targetFormat,
        frameCapacity: outputCapacity
      )
    else {
      return
    }
    var consumed = false
    var conversionError: NSError?
    converter.convert(to: outputBuffer, error: &conversionError) { _, status in
      guard !consumed else {
        status.pointee = .noDataNow
        return nil
      }
      consumed = true
      status.pointee = .haveData
      return inputBuffer
    }
    guard conversionError == nil,
      outputBuffer.frameLength > 0,
      let converted = outputBuffer.floatChannelData?[0]
    else {
      return
    }

    var pcm = Data(capacity: Int(outputBuffer.frameLength) * MemoryLayout<Int16>.size)
    for index in 0..<Int(outputBuffer.frameLength) {
      var sample = Int16(max(-32768, min(32767, converted[index] * 32767))).littleEndian
      withUnsafeBytes(of: &sample) { pcm.append(contentsOf: $0) }
    }
    emit(.pcm, pcm)
    var bits = normalizedPeak(pcm).bitPattern.littleEndian
    emit(.level, withUnsafeBytes(of: &bits) { Data($0) })
  }
}

guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
  fail("Microphone permission is not available to the capture helper.")
}

let requestedDeviceID: AudioDeviceID? = {
  guard let flag = CommandLine.arguments.firstIndex(of: "--device-id"),
    CommandLine.arguments.indices.contains(flag + 1),
    let value = UInt32(CommandLine.arguments[flag + 1]),
    value != kAudioObjectUnknown
  else {
    return nil
  }
  return value
}()
guard let selectedDeviceID = requestedDeviceID ?? defaultInputDeviceID() else {
  fail("No Core Audio default input device is available.")
}

let hello: [String: Any] = [
  "protocol": 1,
  "sampleRate": 16_000,
  "channels": 1,
  "encoding": "pcm_s16le",
  "deviceName": deviceString(selectedDeviceID, selector: kAudioObjectPropertyName)
    ?? "Core Audio input \(selectedDeviceID)",
  "deviceID": selectedDeviceID,
  "deviceUID": deviceString(selectedDeviceID, selector: kAudioDevicePropertyDeviceUID)
    ?? "unknown",
  "transport": deviceTransport(selectedDeviceID).map(String.init) ?? "unknown",
  "binding": "AudioDeviceCreateIOProcIDWithBlock",
  "backend": "historical direct Core Audio callback in a killable helper",
]
emit(.hello, (try? JSONSerialization.data(withJSONObject: hello, options: [.sortedKeys])) ?? Data())
emit(.status, Data("STARTING".utf8))

private let capture = DirectDeviceCapture(deviceID: selectedDeviceID)
do {
  try capture.start()
} catch {
  fail(error.localizedDescription)
}
emit(.status, Data("RUNNING".utf8))

let stopSemaphore = DispatchSemaphore(value: 0)
DispatchQueue.global().async {
  while let line = readLine() {
    if line == "STOP" { break }
  }
  stopSemaphore.signal()
}
signal(SIGTERM, SIG_IGN)
signal(SIGINT, SIG_IGN)
let termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
let intSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
termSource.setEventHandler { stopSemaphore.signal() }
intSource.setEventHandler { stopSemaphore.signal() }
termSource.resume()
intSource.resume()
stopSemaphore.wait()
capture.stop()
writeQueue.sync { try? output.close() }
