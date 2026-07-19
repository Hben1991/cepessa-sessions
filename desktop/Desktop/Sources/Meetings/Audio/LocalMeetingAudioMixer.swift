import Foundation

enum LocalMeetingAudioMixer {
  private static let targetSystemRMS: Float = 0.035
  private static let minimumSystemRMS: Float = 0.0005
  private static let maximumSystemGain: Float = 6

  static func mixMono(micPCM16: Data, systemPCM16: Data) -> Data {
    let micSampleCount = micPCM16.count / MemoryLayout<Int16>.size
    let systemSampleCount = systemPCM16.count / MemoryLayout<Int16>.size
    let sampleCount = max(micSampleCount, systemSampleCount)
    guard sampleCount > 0 else { return Data() }

    let gain = systemGain(forPCM16: systemPCM16)
    var mixed = Data(count: sampleCount * MemoryLayout<Int16>.size)

    micPCM16.withUnsafeBytes { micBytes in
      systemPCM16.withUnsafeBytes { systemBytes in
        mixed.withUnsafeMutableBytes { mixedBytes in
          let micSamples = micBytes.bindMemory(to: Int16.self)
          let systemSamples = systemBytes.bindMemory(to: Int16.self)
          let mixedSamples = mixedBytes.bindMemory(to: Int16.self)

          for index in 0..<sampleCount {
            let mic = index < micSampleCount ? Int32(Int16(littleEndian: micSamples[index])) : 0
            let system =
              index < systemSampleCount
              ? Int32((Float(Int16(littleEndian: systemSamples[index])) * gain).rounded())
              : 0
            let clamped = max(Int32(Int16.min), min(Int32(Int16.max), mic + system))
            mixedSamples[index] = Int16(clamped).littleEndian
          }
        }
      }
    }

    return mixed
  }

  static func systemGain(for samples: [Int16]) -> Float {
    guard !samples.isEmpty else { return 1 }

    let energy = samples.reduce(Float.zero) { partial, sample in
      let normalized = Float(sample) / Float(Int16.max)
      return partial + normalized * normalized
    }
    let rms = sqrt(energy / Float(samples.count))
    guard rms >= minimumSystemRMS, rms < targetSystemRMS else { return 1 }
    return min(maximumSystemGain, targetSystemRMS / rms)
  }

  private static func systemGain(forPCM16 data: Data) -> Float {
    let sampleCount = data.count / MemoryLayout<Int16>.size
    guard sampleCount > 0 else { return 1 }

    let energy = data.withUnsafeBytes { rawBuffer -> Float in
      let samples = rawBuffer.bindMemory(to: Int16.self)
      var energy: Float = 0
      for index in 0..<sampleCount {
        let normalized = Float(Int16(littleEndian: samples[index])) / Float(Int16.max)
        energy += normalized * normalized
      }
      return energy
    }
    let rms = sqrt(energy / Float(sampleCount))
    guard rms >= minimumSystemRMS, rms < targetSystemRMS else { return 1 }
    return min(maximumSystemGain, targetSystemRMS / rms)
  }
}

/// Keeps mic/system audio close enough to mix without retaining an entire long recording
/// when one CoreAudio source stalls. Five seconds covers normal callback jitter and device
/// reconfiguration; older unmatched audio is written with silence for the missing source.
struct LocalMeetingSynchronizedPCMBuffer {
  static let bytesPerSecond = 16_000 * MemoryLayout<Int16>.size
  static let defaultMaximumSkewByteCount = bytesPerSecond * 5

  private(set) var pendingMicPCM = Data()
  private(set) var pendingSystemPCM = Data()
  private var didMicExceedMaximumSkew = false
  private var didSystemExceedMaximumSkew = false
  let maximumSkewByteCount: Int

  init(maximumSkewByteCount: Int = Self.defaultMaximumSkewByteCount) {
    self.maximumSkewByteCount = max(2, (maximumSkewByteCount / 2) * 2)
  }

  var bufferedByteCount: Int {
    pendingMicPCM.count + pendingSystemPCM.count
  }

  mutating func appendMic(_ data: Data, emit: (Data) -> Void) {
    if !data.isEmpty, didSystemExceedMaximumSkew {
      emitUnmatchedSystemTail(emit: emit)
    }
    pendingMicPCM.append(data)
    drain(emit: emit)
  }

