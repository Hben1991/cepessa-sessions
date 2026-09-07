import XCTest

@testable import CepessaSessions

final class LocalTranscriptTextDirectionTests: XCTestCase {
  func testEnglishSentenceStartingWithHebrewNameKeepsEnglishDirection() {
    let text = "דנה will prepare the first design by Thursday."
    XCTAssertFalse(LocalTranscriptTextDirection.isRightToLeft(text))
    XCTAssertEqual(LocalTranscriptTextDirection.displayText(text), "\u{2066}\(text)\u{2069}")
  }

  func testHebrewSentenceStartingWithEnglishProductKeepsHebrewDirection() {
    let text = "Sessions שומרת את ההקלטה ואת התמלול במחשב הזה."
    XCTAssertTrue(LocalTranscriptTextDirection.isRightToLeft(text))
    XCTAssertEqual(LocalTranscriptTextDirection.displayText(text), "\u{2067}\(text)\u{2069}")
  }

  func testMixedParagraphsKeepIndependentDirectionsAndEmptyLines() {
    let text = "דנה prepared the recording.\n\nSessions שומרת את ההקלטה במחשב."
    XCTAssertEqual(
      LocalTranscriptTextDirection.displayText(text),
      "\u{2066}דנה prepared the recording.\u{2069}\n\n\u{2067}Sessions שומרת את ההקלטה במחשב.\u{2069}"
    )
  }
}
