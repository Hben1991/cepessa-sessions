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
    case .mixed, .hebrewFirst, .englishFirst:
      return LocalSessionFileLayout.automaticLanguageCode
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
  private static let typeWhisperPluginModelsPath = [
    "TypeWhisper",
    "PluginData",
    "com.typewhisper.ivrit-asr",
    "models",
  ]
  private static let legacyRootName = "Cepessa Legacy"
  private static let legacySessionsRootName = "Meetings"
  private static let currentRootName = "Cepessa"
  fileprivate static let automaticLanguageCode = "auto"
  private static let whisperKitModelIDsBySpeedMode: [LocalSessionTranscriptionSpeedMode: [String]] =
    [
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
  private let resolvedLegacyRootDirectory: URL
  private let compatibleModelSearchRootsOverride: [URL]?

  init(baseDirectory: URL, compatibleModelSearchRoots: [URL]? = nil) {
    self.baseDirectory = baseDirectory
    compatibleModelSearchRootsOverride = compatibleModelSearchRoots

    let standardizedCurrent = baseDirectory.standardizedFileURL.path
    let standardizedDefault = Self.currentBaseDirectory.standardizedFileURL.path
    if standardizedCurrent == standardizedDefault {
      resolvedLegacyRootDirectory = Self.legacyBaseDirectory
    } else {
      resolvedLegacyRootDirectory = baseDirectory.appendingPathComponent(
        "LegacyMeetings", isDirectory: true)
    }
  }

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
    resolvedLegacyRootDirectory
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
        language: hebrewFallbackLanguage(for: settings.languagePreference),
        prompt: hebrewFallbackPrompt(for: settings.languagePreference),
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
      language: hebrewFallbackLanguage(for: settings.languagePreference),
      prompt: hebrewFallbackPrompt(for: settings.languagePreference),
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

  func transcriptionEvidenceDirectory(for sessionID: UUID) -> URL {
    sessionDirectory(for: sessionID).appendingPathComponent(
      "TranscriptionEvidence", isDirectory: true)
  }

  func transcriptionRunsDirectory(for sessionID: UUID) -> URL {
    transcriptionEvidenceDirectory(for: sessionID).appendingPathComponent(
      "Runs", isDirectory: true)
  }

  func speakerAnnotationsURL(for sessionID: UUID) -> URL {
    sessionDirectory(for: sessionID)
      .appendingPathComponent("speaker-annotations.jsonl", isDirectory: false)
  }

  var meetingEvidenceOutboxDirectory: URL {
    baseDirectory.appendingPathComponent("MeetingEvidenceOutbox", isDirectory: true)
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

  func micTranscriptAudioURL(for sessionID: UUID) -> URL {
    sessionDirectory(for: sessionID).appendingPathComponent(
      "mic-transcript.wav", isDirectory: false)
  }

  func systemAudioURL(for sessionID: UUID) -> URL {
    sessionDirectory(for: sessionID).appendingPathComponent("system.wav", isDirectory: false)
  }

  func mixedAudioURL(for sessionID: UUID) -> URL {
    sessionDirectory(for: sessionID).appendingPathComponent("mixed.wav", isDirectory: false)
  }

  func importedAudioURL(for sessionID: UUID) -> URL {
    sessionDirectory(for: sessionID).appendingPathComponent("imported.wav", isDirectory: false)
  }

  func existingAudioURL(
    for sessionID: UUID,
    artifacts: LocalSessionAudioArtifacts,
    fileManager: FileManager = .default
  ) -> URL? {
    let orderedFileNames = [
      artifacts.importedFileName,
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
        if isUsableWaveAudio(at: candidate, fileManager: fileManager) {
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
    try fileManager.createDirectory(
      at: meetingEvidenceOutboxDirectory, withIntermediateDirectories: true)

    if let sessionID {
      try fileManager.createDirectory(
        at: sessionDirectory(for: sessionID), withIntermediateDirectories: true)
      try fileManager.createDirectory(
        at: attachmentsDirectory(for: sessionID), withIntermediateDirectories: true)
      try fileManager.createDirectory(
        at: exportsDirectory(for: sessionID), withIntermediateDirectories: true)
      try fileManager.createDirectory(
        at: transcriptionRunsDirectory(for: sessionID), withIntermediateDirectories: true)
    }
  }

  private func resolvedMultilingualModelURL(
    speedMode: LocalSessionTranscriptionSpeedMode,
    fileManager: FileManager
  ) -> URL? {
    for modelID in Self.modelIDs(for: speedMode) {
      let candidate = resolvedModelURL(for: modelID, fileManager: fileManager)
      if isValidGGMLModelFile(candidate, fileManager: fileManager) {
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

        if let candidate = resolvedGGMLModelURL(
          in: directoryURL,
          modelID: directoryURL.lastPathComponent,
          fileManager: fileManager)
        {
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
        if LocalSessionWhisperKitModelInspector.isWhisperKitModelDirectory(
          directoryURL,
          fileManager: fileManager)
        {
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

  private func hebrewFallbackLanguage(
    for languagePreference: LocalSessionTranscriptionLanguagePreference
  ) -> String {
    LocalSessionFileLayout.automaticLanguageCode
  }

  private func hebrewFallbackPrompt(
    for languagePreference: LocalSessionTranscriptionLanguagePreference
  ) -> String? {
    switch languagePreference {
    case .mixed:
      return nil
    case .hebrewFirst, .englishFirst:
      return transcriptionPrompt(for: languagePreference)
    }
  }

  private func resolvedModelURL(for modelID: String, fileManager: FileManager) -> URL {
    let modelDirectories =
      [
        modelDirectory(for: modelID),
        legacyModelDirectory(for: modelID),
      ]
      + compatibleModelRoots().map {
        $0.appendingPathComponent(modelID, isDirectory: true)
      } + [
        URL(
          fileURLWithPath: "/Users/ben/Documents/App/General/__MODELS__/\(modelID)",
          isDirectory: true)
      ]

    for directory in modelDirectories {
      if let modelURL = resolvedGGMLModelURL(
        in: directory,
        modelID: modelID,
        fileManager: fileManager)
      {
        return modelURL
      }
    }

    return modelURL(for: modelID)
  }

  private func resolvedWhisperKitModelURL(for modelID: String, fileManager: FileManager) -> URL? {
    let candidates = [
      modelDirectory(for: modelID),
      legacyModelDirectory(for: modelID),
      URL(
        fileURLWithPath: "/Users/ben/Documents/App/General/__MODELS__/\(modelID)", isDirectory: true
      ),
    ]

    for candidate in candidates
    where LocalSessionWhisperKitModelInspector.isWhisperKitModelDirectory(
      candidate,
      fileManager: fileManager)
    {
      return candidate
    }

    return nil
  }

  private func modelSearchRoots() -> [URL] {
    var roots = [
      modelsDirectory,
      legacyModelsDirectory,
      URL(fileURLWithPath: "/Users/ben/Documents/App/General/__MODELS__", isDirectory: true),
    ]
    roots.append(contentsOf: compatibleModelRoots())
    return roots
  }

  private func compatibleModelRoots() -> [URL] {
    if let compatibleModelSearchRootsOverride {
      return deduplicatedModelRoots(compatibleModelSearchRootsOverride)
    }

    let relativeApplicationSupportDirectory = baseDirectory.deletingLastPathComponent()
    let userApplicationSupportDirectory = FileManager.default.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    )[0]
    return deduplicatedModelRoots(
      [relativeApplicationSupportDirectory, userApplicationSupportDirectory].map {
        Self.typeWhisperPluginModelsPath.reduce($0) { partialURL, pathComponent in
          partialURL.appendingPathComponent(pathComponent, isDirectory: true)
        }
      })
  }

  private func deduplicatedModelRoots(_ roots: [URL]) -> [URL] {
    var seenPaths: Set<String> = []
    return roots.filter { seenPaths.insert($0.standardizedFileURL.path).inserted }
  }

  private func resolvedGGMLModelURL(
    in directory: URL,
    modelID: String,
    fileManager: FileManager
  ) -> URL? {
    var candidateNames = [Self.defaultHebrewModelFileName, "\(modelID).bin"]
    let normalizedModelID =
      modelID
      .replacingOccurrences(of: "openai_whisper-", with: "")
      .replacingOccurrences(of: "-ggml", with: "")
    candidateNames.append("ggml-\(normalizedModelID).bin")

    var seenNames: Set<String> = []
    for name in candidateNames where seenNames.insert(name).inserted {
      let candidate = directory.appendingPathComponent(name, isDirectory: false)
      if isValidGGMLModelFile(candidate, fileManager: fileManager) {
        return candidate
      }
    }

    guard
      let contents = try? fileManager.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]
      )
    else {
      return nil
    }
    let validGGMLFiles =
      contents
      .filter { $0.pathExtension.lowercased() == "bin" && $0.lastPathComponent.hasPrefix("ggml-") }
      .filter { isValidGGMLModelFile($0, fileManager: fileManager) }
      .sorted { $0.lastPathComponent < $1.lastPathComponent }
    return validGGMLFiles.count == 1 ? validGGMLFiles[0] : nil
  }

  private func isValidGGMLModelFile(_ url: URL, fileManager: FileManager) -> Bool {
    guard
      let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
      values.isRegularFile == true,
      (values.fileSize ?? 0) >= 4,
      let handle = try? FileHandle(forReadingFrom: url)
    else {
      return false
    }
    defer { try? handle.close() }
    guard
      let magic = try? handle.read(upToCount: 4),
      magic.count == 4
    else {
      return false
    }
    return magic == Data([0x6c, 0x6d, 0x67, 0x67])
  }

  private func isUsableWaveAudio(at url: URL, fileManager: FileManager) -> Bool {
    guard
      let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
      values.isRegularFile == true,
      let fileSize = values.fileSize,
      fileSize >= 44,
      let handle = try? FileHandle(forReadingFrom: url)
    else {
      return false
    }
    defer { try? handle.close() }

    guard
      let header = try? handle.read(upToCount: 12),
      header.count == 12,
      String(data: header[0..<4], encoding: .ascii) == "RIFF",
      String(data: header[8..<12], encoding: .ascii) == "WAVE"
    else {
      return false
    }
    let declaredSize = UInt64(Self.readUInt32(header, offset: 4)) + 8
    guard declaredSize <= UInt64(fileSize) else { return false }

    var byteRate: UInt32?
    var offset: UInt64 = 12
    while offset + 8 <= declaredSize {
      do {
        try handle.seek(toOffset: offset)
        guard let chunkHeader = try handle.read(upToCount: 8), chunkHeader.count == 8 else {
          return false
        }
        let chunkName = String(data: chunkHeader[0..<4], encoding: .ascii)
        let chunkLength = UInt64(Self.readUInt32(chunkHeader, offset: 4))
        let dataOffset = offset + 8
        guard dataOffset + chunkLength <= declaredSize else { return false }

        if chunkName == "fmt ", chunkLength >= 16 {
          guard let formatData = try handle.read(upToCount: 16), formatData.count == 16 else {
            return false
          }
          byteRate = Self.readUInt32(formatData, offset: 8)
        } else if chunkName == "data" {
          guard chunkLength > 0, let byteRate, byteRate > 0 else { return false }
          return Double(chunkLength) / Double(byteRate) > 0
        }

        offset = dataOffset + chunkLength + (chunkLength % 2)
      } catch {
        return false
      }
    }
    return false
  }

  private static func readUInt32(_ data: Data, offset: Int) -> UInt32 {
    guard offset + 4 <= data.count else { return 0 }
    return data[offset..<(offset + 4)].enumerated().reduce(0) {
      $0 | (UInt32($1.element) << UInt32($1.offset * 8))
    }
  }
}

typealias LocalMeetingFileLayout = LocalSessionFileLayout
