import Foundation

protocol LocalSessionRecapGenerating: Sendable {
    func generateRecap(for session: LocalSession) async -> LocalSessionRecap
}

struct LocalSessionRecapGenerationInput: Sendable {
    struct TranscriptCandidate: Sendable {
        let speaker: String
        let text: String
        let timestamp: Date
        let sessionOffset: TimeInterval
    }

    let sessionID: UUID
    let title: String
    let startedAt: Date
    let transcriptCandidates: [TranscriptCandidate]
    let attachmentCount: Int
    let captureArtifactCount: Int
}

protocol LocalSessionRecapLLMProviding: Sendable {
    func generateRecap(for input: LocalSessionRecapGenerationInput) async throws -> LocalSessionRecap
}

struct LocalSessionRecapGenerator: LocalSessionRecapGenerating {
    private let llmClient: (any LocalSessionRecapLLMProviding)?
    private let fallback = LocalSessionDeterministicRecapGenerator()

    init(llmClient: (any LocalSessionRecapLLMProviding)? = Self.defaultLLMClient()) {
        self.llmClient = llmClient
    }

    func generateRecap(for session: LocalSession) async -> LocalSessionRecap {
        let input = Self.makeInput(from: session)

        if let llmClient {
            do {
                let recap = try await llmClient.generateRecap(for: input)
                if recap.isMeaningful {
                    return recap
                }
            } catch {
                // Fall through to the deterministic path.
            }
        }

        return fallback.generateRecap(for: input)
    }

    private static func makeInput(from session: LocalSession) -> LocalSessionRecapGenerationInput {
        let transcriptCandidates = session.transcriptSegments.map { segment in
            LocalSessionRecapGenerationInput.TranscriptCandidate(
                speaker: segment.speaker,
                text: segment.text,
                timestamp: segment.timestamp,
                sessionOffset: max(0, segment.timestamp.timeIntervalSince(session.startedAt))
            )
        }

        return LocalSessionRecapGenerationInput(
            sessionID: session.id,
            title: session.title,
            startedAt: session.startedAt,
            transcriptCandidates: transcriptCandidates,
            attachmentCount: session.attachments.count,
            captureArtifactCount: session.captureArtifacts.count
        )
    }

    static func defaultLLMClient(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> (any LocalSessionRecapLLMProviding)? {
        let baseURL = normalizedBaseURL(environment["CEPESSA_OLLAMA_BASE_URL"] ?? environment["OLLAMA_HOST"])
            ?? URL(string: "http://127.0.0.1:11434")
        let model = environment["CEPESSA_OLLAMA_MODEL"] ?? environment["OLLAMA_MODEL"] ?? "gemma4:e4b"

        guard let baseURL else { return nil }
        return LocalSessionOllamaRecapClient(baseURL: baseURL, model: model)
    }

    private static func normalizedBaseURL(_ rawValue: String?) -> URL? {
        guard let rawValue = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty else {
            return nil
        }

        if rawValue.contains("://") {
            return URL(string: rawValue)
        }

        return URL(string: "http://\(rawValue)")
    }
}

struct LocalSessionOllamaRecapClient: LocalSessionRecapLLMProviding, Sendable {
    let baseURL: URL
    let model: String
    var requestTimeout: TimeInterval = 90
    var availabilityTimeout: TimeInterval = 1.5

    func generateRecap(for input: LocalSessionRecapGenerationInput) async throws -> LocalSessionRecap {
        struct RequestBody: Codable {
            let model: String
            let prompt: String
            let stream: Bool
        }

        struct ResponseBody: Codable {
            let response: String
        }

        try await ensureServerIsReachable()

        let prompt = LocalSessionOllamaRecapClient.prompt(for: input)
        let endpoint = baseURL.appendingPathComponent("api").appendingPathComponent("generate")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            RequestBody(model: model, prompt: prompt, stream: false)
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw NSError(domain: "LocalSessionOllamaRecapClient", code: 1)
        }

        let decoded = try JSONDecoder().decode(ResponseBody.self, from: data)
        let jsonString = decoded.response.jsonSubstringOrSelf
        let payloadData = jsonString.data(using: .utf8) ?? Data()
        let payload = try JSONDecoder().decode(LocalSessionRecapPayload.self, from: payloadData)
        return payload.makeRecap(startedAt: input.startedAt)
    }

