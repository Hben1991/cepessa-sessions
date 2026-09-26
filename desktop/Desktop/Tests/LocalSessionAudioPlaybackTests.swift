import XCTest

@testable import CepessaSessions

final class LocalSessionAudioPlaybackTests: XCTestCase {
  func testAudioSeekClampsWithinDuration() {
    XCTAssertEqual(LocalSessionAudioPlayback.resolvedSeek(time: 12.2, duration: 90), 12.2, accuracy: 0.01)
    XCTAssertEqual(LocalSessionAudioPlayback.resolvedSeek(time: 500, duration: 90), 90, accuracy: 0.01)
    XCTAssertEqual(LocalSessionAudioPlayback.resolvedSeek(time: .nan, duration: 90), 0, accuracy: 0.01)
  }
}
