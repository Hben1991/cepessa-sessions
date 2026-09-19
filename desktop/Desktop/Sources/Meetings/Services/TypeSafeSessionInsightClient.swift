import Foundation

protocol LocalSessionInsightHTTPTransporting: Sendable {
  func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

struct LocalSessionInsightURLSessionTransport: LocalSessionInsightHTTPTransporting {
  let session: URLSession

  init(session: URLSession = .shared) {
    self.session = session
  }

  func data(for request: URLRequest) async throws -> (Data, URLResponse) {
    try await session.data(for: request)
  }
}

struct TypeSafeSessionInsightClient: LocalSessionInsightProviding {
  var providerName: String { LocalSessionInsightPolicy.providerName }
  var requestedModel: String

  private let endpoint: URL
  private let transport: any LocalSessionInsightHTTPTransporting
  private let loadCredential: @Sendable () throws -> String?
  private let consent: @Sendable () -> Bool

  init(
    endpoint: URL = URL(string: "https://api.typesafe.ai/v1/systemone")!,
    requestedModel: String = LocalSessionInsightPolicy.requestedModel,
    transport: any LocalSessionInsightHTTPTransporting = LocalSessionInsightURLSessionTransport(),
    loadCredential: @escaping @Sendable () throws -> String? = {
      try LocalSessionInsightCredentialStore().load()
    },
    consent: @escaping @Sendable () -> Bool = { LocalSessionInsightPolicy.hasCloudConsent() }
  ) {
    self.endpoint = endpoint
    self.requestedModel = requestedModel
    self.transport = transport
    self.loadCredential = loadCredential
    self.consent = consent
  }

  func evaluate(
    state: LocalSessionInsightRequestState,
    questions: [LocalSessionInsightQuestion]
  ) async throws -> LocalSessionInsightProviderResponse {
    try Task.checkCancellation()
    guard consent() else { throw LocalSessionInsightProviderError.missingConsent }
    let apiKey: String
    do {
      guard let loaded = try loadCredential()?.trimmingCharacters(in: .whitespacesAndNewlines),
        !loaded.isEmpty
      else {
        throw LocalSessionInsightProviderError.missingCredential
      }
      apiKey = loaded
    } catch let error as LocalSessionInsightProviderError {
      throw error
    } catch {
      throw LocalSessionInsightProviderError.missingCredential
    }

    let body = try requestBody(state: state, questions: questions)
    var lastError: LocalSessionInsightProviderError = .unknownStatus
    for attempt in 0...LocalSessionInsightPolicy.maxRetriesPerRequest {
      try Task.checkCancellation()
      var request = URLRequest(url: endpoint, timeoutInterval: LocalSessionInsightPolicy.requestTimeoutSeconds)
      request.httpMethod = "POST"
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
      request.httpBody = body

      let data: Data
      let response: URLResponse
      do {
        (data, response) = try await transport.data(for: request)
      } catch is CancellationError {
        throw LocalSessionInsightProviderError.cancelled
      } catch {
        if Task.isCancelled { throw LocalSessionInsightProviderError.cancelled }
        lastError = mapTransportError(error)
        if shouldRetry(lastError), attempt < LocalSessionInsightPolicy.maxRetriesPerRequest {
          try await backoff(attempt: attempt, retryAfter: retryAfter(from: lastError))
          continue
        }
        throw lastError
      }

      guard let http = response as? HTTPURLResponse else {
        throw LocalSessionInsightProviderError.offline
      }
      if (200..<300).contains(http.statusCode) {
        do {
          return try decodeSuccess(data)
        } catch let error as LocalSessionInsightProviderError {
          throw error
        } catch {
          throw LocalSessionInsightProviderError.invalidAnswer("response")
        }
      }
      lastError = mapHTTP(http, data: data)
      if shouldRetry(lastError), attempt < LocalSessionInsightPolicy.maxRetriesPerRequest {
        try await backoff(attempt: attempt, retryAfter: retryAfter(from: lastError))
        continue
      }
      throw lastError
    }
    throw lastError
  }

  private func requestBody(
    state: LocalSessionInsightRequestState,
    questions: [LocalSessionInsightQuestion]
  ) throws -> Data {
    var questionMap: [String: Any] = [:]
    for question in questions {
      var payload: [String: Any] = [
        "type": question.kind.rawValue,
        "instructions": question.instructions,
      ]
      if question.kind == .score {
        payload["criteria"] = question.scoreLevels
      } else if !question.criteria.isEmpty {
        payload["criteria"] = question.criteria
      }
      questionMap[question.id] = payload
    }
    let stateObject = try JSONSerialization.jsonObject(
      with: try LocalSessionInsightJSON.encoder.encode(state)
    )
    let envelope: [String: Any] = [
      "state": stateObject,
      "model": requestedModel,
      "questions": questionMap,
    ]
    return try JSONSerialization.data(withJSONObject: envelope)
  }

