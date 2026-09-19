import Foundation
import XCTest

@testable import CepessaSessions

final class MicrophoneCaptureProcessTests: XCTestCase {
  func testDecoderHandlesSplitFrames() throws {
    var decoder = MicrophoneCaptureFrameDecoder()
    let bytes = frame(.pcm, Data([1, 2, 3, 4]))

    XCTAssertEqual(try decoder.append(bytes.prefix(3)), [])
    XCTAssertEqual(
      try decoder.append(bytes.dropFirst(3)),
      [.init(type: .pcm, payload: Data([1, 2, 3, 4]))]
    )
  }

  func testStartRequiresHelloAndValidPCMThenPreservesSilence() async throws {
    let child = FakeMicrophoneChild()
    let process = MicrophoneCaptureProcess(
      launcher: FakeMicrophoneLauncher(child),
      handshakeTimeout: 0.2,
      firstAudioTimeout: 0.3,
      shutdownStageTimeout: 0.01
    )
    let receivedBytes = LockedInt()
    Task {
      try? await Task.sleep(nanoseconds: 10_000_000)
      child.send(frame(.hello))
      child.send(frame(.pcm, Data([3, 0, 4, 0])))
    }

    try await process.start(
      overrideDeviceID: nil,
      onChunk: { receivedBytes.add($0.count) },
      onLevel: nil,
      onFailure: { _ in }
    )
    child.send(frame(.pcm, Data([0, 0, 0, 0, 0, 0])))
    try? await Task.sleep(nanoseconds: 20_000_000)

    XCTAssertTrue(process.isHealthy)
    XCTAssertEqual(receivedBytes.value, 10)
    await process.stopAndWait()
    XCTAssertFalse(child.isRunning)
    XCTAssertEqual(child.stopRequests, 1)
  }

  func testPCMBeforeHelloFailsProtocol() async {
    let child = FakeMicrophoneChild()
    let process = MicrophoneCaptureProcess(
      launcher: FakeMicrophoneLauncher(child),
      handshakeTimeout: 0.2,
      firstAudioTimeout: 0.3,
      shutdownStageTimeout: 0.01
    )
    Task {
      try? await Task.sleep(nanoseconds: 10_000_000)
      child.send(frame(.pcm, Data([1, 0])))
    }

    do {
      try await process.start(
        overrideDeviceID: nil,
        onChunk: { _ in },
        onLevel: nil,
        onFailure: { _ in }
      )
      XCTFail("Expected invalid protocol")
    } catch {
      XCTAssertEqual(
        error as? MicrophoneCaptureProcessError,
        .invalidProtocol("PCM received before HELLO")
      )
    }
  }

  func testStopDrainsFinalPCMBeforeReturning() async throws {
    let child = FakeMicrophoneChild()
    let finalPCM = Data([7, 0, 8, 0, 9, 0])
    child.finalPCMOnStop = finalPCM
    let process = MicrophoneCaptureProcess(
      launcher: FakeMicrophoneLauncher(child),
      handshakeTimeout: 0.2,
      firstAudioTimeout: 0.3,
      shutdownStageTimeout: 0.01
    )
    let receivedBytes = LockedInt()
    Task {
      try? await Task.sleep(nanoseconds: 10_000_000)
      child.send(frame(.hello) + frame(.pcm, Data([1, 0])))
    }
    try await process.start(
      overrideDeviceID: nil,
      onChunk: { receivedBytes.add($0.count) },
      onLevel: nil,
      onFailure: { _ in }
    )

    await process.stopAndWait()

    XCTAssertEqual(receivedBytes.value, 2 + finalPCM.count)
    XCTAssertNil(process.processIdentifier)
  }

  func testHungHelperTimesOutAndStops() async {
    let child = FakeMicrophoneChild()
    let process = MicrophoneCaptureProcess(
      launcher: FakeMicrophoneLauncher(child),
      handshakeTimeout: 0.02,
      firstAudioTimeout: 0.05,
      shutdownStageTimeout: 0.01
    )

    do {
      try await process.start(
        overrideDeviceID: nil,
        onChunk: { _ in },
        onLevel: nil,
        onFailure: { _ in }
      )
      XCTFail("Expected timeout")
    } catch {
      XCTAssertEqual(error as? MicrophoneCaptureProcessError, .handshakeTimedOut)
    }

    try? await Task.sleep(nanoseconds: 50_000_000)
    XCTAssertFalse(child.isRunning)
    XCTAssertNil(process.processIdentifier)
  }

  func testStubbornHelperIsKilledAndPIDClears() async {
    let child = FakeMicrophoneChild()
    child.ignoresStopAndTerminate = true
    let process = MicrophoneCaptureProcess(
      launcher: FakeMicrophoneLauncher(child),
      handshakeTimeout: 0.01,
      firstAudioTimeout: 0.02,
      shutdownStageTimeout: 0.01
    )

    try? await process.start(
      overrideDeviceID: nil,
      onChunk: { _ in },
      onLevel: nil,
      onFailure: { _ in }
    )
    try? await Task.sleep(nanoseconds: 80_000_000)

    XCTAssertEqual(child.killRequests, 1)
    XCTAssertFalse(child.isRunning)
    XCTAssertNil(process.processIdentifier)
  }

  func testExplicitDeviceOverrideIsPassedToHelper() {
    XCTAssertEqual(
      FoundationMicrophoneCaptureLauncher.arguments(for: 132),
      ["--device-id", "132"]
    )
    XCTAssertEqual(FoundationMicrophoneCaptureLauncher.arguments(for: nil), [])
  }
}

private func frame(_ type: MicrophoneCaptureFrameType, _ payload: Data = Data()) -> Data {
  var data = Data([type.rawValue])
  var count = UInt32(payload.count).littleEndian
  withUnsafeBytes(of: &count) { data.append(contentsOf: $0) }
  data.append(payload)
  return data
}

private final class FakeMicrophoneLauncher: MicrophoneCaptureChildLaunching {
  let child: FakeMicrophoneChild

  init(_ child: FakeMicrophoneChild) {
    self.child = child
  }

  func makeChild(overrideDeviceID: UInt32?) throws -> MicrophoneCaptureChild {
    child
  }
}

private final class FakeMicrophoneChild: MicrophoneCaptureChild {
  var processIdentifier: Int32 = 42
  var isRunning = false
  var terminationStatus: Int32 = 0
  var onStdout: ((Data) -> Void)?
  var onTermination: (() -> Void)?
  var stopRequests = 0
  var terminateRequests = 0
  var killRequests = 0
  var ignoresStopAndTerminate = false
  var finalPCMOnStop: Data?

  func launch() throws {
    isRunning = true
  }

  func send(_ data: Data) {
    onStdout?(data)
  }

  func requestStop() {
    stopRequests += 1
    if let finalPCMOnStop { send(frame(.pcm, finalPCMOnStop)) }
    if !ignoresStopAndTerminate { isRunning = false }
  }

  func terminate() {
    terminateRequests += 1
    if !ignoresStopAndTerminate { isRunning = false }
  }

  func kill() {
    killRequests += 1
    isRunning = false
  }

  func drainOutput() {}
}

private final class LockedInt: @unchecked Sendable {
  private let lock = NSLock()
  private var storage = 0

  var value: Int {
    lock.withLock { storage }
  }

  func add(_ amount: Int) {
    lock.withLock { storage += amount }
  }
}
