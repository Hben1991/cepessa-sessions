import AVFoundation
import Foundation

struct AudioPCM16Encoding {
  let data: Data
  let sumOfSquares: Float
  let peakMagnitude: Int16
  let sampleCount: Int

  var rms: Float {
    guard sampleCount > 0 else { return 0 }
    return sqrt(sumOfSquares / Float(sampleCount))
  }
}

/// Converts a Float32 audio plane directly into its callback `Data` while collecting the
/// level/watchdog statistics in the same pass. This avoids an intermediate Int16 array and
/// the two additional full-buffer scans that each mic callback previously performed.
enum AudioPCM16Encoder {
  static func encode(_ samples: UnsafeBufferPointer<Float>) -> AudioPCM16Encoding {
    guard !samples.isEmpty else {
      return AudioPCM16Encoding(
        data: Data(), sumOfSquares: 0, peakMagnitude: 0, sampleCount: 0)
    }

    var data = Data(count: samples.count * MemoryLayout<Int16>.size)
    var sumOfSquares: Float = 0
    var peakMagnitude: Int16 = 0

    data.withUnsafeMutableBytes { rawBuffer in
      let output = rawBuffer.bindMemory(to: Int16.self)
      for index in samples.indices {
        let finiteSample = samples[index].isFinite ? samples[index] : 0
        let pcmSample = Int16(max(-32_768, min(32_767, finiteSample * 32_767)))
        output[index] = pcmSample.littleEndian

        let normalized = Float(pcmSample) / 32_767
        sumOfSquares += normalized * normalized
        let magnitude = pcmSample == Int16.min ? Int16.max : Int16(pcmSample.magnitude)
        peakMagnitude = max(peakMagnitude, magnitude)
      }
    }

    return AudioPCM16Encoding(
      data: data,
      sumOfSquares: sumOfSquares,
      peakMagnitude: peakMagnitude,
      sampleCount: samples.count
    )
  }

  static func encode(_ samples: [Float]) -> AudioPCM16Encoding {
    samples.withUnsafeBufferPointer(encode)
  }
}

/// Reuses the two AVAudio buffers on a serial CoreAudio callback. Capacities only grow when
/// hardware supplies a larger callback, eliminating two object/backing-store allocations on
/// every normal mic and system-audio IO cycle.
final class AudioConversionBufferPool {
  private var inputBuffer: AVAudioPCMBuffer?
  private var outputBuffer: AVAudioPCMBuffer?
  private(set) var allocationCount = 0

  func prepare(
    inputFormat: AVAudioFormat,
    inputFrameCount: AVAudioFrameCount,
    outputFormat: AVAudioFormat,
    outputFrameCapacity: AVAudioFrameCount
  ) -> (input: AVAudioPCMBuffer, output: AVAudioPCMBuffer)? {
    if inputBuffer == nil || inputBuffer!.frameCapacity < inputFrameCount {
      inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: inputFrameCount)
      allocationCount += 1
    }
    if outputBuffer == nil || outputBuffer!.frameCapacity < outputFrameCapacity {
      outputBuffer = AVAudioPCMBuffer(
        pcmFormat: outputFormat,
        frameCapacity: outputFrameCapacity
      )
      allocationCount += 1
    }

    guard let inputBuffer, let outputBuffer else { return nil }
    inputBuffer.frameLength = inputFrameCount
    outputBuffer.frameLength = 0
    return (inputBuffer, outputBuffer)
  }

  func reset() {
    inputBuffer = nil
    outputBuffer = nil
  }
}