    private func ensureServerIsReachable() async throws {
        let endpoint = baseURL.appendingPathComponent("api").appendingPathComponent("tags")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = availabilityTimeout

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw NSError(domain: "LocalSessionOllamaRecapClient", code: 0)
        }
    }

    private static func prompt(for input: LocalSessionRecapGenerationInput) -> String {
        let transcript = input.transcriptCandidates.map { candidate in
            let offset = String(format: "%.1f", candidate.sessionOffset)
            return "[\(offset)s] \(candidate.speaker): \(candidate.text)"
        }
        .joined(separator: "\n")

        return """
        You are generating a local session recap from a transcript.

        Return only valid JSON. No markdown. No commentary.
        The JSON object must match this shape:
        {
          "overview": "one concise paragraph",
          "keyPoints": [{"title":"...","summary":"...","bullets":["..."],"startOffsetSeconds":0,"endOffsetSeconds":0}],
          "decisions": [{"title":"...","summary":"...","bullets":["..."],"startOffsetSeconds":0,"endOffsetSeconds":0}],
          "actionItems": [{"title":"...","summary":"...","bullets":["..."],"startOffsetSeconds":0,"endOffsetSeconds":0}],
          "openQuestions": [{"title":"...","summary":"...","bullets":["..."],"startOffsetSeconds":0,"endOffsetSeconds":0}],
          "nextSteps": [{"title":"...","summary":"...","bullets":["..."],"startOffsetSeconds":0,"endOffsetSeconds":0}]
        }

        Session title: \(input.title)
        Attachment count: \(input.attachmentCount)
        Capture artifact count: \(input.captureArtifactCount)

        Transcript:
        \(transcript)
        """
    }
}

struct LocalSessionDeterministicRecapGenerator {
    func generateRecap(for input: LocalSessionRecapGenerationInput) -> LocalSessionRecap {
        let candidates = normalizedCandidates(from: input)

        let overviewSection = makeSection(
            kind: .overview,
            title: "Overview",
            summary: overviewSummary(for: input, candidates: candidates),
            candidates: candidates,
            maxItems: 2,
            matcher: { _ in true },
            fallbackBullets: [
                "Transcript captured locally on this Mac.",
                "The recap is generated without sending data to a remote service."
            ],
            startedAt: input.startedAt
        )

        let keyPointsSection = makeSection(
            kind: .keyPoints,
            title: "Key points",
            summary: "Notable discussion points from the session.",
            candidates: candidates,
            maxItems: 4,
            matcher: { candidate in
                candidate.score.contains(.keyPoint)
            },
            fallbackBullets: ["No strong key points were extracted from the transcript yet."],
            startedAt: input.startedAt
        )

        let decisionsSection = makeSection(
            kind: .decisions,
            title: "Decisions",
            summary: "Explicit decisions or agreements captured in the session.",
            candidates: candidates,
            maxItems: 3,
            matcher: { candidate in
                candidate.score.contains(.decision)
            },
            fallbackBullets: ["No explicit decisions were detected."],
            startedAt: input.startedAt
        )

        let actionItemsSection = makeSection(
            kind: .actionItem,
            title: "Action items",
            summary: "Tasks and follow-ups that need ownership.",
            candidates: candidates,
            maxItems: 4,
            matcher: { candidate in
                candidate.score.contains(.action)
            },
            fallbackBullets: ["No action items were detected."],
            startedAt: input.startedAt
        )

        let openQuestionsSection = makeSection(
            kind: .openQuestions,
            title: "Open questions",
            summary: "Items that still need confirmation or a decision.",
            candidates: candidates,
            maxItems: 3,
            matcher: { candidate in
                candidate.score.contains(.question)
            },
            fallbackBullets: ["No open questions were detected."],
            startedAt: input.startedAt
        )

        let nextStepsSection = makeSection(
            kind: .nextSteps,
            title: "Next steps",
            summary: "What should happen after the session.",
            candidates: candidates,
            maxItems: 4,
            matcher: { candidate in
                candidate.score.contains(.nextStep) || candidate.score.contains(.action)
            },
            fallbackBullets: ["No next steps were detected."],
            startedAt: input.startedAt
        )

        return LocalSessionRecap(
            overview: overviewSection.summary,
            generatedAt: Date(),
            sections: [
                overviewSection,
                keyPointsSection,
                decisionsSection,
                actionItemsSection,
                openQuestionsSection,
                nextStepsSection
            ]
        )
    }

    private func normalizedCandidates(
        from input: LocalSessionRecapGenerationInput
    ) -> [Candidate] {
        input.transcriptCandidates
            .flatMap { candidate in
                splitIntoSentences(candidate.text)
                    .map { sentence in
                        Candidate(
                            speaker: candidate.speaker,
                            text: sentence,
                            timestamp: candidate.timestamp,
                            sessionOffset: candidate.sessionOffset
                        )
                    }
            }
            .filter { !$0.text.isEmpty }
    }

