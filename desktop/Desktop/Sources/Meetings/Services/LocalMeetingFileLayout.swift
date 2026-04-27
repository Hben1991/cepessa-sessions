import Foundation

enum LocalSessionTranscriptionEngineKind: String, Codable, Equatable, Sendable {
  case whisperKit
  case whisperCpp
}

enum LocalSessionTranscriptionModelFlavor: String, Equatable, Sendable {
  case whisperKitMultilingualTurbo
  case whisperKitHebrewTurbo
  case multilingualFast
  case hebrewTurbo
}

struct LocalSessionTranscriptionPlan: Equatable, Sendable {
  let engine: LocalSessionTranscriptionEngineKind
  let modelURL: URL
  let language: String
  let prompt: String?
  let modelFlavor: LocalSessionTranscriptionModelFlavor
  let speedMode: LocalSessionTranscriptionSpeedMode
}

enum LocalSessionTranscriptionSpeedMode: String, CaseIterable, Equatable, Sendable {
  case fastDraft = "Fast draft"
  case balanced = "Balanced"
  case mostAccurate = "Most accurate"

  init(settingsValue: String) {
    self = Self(rawValue: settingsValue) ?? .balanced
  }
}

enum LocalSessionTranscriptionLanguagePreference: String, Equatable, Sendable {
  case mixed = "Mixed"
  case hebrewFirst = "Hebrew-first"
  case englishFirst = "English-first"

  init(settingsValue: String) {
    self = Self(rawValue: settingsValue) ?? .mixed
  }

  var languageCode: String {
    switch self {
    case .mixed:
      return LocalSessionFileLayout.automaticLanguageCode
    case .hebrewFirst:
      return "he"
    case .englishFirst:
      return "en"
    }
  }
}

struct LocalSessionTranscriptionSettings: Equatable, Sendable {
  let speedMode: LocalSessionTranscriptionSpeedMode
  let languagePreference: LocalSessionTranscriptionLanguagePreference

  static func current(defaults: UserDefaults = .standard) -> Self {
    Self(
      speedMode: .init(
        settingsValue: defaults.string(forKey: "cepessa.sessions.transcriptionSpeedMode")
          ?? LocalSessionTranscriptionSpeedMode.balanced.rawValue),
      languagePreference: .init(
        settingsValue: defaults.string(forKey: "cepessa.sessions.preferredTranscriptLanguage")
          ?? LocalSessionTranscriptionLanguagePreference.mixed.rawValue)
    )
  }
}

struct LocalSessionFileLayout {
  static let defaultWhisperKitMultilingualModelID = "openai_whisper-large-v3-turbo"
  static let defaultWhisperKitHebrewModelID = "ivrit-ai_whisper-large-v3-turbo"
  static let defaultHebrewModelID = "ivrit-ai_whisper-large-v3-turbo-ggml"
  private static let defaultHebrewModelFileName = "ggml-model.bin"
  private static let legacyRootName = "Cepessa Legacy"
  private static let legacySessionsRootName = "Meetings"
  private static let currentRootName = "Cepessa"
  fileprivate static let automaticLanguageCode = "auto"
  private static let fallbackMixedLanguagePrompt =
    "Keep Hebrew and English words in the language they were spoken."
  private static let whisperKitModelIDsBySpeedMode: [LocalSessionTranscriptionSpeedMode: [String]]
    = [
      .fastDraft: [
        "openai_whisper-small",
        "openai_whisper-base",
        "openai_whisper-tiny",
        Self.defaultWhisperKitMultilingualModelID,
        "openai_whisper-large-v3-v20240930_626MB",
      ],
      .balanced: [
        Self.defaultWhisperKitMultilingualModelID,
        "openai_whisper-large-v3-v20240930_626MB",
        "openai_whisper-small",
        "openai_whisper-base",
        "openai_whisper-tiny",
      ],
      .mostAccurate: [
        Self.defaultWhisperKitMultilingualModelID,
        "openai_whisper-large-v3-v20240930_626MB",
        "openai_whisper-large-v3",
        "openai_whisper-small",
      ],
    ]
  private static let modelIDsBySpeedMode: [LocalSessionTranscriptionSpeedMode: [String]] = [
    .fastDraft: [
      "ggml-tiny",
      "ggml-base",
      "ggml-small",
      "ggml-large-v3-turbo",
      "openai_whisper-tiny",
      "openai_whisper-base",
      "openai_whisper-small",
      "openai_whisper-large-v3-turbo-ggml",
    ],
    .balanced: [
      "ggml-small",
      "ggml-base",
      "ggml-large-v3-turbo",
      "ggml-tiny",
      "openai_whisper-small",
      "openai_whisper-base",
      "openai_whisper-large-v3-turbo-ggml",
      "openai_whisper-tiny",
    ],
    .mostAccurate: [
      "ggml-large-v3-turbo",
      "openai_whisper-large-v3-turbo-ggml",
      "ggml-small",
      "openai_whisper-small",
      "ggml-base",
      "openai_whisper-base",
      "ggml-tiny",
      "openai_whisper-tiny",
    ],
  ]

