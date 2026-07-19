import AVFoundation
import XCTest

@testable import CepessaSessions

final class SystemAudioCaptureServiceTests: XCTestCase {
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
