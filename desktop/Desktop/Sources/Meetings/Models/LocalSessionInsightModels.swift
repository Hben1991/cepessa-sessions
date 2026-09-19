import Foundation

enum LocalSessionInsightSchema {
  static let version = 1
  static let questionVersion = "session-insights-questions-v5"
  static let policyVersion = "session-insights-policy-experimental-v1"
  static let sidecarFileName = "insights.json"
}

enum LocalSessionInsightStatus: String, Codable, Equatable, Sendable {
  case notAnalyzed
  case running
  case complete
  case partial
  case failed
  case cancelled
  case stale
}

enum LocalSessionInsightKind: String, Codable, Equatable, Sendable, CaseIterable {
  case decision
  case commitment
  case openQuestion
}

enum LocalSessionInsightLifecycle: String, Codable, Equatable, Sendable {
  case proposed
  case conditional
  case retracted
  case superseded
  case unresolved
}

enum LocalSessionInsightReviewState: String, Codable, Equatable, Sendable {
  case unreviewed
  case confirmed
  case dismissed
}

enum LocalSessionInsightFailureCategory: String, Codable, Equatable, Sendable {
  case missingCredential
  case missingConsent
  case unauthorized
  case malformedRequest
  case rateLimited
  case overloaded
  case timeout
  case cancelled
  case offline
  case invalidAnswer
  case budgetExceeded
  case uncoveredInput
  case interrupted
  case unknown
}

enum LocalSessionInsightRelation: String, Codable, Equatable, Sendable, CaseIterable {
  case unrelated
  case supports
  case retracts
  case supersedes
  case ambiguous
}

struct LocalSessionInsightTextRange: Codable, Equatable, Sendable {
  var utf16Start: Int
  var utf16Length: Int

  var utf16End: Int { utf16Start + utf16Length }

  func isValid(in text: String) -> Bool {
    utf16Start >= 0 && utf16Length >= 0 && utf16End <= text.utf16.count
  }
}

struct LocalSessionInsightEvidenceSpan: Codable, Equatable, Sendable {
  var segmentID: UUID
  var range: LocalSessionInsightTextRange
}

struct LocalSessionInsightEvidence: Codable, Equatable, Sendable {
  var sessionID: UUID
  var spans: [LocalSessionInsightEvidenceSpan]
  var sourceSubstring: String
  var startOffsetSeconds: Double
  var endOffsetSeconds: Double?

  var segmentIDs: [UUID] { spans.map(\.segmentID) }
}

struct LocalSessionInsightJudgment: Codable, Equatable, Sendable {
  var decisionNoul: Double?
  var commitmentNoul: Double?
  var openQuestionNoul: Double?
  var conditionalNoul: Double?
  var evidenceSufficientNoul: Double?
  var relation: LocalSessionInsightRelation?
  var relationProbabilities: [String: Double]
  var relationConfidence: Double?
}

struct LocalSessionInsightItem: Identifiable, Codable, Equatable, Sendable {
  var id: UUID
  var identity: String
  var kind: LocalSessionInsightKind
  var evidence: LocalSessionInsightEvidence
  var proposalText: String
  var speaker: String
  var speakerID: String?
  var ownerEvidence: String?
  var deadlineQuote: String?
  var lifecycle: LocalSessionInsightLifecycle
  var relatedItemIDs: [UUID]
  var judgment: LocalSessionInsightJudgment
  var isProvisional: Bool
  var reviewState: LocalSessionInsightReviewState
  var reviewUpdatedAt: Date?
}

struct LocalSessionInsightReviewRecord: Codable, Equatable, Sendable {
  var identity: String
  var kind: LocalSessionInsightKind
  var evidenceSubstring: String
  var state: LocalSessionInsightReviewState
  var updatedAt: Date
}

struct LocalSessionInsightCoverage: Codable, Equatable, Sendable {
  var totalSegments: Int
  var totalSpans: Int
  var coveredSpanIDs: [String]
  var omittedSpanIDs: [String]
  var failedWindowIDs: [String]
  var reconciliationCoveredItemIDs: [UUID]
  var reconciliationOmittedItemIDs: [UUID]
}

struct LocalSessionInsightUsage: Codable, Equatable, Sendable {
  var requestCount: Int
  var retryCount: Int
  var inputTokens: Int
  var outputTokens: Int
  var latencyMilliseconds: Int
}

struct LocalSessionInsightMeetingJudgments: Codable, Equatable, Sendable {
  var meetingType: String?
  var meetingTypeLabel: String?
  var meetingTypeConfidence: Double?
  var decisionMadeNoul: Double?
  var actionItemClarityScore: Double?
  var actionItemClarityLevel: Int?
  var actionItemClarityLabel: String?
  var actionItemClarityConfidence: Double?
  var unresolvedFollowUpScore: Double?
  var unresolvedFollowUpLevel: Int?
  var unresolvedFollowUpLabel: String?
  var tensionScore: Double?
  var tensionLevel: Int?
  var tensionLabel: String?
}

struct LocalSessionInsightRecord: Codable, Equatable, Sendable {
  var schemaVersion: Int
  var analysisID: UUID
  var sessionID: UUID
  var createdAt: Date
  var updatedAt: Date
  var transcriptRevisionHash: String
  var provider: String
  var requestedModel: String
  var returnedModel: String?
  var questionVersion: String
  var policyVersion: String
  var status: LocalSessionInsightStatus
  var failureCategory: LocalSessionInsightFailureCategory?
  var failureMessage: String?
  var coverage: LocalSessionInsightCoverage
  var usage: LocalSessionInsightUsage
  var items: [LocalSessionInsightItem]
  var historicalReviews: [LocalSessionInsightReviewRecord]
  var userConsentedToCloud: Bool
  var meetingJudgments: LocalSessionInsightMeetingJudgments? = nil
}

struct LocalSessionInsightReveal: Equatable, Sendable {
  var sessionID: UUID
  var segmentID: UUID
  var range: LocalSessionInsightTextRange?
  var audioOffsetSeconds: Double?
  var generation: UUID
}

enum LocalSessionInsightJSON {
  static let encoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    return encoder
  }()

  static let decoder: JSONDecoder = {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }()
}