  let baseDirectory: URL

  private static var currentBaseDirectory: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent(Self.currentRootName, isDirectory: true)
  }

  static var legacyBaseDirectory: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent(Self.legacyRootName, isDirectory: true)
      .appendingPathComponent(Self.legacySessionsRootName, isDirectory: true)
  }

  var sessionsDirectory: URL {
    baseDirectory.appendingPathComponent("Sessions", isDirectory: true)
  }

  var modelsDirectory: URL {
    baseDirectory.appendingPathComponent("Models", isDirectory: true)
  }

  var legacySessionsDirectory: URL {
    resolvedLegacyBaseDirectory.appendingPathComponent("Sessions", isDirectory: true)
  }

  var legacyModelsDirectory: URL {
    resolvedLegacyBaseDirectory.appendingPathComponent("Models", isDirectory: true)
  }

  func sessionDirectory(for sessionID: UUID) -> URL {
    sessionsDirectory.appendingPathComponent(sessionID.uuidString, isDirectory: true)
  }

  func legacySessionDirectory(for sessionID: UUID) -> URL {
    legacySessionsDirectory.appendingPathComponent(sessionID.uuidString, isDirectory: true)
  }

  func modelDirectory(for modelID: String = Self.defaultHebrewModelID) -> URL {
    modelsDirectory.appendingPathComponent(modelID, isDirectory: true)
  }

  func legacyModelDirectory(for modelID: String = Self.defaultHebrewModelID) -> URL {
    legacyModelsDirectory.appendingPathComponent(modelID, isDirectory: true)
  }

  private var resolvedLegacyBaseDirectory: URL {
    let standardizedCurrent = baseDirectory.standardizedFileURL.path
    let standardizedDefault = Self.currentBaseDirectory.standardizedFileURL.path

    if standardizedCurrent == standardizedDefault {
      return Self.legacyBaseDirectory
    }

    return baseDirectory.appendingPathComponent("LegacyMeetings", isDirectory: true)
  }

  func modelURL(
    for modelID: String = Self.defaultHebrewModelID,
    fileName: String = Self.defaultHebrewModelFileName
  ) -> URL {
    modelDirectory(for: modelID).appendingPathComponent(fileName, isDirectory: false)
  }

  func legacyModelURL(
    for modelID: String = Self.defaultHebrewModelID,
    fileName: String = Self.defaultHebrewModelFileName
  ) -> URL {
    legacyModelDirectory(for: modelID).appendingPathComponent(fileName, isDirectory: false)
  }

  func resolvedHebrewModelURL(fileManager: FileManager = .default) -> URL {
    resolvedModelURL(for: Self.defaultHebrewModelID, fileManager: fileManager)
  }

  func resolvedTranscriptionPlan(fileManager: FileManager = .default)
    -> LocalSessionTranscriptionPlan
  {
    resolvedTranscriptionPlan(settings: .current(), fileManager: fileManager)
  }

  func resolvedTranscriptionPlan(
    settings: LocalSessionTranscriptionSettings,
    fileManager: FileManager = .default
  ) -> LocalSessionTranscriptionPlan {
    let language = settings.languagePreference.languageCode
    let prompt = transcriptionPrompt(for: settings.languagePreference)

    if settings.languagePreference == .hebrewFirst,
      let hebrewWhisperKitModelURL = resolvedWhisperKitModelURL(
        for: Self.defaultWhisperKitHebrewModelID,
        fileManager: fileManager)
    {
      return LocalSessionTranscriptionPlan(
        engine: .whisperKit,
        modelURL: hebrewWhisperKitModelURL,
        language: language,
        prompt: prompt,
        modelFlavor: .whisperKitHebrewTurbo,
        speedMode: settings.speedMode
      )
    }

    if let whisperKitModelURL = resolvedWhisperKitMultilingualModelURL(
      speedMode: settings.speedMode,
      fileManager: fileManager)
    {
      return LocalSessionTranscriptionPlan(
        engine: .whisperKit,
        modelURL: whisperKitModelURL,
        language: language,
        prompt: prompt,
        modelFlavor: .whisperKitMultilingualTurbo,
        speedMode: settings.speedMode
      )
    }

    if let hebrewWhisperKitModelURL = resolvedWhisperKitModelURL(
      for: Self.defaultWhisperKitHebrewModelID,
      fileManager: fileManager)
    {
      return LocalSessionTranscriptionPlan(
        engine: .whisperKit,
        modelURL: hebrewWhisperKitModelURL,
        language: language,
        prompt: prompt ?? Self.fallbackMixedLanguagePrompt,
        modelFlavor: .whisperKitHebrewTurbo,
        speedMode: settings.speedMode
      )
    }

    if let multilingualModelURL = resolvedMultilingualModelURL(
      speedMode: settings.speedMode,
      fileManager: fileManager)
    {
      return LocalSessionTranscriptionPlan(
        engine: .whisperCpp,
        modelURL: multilingualModelURL,
        language: language,
        prompt: prompt,
        modelFlavor: .multilingualFast,
        speedMode: settings.speedMode
      )
    }

    return LocalSessionTranscriptionPlan(
      engine: .whisperCpp,
      modelURL: resolvedHebrewModelURL(fileManager: fileManager),
      language: language,
      prompt: prompt ?? Self.fallbackMixedLanguagePrompt,
      modelFlavor: .hebrewTurbo,
      speedMode: settings.speedMode
    )
  }

  func metadataURL(for sessionID: UUID) -> URL {
    sessionDirectory(for: sessionID).appendingPathComponent("session.json", isDirectory: false)
  }

  func attachmentsDirectory(for sessionID: UUID) -> URL {
    sessionDirectory(for: sessionID).appendingPathComponent("Attachments", isDirectory: true)
  }

  func exportsDirectory(for sessionID: UUID) -> URL {
    sessionDirectory(for: sessionID).appendingPathComponent("Exports", isDirectory: true)
  }

  func promptPackageMarkdownURL(for sessionID: UUID) -> URL {
    exportsDirectory(for: sessionID).appendingPathComponent(
      "session-package.md", isDirectory: false)
  }

  func promptPackageJSONURL(for sessionID: UUID) -> URL {
    exportsDirectory(for: sessionID).appendingPathComponent(
      "session-package.json", isDirectory: false)
  }

  func legacyMetadataURL(for sessionID: UUID) -> URL {
    legacySessionDirectory(for: sessionID).appendingPathComponent(
      "session.json", isDirectory: false)
  }

  func micAudioURL(for sessionID: UUID) -> URL {
    sessionDirectory(for: sessionID).appendingPathComponent("mic.wav", isDirectory: false)
  }

  func systemAudioURL(for sessionID: UUID) -> URL {
    sessionDirectory(for: sessionID).appendingPathComponent("system.wav", isDirectory: false)
  }

  func mixedAudioURL(for sessionID: UUID) -> URL {
    sessionDirectory(for: sessionID).appendingPathComponent("mixed.wav", isDirectory: false)
  }

  func existingAudioURL(
    for sessionID: UUID,
    artifacts: LocalSessionAudioArtifacts,
    fileManager: FileManager = .default
  ) -> URL? {
    let orderedFileNames = [
      artifacts.mixedFileName,
      artifacts.micFileName,
      artifacts.systemFileName,
      "mixed.wav",
      "mic.wav",
      "system.wav",
    ].compactMap { $0 }
    var seenFileNames: Set<String> = []
    let candidateFileNames = orderedFileNames.filter { seenFileNames.insert($0).inserted }

    let roots = [
      sessionDirectory(for: sessionID),
      legacySessionDirectory(for: sessionID),
    ]

    for root in roots {
      for fileName in candidateFileNames {
        let candidate = root.appendingPathComponent(fileName, isDirectory: false)
        if fileManager.fileExists(atPath: candidate.path) {
          return candidate
        }
      }
    }

    return nil
  }

  func ensureDirectories(fileManager: FileManager = .default, for sessionID: UUID? = nil) throws {
    try fileManager.createDirectory(at: sessionsDirectory, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: modelDirectory(), withIntermediateDirectories: true)

    if let sessionID {
      try fileManager.createDirectory(
        at: sessionDirectory(for: sessionID), withIntermediateDirectories: true)
      try fileManager.createDirectory(
        at: attachmentsDirectory(for: sessionID), withIntermediateDirectories: true)
      try fileManager.createDirectory(
        at: exportsDirectory(for: sessionID), withIntermediateDirectories: true)
    }
  }

  private func resolvedMultilingualModelURL(
    speedMode: LocalSessionTranscriptionSpeedMode,
    fileManager: FileManager
  ) -> URL? {
    for modelID in Self.modelIDs(for: speedMode) {
      let candidate = resolvedModelURL(for: modelID, fileManager: fileManager)
      if fileManager.fileExists(atPath: candidate.path) {
        return candidate
      }
    }

    for rootDirectory in modelSearchRoots() {
      guard
        let candidateDirectories = try? fileManager.contentsOfDirectory(
          at: rootDirectory,
          includingPropertiesForKeys: nil,
          options: [.skipsHiddenFiles]
        )
      else {
        continue
      }

      for directoryURL in candidateDirectories.sorted(by: {
        $0.lastPathComponent < $1.lastPathComponent
      }) {
        let modelID = directoryURL.lastPathComponent.lowercased()
        guard !modelID.contains(Self.defaultHebrewModelID.lowercased()) else { continue }

        let candidate = directoryURL.appendingPathComponent(
          Self.defaultHebrewModelFileName, isDirectory: false)
        if fileManager.fileExists(atPath: candidate.path) {
          return candidate
        }
      }
    }

    return nil
  }

  private func resolvedWhisperKitMultilingualModelURL(
    speedMode: LocalSessionTranscriptionSpeedMode,
    fileManager: FileManager
  ) -> URL? {
    for modelID in Self.whisperKitModelIDs(for: speedMode) {
      if let candidate = resolvedWhisperKitModelURL(for: modelID, fileManager: fileManager) {
        return candidate
      }
    }

    for rootDirectory in modelSearchRoots() {
      guard
        let candidateDirectories = try? fileManager.contentsOfDirectory(
          at: rootDirectory,
          includingPropertiesForKeys: nil,
          options: [.skipsHiddenFiles]
        )
      else {
        continue
      }

      for directoryURL in candidateDirectories.sorted(by: {
        $0.lastPathComponent < $1.lastPathComponent
      }) {
        let modelID = directoryURL.lastPathComponent.lowercased()
        guard modelID.contains("whisper") || modelID.contains("openai") else { continue }
        guard !modelID.contains("ggml"), !modelID.contains("ivrit-ai") else { continue }
        if isWhisperKitModelDirectory(directoryURL, fileManager: fileManager) {
          return directoryURL
        }
      }
    }

    return nil
  }

  private static func modelIDs(for speedMode: LocalSessionTranscriptionSpeedMode) -> [String] {
    modelIDsBySpeedMode[speedMode] ?? modelIDsBySpeedMode[.balanced] ?? []
  }

  private static func whisperKitModelIDs(for speedMode: LocalSessionTranscriptionSpeedMode)
    -> [String]
  {
    whisperKitModelIDsBySpeedMode[speedMode] ?? whisperKitModelIDsBySpeedMode[.balanced] ?? []
  }

  private func transcriptionPrompt(
    for languagePreference: LocalSessionTranscriptionLanguagePreference
  ) -> String? {
    switch languagePreference {
    case .mixed:
      return nil
    case .hebrewFirst:
      return "The meeting is primarily Hebrew. Keep English terms as spoken."
    case .englishFirst:
      return "The meeting is primarily English. Keep Hebrew terms as spoken."
    }
  }

  private func resolvedModelURL(for modelID: String, fileManager: FileManager) -> URL {
    let installedModelURL = modelURL(for: modelID)
    if fileManager.fileExists(atPath: installedModelURL.path) {
      return installedModelURL
    }

    let legacyModelURL = legacyModelURL(for: modelID)
    if fileManager.fileExists(atPath: legacyModelURL.path) {
      return legacyModelURL
    }

    let developmentModelURL = URL(
      fileURLWithPath:
        "/Users/ben/Documents/App/General/__MODELS__/\(modelID)/\(Self.defaultHebrewModelFileName)"
    )
    if fileManager.fileExists(atPath: developmentModelURL.path) {
      return developmentModelURL
    }

    return installedModelURL
  }

  private func resolvedWhisperKitModelURL(for modelID: String, fileManager: FileManager) -> URL? {
    let candidates = [
      modelDirectory(for: modelID),
      legacyModelDirectory(for: modelID),
      URL(fileURLWithPath: "/Users/ben/Documents/App/General/__MODELS__/\(modelID)", isDirectory: true),
    ]

    for candidate in candidates where isWhisperKitModelDirectory(candidate, fileManager: fileManager)
    {
      return candidate
    }

    return nil
  }

  private func isWhisperKitModelDirectory(_ url: URL, fileManager: FileManager) -> Bool {
    var isDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else {
      return false
    }

    let requiredComponents = [
      "AudioEncoder.mlmodelc",
      "TextDecoder.mlmodelc",
      "MelSpectrogram.mlmodelc",
    ]
    if requiredComponents.allSatisfy({
      fileManager.fileExists(atPath: url.appendingPathComponent($0, isDirectory: true).path)
    }) {
      return true
    }

    guard
      let enumerator = fileManager.enumerator(
        at: url,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
      )
    else {
      return false
    }

    var modelComponentCount = 0
    for case let fileURL as URL in enumerator {
      guard fileURL.pathExtension == "mlmodelc" else { continue }
      modelComponentCount += 1
      if modelComponentCount >= 2 {
        return true
      }
    }

    return false
  }

  private func modelSearchRoots() -> [URL] {
    [
      modelsDirectory,
      legacyModelsDirectory,
      URL(fileURLWithPath: "/Users/ben/Documents/App/General/__MODELS__", isDirectory: true),
    ]
  }
}

typealias LocalMeetingFileLayout = LocalSessionFileLayout
