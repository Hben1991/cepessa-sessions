import Foundation

actor LocalSessionInsightAnalyzer {
  private let provider: any LocalSessionInsightProviding
  private let clock: @Sendable () -> Date
  private let requestLimit: Int
  private var requestCount = 0

  init(
    provider: any LocalSessionInsightProviding,
    clock: @escaping @Sendable () -> Date = { Date() },
    requestLimit: Int = LocalSessionInsightPolicy.maxRequestsPerAnalysis
  ) {
    self.provider = provider
    self.clock = clock
    self.requestLimit = requestLimit
  }

  func analyze(
    session: LocalSession,
    languagePreference: LocalSessionTranscriptionLanguagePreference,
    previous: LocalSessionInsightRecord?,
    userConsentedToCloud: Bool,
    onProgress: @Sendable (LocalSessionInsightRecord) -> Void = { _ in }
  ) async throws -> LocalSessionInsightRecord {
    let started = clock()
    let revision = LocalSessionInsightPolicy.transcriptRevisionHash(
      session: session, languagePreference: languagePreference)
    let analysisID = UUID()
    var usage = LocalSessionInsightUsage(
      requestCount: 0, retryCount: 0, inputTokens: 0, outputTokens: 0, latencyMilliseconds: 0)
    requestCount = 0

    let plan = LocalSessionInsightWindowBuilder.plan(session: session)
    var processedSpanIDs: [String] = []
    var coverage = LocalSessionInsightCoverage(
      totalSegments: session.transcriptSegments.count,
      totalSpans: plan.spans.count,
      coveredSpanIDs: [],
      omittedSpanIDs: plan.omittedSpanIDs,
      failedWindowIDs: [],
      reconciliationCoveredItemIDs: [],
      reconciliationOmittedItemIDs: []
    )

    var record = LocalSessionInsightRecord(
      schemaVersion: LocalSessionInsightSchema.version,
      analysisID: analysisID,
      sessionID: session.id,
      createdAt: started,
      updatedAt: started,
      transcriptRevisionHash: revision,
      provider: provider.providerName,
      requestedModel: provider.requestedModel,
      returnedModel: nil,
      questionVersion: LocalSessionInsightSchema.questionVersion,
      policyVersion: LocalSessionInsightSchema.policyVersion,
      status: .running,
      failureCategory: nil,
      failureMessage: nil,
      coverage: coverage,
      usage: usage,
      items: [],
      historicalReviews: previous?.historicalReviews ?? [],
      userConsentedToCloud: userConsentedToCloud
    )
    onProgress(record)

    var items: [LocalSessionInsightItem] = []
    var meetingJudgments: LocalSessionInsightMeetingJudgments?
    var returnedModel: String?
    let languageHint = languagePreference.rawValue

    do {
      try Task.checkCancellation()
      for window in plan.windows {
        try Task.checkCancellation()
        try checkBudget(started: started)
        let questions = LocalSessionInsightQuestionBuilder.detectionQuestions(for: window)
        let state = LocalSessionInsightQuestionBuilder.state(
          session: session, window: window, languageHint: languageHint)
        let response = try await perform(state: state, questions: questions, usage: &usage)
        returnedModel = response.model
        processedSpanIDs.append(contentsOf: window.focal.map(\.id))
        items.append(
          contentsOf: itemsFromDetection(
            session: session,
            window: window,
            response: response,
            now: started
          )
        )
        coverage.coveredSpanIDs = processedSpanIDs
        record.coverage = coverage
        record.usage = usage
        record.returnedModel = returnedModel
        record.items = items
        record.updatedAt = clock()
        onProgress(record)
      }

      let unprocessed = plan.windows.flatMap(\.focal).map(\.id).filter {
        !processedSpanIDs.contains($0)
      }
      if !unprocessed.isEmpty {
        coverage.omittedSpanIDs.append(contentsOf: unprocessed)
      }

      let reconcilable = items.filter {
        $0.kind == .decision || $0.kind == .commitment || $0.kind == .openQuestion
      }
      for item in reconcilable {
        try Task.checkCancellation()
        let originIndex = itemSpanSegmentIndex(item, plan)
        let laterSpans = plan.spans.filter { $0.segmentIndex > originIndex }
        if laterSpans.isEmpty {
          coverage.reconciliationCoveredItemIDs.append(item.id)
          continue
        }
        let packed = packedLaterWindow(id: "later:\(item.id.uuidString)", spans: laterSpans)
        do {
          try checkBudget(started: started)
          let question = LocalSessionInsightQuestionBuilder.relationQuestion(
            item: item, window: packed)
          let state = LocalSessionInsightQuestionBuilder.state(
            session: session, window: packed, languageHint: languageHint, candidate: item)
          let response = try await perform(state: state, questions: [question], usage: &usage)
          returnedModel = response.model
          applyRelation(response, to: &items, itemID: item.id)
          coverage.reconciliationCoveredItemIDs.append(item.id)
        } catch LocalSessionInsightProviderError.cancelled {
          throw LocalSessionInsightProviderError.cancelled
        } catch LocalSessionInsightProviderError.budgetExceeded {
          coverage.reconciliationOmittedItemIDs.append(item.id)
          markProvisional(&items, itemID: item.id)
          let rest = reconcilable.filter {
            !coverage.reconciliationCoveredItemIDs.contains($0.id)
              && !coverage.reconciliationOmittedItemIDs.contains($0.id)
          }
          for leftover in rest {
            coverage.reconciliationOmittedItemIDs.append(leftover.id)
            markProvisional(&items, itemID: leftover.id)
          }
          throw LocalSessionInsightProviderError.budgetExceeded
        } catch {
          coverage.failedWindowIDs.append(packed.id)
          coverage.reconciliationOmittedItemIDs.append(item.id)
          markProvisional(&items, itemID: item.id)
        }
      }

      do {
        try Task.checkCancellation()
        try checkBudget(started: started)
        let questions = LocalSessionInsightQuestionBuilder.meetingQuestions()
        let state = LocalSessionInsightQuestionBuilder.meetingState(
          session: session, languageHint: languageHint, items: items)
        let response = try await perform(state: state, questions: questions, usage: &usage)
        returnedModel = response.model
        meetingJudgments = LocalSessionInsightQuestionBuilder.meetingJudgments(from: response)
        record.meetingJudgments = meetingJudgments
        record.usage = usage
        record.returnedModel = returnedModel
        record.updatedAt = clock()
        onProgress(record)
      } catch LocalSessionInsightProviderError.cancelled {
        throw LocalSessionInsightProviderError.cancelled
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        // Span results stay; meeting scores are optional.
      }
    } catch is CancellationError {
      coverage.coveredSpanIDs = processedSpanIDs
      let leftover = plan.windows.flatMap(\.focal).map(\.id).filter {
        !processedSpanIDs.contains($0) && !coverage.omittedSpanIDs.contains($0)
      }
      coverage.omittedSpanIDs.append(contentsOf: leftover)
      record = finish(
        record, items: items, coverage: coverage, usage: usage, model: returnedModel,
        status: .cancelled, category: .cancelled, message: "Analysis was cancelled.",
        now: clock())
      onProgress(record)
      return record
    } catch LocalSessionInsightProviderError.cancelled {
      coverage.coveredSpanIDs = processedSpanIDs
      let leftover = plan.windows.flatMap(\.focal).map(\.id).filter {
        !processedSpanIDs.contains($0) && !coverage.omittedSpanIDs.contains($0)
      }
      coverage.omittedSpanIDs.append(contentsOf: leftover)
      record = finish(
        record, items: items, coverage: coverage, usage: usage, model: returnedModel,
        status: .cancelled, category: .cancelled, message: "Analysis was cancelled.",
        now: clock())
      onProgress(record)
      return record
    } catch {
      coverage.coveredSpanIDs = processedSpanIDs
      let leftover = plan.windows.flatMap(\.focal).map(\.id).filter {
        !processedSpanIDs.contains($0) && !coverage.omittedSpanIDs.contains($0)
      }
      coverage.omittedSpanIDs.append(contentsOf: leftover)
      let mapped = mapFailure(error)
      let status: LocalSessionInsightStatus = items.isEmpty ? .failed : .partial
      record = finish(
        record, items: items, coverage: coverage, usage: usage, model: returnedModel,
        status: status, category: mapped.0, message: mapped.1, now: clock())
      onProgress(record)
      return record
    }

    let hasHoles =
      !coverage.omittedSpanIDs.isEmpty || !coverage.failedWindowIDs.isEmpty
      || !coverage.reconciliationOmittedItemIDs.isEmpty
    items = applyReviews(items, previous: previous, now: clock())
    let historical = mergedHistory(previous: previous, items: items)
    record = finish(
      record,
      items: items,
      coverage: coverage,
      usage: usage,
      model: returnedModel,
      status: hasHoles ? .partial : .complete,
      category: hasHoles ? .uncoveredInput : nil,
      message: hasHoles
        ? "Some spans were omitted or could not be reconciled. Results stay provisional." : nil,
      now: clock()
    )
    record.meetingJudgments = meetingJudgments
    record.historicalReviews = historical
    record.usage.latencyMilliseconds = Int(clock().timeIntervalSince(started) * 1000)
    onProgress(record)
    return record
  }

  private func perform(
    state: LocalSessionInsightRequestState,
    questions: [LocalSessionInsightQuestion],
    usage: inout LocalSessionInsightUsage
  ) async throws -> LocalSessionInsightProviderResponse {
    if requestCount >= requestLimit {
      throw LocalSessionInsightProviderError.budgetExceeded
    }
    requestCount += 1
    usage.requestCount += 1
    let response = try await provider.evaluate(state: state, questions: questions)
    usage.inputTokens += response.inputTokens
    usage.outputTokens += response.outputTokens
    try validate(response, questions: questions)
    return response
  }

  private func validate(
    _ response: LocalSessionInsightProviderResponse,
    questions: [LocalSessionInsightQuestion]
  ) throws {
    for question in questions {
      switch question.kind {
      case .noul:
        guard let answer = response.noul[question.id],
          LocalSessionInsightPolicy.isFiniteUnitInterval(answer.noul)
        else {
          throw LocalSessionInsightProviderError.invalidAnswer(question.id)
        }
      case .choice:
        guard let answer = response.choices[question.id],
          question.criteria.keys.contains(answer.choice),
          answer.confidence.isFinite
        else {
          throw LocalSessionInsightProviderError.invalidAnswer(question.id)
        }
        for value in answer.probabilities.values where !value.isFinite {
          throw LocalSessionInsightProviderError.invalidAnswer(question.id)
        }
      case .score:
        guard let answer = response.scores[question.id],
          answer.score.isFinite,
          answer.confidence.isFinite,
          question.scoreLevels.count >= 2
        else {
          throw LocalSessionInsightProviderError.invalidAnswer(question.id)
        }
        for value in answer.probabilities.values where !value.isFinite {
          throw LocalSessionInsightProviderError.invalidAnswer(question.id)
        }
      }
    }
  }

  private func itemsFromDetection(
    session: LocalSession,
    window: LocalSessionInsightWindow,
    response: LocalSessionInsightProviderResponse,
    now: Date
  ) -> [LocalSessionInsightItem] {
    var items: [LocalSessionInsightItem] = []
    for span in window.focal {
      let sufficient =
        response.noul["\(span.id)|sufficient"]?.noul
        ?? 0
      guard sufficient >= LocalSessionInsightPolicy.evidenceSufficientNoulThreshold else {
        continue
      }
      let evidence = LocalSessionInsightWindowBuilder.evidence(for: span, sessionID: session.id)
      guard LocalSessionInsightWindowBuilder.validateEvidence(evidence, in: session) else {
        continue
      }
      let conditional =
        (response.noul["\(span.id)|conditional"]?.noul ?? 0)
        >= LocalSessionInsightPolicy.conditionalNoulThreshold
      let judgment = LocalSessionInsightJudgment(
        decisionNoul: response.noul["\(span.id)|decision"]?.noul,
        commitmentNoul: response.noul["\(span.id)|commitment"]?.noul,
        openQuestionNoul: response.noul["\(span.id)|open_question"]?.noul,
        conditionalNoul: response.noul["\(span.id)|conditional"]?.noul,
        evidenceSufficientNoul: sufficient,
        relation: nil,
        relationProbabilities: [:],
        relationConfidence: nil
      )
      let speaker = span.speaker.trimmingCharacters(in: .whitespacesAndNewlines)

      func append(kind: LocalSessionInsightKind, noul: Double, threshold: Double) {
        guard noul >= threshold else { return }
        let lifecycle: LocalSessionInsightLifecycle =
          conditional
          ? .conditional
          : (kind == .openQuestion ? .unresolved : .proposed)
        items.append(
          LocalSessionInsightItem(
            id: UUID(),
            identity: LocalSessionInsightPolicy.itemIdentity(kind: kind, evidence: evidence),
            kind: kind,
            evidence: evidence,
            proposalText: span.text.trimmingCharacters(in: .whitespacesAndNewlines),
            speaker: speaker,
            speakerID: span.speakerID,
            ownerEvidence: nil,
            deadlineQuote: nil,
            lifecycle: lifecycle,
            relatedItemIDs: [],
            judgment: judgment,
            isProvisional: false,
            reviewState: .unreviewed,
            reviewUpdatedAt: nil
          )
        )
      }

      append(
        kind: .decision,
        noul: judgment.decisionNoul ?? 0,
        threshold: LocalSessionInsightPolicy.decisionNoulThreshold
      )
      append(
        kind: .commitment,
        noul: judgment.commitmentNoul ?? 0,
        threshold: LocalSessionInsightPolicy.commitmentNoulThreshold
      )
      append(
        kind: .openQuestion,
        noul: judgment.openQuestionNoul ?? 0,
        threshold: LocalSessionInsightPolicy.openQuestionNoulThreshold
      )
    }
    return items
  }

  private func applyRelation(
    _ response: LocalSessionInsightProviderResponse,
    to items: inout [LocalSessionInsightItem],
    itemID: UUID
  ) {
    guard let index = items.firstIndex(where: { $0.id == itemID }) else { return }
    guard let answer = response.choices.values.first,
      let relation = LocalSessionInsightRelation(rawValue: answer.choice)
    else { return }
    items[index].judgment.relation = relation
    items[index].judgment.relationProbabilities = answer.probabilities
    items[index].judgment.relationConfidence = answer.confidence
    switch relation {
    case .retracts:
      items[index].lifecycle = .retracted
    case .supersedes:
      items[index].lifecycle = .superseded
    case .supports, .unrelated, .ambiguous:
      break
    }
  }

  private func markProvisional(_ items: inout [LocalSessionInsightItem], itemID: UUID) {
    guard let index = items.firstIndex(where: { $0.id == itemID }) else { return }
    items[index].isProvisional = true
  }

  private func applyReviews(
    _ items: [LocalSessionInsightItem],
    previous: LocalSessionInsightRecord?,
    now: Date
  ) -> [LocalSessionInsightItem] {
    guard let previous else { return items }
    let byIdentity = Dictionary(uniqueKeysWithValues: previous.items.map { ($0.identity, $0) })
    return items.map { item in
      var updated = item
      if let prior = byIdentity[item.identity],
        prior.evidence.sourceSubstring == item.evidence.sourceSubstring,
        prior.kind == item.kind
      {
        updated.reviewState = prior.reviewState
        updated.reviewUpdatedAt = prior.reviewUpdatedAt
        updated.id = prior.id
      }
      return updated
    }
  }

  private func mergedHistory(
    previous: LocalSessionInsightRecord?,
    items: [LocalSessionInsightItem]
  ) -> [LocalSessionInsightReviewRecord] {
    var history = previous?.historicalReviews ?? []
    let currentIdentities = Set(items.map(\.identity))
    if let previous {
      for item in previous.items
      where item.reviewState != .unreviewed && !currentIdentities.contains(item.identity) {
        history.append(
          LocalSessionInsightReviewRecord(
            identity: item.identity,
            kind: item.kind,
            evidenceSubstring: item.evidence.sourceSubstring,
            state: item.reviewState,
            updatedAt: item.reviewUpdatedAt ?? previous.updatedAt
          )
        )
      }
    }
    return history
  }

  private func finish(
    _ record: LocalSessionInsightRecord,
    items: [LocalSessionInsightItem],
    coverage: LocalSessionInsightCoverage,
    usage: LocalSessionInsightUsage,
    model: String?,
    status: LocalSessionInsightStatus,
    category: LocalSessionInsightFailureCategory?,
    message: String?,
    now: Date
  ) -> LocalSessionInsightRecord {
    var next = record
    next.items = items
    next.coverage = coverage
    next.usage = usage
    next.returnedModel = model
    next.status = status
    next.failureCategory = category
    next.failureMessage = message
    next.updatedAt = now
    return next
  }

  private func packedLaterWindow(
    id: String,
    spans: [LocalSessionInsightSpan]
  ) -> LocalSessionInsightWindow {
    let focalLimit = LocalSessionInsightPolicy.maxFocalsPerWindow
    let focal = Array(spans.prefix(focalLimit))
    let following = Array(spans.dropFirst(focalLimit).prefix(LocalSessionInsightPolicy.contextSpanCount))
    return LocalSessionInsightWindow(
      id: id,
      focal: focal,
      preceding: [],
      following: following
    )
  }

  private func itemSpanSegmentIndex(
    _ item: LocalSessionInsightItem,
    _ plan: LocalSessionInsightWindowPlan
  ) -> Int {
    guard let segmentID = item.evidence.segmentIDs.first,
      let span = plan.spans.first(where: { $0.segmentID == segmentID })
    else { return 0 }
    return span.segmentIndex
  }

  private func checkBudget(started: Date) throws {
    if clock().timeIntervalSince(started) > LocalSessionInsightPolicy.analysisBudgetSeconds {
      throw LocalSessionInsightProviderError.timeout
    }
  }

  private func mapFailure(_ error: Error) -> (LocalSessionInsightFailureCategory, String) {
    if let providerError = error as? LocalSessionInsightProviderError {
      switch providerError {
      case .missingCredential:
        return (.missingCredential, "Add a TypeSafe API key in Settings to analyze this transcript.")
      case .missingConsent:
        return (.missingConsent, "Cloud analysis stays off until it is explicitly started.")
      case .unauthorized:
        return (.unauthorized, "TypeSafe rejected the stored API key.")
      case .malformedRequest:
        return (.malformedRequest, "The analysis request was rejected as malformed.")
      case .rateLimited:
        return (.rateLimited, "TypeSafe rate-limited the analysis.")
      case .overloaded:
        return (.overloaded, "TypeSafe was overloaded.")
      case .timeout:
        return (.timeout, "The analysis timed out.")
      case .cancelled:
        return (.cancelled, "Analysis was cancelled.")
      case .offline:
        return (.offline, "The Mac could not reach TypeSafe.")
      case .invalidAnswer:
        return (.invalidAnswer, "A provider answer failed local validation.")
      case .httpStatus:
        return (.unknown, "The provider returned an unexpected HTTP status.")
      case .budgetExceeded:
        return (.budgetExceeded, "The analysis reached its request budget.")
      }
    }
    return (.unknown, "Analysis failed.")
  }
}
