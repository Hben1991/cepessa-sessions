import Foundation

protocol LocalSessionLanguageModelGenerating: Sendable {
  func generateText(prompt: String, maxTokens: Int) async throws -> String
}

enum EmbeddedLocalLanguageModelError: LocalizedError {
  case modelNotFound
  case runnerNotFound
  case runnerFailed(String)
  case runnerTimedOut
  case emptyResponse

  var errorDescription: String? {
    switch self {
    case .modelNotFound:
      return "The bundled local model is missing."
    case .runnerNotFound:
      return "The bundled local model runner is missing."
    case .runnerFailed(let message):
      return message.isEmpty ? "The bundled local model runner failed." : message
    case .runnerTimedOut:
      return "The bundled local model runner timed out."
    case .emptyResponse:
      return "The bundled local model returned an empty response."
    }
  }
}

enum EmbeddedLocalLanguageModelConfiguration {
  static let bundledModelFileName = "cepessa-local-model"
  static let bundledModelExtension = "gguf"
  static let runnerExecutableName = "CepessaLocalModelRunner"

  static func defaultModelURL(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    fileManager: FileManager = .default
  ) -> URL? {
    if let configuredPath = environment["CEPESSA_EMBEDDED_MODEL_PATH"]
      ?? environment["LOCAL_MODEL_PATH"],
      !configuredPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      return URL(fileURLWithPath: configuredPath).standardizedFileURL
    }

    if let bundledURL = Bundle.module.url(
      forResource: bundledModelFileName,
      withExtension: bundledModelExtension,
      subdirectory: "Models"
    ) {
      return bundledURL
    }

    guard
      let supportDirectory = try? fileManager.url(
        for: .applicationSupportDirectory,
        in: .userDomainMask,
        appropriateFor: nil,
        create: false
      )
    else {
      return nil
    }

    let appOwnedModelURL =
      supportDirectory
      .appendingPathComponent("Cepessa Sessions", isDirectory: true)
      .appendingPathComponent("Models", isDirectory: true)
      .appendingPathComponent("\(bundledModelFileName).\(bundledModelExtension)")

    return fileManager.fileExists(atPath: appOwnedModelURL.path) ? appOwnedModelURL : nil
  }

  static func defaultRunnerURL(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    fileManager: FileManager = .default
  ) -> URL? {
    if let configuredPath = environment["CEPESSA_LOCAL_MODEL_RUNNER_PATH"],
      !configuredPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      return URL(fileURLWithPath: configuredPath).standardizedFileURL
    }

    let bundledRunnerURL = Bundle.main.bundleURL
      .appendingPathComponent("Contents", isDirectory: true)
      .appendingPathComponent("MacOS", isDirectory: true)
      .appendingPathComponent(runnerExecutableName)
    if fileManager.isExecutableFile(atPath: bundledRunnerURL.path) {
      return bundledRunnerURL
    }

    let buildRunnerURL = Bundle.main.executableURL?
      .deletingLastPathComponent()
      .appendingPathComponent(runnerExecutableName)
    if let buildRunnerURL, fileManager.isExecutableFile(atPath: buildRunnerURL.path) {
      return buildRunnerURL
    }

    return nil
  }
}

struct EmbeddedLocalLanguageModel: LocalSessionLanguageModelGenerating {
  static let shared = EmbeddedLocalLanguageModel()

  let modelURL: URL?
  let runnerURL: URL?

  init(
    modelURL: URL? = EmbeddedLocalLanguageModelConfiguration.defaultModelURL(),
    runnerURL: URL? = EmbeddedLocalLanguageModelConfiguration.defaultRunnerURL()
  ) {
    self.modelURL = modelURL
    self.runnerURL = runnerURL
  }

  func generateText(prompt: String, maxTokens: Int = 700) async throws -> String {
    guard let modelURL else {
      throw EmbeddedLocalLanguageModelError.modelNotFound
    }
    guard let runnerURL else {
      throw EmbeddedLocalLanguageModelError.runnerNotFound
    }

    let process = Process()
    process.executableURL = runnerURL
    process.arguments = [
      "--model", modelURL.path,
      "--max-tokens", "\(max(1, maxTokens))",
    ]

    let inputPipe = Pipe()
    let outputPipe = Pipe()
    let errorPipe = Pipe()
    process.standardInput = inputPipe
    process.standardOutput = outputPipe
    process.standardError = errorPipe

    try process.run()
    if let data = prompt.data(using: .utf8) {
      inputPipe.fileHandleForWriting.write(data)
    }
    try? inputPipe.fileHandleForWriting.close()

    let didExit = await process.waitUntilExit(
      timeout: Self.timeoutSeconds(prompt: prompt, maxTokens: maxTokens)
    )
    if !didExit {
      process.terminate()
      try? await Task.sleep(nanoseconds: 300_000_000)
      if process.isRunning {
        process.interrupt()
      }
      throw EmbeddedLocalLanguageModelError.runnerTimedOut
    }

    let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
    let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()

    let output =
      String(data: outputData, encoding: .utf8)?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let error =
      String(data: errorData, encoding: .utf8)?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

    guard process.terminationStatus == 0 else {
      throw EmbeddedLocalLanguageModelError.runnerFailed(error)
    }
    guard !output.isEmpty else {
      throw EmbeddedLocalLanguageModelError.emptyResponse
    }

    return output
  }

  static func timeoutSeconds(prompt: String, maxTokens: Int) -> TimeInterval {
    let promptBudget = Double(prompt.utf8.count) / 1_500
    let generationBudget = Double(max(1, maxTokens)) * 0.05
    return min(90, max(30, 12 + promptBudget + generationBudget))
  }
}

extension Process {
  fileprivate func waitUntilExit(timeout: TimeInterval) async -> Bool {
    await withCheckedContinuation { continuation in
      let state = ProcessWaitState()

      DispatchQueue.global(qos: .userInitiated).async {
        self.waitUntilExit()
        state.resumeIfNeeded(continuation, value: true)
      }

      DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout) {
        state.resumeIfNeeded(continuation, value: false)
      }
    }
  }
}

private final class ProcessWaitState: @unchecked Sendable {
  private let lock = NSLock()
  private var didResume = false

  func resumeIfNeeded(_ continuation: CheckedContinuation<Bool, Never>, value: Bool) {
    lock.lock()
    defer { lock.unlock() }

    guard !didResume else { return }
    didResume = true
    continuation.resume(returning: value)
  }
}