  private func decodeSuccess(_ data: Data) throws -> LocalSessionInsightProviderResponse {
    let object = try JSONSerialization.jsonObject(with: data)
    guard let root = object as? [String: Any] else {
      throw LocalSessionInsightProviderError.invalidAnswer("response")
    }
    let model = root["model"] as? String ?? requestedModel
    let usage = root["usage"] as? [String: Any]
    let inputTokens = intValue(usage?["input_tokens"])
    let outputTokens = intValue(usage?["output_tokens"])
    guard let answers = root["answers"] as? [String: Any] else {
      throw LocalSessionInsightProviderError.invalidAnswer("answers")
    }

    var noul: [String: LocalSessionInsightNoulAnswer] = [:]
    var choices: [String: LocalSessionInsightChoiceAnswer] = [:]
    var scores: [String: LocalSessionInsightScoreAnswer] = [:]
    for (id, raw) in answers {
      guard let answer = raw as? [String: Any] else {
        throw LocalSessionInsightProviderError.invalidAnswer(id)
      }
      let type = answer["type"] as? String
      if type == "noul" || answer["noul"] != nil {
        guard let value = doubleValue(answer["noul"]),
          LocalSessionInsightPolicy.isFiniteUnitInterval(value)
        else {
          throw LocalSessionInsightProviderError.invalidAnswer(id)
        }
        noul[id] = LocalSessionInsightNoulAnswer(noul: value)
      } else if type == "choice" || answer["choice"] != nil {
        guard let choice = answer["choice"] as? String, !choice.isEmpty else {
          throw LocalSessionInsightProviderError.invalidAnswer(id)
        }
        var probabilities: [String: Double] = [:]
        if let rawProbabilities = answer["probabilities"] as? [String: Any] {
          for (key, rawValue) in rawProbabilities {
            guard let value = doubleValue(rawValue), value.isFinite else {
              throw LocalSessionInsightProviderError.invalidAnswer(id)
            }
            probabilities[key] = value
          }
        }
        let confidence = doubleValue(answer["confidence"]) ?? 0
        guard confidence.isFinite else {
          throw LocalSessionInsightProviderError.invalidAnswer(id)
        }
        choices[id] = LocalSessionInsightChoiceAnswer(
          choice: choice,
          probabilities: probabilities,
          confidence: confidence
        )
      } else if type == "score" || answer["score"] != nil {
        guard let value = doubleValue(answer["score"]), value.isFinite else {
          throw LocalSessionInsightProviderError.invalidAnswer(id)
        }
        let confidence = doubleValue(answer["confidence"]) ?? 0
        guard confidence.isFinite else {
          throw LocalSessionInsightProviderError.invalidAnswer(id)
        }
        var probabilities: [String: Double] = [:]
        if let rawProbabilities = answer["probabilities"] as? [String: Any] {
          for (key, rawValue) in rawProbabilities {
            guard let number = doubleValue(rawValue), number.isFinite else {
              throw LocalSessionInsightProviderError.invalidAnswer(id)
            }
            probabilities[key] = number
          }
        }
        var legend: [String: String] = [:]
        if let rawLegend = answer["legend"] as? [String: Any] {
          for (key, rawValue) in rawLegend {
            if let text = rawValue as? String {
              legend[key] = text
            }
          }
        }
        scores[id] = LocalSessionInsightScoreAnswer(
          score: value,
          confidence: confidence,
          probabilities: probabilities,
          legend: legend
        )
      } else {
        throw LocalSessionInsightProviderError.invalidAnswer(id)
      }
    }

    return LocalSessionInsightProviderResponse(
      model: model,
      noul: noul,
      choices: choices,
      scores: scores,
      inputTokens: inputTokens,
      outputTokens: outputTokens
    )
  }

  private func mapHTTP(_ response: HTTPURLResponse, data: Data) -> LocalSessionInsightProviderError {
    let retryAfter = retryAfterInterval(from: response)
    switch response.statusCode {
    case 401:
      return .unauthorized
    case 422:
      return .malformedRequest
    case 429:
      return .rateLimited(retryAfter: retryAfter)
    case 529:
      return .overloaded(retryAfter: retryAfter)
    default:
      _ = data.count
      return .httpStatus(response.statusCode)
    }
  }

  private func mapTransportError(_ error: Error) -> LocalSessionInsightProviderError {
    let urlError = error as? URLError
    switch urlError?.code {
    case .timedOut:
      return .timeout
    case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost, .dnsLookupFailed:
      return .offline
    case .cancelled:
      return .cancelled
    default:
      return .offline
    }
  }

  private func shouldRetry(_ error: LocalSessionInsightProviderError) -> Bool {
    switch error {
    case .rateLimited, .overloaded, .timeout, .offline:
      return true
    case .httpStatus(let code):
      return code >= 500
    default:
      return false
    }
  }

  private func retryAfter(from error: LocalSessionInsightProviderError) -> TimeInterval? {
    switch error {
    case .rateLimited(let value), .overloaded(let value):
      return value
    default:
      return nil
    }
  }

  private func retryAfterInterval(from response: HTTPURLResponse) -> TimeInterval? {
    guard let raw = response.value(forHTTPHeaderField: "Retry-After") else { return nil }
    if let seconds = TimeInterval(raw) { return max(0, seconds) }
    return nil
  }

  private func backoff(attempt: Int, retryAfter: TimeInterval?) async throws {
    try Task.checkCancellation()
    let delay = retryAfter ?? min(8, pow(2, Double(attempt)))
    let nanoseconds = UInt64(max(0.2, delay) * 1_000_000_000)
    try await Task.sleep(nanoseconds: nanoseconds)
  }

  private func intValue(_ raw: Any?) -> Int {
    if let value = raw as? Int { return value }
    if let value = raw as? Double { return Int(value) }
    if let value = raw as? NSNumber { return value.intValue }
    return 0
  }

  private func doubleValue(_ raw: Any?) -> Double? {
    if let value = raw as? Double { return value }
    if let value = raw as? Int { return Double(value) }
    if let value = raw as? NSNumber { return value.doubleValue }
    return nil
  }
}

extension LocalSessionInsightProviderError {
  static var unknownStatus: LocalSessionInsightProviderError { .httpStatus(-1) }
}
