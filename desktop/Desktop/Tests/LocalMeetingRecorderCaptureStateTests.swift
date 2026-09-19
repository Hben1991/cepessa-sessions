import XCTest

@testable import CepessaSessions

final class LocalMeetingRecorderCaptureStateTests: XCTestCase {
  func testSecondStartIsRejectedWhileFirstStartIsSuspended() throws {
    var state = LocalMeetingRecorderCaptureState()

    let token = try XCTUnwrap(state.beginStart())

    XCTAssertNil(state.beginStart())
    XCTAssertTrue(state.isStarting(token))
  }

  func testStartIsRejectedUntilStopFinishes() throws {
    var state = LocalMeetingRecorderCaptureState()
    let token = try XCTUnwrap(state.beginStart())
    XCTAssertTrue(state.markRecording(token))

    XCTAssertEqual(state.beginStop(), token)
    XCTAssertNil(state.beginStart())
    XCTAssertTrue(state.finish(token))
    XCTAssertNotNil(state.beginStart())
  }

  func testStopDuringStartInvalidatesLateStartupCompletion() throws {
    var state = LocalMeetingRecorderCaptureState()
    let token = try XCTUnwrap(state.beginStart())

    XCTAssertEqual(state.beginStop(), token)
    XCTAssertFalse(state.markRecording(token))
    XCTAssertTrue(state.finish(token))
    XCTAssertEqual(state.phase, .idle)
  }

  func testStaleTokenCannotFinishNewerCapture() throws {
    var state = LocalMeetingRecorderCaptureState()
    let staleToken = try XCTUnwrap(state.beginStart())
    XCTAssertTrue(state.finish(staleToken))
    let currentToken = try XCTUnwrap(state.beginStart())

    XCTAssertFalse(state.finish(staleToken))
    XCTAssertTrue(state.isStarting(currentToken))
  }
}
