import Foundation
import XCTest

@testable import CepessaSessions

final class TypeSafeSessionInsightLiveTests: XCTestCase {
  func testLiveJevRoundTripOnSyntheticHebrewDecision() async throws {
    guard let key = ProcessInfo.processInfo.environment["TYPESAFE_API_KEY"]?
      .trimmingCharacters(in: .whitespacesAndNewlines),
      !key.isEmpty
    else {
      throw XCTSkip("Live Jev is not configured in this process.")
    }

    let client = TypeSafeSessionInsightClient(
      loadCredential: { key },
      consent: { true }
    )
    let session = makeSession(
      startedAt: Date(timeIntervalSince1970: 1_700_000_000),
      segments: [("Maya", "סיכמנו שעולים בראשון")]
    )
    let window = LocalSessionInsightWindowBuilder.plan(session: session).windows[0]
    let state = LocalSessionInsightQuestionBuilder.state(
      session: session,
      window: window,
      languageHint: "Hebrew-first"
    )
    let question = try XCTUnwrap(
      LocalSessionInsightQuestionBuilder.detectionQuestions(for: window)
        .first { $0.id.hasSuffix("|decision") }
    )
    let response = try await client.evaluate(state: state, questions: [question])
    let noul = try XCTUnwrap(response.noul[question.id]?.noul)
    XCTAssertTrue(LocalSessionInsightPolicy.isFiniteUnitInterval(noul))
    XCTAssertFalse(response.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    XCTAssertGreaterThan(response.inputTokens, 0)
  }
}