  mutating func appendSystem(_ data: Data, emit: (Data) -> Void) {
    if !data.isEmpty, didMicExceedMaximumSkew {
      emitUnmatchedMicTail(emit: emit)
    }
    pendingSystemPCM.append(data)
    drain(emit: emit)
  }

  mutating func flush(emit: (Data) -> Void) {
    let byteCount = Self.evenByteCount(max(pendingMicPCM.count, pendingSystemPCM.count))
    if byteCount > 0 {
      emit(
        LocalMeetingAudioMixer.mixMono(
          micPCM16: Self.paddedPrefix(of: pendingMicPCM, byteCount: byteCount),
          systemPCM16: Self.paddedPrefix(of: pendingSystemPCM, byteCount: byteCount)
        ))
    }
    reset()
  }

  mutating func reset() {
    pendingMicPCM.removeAll(keepingCapacity: false)
    pendingSystemPCM.removeAll(keepingCapacity: false)
    didMicExceedMaximumSkew = false
    didSystemExceedMaximumSkew = false
  }

  private mutating func drain(emit: (Data) -> Void) {
    let pairedByteCount = Self.evenByteCount(min(pendingMicPCM.count, pendingSystemPCM.count))
    if pairedByteCount > 0 {
      emit(
        LocalMeetingAudioMixer.mixMono(
          micPCM16: Self.consumePrefix(from: &pendingMicPCM, byteCount: pairedByteCount),
          systemPCM16: Self.consumePrefix(from: &pendingSystemPCM, byteCount: pairedByteCount)
        ))
    }

    didMicExceedMaximumSkew =
      Self.emitExcessIfNeeded(
        from: &pendingMicPCM,
        maximumSkewByteCount: maximumSkewByteCount,
        emit: { micPCM in
          emit(LocalMeetingAudioMixer.mixMono(micPCM16: micPCM, systemPCM16: Data()))
        }) || didMicExceedMaximumSkew
    didSystemExceedMaximumSkew =
      Self.emitExcessIfNeeded(
        from: &pendingSystemPCM,
        maximumSkewByteCount: maximumSkewByteCount,
        emit: { systemPCM in
          emit(LocalMeetingAudioMixer.mixMono(micPCM16: Data(), systemPCM16: systemPCM))
        }) || didSystemExceedMaximumSkew
  }

  /// Once a source has exceeded the skew window, its retained tail predates the returning
  /// source. Emit that tail against silence before accepting resumed audio; otherwise the
  /// newly returned source would remain paired approximately one full skew window behind.
  private mutating func emitUnmatchedMicTail(emit: (Data) -> Void) {
    let byteCount = Self.evenByteCount(pendingMicPCM.count)
    if byteCount > 0 {
      emit(
        LocalMeetingAudioMixer.mixMono(
          micPCM16: Self.consumePrefix(from: &pendingMicPCM, byteCount: byteCount),
          systemPCM16: Data()
        ))
    }
    pendingMicPCM.removeAll(keepingCapacity: true)
    didMicExceedMaximumSkew = false
  }

  private mutating func emitUnmatchedSystemTail(emit: (Data) -> Void) {
    let byteCount = Self.evenByteCount(pendingSystemPCM.count)
    if byteCount > 0 {
      emit(
        LocalMeetingAudioMixer.mixMono(
          micPCM16: Data(),
          systemPCM16: Self.consumePrefix(from: &pendingSystemPCM, byteCount: byteCount)
        ))
    }
    pendingSystemPCM.removeAll(keepingCapacity: true)
    didSystemExceedMaximumSkew = false
  }

  private static func evenByteCount(_ count: Int) -> Int {
    (count / MemoryLayout<Int16>.size) * MemoryLayout<Int16>.size
  }

  private static func consumePrefix(from data: inout Data, byteCount: Int) -> Data {
    let prefix = Data(data.prefix(byteCount))
    data.removeFirst(byteCount)
    return prefix
  }

  private static func paddedPrefix(of data: Data, byteCount: Int) -> Data {
    guard data.count < byteCount else { return Data(data.prefix(byteCount)) }
    var padded = Data(data)
    padded.append(Data(repeating: 0, count: byteCount - data.count))
    return padded
  }

  private static func emitExcessIfNeeded(
    from data: inout Data,
    maximumSkewByteCount: Int,
    emit: (Data) -> Void
  ) -> Bool {
    let excessByteCount = evenByteCount(data.count - maximumSkewByteCount)
    guard excessByteCount > 0 else { return false }
    emit(consumePrefix(from: &data, byteCount: excessByteCount))
    return true
  }
}
