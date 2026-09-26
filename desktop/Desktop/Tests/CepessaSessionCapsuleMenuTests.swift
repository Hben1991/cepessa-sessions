import AppKit
import XCTest

@testable import CepessaSessions

@MainActor
final class CepessaSessionCapsuleMenuTests: XCTestCase {
  override func setUp() {
    super.setUp()
    _ = NSApplication.shared
  }

  override func tearDown() {
    CepessaSessionCapsuleMenuController.shared.close()
    super.tearDown()
  }

  func testEveryRowHasItsOwnIdentityIncludingSeparators() {
    let items: [CepessaSessionCapsuleMenuItem] = [
      .action("A") {}, .separator, .header("Recent"), .separator, .action("B") {},
    ]
    XCTAssertEqual(Set(items.map(\.id)).count, items.count)
  }

  /// A click that closes one menu and opens the next (a right-click on the
  /// capsule while its menu is open) must leave the new menu open.
  func testAQueuedCloseOnlyClosesTheMenuItWasFor() throws {
    let menu = CepessaSessionCapsuleMenuController.shared
    let anchor = NSRect(x: 400, y: 600, width: 80, height: 44)

    menu.open(items: [.action("First") {}], below: anchor)
    let first = try XCTUnwrap(menu.currentPanel)
    menu.open(items: [.action("Second") {}], below: anchor)
    let second = try XCTUnwrap(menu.currentPanel)
    XCTAssertFalse(first === second)

    menu.closeAfterClick(first)
    XCTAssertTrue(menu.isOpen, "the stale close must not close the new menu")

    menu.closeAfterClick(second)
    XCTAssertFalse(menu.isOpen)
  }
}