    private func makeSection(
        kind: LocalSessionRecapSection.Kind,
        title: String,
        summary: String,
        candidates: [Candidate],
        maxItems: Int,
        matcher: (Candidate) -> Bool,
        fallbackBullets: [String],
        startedAt: Date
    ) -> LocalSessionRecapSection {
        let matched = candidates
            .filter(matcher)
            .sorted { lhs, rhs in
                if lhs.score.total != rhs.score.total {
                    return lhs.score.total > rhs.score.total
                }

                return lhs.sessionOffset < rhs.sessionOffset
            }

        let bullets = deduplicatedBullets(from: matched.prefix(maxItems).map { bulletText(for: $0) })
        let selectedBullets = bullets.isEmpty ? fallbackBullets : bullets
        let anchor = matched.first

        return LocalSessionRecapSection(
            id: UUID(),
            kind: kind,
            title: title,
            summary: summary,
            bullets: selectedBullets,
            anchorTimestamp: anchor?.timestamp ?? startedAt,
            startOffset: anchor?.sessionOffset,
            endOffset: anchor.map { $0.sessionOffset + 15 }
        )
    }

    private func overviewSummary(
        for input: LocalSessionRecapGenerationInput,
        candidates: [Candidate]
    ) -> String {
        guard let first = candidates.first else {
            return "No transcript text was captured for \"\(input.title)\" yet."
        }

        let highlight = candidates.prefix(2).map { bulletText(for: $0) }.joined(separator: " • ")
        var summary = "\"\(input.title)\" captured \(input.transcriptCandidates.count) transcript segment\(input.transcriptCandidates.count == 1 ? "" : "s")."
        if !highlight.isEmpty {
            summary += " \(highlight)"
        }
        if input.attachmentCount > 0 {
            summary += " \(input.attachmentCount) attachment\(input.attachmentCount == 1 ? "" : "s") anchored locally."
        }
        if input.captureArtifactCount > 0 {
            summary += " \(input.captureArtifactCount) capture artifact\(input.captureArtifactCount == 1 ? "" : "s") retained."
        }
        summary += " Opening line: \(bulletText(for: first))."
        return summary
    }

    private func bulletText(for candidate: Candidate) -> String {
        let speaker = candidate.speaker.trimmingCharacters(in: .whitespacesAndNewlines)
        if speaker.isEmpty || speaker == "Transcript" {
            return candidate.text
        }

        return "\(speaker): \(candidate.text)"
    }

    private func deduplicatedBullets(from bullets: [String]) -> [String] {
        var seen: Set<String> = []
        return bullets.filter { bullet in
            let key = bullet.lowercased()
            guard !seen.contains(key) else { return false }
            seen.insert(key)
            return true
        }
    }

    private func splitIntoSentences(_ text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let parts = trimmed
            .replacingOccurrences(of: "\n", with: " ")
            .split(whereSeparator: { ".!?".contains($0) })
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        return parts.isEmpty ? [trimmed] : parts
    }
}

private struct Candidate {
    struct Score: OptionSet {
        let rawValue: Int

        static let keyPoint = Score(rawValue: 1 << 0)
        static let decision = Score(rawValue: 1 << 1)
        static let action = Score(rawValue: 1 << 2)
        static let question = Score(rawValue: 1 << 3)
        static let nextStep = Score(rawValue: 1 << 4)

        var total: Int {
            rawValue.nonzeroBitCount
        }
    }

    let speaker: String
    let text: String
    let timestamp: Date
    let sessionOffset: TimeInterval

    var score: Score {
        let lowercased = text.lowercased()
        var score: Score = []

        if containsAny(lowercased, [
            "important",
            "blocker",
            "risk",
            "decision",
            "summary",
            "key",
            "goal",
            "scope",
            "owner",
            "timeline"
        ]) {
            score.insert(.keyPoint)
        }

        if containsAny(lowercased, [
            "decide",
            "decided",
            "agreed",
            "approved",
            "settled",
            "choose",
            "choose",
            "selected",
            "will use"
        ]) {
            score.insert(.decision)
        }

        if containsAny(lowercased, [
            "will",
            "i'll",
            "i will",
            "we will",
            "follow up",
            "follow-up",
            "action item",
            "own",
            "send",
            "prepare",
            "fix",
            "review",
            "update",
            "schedule"
        ]) {
            score.insert(.action)
            score.insert(.nextStep)
        }

        if text.contains("?") || containsAny(lowercased, [
            "question",
            "open question",
            "not sure",
            "unknown",
            "need to confirm",
            "depends",
            "clarify",
            "unresolved"
        ]) {
            score.insert(.question)
        }

        if containsAny(lowercased, [
            "next step",
            "next steps",
            "after this",
            "going forward",
            "follow up",
            "by tomorrow",
            "by next",
            "moving forward"
        ]) {
            score.insert(.nextStep)
        }

        return score
    }

