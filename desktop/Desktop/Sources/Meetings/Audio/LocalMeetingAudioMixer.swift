import Foundation

enum LocalMeetingAudioMixer {
  private static let targetSystemRMS: Float = 0.035
  private static let minimumSystemRMS: Float = 0.0005
  private static let maximumSystemGain: Float = 6

  static func mixMono(micPCM16: Data, systemPCM16: Data) -> Data {
    let micSamples = int16Samples(from: micPCM16)
    let systemSamples = int16Samples(from: systemPCM16)
    let sampleCount = max(micSamples.count, systemSamples.count)
    let systemGain = systemGain(for: systemSamples)

    var mixed = [Int16]()
    mixed.reserveCapacity(sampleCount)

    for index in 0..<sampleCount {
      let mic = index < micSamples.count ? Int32(micSamples[index]) : 0
      let system =
        index < systemSamples.count
        ? Int32((Float(systemSamples[index]) * systemGain).rounded())
        : 0
      let summed = mic + system
      let clamped = max(Int32(Int16.min), min(Int32(Int16.max), summed))
      mixed.append(Int16(clamped))
    }

    return pcm16Data(from: mixed)
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

  private static func int16Samples(from data: Data) -> [Int16] {
    data.withUnsafeBytes { rawBuffer in
      let words = rawBuffer.bindMemory(to: Int16.self)
      return words.map(Int16.init(littleEndian:))
    }
  }

  private static func pcm16Data(from samples: [Int16]) -> Data {
    var data = Data()
    data.reserveCapacity(samples.count * 2)

    for sample in samples {
      var littleEndian = sample.littleEndian
      withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }

    return data
  }
}
