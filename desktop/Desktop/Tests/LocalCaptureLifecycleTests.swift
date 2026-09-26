import XCTest

@testable import CepessaSessions

@MainActor
final class LocalCaptureLifecycleTests: XCTestCase {
  func testBeginCaptureLatchesBeforeAsyncWorkCanStart() throws {
    let lifecycle = LocalCaptureLifecycle()

    let lease = try lifecycle.beginCapture(.session)

    XCTAssertEqual(lifecycle.phase, .starting(lease))
    XCTAssertTrue(lifecycle.isBusy)
    XCTAssertEqual(lifecycle.activeKind, .session)
    XCTAssertThrowsError(try lifecycle.beginCapture(.session))
  }

  func testMatchingLeaseMovesThroughRecordingAndStopping() throws {
    let lifecycle = LocalCaptureLifecycle()
    let lease = try lifecycle.beginCapture(.session)

    XCTAssertTrue(lifecycle.markRecording(lease))
    XCTAssertEqual(lifecycle.phase, .recording(lease))
    XCTAssertTrue(lifecycle.beginStopping(lease))
    XCTAssertEqual(lifecycle.phase, .stopping(lease))
    XCTAssertTrue(lifecycle.finishCapture(lease))
    XCTAssertEqual(lifecycle.phase, .idle)
  }

  func testStaleLeaseCannotMutateOrReleaseNewerCapture() throws {
    let lifecycle = LocalCaptureLifecycle()
    let staleLease = try lifecycle.beginCapture(.session)
    XCTAssertTrue(lifecycle.finishCapture(staleLease))
    let currentLease = try lifecycle.beginCapture(.session)

    XCTAssertFalse(lifecycle.markRecording(staleLease))
    XCTAssertFalse(lifecycle.beginStopping(staleLease))
    XCTAssertFalse(lifecycle.finishCapture(staleLease))
    XCTAssertEqual(lifecycle.phase, .starting(currentLease))
  }

  func testStartingCaptureCanMoveDirectlyToStopping() throws {
    let lifecycle = LocalCaptureLifecycle()
    let lease = try lifecycle.beginCapture(.session)

    XCTAssertTrue(lifecycle.beginStopping(lease))
    XCTAssertEqual(lifecycle.phase, .stopping(lease))
  }
}
