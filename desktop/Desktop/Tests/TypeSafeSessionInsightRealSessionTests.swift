import Foundation
import XCTest

@testable import CepessaSessions

/// Live Jev on isolated copies of real session.json files. Never writes back to
/// the production Sessions store.
final class TypeSafeSessionInsightRealSessionTests: XCTestCase {
  func testLiveJevOnIsolatedRealSessionCopies() async throws {
    guard let key = ProcessInfo.processInfo.environment["TYPESAFE_API_KEY"]?
      .trimmingCharacters(in: .whitespacesAndNewlines),
      !key.isEmpty
    else {
      throw XCTSkip("Live Jev is not configured in this process.")
    }
    let root = ProcessInfo.processInfo.environment["CEPESSA_LIVE_SESSIONS_ROOT"]?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard let root, !root.isEmpty else {
      throw XCTSkip("CEPESSA_LIVE_SESSIONS_ROOT is not set.")
    }

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let fm = FileManager.default
    let sessionDirs = try fm.contentsOfDirectory(
      at: URL(fileURLWithPath: root, isDirectory: true),
      includingPropertiesForKeys: nil
    ).filter { url in
      fm.fileExists(atPath: url.appendingPathComponent("session.json").path)
    }.sorted { $0.lastPathComponent < $1.lastPathComponent }

    XCTAssertFalse(sessionDirs.isEmpty)
    let envOut = ProcessInfo.processInfo.environment["CEPESSA_LIVE_EVAL_OUT"]?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let outRoot = URL(
      fileURLWithPath: (envOut?.isEmpty == false ? envOut! : "/private/tmp/cepessa-sessions-jev/real-eval"),
      isDirectory: true
    )
    try fm.createDirectory(at: outRoot, withIntermediateDirectories: true)

    let client = TypeSafeSessionInsightClient(
      loadCredential: { key },
      consent: { true }
    )
    var summaries: [[String: Any]] = []

    for dir in sessionDirs {
      let data = try Data(contentsOf: dir.appendingPathComponent("session.json"))
      let session = try decoder.decode(LocalSession.self, from: data)
      let started = Date()
      let analyzer = LocalSessionInsightAnalyzer(provider: client)
      let record = try await analyzer.analyze(
        session: session,
        languagePreference: .mixed,
        previous: nil,
        userConsentedToCloud: true
      )
      let elapsed = Date().timeIntervalSince(started)
      let byKind = Dictionary(grouping: record.items, by: \.kind)
      let summary: [String: Any] = [
        "session_id": session.id.uuidString,
        "title": session.title,
        "segments": session.transcriptSegments.count,
        "status": record.status.rawValue,
        "provider": record.provider,
        "requested_model": record.requestedModel,
        "returned_model": record.returnedModel as Any,
        "failure": record.failureCategory?.rawValue as Any,
        "failure_message": record.failureMessage as Any,
        "requests": record.usage.requestCount,
        "input_tokens": record.usage.inputTokens,
        "output_tokens": record.usage.outputTokens,
        "elapsed_s": elapsed,
        "covered_spans": record.coverage.coveredSpanIDs.count,
        "total_spans": record.coverage.totalSpans,
        "omitted_spans": record.coverage.omittedSpanIDs.count,
        "failed_windows": record.coverage.failedWindowIDs.count,
        "item_count": record.items.count,
        "question_version": record.questionVersion,
        "decisions": byKind[.decision]?.count ?? 0,
        "commitments": byKind[.commitment]?.count ?? 0,
        "open_questions": byKind[.openQuestion]?.count ?? 0,
        "meeting_type": record.meetingJudgments?.meetingType as Any,
        "decision_made": record.meetingJudgments?.decisionMadeNoul as Any,
        "action_item_clarity": record.meetingJudgments?.actionItemClarityLevel as Any,
        "unresolved_followup": record.meetingJudgments?.unresolvedFollowUpLevel as Any,
        "tension": record.meetingJudgments?.tensionLevel as Any,
        "confirmed": record.items.filter { $0.reviewState == .confirmed }.count,
        "items": record.items.map { item in
          [
            "kind": item.kind.rawValue,
            "lifecycle": item.lifecycle.rawValue,
            "speaker": item.speaker,
            "offset_s": item.evidence.startOffsetSeconds,
            "chars": item.proposalText.count,
          ]
        },
      ]
      summaries.append(summary)
      let out = outRoot.appendingPathComponent("\(session.id.uuidString).json")
      let payload = try JSONSerialization.data(
        withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
      try payload.write(to: out)
      XCTAssertNotEqual(record.status, .failed, session.title)
    }

    let index = try JSONSerialization.data(
      withJSONObject: summaries, options: [.prettyPrinted, .sortedKeys])
    try index.write(to: outRoot.appendingPathComponent("index.json"))
  }
}