    private func containsAny(_ text: String, _ patterns: [String]) -> Bool {
        patterns.contains { text.contains($0) }
    }
}

private struct LocalSessionRecapPayload: Codable {
    struct SectionPayload: Codable {
        var title: String
        var summary: String
        var bullets: [String]
        var startOffsetSeconds: TimeInterval?
        var endOffsetSeconds: TimeInterval?
    }

    var overview: String
    var keyPoints: [SectionPayload]
    var decisions: [SectionPayload]
    var actionItems: [SectionPayload]
    var openQuestions: [SectionPayload]
    var nextSteps: [SectionPayload]

    func makeRecap(startedAt: Date) -> LocalSessionRecap {
        LocalSessionRecap(
            overview: overview,
            generatedAt: Date(),
            sections: [
                makeSectionPayload(kind: .overview, payload: SectionPayload(title: "Overview", summary: overview, bullets: [overview], startOffsetSeconds: nil, endOffsetSeconds: nil), startedAt: startedAt),
                makeSectionPayloads(kind: .keyPoints, payloads: keyPoints, startedAt: startedAt),
                makeSectionPayloads(kind: .decisions, payloads: decisions, startedAt: startedAt),
                makeSectionPayloads(kind: .actionItem, payloads: actionItems, startedAt: startedAt),
                makeSectionPayloads(kind: .openQuestions, payloads: openQuestions, startedAt: startedAt),
                makeSectionPayloads(kind: .nextSteps, payloads: nextSteps, startedAt: startedAt)
            ]
        )
    }

    private func makeSectionPayload(
        kind: LocalSessionRecapSection.Kind,
        payload: SectionPayload,
        startedAt: Date
    ) -> LocalSessionRecapSection {
        LocalSessionRecapSection(
            id: UUID(),
            kind: kind,
            title: payload.title,
            summary: payload.summary,
            bullets: payload.bullets,
            anchorTimestamp: payload.startOffsetSeconds.map { startedAt.addingTimeInterval($0) },
            startOffset: payload.startOffsetSeconds,
            endOffset: payload.endOffsetSeconds
        )
    }

    private func makeSectionPayloads(
        kind: LocalSessionRecapSection.Kind,
        payloads: [SectionPayload],
        startedAt: Date
    ) -> LocalSessionRecapSection {
        guard let payload = payloads.first else {
            return LocalSessionRecapSection(
                id: UUID(),
                kind: kind,
                title: title(for: kind),
                summary: "",
                bullets: [],
                anchorTimestamp: nil,
                startOffset: nil,
                endOffset: nil
            )
        }

        let mergedBullets = payloads.flatMap { $0.bullets }
        let fallbackBullets = mergedBullets.isEmpty ? [payload.summary].filter { !$0.isEmpty } : mergedBullets
        let startOffset = payloads.compactMap(\.startOffsetSeconds).min()
        let endOffset = payloads.compactMap(\.endOffsetSeconds).max()

        return LocalSessionRecapSection(
            id: UUID(),
            kind: kind,
            title: payload.title.isEmpty ? title(for: kind) : payload.title,
            summary: payload.summary,
            bullets: fallbackBullets,
            anchorTimestamp: startOffset.map { startedAt.addingTimeInterval($0) },
            startOffset: startOffset,
            endOffset: endOffset
        )
    }

    private func title(for kind: LocalSessionRecapSection.Kind) -> String {
        switch kind {
        case .overview: return "Overview"
        case .keyPoints: return "Key points"
        case .decisions: return "Decisions"
        case .actionItem: return "Action items"
        case .openQuestions: return "Open questions"
        case .nextSteps: return "Next steps"
        case .notes: return "Notes"
        }
    }
}

private extension LocalSessionRecap {
    var isMeaningful: Bool {
        !overview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !sections.isEmpty
    }
}

private extension String {
    var jsonSubstringOrSelf: String {
        guard let firstBrace = firstIndex(of: "{"),
              let lastBrace = lastIndex(of: "}") else {
            return self.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return String(self[firstBrace...lastBrace]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
