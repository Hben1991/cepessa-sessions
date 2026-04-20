import XCTest
@testable import OmiLocalMeetings

@MainActor
final class AppModelTests: XCTestCase {
    func testStartsWithEmptyLibraryAndNoSelection() {
        let model = AppModel()

        XCTAssertTrue(model.sessions.isEmpty)
        XCTAssertNil(model.selectedSessionID)
        XCTAssertNil(model.selectedSession)
    }

    func testLoadingSampleSessionsSelectsTheFirstSession() {
        let model = AppModel()

        model.loadSampleSessions()

        XCTAssertEqual(model.sessions.count, 2)
        XCTAssertEqual(model.selectedSession?.id, model.sessions.first?.id)
    }

    func testSelectingExistingNonDefaultSessionResolvesSelectedSession() {
        let model = AppModel()
        model.loadSampleSessions()

        let secondSession = model.sessions[1]

        model.selectSession(id: secondSession.id)

        XCTAssertEqual(model.selectedSessionID, secondSession.id)
        XCTAssertEqual(model.selectedSession, secondSession)
    }

    func testSelectingMissingSessionLeavesSelectionCleared() {
        let model = AppModel()
        model.loadSampleSessions()

        model.selectSession(id: UUID())

        XCTAssertNil(model.selectedSessionID)
        XCTAssertNil(model.selectedSession)
    }

    func testReplacingSessionsClearsStaleSelection() {
        let model = AppModel()
        model.loadSampleSessions()

        let secondSession = model.sessions[1]
        model.selectSession(id: secondSession.id)

        model.sessions = [model.sessions[0]]

        XCTAssertNil(model.selectedSessionID)
        XCTAssertNil(model.selectedSession)
    }
}
