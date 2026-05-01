import XCTest

@testable import CepessaSessions

final class SessionDocumentChatPresentationTests: XCTestCase {
  func testOpenChatUsesInlinePlacementInsteadOfFloatingOverlay() {
    XCTAssertEqual(
      WorkspaceDocumentChatPlacement.resolve(layout: .wide, isOpen: true),
      .trailingDock
    )
    XCTAssertEqual(
      WorkspaceDocumentChatPlacement.resolve(layout: .split, isOpen: true),
      .inlineBelowDocument
    )
    XCTAssertEqual(
      WorkspaceDocumentChatPlacement.resolve(layout: .stacked, isOpen: true),
      .inlineBelowDocument
    )
    XCTAssertEqual(
      WorkspaceDocumentChatPlacement.resolve(layout: .wide, isOpen: false),
      .hidden
    )
  }

  func testPendingProposalKeepsChatHistoryCompactEnoughForActionControls() {
    XCTAssertLessThan(
      SessionDocumentChatLayout.messageHistoryMaxHeight(hasPendingProposal: true),
      SessionDocumentChatLayout.messageHistoryMaxHeight(hasPendingProposal: false)
    )
    XCTAssertLessThanOrEqual(
      SessionDocumentChatLayout.messageHistoryMaxHeight(hasPendingProposal: true),
      180
    )
  }

  func testAssistantDisplayNameUsesSessionsBrand() {
    XCTAssertEqual(SessionDocumentChatCopy.assistantDisplayName, "Sessions")
  }
}
