import AVFoundation
import XCTest

@testable import CepessaSessions

final class SystemAudioCaptureServiceTests: XCTestCase {
  func testPCM16EncoderClampsAndCollectsStatisticsInOnePass() {
    let encoding = AudioPCM16Encoder.encode([0, 1, -1, 2, -2, .nan])
    let samples = encoding.data.withUnsafeBytes { rawBuffer in
      rawBuffer.bindMemory(to: Int16.self).map(Int16.init(littleEndian:))
    }

    XCTAssertEqual(samples, [0, 32_767, -32_767, 32_767, -32_768, 0])
    XCTAssertEqual(encoding.sampleCount, 6)
    XCTAssertEqual(encoding.peakMagnitude, 32_767)
    XCTAssertGreaterThan(encoding.rms, 0.8)
  }

  func testPCM16EncoderReturnsEmptyEncodingForEmptyInput() {
    let encoding = AudioPCM16Encoder.encode([])

    XCTAssertTrue(encoding.data.isEmpty)
    XCTAssertEqual(encoding.sampleCount, 0)
    XCTAssertEqual(encoding.peakMagnitude, 0)
    XCTAssertEqual(encoding.rms, 0)
  }

  func testAudioConversionBufferPoolReusesCapacityAndClearsOutputLength() throws {
    let inputFormat = try XCTUnwrap(
      AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 48_000,
        channels: 1,
        interleaved: false
      ))
    let outputFormat = try XCTUnwrap(
      AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
    let pool = AudioConversionBufferPool()

    let first = try XCTUnwrap(
      pool.prepare(
        inputFormat: inputFormat,
        inputFrameCount: 480,
        outputFormat: outputFormat,
        outputFrameCapacity: 160
      ))
    first.output.frameLength = 100
    let reused = try XCTUnwrap(
      pool.prepare(
        inputFormat: inputFormat,
        inputFrameCount: 240,
        outputFormat: outputFormat,
        outputFrameCapacity: 80
      ))

    XCTAssertTrue(first.input === reused.input)
    XCTAssertTrue(first.output === reused.output)
    XCTAssertEqual(reused.output.frameLength, 0)
    XCTAssertEqual(pool.allocationCount, 2)
  }

  func testMicrophoneOutputFrameCapacityRejectsStoppedCaptureSampleRate() {
    XCTAssertNil(
      AudioCaptureService.outputFrameCapacity(
        inputFrameCount: 480,
        sourceSampleRate: 0,
        targetSampleRate: 16_000
      )
    )
  }

  func testOutputFrameCapacityRejectsStoppedCaptureSampleRate() throws {
    guard #available(macOS 14.4, *) else {
      throw XCTSkip("System audio capture requires macOS 14.4 or later")
    }

    XCTAssertNil(
      SystemAudioCaptureService.outputFrameCapacity(
        inputFrameCount: 480,
        sourceSampleRate: 0,
        targetSampleRate: 16_000
      )
    )
  }

  func testOutputFrameCapacityRoundsUpValidConversion() throws {
    guard #available(macOS 14.4, *) else {
      throw XCTSkip("System audio capture requires macOS 14.4 or later")
    }

    XCTAssertEqual(
      SystemAudioCaptureService.outputFrameCapacity(
        inputFrameCount: 481,
        sourceSampleRate: 48_000,
        targetSampleRate: 16_000
      ),
      161
    )
  }

  func testDownmixReadsBothChannelsFromInterleavedBuffer() throws {
    guard #available(macOS 14.4, *) else {
      throw XCTSkip("System audio capture requires macOS 14.4 or later")
    }

    XCTAssertEqual(
      SystemAudioCaptureService.downmixFloat32Buffers(
        [[1, 3, 2, 4]],
        channelsPerBuffer: [2]
      ),
      [2, 3]
    )
  }

  func testDownmixReadsEveryPlanarBuffer() throws {
    guard #available(macOS 14.4, *) else {
      throw XCTSkip("System audio capture requires macOS 14.4 or later")
    }

    XCTAssertEqual(
      SystemAudioCaptureService.downmixFloat32Buffers(
        [[1, 2], [3, 4]],
        channelsPerBuffer: [1, 1]
      ),
      [2, 3]
    )
  }
}
