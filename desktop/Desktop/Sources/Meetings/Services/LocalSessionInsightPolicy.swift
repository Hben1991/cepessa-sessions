import CryptoKit
import Foundation

enum LocalSessionInsightPolicy {
  static let requestedModel = "jev-latest"
  static let providerName = "typesafe-jev"
  static let fixtureProviderName = "fixture"
  static let experimentalLabel = "Experimental"

  /// Versioned development thresholds. These are not an accuracy guarantee.
  static let decisionNoulThreshold = 0.72
  static let commitmentNoulThreshold = 0.72
  static let openQuestionNoulThreshold = 0.72
  static let evidenceSufficientNoulThreshold = 0.55
  static let conditionalNoulThreshold = 0.60

  static let maxConcurrentRequests = 2
  static let maxRequestsPerAnalysis = 180
  static let maxRetriesPerRequest = 3
  static let requestTimeoutSeconds: TimeInterval = 45
  static let analysisBudgetSeconds: TimeInterval = 600
  static let maxEstimatedInputCharacters = 20_000
  static let maxFocalCharacters = 1_200
  static let contextSpanCount = 2
  static let maxFocalsPerWindow = 12
  static let audioSeekToleranceSeconds: TimeInterval = 0.35

  static let featureEnabledDefaultsKey = "cepessa.sessions.insights.featureEnabled"
  static let cloudConsentDefaultsKey = "cepessa.sessions.insights.cloudConsent"
  static let fixtureEnvironmentKey = "CEPESSA_INSIGHTS_USE_FIXTURE"

  static let cloudDisclosure =
    "This sends the selected transcript text to TypeSafe (Jev). Audio, screenshots, attachments, other sessions, and local file paths are not sent."

  static func isFeatureEnabled(defaults: UserDefaults = .standard) -> Bool {
    defaults.bool(forKey: featureEnabledDefaultsKey)
  }

  static func hasCloudConsent(defaults: UserDefaults = .standard) -> Bool {
    defaults.bool(forKey: cloudConsentDefaultsKey)
  }

  static func shouldUseFixtureProvider(
    processInfo: ProcessInfo = .processInfo
  ) -> Bool {
    processInfo.environment[fixtureEnvironmentKey] == "1"
  }

  static func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  static func transcriptRevisionHash(
    session: LocalSession,
    languagePreference: LocalSessionTranscriptionLanguagePreference
  ) -> String {
    let payload: [[String: String]] = session.transcriptSegments.map { segment in
      [
        "id": segment.id.uuidString,
        "text": segment.text,
        "timestamp": iso8601(segment.timestamp),
        "endTimestamp": segment.endTimestamp.map(iso8601) ?? "",
        "speaker": segment.speaker,
        "speakerID": segment.speakerID ?? "",
      ]
    }
    let envelope: [String: Any] = [
      "sessionID": session.id.uuidString,
      "startedAt": iso8601(session.startedAt),
      "languagePreference": languagePreference.rawValue,
      "segments": payload,
    ]
    let data =
      (try? JSONSerialization.data(
        withJSONObject: envelope, options: [.sortedKeys]
      )) ?? Data()
    return sha256Hex(data)
  }

  static func itemIdentity(
    kind: LocalSessionInsightKind,
    evidence: LocalSessionInsightEvidence
  ) -> String {
    let spanKey = evidence.spans.map { span in
      "\(span.segmentID.uuidString):\(span.range.utf16Start):\(span.range.utf16Length)"
    }.joined(separator: "|")
    let raw = "\(kind.rawValue)|\(evidence.sessionID.uuidString)|\(spanKey)|\(evidence.sourceSubstring)"
    return sha256Hex(Data(raw.utf8))
  }

  static func isFiniteUnitInterval(_ value: Double) -> Bool {
    value.isFinite && value >= 0 && value <= 1
  }

  static func iso8601(_ date: Date) -> String {
    ISO8601DateFormatter().string(from: date)
  }

  static func offsetSeconds(from start: Date, to timestamp: Date) -> Double {
    max(0, timestamp.timeIntervalSince(start))
  }
}
