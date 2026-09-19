import AppKit
import XCTest

@testable import CepessaSessions

@MainActor
final class CepessaSessionReadingToolbarTests: XCTestCase {
  func testShowingReaderRestoresItsRetainedToolbarAfterForeignToolbar() {
    let window = NSWindow()
    let readerToolbar = CepessaSessionReadingToolbar(
      model: CepessaSessionsStore.shared.model,
      window: window
    )
    let ownedToolbar = window.toolbar
    let foreignToolbar = NSToolbar(identifier: "test.clips.toolbar")
    window.toolbar = foreignToolbar

    readerToolbar.setVisible(true)

    XCTAssertTrue(window.toolbar === ownedToolbar)
    XCTAssertTrue(window.toolbar?.isVisible == true)
  }

  func testHidingReaderDoesNotChangeForeignDestinationToolbar() {
    let window = NSWindow()
    let readerToolbar = CepessaSessionReadingToolbar(
      model: CepessaSessionsStore.shared.model,
      window: window
    )
    let foreignToolbar = NSToolbar(identifier: "test.clips.toolbar")
    foreignToolbar.isVisible = true
    window.toolbar = foreignToolbar

    readerToolbar.setVisible(false)

    XCTAssertTrue(window.toolbar === foreignToolbar)
    XCTAssertTrue(foreignToolbar.isVisible)
  }
}
