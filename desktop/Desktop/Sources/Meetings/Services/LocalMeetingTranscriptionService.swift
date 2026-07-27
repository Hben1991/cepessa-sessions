import Foundation
@preconcurrency import WhisperKit
import whisper

protocol LocalSessionTranscribing: Sendable {
  func warmUp(modelURL: URL) async

  func transcribe(
    wavURL: URL,
    modelURL: URL,
    language: String,
    prompt: String?,
    translateToEnglish: Bool,
    onProgress: (@Sendable (LocalSessionTranscriptionProgress) async -> Void)?
  ) async throws -> LocalSessionTranscriptionResult
}

struct LocalSessionTranscriptionProgress: Sendable, Equatable {
  enum Stage: Sendable, Equatable {
    case decodingAudio
    case loadingModel
    case analyzingSpeech(
      chunks: Int, speechDuration: TimeInterval, skippedSilenceDuration: TimeInterval)
    case transcribing(percent: Int)
    case partialSegments([LocalSessionTranscriptionSegment])
    case extractingSegments
  }

  let stage: Stage
}

struct LocalSessionTranscriptionWord: Sendable, Codable, Equatable {
  let startTime: TimeInterval
  let endTime: TimeInterval
  let text: String
  let confidence: Double?
  let timestampProvenance: LocalSessionTimestampProvenance

  init(
    startTime: TimeInterval,
    endTime: TimeInterval,
    text: String,
    confidence: Double? = nil,
    timestampProvenance: LocalSessionTimestampProvenance = .asr
  ) {
    self.startTime = startTime
    self.endTime = endTime
    self.text = text
    self.confidence = confidence
    self.timestampProvenance = timestampProvenance
  }
}

struct LocalSessionTranscriptionSegment: Sendable, Codable, Equatable {
  let startTime: TimeInterval
  let endTime: TimeInterval
  let text: String
  let words: [LocalSessionTranscriptionWord]

  init(
    startTime: TimeInterval,
    endTime: TimeInterval,
    text: String,
    words: [LocalSessionTranscriptionWord] = []
  ) {
    self.startTime = startTime
    self.endTime = endTime
    self.text = text
    self.words = words
  }

  private enum CodingKeys: String, CodingKey {
    case startTime
    case endTime
    case text
    case words
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    startTime = try container.decode(TimeInterval.self, forKey: .startTime)
    endTime = try container.decode(TimeInterval.self, forKey: .endTime)
    text = try container.decode(String.self, forKey: .text)
    words =
      try container.decodeIfPresent([LocalSessionTranscriptionWord].self, forKey: .words) ?? []
  }
}

struct LocalSessionTranscriptionResult: Sendable, Codable, Equatable {
  let text: String
  let detectedLanguage: String?
  let segments: [LocalSessionTranscriptionSegment]
  let modelPath: String
  let engine: LocalSessionTranscriptionEngineKind
  let warnings: [String]

  init(
    text: String,
    detectedLanguage: String?,
    segments: [LocalSessionTranscriptionSegment],
    modelPath: String,
    engine: LocalSessionTranscriptionEngineKind = .whisperCpp,
    warnings: [String] = []
  ) {
    self.text = text
    self.detectedLanguage = detectedLanguage
    self.segments = segments
    self.modelPath = modelPath
    self.engine = engine
    self.warnings = warnings
  }
}

enum LocalSessionTranscriptionPostprocessor {
  static func cleanSegments(
    _ segments: [LocalSessionTranscriptionSegment]
  ) -> [LocalSessionTranscriptionSegment] {
    guard !segments.isEmpty else { return [] }

    var cleaned: [LocalSessionTranscriptionSegment] = []
    var index = segments.startIndex
    while index < segments.endIndex {
      guard let courtesyKey = courtesyFillerKey(for: segments[index].text) else {
        cleaned.append(segments[index])
        index = segments.index(after: index)
        continue
      }

      let clusterStart = index
      var clusterEnd = segments.index(after: index)
      while clusterEnd < segments.endIndex,
        courtesyFillerKey(for: segments[clusterEnd].text) == courtesyKey
      {
        clusterEnd = segments.index(after: clusterEnd)
      }

      let clusterCount = segments.distance(from: clusterStart, to: clusterEnd)
      let isTrailingCluster = clusterEnd == segments.endIndex
      if clusterCount == 1 {
        cleaned.append(segments[clusterStart])
      } else if !isTrailingCluster {
        cleaned.append(segments[clusterStart])
      }

      index = clusterEnd
    }

    return cleaned
  }

  static func transcriptText(
    from segments: [LocalSessionTranscriptionSegment],
    fallback: String
  ) -> String {
    let segmentText = segments.map(\.text).joined(separator: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    if !segmentText.isEmpty {
      return segmentText
    }

    return cleanRepeatedCourtesyFillers(in: fallback)
  }

  private static func cleanRepeatedCourtesyFillers(in text: String) -> String {
    let pieces = text
      .components(separatedBy: .newlines)
      .flatMap { $0.components(separatedBy: ".") }
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    guard pieces.count > 1 else { return text.trimmingCharacters(in: .whitespacesAndNewlines) }

    let segmentProxies = pieces.map {
      LocalSessionTranscriptionSegment(startTime: 0, endTime: 0, text: $0)
    }
    return cleanSegments(segmentProxies).map(\.text).joined(separator: ". ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func courtesyFillerKey(for text: String) -> String? {
    let key = text
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: "\u{200f}", with: "")
      .replacingOccurrences(of: "\u{200e}", with: "")
      .lowercased()
      .unicodeScalars
      .filter { CharacterSet.letters.union(.decimalDigits).contains($0) }
    let normalized = String(String.UnicodeScalarView(key))
    guard !normalized.isEmpty else { return nil }

    let courtesyKeys: Set<String> = [
      "תודה",
      "תודהרבה",
      "תודהלכם",
      "תודהרבהלכם",
      "thanks",
      "thankyou",
      "thankyouverymuch",
      "thanksverymuch",
      "thanksalot",
    ]
    return courtesyKeys.contains(normalized) ? normalized : nil
  }
}

enum LocalSessionTranscriptionServiceError: LocalizedError {
  case invalidAudio(String)
  case modelLoadFailed(String)
  case transcriptionFailed(String)

  var errorDescription: String? {
    switch self {
    case .invalidAudio(let message),
      .modelLoadFailed(let message),
      .transcriptionFailed(let message):
      return message
    }
  }
}

actor LocalSessionTranscriptionService: LocalSessionTranscribing {
  private let whisperKitService: LocalSessionWhisperKitTranscriptionService
  private let whisperCppService: LocalSessionWhisperCppTranscriptionService
  private let fileManager: FileManager

  init(
    whisperKitService: LocalSessionWhisperKitTranscriptionService =
      LocalSessionWhisperKitTranscriptionService(),
    whisperCppService: LocalSessionWhisperCppTranscriptionService =
      LocalSessionWhisperCppTranscriptionService(),
    fileManager: FileManager = .default
  ) {
    self.whisperKitService = whisperKitService
    self.whisperCppService = whisperCppService
    self.fileManager = fileManager
  }

  func warmUp(modelURL: URL) async {
    await service(for: modelURL).warmUp(modelURL: modelURL)
  }

  func transcribe(
    wavURL: URL,
    modelURL: URL,
    language: String = "auto",
    prompt: String? = nil,
    translateToEnglish: Bool = false,
    onProgress: (@Sendable (LocalSessionTranscriptionProgress) async -> Void)? = nil
  ) async throws -> LocalSessionTranscriptionResult {
    try await service(for: modelURL).transcribe(
      wavURL: wavURL,
      modelURL: modelURL,
      language: language,
      prompt: prompt,
      translateToEnglish: translateToEnglish,
      onProgress: onProgress
    )
  }

  private func service(for modelURL: URL) -> any LocalSessionTranscribing {
    if LocalSessionWhisperKitModelInspector.isWhisperKitModelDirectory(
      modelURL,
      fileManager: fileManager)
    {
      return whisperKitService
    }

    return whisperCppService
  }
}

actor LocalSessionWhisperKitTranscriptionService: LocalSessionTranscribing {
  private var pipelines: [String: WhisperKit] = [:]

  func warmUp(modelURL: URL) async {
    _ = try? await pipeline(for: modelURL)
  }

  func transcribe(
    wavURL: URL,
    modelURL: URL,
    language: String = "auto",
    prompt: String? = nil,
    translateToEnglish: Bool = false,
    onProgress: (@Sendable (LocalSessionTranscriptionProgress) async -> Void)? = nil
  ) async throws -> LocalSessionTranscriptionResult {
    if let onProgress {
      await onProgress(.init(stage: .loadingModel))
    }

    let pipeline = try await pipeline(for: modelURL)
    if let onProgress {
      await onProgress(.init(stage: .decodingAudio))
    }

    var options = decodingOptions(language: language, translateToEnglish: translateToEnglish)
    options.wordTimestamps = true
    if let promptTokens = promptTokens(for: prompt, using: pipeline) {
      options.promptTokens = promptTokens
      options.usePrefillPrompt = true
    }

    let progressCallback: TranscriptionCallback = { [weak pipeline] _ in
      guard let pipeline, let onProgress else { return nil }
      let percent = Int((pipeline.progress.fractionCompleted * 100).rounded())
      Task {
        await onProgress(.init(stage: .transcribing(percent: max(0, min(percent, 100)))))
      }
      return nil
    }

    let results: [TranscriptionResult]
    do {
      results = try await pipeline.transcribe(
        audioPath: wavURL.path,
        decodeOptions: options,
        callback: progressCallback
      )
    } catch {
      throw LocalSessionTranscriptionServiceError.transcriptionFailed(
        "WhisperKit failed to transcribe \(wavURL.lastPathComponent). \(error.localizedDescription)"
      )
    }

    if let onProgress {
      await onProgress(.init(stage: .extractingSegments))
    }

    let rawSegments = results.flatMap { result in
      result.segments.map { segment in
        LocalSessionTranscriptionSegment(
          startTime: TimeInterval(segment.start),
          endTime: TimeInterval(segment.end),
          text: segment.text.trimmingCharacters(in: .whitespacesAndNewlines),
          words: (segment.words ?? []).map {
            LocalSessionTranscriptionWord(
              startTime: TimeInterval($0.start),
              endTime: TimeInterval($0.end),
              text: $0.word,
              confidence: Double($0.probability)
            )
          }
        )
      }
      .filter { !$0.text.isEmpty }
    }
    let cleanedSegments = LocalSessionTranscriptionPostprocessor.cleanSegments(rawSegments)
    let rawTranscript = results.map(\.text).joined(separator: " ").trimmingCharacters(
      in: .whitespacesAndNewlines)
    let transcript = LocalSessionTranscriptionPostprocessor.transcriptText(
      from: cleanedSegments,
      fallback: rawTranscript
    )
    let detectedLanguage = results.first { !$0.language.isEmpty }?.language

    return LocalSessionTranscriptionResult(
      text: transcript,
      detectedLanguage: detectedLanguage,
      segments: cleanedSegments,
      modelPath: modelURL.path,
      engine: .whisperKit
    )
  }

  private func pipeline(for modelURL: URL) async throws -> WhisperKit {
    let cacheKey = modelURL.standardizedFileURL.path
    if let cached = pipelines[cacheKey] {
      return cached
    }

    do {
      let pipeline = try await WhisperKit(
        WhisperKitConfig(
          modelFolder: modelURL.path,
          computeOptions: ModelComputeOptions(),
          verbose: false,
          prewarm: false,
          load: true,
          download: false
        )
      )
      pipelines[cacheKey] = pipeline
      return pipeline
    } catch {
      throw LocalSessionTranscriptionServiceError.modelLoadFailed(
        "Failed to load WhisperKit model at \(modelURL.path). \(error.localizedDescription)"
      )
    }
  }

  private func decodingOptions(language: String, translateToEnglish: Bool) -> DecodingOptions {
    let normalizedLanguage = language.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let shouldDetectLanguage = normalizedLanguage.isEmpty || normalizedLanguage == "auto"
    let languageCode: String? =
      shouldDetectLanguage
      ? nil
      : (normalizedLanguage == "hebrew" ? "he" : normalizedLanguage)

    return DecodingOptions(
      verbose: false,
      task: translateToEnglish ? .translate : .transcribe,
      language: languageCode,
      temperature: 0,
      topK: 1,
      usePrefillPrompt: languageCode != nil || translateToEnglish,
      usePrefillCache: true,
      detectLanguage: shouldDetectLanguage,
      withoutTimestamps: false,
      wordTimestamps: true,
      chunkingStrategy: .vad
    )
  }

  private func promptTokens(for prompt: String?, using pipeline: WhisperKit) -> [Int]? {
    guard let tokenizer = pipeline.tokenizer else { return nil }
    guard let prompt = prompt?.trimmingCharacters(in: .whitespacesAndNewlines), !prompt.isEmpty
    else {
      return nil
    }

    let tokens = tokenizer.encode(text: " " + prompt)
      .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
    return tokens.isEmpty ? nil : tokens
  }
}

actor LocalSessionWhisperCppTranscriptionService: LocalSessionTranscribing {
  private let cache = LocalMeetingWhisperContextCache()

  func warmUp(modelURL: URL) async {
    _ = try? cache.context(for: modelURL)
  }

  func transcribe(
    wavURL: URL,
    modelURL: URL,
    language: String = "auto",
    prompt: String? = nil,
    translateToEnglish: Bool = false,
    onProgress: (@Sendable (LocalSessionTranscriptionProgress) async -> Void)? = nil
  ) async throws -> LocalSessionTranscriptionResult {
    if let onProgress {
      await onProgress(.init(stage: .decodingAudio))
    }
    let samples = try decodePCM16MonoWav(from: wavURL)
    let recognitionSamples = Self.normalizedSamplesForRecognition(samples)
    if let onProgress {
      await onProgress(.init(stage: .loadingModel))
    }
    let context = try cache.context(for: modelURL)
    let segments = try await transcribe(
      samples: recognitionSamples,
      context: context,
      modelURL: modelURL,
      language: language,
      prompt: prompt,
      translateToEnglish: translateToEnglish,
      onProgress: onProgress
    )
    let transcript = segments.items.map(\.text).joined(separator: " ").trimmingCharacters(
      in: .whitespacesAndNewlines)

    return LocalSessionTranscriptionResult(
      text: transcript,
      detectedLanguage: segments.detectedLanguage,
      segments: segments.items,
      modelPath: modelURL.path,
      engine: .whisperCpp
    )
  }

  func transcriptText(
    wavURL: URL,
    modelURL: URL,
    language: String = "auto",
    prompt: String? = nil,
    translateToEnglish: Bool = false,
    onProgress: (@Sendable (LocalSessionTranscriptionProgress) async -> Void)? = nil
  ) async throws -> String {
    try await transcribe(
      wavURL: wavURL,
      modelURL: modelURL,
      language: language,
      prompt: prompt,
      translateToEnglish: translateToEnglish,
      onProgress: onProgress
    ).text
  }

  private func transcribe(
    samples: [Float],
    context: OpaquePointer,
    modelURL: URL,
    language: String,
    prompt: String?,
    translateToEnglish: Bool,
    onProgress: (@Sendable (LocalSessionTranscriptionProgress) async -> Void)?
  ) async throws -> (items: [LocalSessionTranscriptionSegment], detectedLanguage: String?) {
    guard !samples.isEmpty else {
      throw LocalSessionTranscriptionServiceError.invalidAudio("WAV file contains no PCM samples.")
    }

    let regions = LocalMeetingSpeechRegionDetector().regions(in: samples)
    let chunks = LocalMeetingSpeechChunker().chunks(from: regions, samples: samples)
    let sampleRate = Double(LocalMeetingSpeechRegionDetector.sampleRate)
    let speechDuration = Double(chunks.reduce(0) { $0 + $1.speechSampleCount }) / sampleRate
    let skippedSilenceDuration = max(
      0,
      (Double(samples.count) / sampleRate) - speechDuration
    )
    if let onProgress {
      await onProgress(
        .init(
          stage: .analyzingSpeech(
            chunks: chunks.count,
            speechDuration: speechDuration,
            skippedSilenceDuration: skippedSilenceDuration
          )
        )
      )
    }
    guard !chunks.isEmpty else {
      return ([], nil)
    }
    let totalChunkSamples = max(1, chunks.reduce(0) { $0 + $1.samples.count })
    var consumedChunkSamples = 0
    var allItems: [LocalSessionTranscriptionSegment] = []
    allItems.reserveCapacity(chunks.count * 12)
    var detectedLanguage: String?

    for chunk in chunks {
      let chunkSampleCount = chunk.samples.count
      let chunkStartSample = chunk.startSample
      let chunkResult = try transcribeChunk(
        samples: chunk.samples,
        context: context,
        modelURL: modelURL,
        language: language,
        prompt: prompt,
        translateToEnglish: translateToEnglish,
        reportProgress: { chunkProgress in
          guard let onProgress else { return }
          let completedSamples =
            Double(consumedChunkSamples)
            + (Double(chunkSampleCount) * Double(chunkProgress) / 100.0)
          let overallProgress = Int(
            (completedSamples / Double(totalChunkSamples) * 100.0).rounded())
          Task {
            await onProgress(.init(stage: .transcribing(percent: overallProgress)))
          }
        }
      )

      let timeOffset =
        Double(chunkStartSample) / Double(LocalMeetingSpeechRegionDetector.sampleRate)
      allItems.append(
        contentsOf: chunkResult.items.map { segment in
          LocalSessionTranscriptionSegment(
            startTime: segment.startTime + timeOffset,
            endTime: segment.endTime + timeOffset,
            text: segment.text
          )
        }
      )
      if detectedLanguage == nil {
        detectedLanguage = chunkResult.detectedLanguage
      }
      consumedChunkSamples += chunkSampleCount
      if let onProgress, !allItems.isEmpty {
        await onProgress(.init(stage: .partialSegments(allItems)))
      }
    }

    if let onProgress {
      await onProgress(.init(stage: .extractingSegments))
    }

    allItems.sort { lhs, rhs in
      if lhs.startTime == rhs.startTime {
        return lhs.endTime < rhs.endTime
      }
      return lhs.startTime < rhs.startTime
    }

    return (LocalSessionTranscriptionPostprocessor.cleanSegments(allItems), detectedLanguage)
  }

  private func transcribeChunk(
    samples: [Float],
    context: OpaquePointer,
    modelURL: URL,
    language: String,
    prompt: String?,
    translateToEnglish: Bool,
    reportProgress: ((Int) -> Void)?
  ) throws -> (items: [LocalSessionTranscriptionSegment], detectedLanguage: String?) {
    guard !samples.isEmpty else {
      return ([], nil)
    }

    let normalizedLanguage = language.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let shouldDetectLanguage = normalizedLanguage.isEmpty || normalizedLanguage == "auto"
    let primaryResult = try runWhisperChunkPass(
      samples: samples,
      context: context,
      modelURL: modelURL,
      language: normalizedLanguage,
      shouldDetectLanguage: shouldDetectLanguage,
      prompt: prompt,
      translateToEnglish: translateToEnglish,
      noTimestamps: false,
      singleSegment: false,
      suppressBlank: true,
      reportProgress: reportProgress
    )
    if !primaryResult.items.isEmpty {
      return primaryResult
    }

    if shouldDetectLanguage {
      for fallbackLanguage in ["he", "en"] {
        let fallbackResult = try runWhisperChunkPass(
          samples: samples,
          context: context,
          modelURL: modelURL,
          language: fallbackLanguage,
          shouldDetectLanguage: false,
          prompt: nil,
          translateToEnglish: translateToEnglish,
          noTimestamps: false,
          singleSegment: false,
          suppressBlank: false,
          reportProgress: reportProgress
        )
        if !fallbackResult.items.isEmpty {
          return fallbackResult
        }
      }
    }

    return try runWhisperChunkPass(
      samples: samples,
      context: context,
      modelURL: modelURL,
      language: normalizedLanguage,
      shouldDetectLanguage: shouldDetectLanguage,
      prompt: nil,
      translateToEnglish: translateToEnglish,
      noTimestamps: true,
      singleSegment: true,
      suppressBlank: false,
      reportProgress: reportProgress
    )
  }

  private func runWhisperChunkPass(
    samples: [Float],
    context: OpaquePointer,
    modelURL: URL,
    language: String,
    shouldDetectLanguage: Bool,
    prompt: String?,
    translateToEnglish: Bool,
    noTimestamps: Bool,
    singleSegment: Bool,
    suppressBlank: Bool,
    reportProgress: ((Int) -> Void)?
  ) throws -> (items: [LocalSessionTranscriptionSegment], detectedLanguage: String?) {
    var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
    params.print_realtime = false
    params.print_progress = false
    params.print_timestamps = false
    params.print_special = false
    params.translate = translateToEnglish
    params.no_context = true
    params.no_timestamps = noTimestamps
    params.single_segment = singleSegment
    params.suppress_blank = suppressBlank
    params.n_threads = Int32(max(1, ProcessInfo.processInfo.activeProcessorCount))

    var languagePointer: UnsafeMutablePointer<CChar>?
    if shouldDetectLanguage {
      params.detect_language = true
      params.language = nil
    } else {
      let languageCode = language == "hebrew" ? "he" : language
      languagePointer = strdup(languageCode)
      params.detect_language = false
      params.language = UnsafePointer(languagePointer)
    }
    defer {
      if let languagePointer {
        free(languagePointer)
      }
    }

    var promptPointer: UnsafeMutablePointer<CChar>?
    if let prompt, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      promptPointer = strdup(prompt)
      params.initial_prompt = UnsafePointer(promptPointer)
    }
    defer {
      if let promptPointer {
        free(promptPointer)
      }
    }

    let progressRelay = LocalMeetingWhisperProgressRelay { progress in
      reportProgress?(progress)
    }
    let progressRelayPointer = Unmanaged.passRetained(progressRelay).toOpaque()
    params.progress_callback_user_data = progressRelayPointer
    params.progress_callback = { _, _, progress, userData in
      guard let userData else { return }
      let relay = Unmanaged<LocalMeetingWhisperProgressRelay>.fromOpaque(userData)
        .takeUnretainedValue()
      relay.emit(progress: Int(progress))
    }
    defer {
      Unmanaged<LocalMeetingWhisperProgressRelay>.fromOpaque(progressRelayPointer).release()
    }

    let runResult = samples.withUnsafeBufferPointer { buffer -> Int32 in
      guard let baseAddress = buffer.baseAddress else { return -1 }
      return whisper_full(context, params, baseAddress, Int32(buffer.count))
    }

    guard runResult == 0 else {
      throw LocalSessionTranscriptionServiceError.transcriptionFailed(
        "whisper.cpp failed with exit code \(runResult) for \(modelURL.path)."
      )
    }

    let segmentCount = Int(whisper_full_n_segments(context))
    var items: [LocalSessionTranscriptionSegment] = []
    items.reserveCapacity(segmentCount)

    for index in 0..<segmentCount {
      let start = Double(whisper_full_get_segment_t0(context, Int32(index))) / 100.0
      let end = Double(whisper_full_get_segment_t1(context, Int32(index))) / 100.0
      let text = String(cString: whisper_full_get_segment_text(context, Int32(index)))
        .trimmingCharacters(in: .whitespacesAndNewlines)

      guard !text.isEmpty else { continue }
      items.append(LocalSessionTranscriptionSegment(startTime: start, endTime: end, text: text))
    }

    let detectedLanguage: String? = {
      let languageID = whisper_full_lang_id(context)
      guard languageID >= 0, let cString = whisper_lang_str(languageID) else { return nil }
      return String(cString: cString)
    }()

    return (items, detectedLanguage)
  }

  static func normalizedSamplesForRecognition(_ samples: [Float]) -> [Float] {
    guard !samples.isEmpty else { return samples }

    let peak = samples.reduce(Float.zero) { partial, sample in
      max(partial, abs(sample))
    }

    guard peak > 0 else { return samples }
    guard peak < 0.08 else { return samples }

    let targetPeak: Float = 0.22
    let gain = min(max(targetPeak / peak, 1), 8)
    guard gain > 1.05 else { return samples }

    return samples.map { sample in
      min(max(sample * gain, -1), 1)
    }
  }

  private func decodePCM16MonoWav(from url: URL) throws -> [Float] {
    let data = try Data(contentsOf: url)
    guard data.count >= 44 else {
      throw LocalSessionTranscriptionServiceError.invalidAudio("WAV file is too small.")
    }

    guard String(data: data.prefix(4), encoding: .ascii) == "RIFF",
      String(data: data[8..<12], encoding: .ascii) == "WAVE"
    else {
      throw LocalSessionTranscriptionServiceError.invalidAudio(
        "Only RIFF/WAVE files are supported.")
    }

    var offset = 12
    var audioFormat: UInt16?
    var channelCount: UInt16?
    var sampleRate: UInt32?
    var bitsPerSample: UInt16?
    var pcmData: Data?

    while offset + 8 <= data.count {
      let chunkID = String(data: data[offset..<(offset + 4)], encoding: .ascii) ?? ""
      let chunkSize = Int(readUInt32LE(from: data, at: offset + 4))
      let chunkStart = offset + 8
      let chunkEnd = chunkStart + chunkSize

      guard chunkEnd <= data.count else {
        throw LocalSessionTranscriptionServiceError.invalidAudio("WAV chunk is truncated.")
      }

      switch chunkID {
      case "fmt ":
        audioFormat = readUInt16LE(from: data, at: chunkStart)
        channelCount = readUInt16LE(from: data, at: chunkStart + 2)
        sampleRate = readUInt32LE(from: data, at: chunkStart + 4)
        bitsPerSample = readUInt16LE(from: data, at: chunkStart + 14)

      case "data":
        pcmData = data[chunkStart..<chunkEnd]

      default:
        break
      }

      offset = chunkEnd + (chunkSize % 2)
    }

    guard audioFormat == 1 else {
      throw LocalSessionTranscriptionServiceError.invalidAudio("Only PCM WAV files are supported.")
    }
    guard channelCount == 1 else {
      throw LocalSessionTranscriptionServiceError.invalidAudio("Only mono WAV files are supported.")
    }
    guard sampleRate == 16_000 else {
      throw LocalSessionTranscriptionServiceError.invalidAudio(
        "Expected 16 kHz audio, got \(sampleRate ?? 0) Hz.")
    }
    guard bitsPerSample == 16 else {
      throw LocalSessionTranscriptionServiceError.invalidAudio(
        "Only 16-bit WAV files are supported.")
    }
    guard let pcmData else {
      throw LocalSessionTranscriptionServiceError.invalidAudio("WAV file is missing a data chunk.")
    }

    let sampleCount = pcmData.count / MemoryLayout<Int16>.size
    var samples: [Float] = []
    samples.reserveCapacity(sampleCount)

    for index in 0..<sampleCount {
      let sampleOffset = pcmData.startIndex + (index * MemoryLayout<Int16>.size)
      let value = Int16(bitPattern: readUInt16LE(from: pcmData, at: sampleOffset))
      samples.append(Float(value) / 32_768.0)
    }

    return samples
  }

  private func readUInt16LE(from data: Data, at offset: Int) -> UInt16 {
    data.withUnsafeBytes { rawBuffer in
      let start = rawBuffer.baseAddress!.advanced(by: offset)
      return start.assumingMemoryBound(to: UInt16.self).pointee.littleEndian
    }
  }

  private func readUInt32LE(from data: Data, at offset: Int) -> UInt32 {
    data.withUnsafeBytes { rawBuffer in
      let start = rawBuffer.baseAddress!.advanced(by: offset)
      return start.assumingMemoryBound(to: UInt32.self).pointee.littleEndian
    }
  }
}

private final class LocalMeetingWhisperProgressRelay: @unchecked Sendable {
  private let lock = NSLock()
  private let handler: @Sendable (Int) -> Void
  private var lastProgress = -1

  init(handler: @escaping @Sendable (Int) -> Void) {
    self.handler = handler
  }

  func emit(progress: Int) {
    lock.lock()
    let clampedProgress = max(0, min(progress, 100))
    guard clampedProgress != lastProgress else {
      lock.unlock()
      return
    }
    lastProgress = clampedProgress
    lock.unlock()

    handler(clampedProgress)
  }
}

enum LocalSessionWhisperKitModelInspector {
  static func isWhisperKitModelDirectory(
    _ url: URL,
    fileManager: FileManager = .default
  ) -> Bool {
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
}

struct LocalMeetingSpeechRegion: Equatable {
  let startSample: Int
  let endSample: Int
}

struct LocalMeetingSpeechChunk: Equatable {
  let startSample: Int
  let endSample: Int
  let speechSampleCount: Int
  let samples: [Float]
}

struct LocalMeetingSpeechChunker {
  private let minimumChunkDuration: TimeInterval = 12
  private let maximumChunkDuration: TimeInterval = 75
  private let maximumMergedSilenceGap: TimeInterval = 10

  func chunks(from regions: [LocalMeetingSpeechRegion], samples: [Float])
    -> [LocalMeetingSpeechChunk]
  {
    guard !samples.isEmpty else { return [] }
    guard var currentRegion = regions.first else {
      return []
    }

    var chunks: [LocalMeetingSpeechChunk] = []
    var currentStartSample = currentRegion.startSample
    var currentEndSample = currentRegion.endSample
    var currentSpeechSampleCount = currentRegion.endSample - currentRegion.startSample

    for region in regions.dropFirst() {
      let gapDuration = seconds(region.startSample - currentEndSample)
      let currentDuration = seconds(currentEndSample - currentStartSample)
      let proposedDuration = seconds(region.endSample - currentStartSample)
      let shouldMerge =
        proposedDuration <= maximumChunkDuration
        && (gapDuration <= maximumMergedSilenceGap || currentDuration < minimumChunkDuration)

      if shouldMerge {
        currentEndSample = region.endSample
        currentSpeechSampleCount += region.endSample - region.startSample
      } else {
        chunks.append(
          makeChunk(
            startSample: currentStartSample,
            endSample: currentEndSample,
            speechSampleCount: currentSpeechSampleCount,
            samples: samples
          )
        )
        currentRegion = region
        currentStartSample = currentRegion.startSample
        currentEndSample = currentRegion.endSample
        currentSpeechSampleCount = currentRegion.endSample - currentRegion.startSample
      }
    }

    chunks.append(
      makeChunk(
        startSample: currentStartSample,
        endSample: currentEndSample,
        speechSampleCount: currentSpeechSampleCount,
        samples: samples
      )
    )
    return chunks
  }

  private func makeChunk(
    startSample: Int,
    endSample: Int,
    speechSampleCount: Int,
    samples: [Float]
  ) -> LocalMeetingSpeechChunk {
    LocalMeetingSpeechChunk(
      startSample: startSample,
      endSample: endSample,
      speechSampleCount: speechSampleCount,
      samples: Array(samples[startSample..<endSample])
    )
  }

  private func seconds(_ sampleCount: Int) -> TimeInterval {
    Double(max(0, sampleCount)) / Double(LocalMeetingSpeechRegionDetector.sampleRate)
  }
}

struct LocalMeetingSpeechRegionDetector {
  static let sampleRate = 16_000
  private let frameSize = 320
  private let speechThreshold: Float = 0.0085
  private let minimumSpeechFrames = 8
  private let mergeGapFrames = 18
  private let leadingPaddingFrames = 8
  private let trailingPaddingFrames = 12

  func regions(in samples: [Float]) -> [LocalMeetingSpeechRegion] {
    guard !samples.isEmpty else { return [] }

    let frameCount = Int(ceil(Double(samples.count) / Double(frameSize)))
    var activeFrames: [Bool] = Array(repeating: false, count: frameCount)

    for frameIndex in 0..<frameCount {
      let start = frameIndex * frameSize
      let end = min(start + frameSize, samples.count)
      guard start < end else { continue }

      var energy: Float = 0
      var peak: Float = 0
      for sample in samples[start..<end] {
        let magnitude = abs(sample)
        energy += magnitude * magnitude
        peak = max(peak, magnitude)
      }

      let rms = sqrt(energy / Float(end - start))
      activeFrames[frameIndex] = rms >= speechThreshold || peak >= 0.045
    }

    var baseRegions: [(startFrame: Int, endFrame: Int)] = []
    var currentStart: Int?
    var consecutiveSilenceFrames = 0

    for frameIndex in 0..<frameCount {
      if activeFrames[frameIndex] {
        if currentStart == nil {
          currentStart = frameIndex
        }
        consecutiveSilenceFrames = 0
        continue
      }

      guard let regionStart = currentStart else { continue }
      consecutiveSilenceFrames += 1
      if consecutiveSilenceFrames > mergeGapFrames {
        let endFrame = frameIndex - consecutiveSilenceFrames + 1
        if endFrame - regionStart >= minimumSpeechFrames {
          baseRegions.append((regionStart, endFrame))
        }
        self.resetTracking(
          currentStart: &currentStart, consecutiveSilenceFrames: &consecutiveSilenceFrames)
      }
    }

    if let currentStart {
      let endFrame = frameCount
      if endFrame - currentStart >= minimumSpeechFrames {
        baseRegions.append((currentStart, endFrame))
      }
    }

    guard !baseRegions.isEmpty else { return [] }

    let paddedRegions = baseRegions.map { region in
      (
        startFrame: max(0, region.startFrame - leadingPaddingFrames),
        endFrame: min(frameCount, region.endFrame + trailingPaddingFrames)
      )
    }

    let mergedRegions = merge(regions: paddedRegions)
    return mergedRegions.map { region in
      LocalMeetingSpeechRegion(
        startSample: region.startFrame * frameSize,
        endSample: min(samples.count, region.endFrame * frameSize)
      )
    }
  }

  private func merge(regions: [(startFrame: Int, endFrame: Int)]) -> [(
    startFrame: Int, endFrame: Int
  )] {
    guard var current = regions.first else { return [] }
    var merged: [(startFrame: Int, endFrame: Int)] = []

    for region in regions.dropFirst() {
      if region.startFrame <= current.endFrame {
        current.endFrame = max(current.endFrame, region.endFrame)
      } else {
        merged.append(current)
        current = region
      }
    }

    merged.append(current)
    return merged
  }

  private func resetTracking(currentStart: inout Int?, consecutiveSilenceFrames: inout Int) {
    currentStart = nil
    consecutiveSilenceFrames = 0
  }
}

private final class LocalMeetingWhisperContextCache {
  private var contexts: [String: OpaquePointer] = [:]

  func context(for modelURL: URL) throws -> OpaquePointer {
    if let cached = contexts[modelURL.path] {
      return cached
    }

    configureMetalResourcesIfNeeded()

    var contextParams = whisper_context_default_params()
    #if arch(arm64)
      contextParams.use_gpu = true
      contextParams.flash_attn = true
    #else
      contextParams.use_gpu = false
      contextParams.flash_attn = false
    #endif

    guard let context = whisper_init_from_file_with_params(modelURL.path, contextParams) else {
      throw LocalSessionTranscriptionServiceError.modelLoadFailed(
        "Failed to load whisper model at \(modelURL.path).")
    }

    contexts[modelURL.path] = context
    return context
  }

  deinit {
    for context in contexts.values {
      whisper_free(context)
    }
  }

  private func configureMetalResourcesIfNeeded() {
    if let resourcePath = LocalMeetingMetalResourceLocator.preparedResourcePath(
      existingValue: ProcessInfo.processInfo.environment["GGML_METAL_PATH_RESOURCES"],
      candidateDirectories: LocalMeetingMetalResourceLocator.candidateDirectories()
    ) {
      setenv("GGML_METAL_PATH_RESOURCES", resourcePath, 1)
    }
  }
}

struct LocalMeetingMetalResourceLocator {
  private static let defaultMetalLibraryFileName = "default.metallib"
  private static let metalSourceFileName = "ggml-metal.metal"
  private static let commonHeaderFileName = "ggml-common.h"
  private static let requiredSourceFileNames = [metalSourceFileName, commonHeaderFileName]

  static func resolveResourcePath(
    existingValue: String?,
    candidateDirectories: [URL],
    fileManager: FileManager = .default
  ) -> String? {
    resolveResourceDirectory(
      existingValue: existingValue,
      candidateDirectories: candidateDirectories,
      fileManager: fileManager
    )?.path
  }

  static func preparedResourcePath(
    existingValue: String?,
    candidateDirectories: [URL],
    fileManager: FileManager = .default,
    writableDirectory: URL? = nil
  ) -> String? {
    guard
      let resourceDirectory = resolveResourceDirectory(
        existingValue: existingValue,
        candidateDirectories: candidateDirectories,
        fileManager: fileManager
      )
    else {
      return nil
    }

    if fileManager.fileExists(
      atPath: resourceDirectory.appendingPathComponent(defaultMetalLibraryFileName).path)
    {
      return resourceDirectory.path
    }

    return preparedSourceDirectory(
      from: resourceDirectory,
      fileManager: fileManager,
      writableDirectory: writableDirectory
    )?.path ?? resourceDirectory.path
  }

  private static func resolveResourceDirectory(
    existingValue: String?,
    candidateDirectories: [URL],
    fileManager: FileManager
  ) -> URL? {
    if let existingValue, !existingValue.isEmpty,
      directoryCanProvideMetalResources(
        URL(fileURLWithPath: existingValue, isDirectory: true),
        fileManager: fileManager)
    {
      return URL(fileURLWithPath: existingValue, isDirectory: true)
    }

    return uniqueCandidateDirectories(candidateDirectories).first { directory in
      directoryCanProvideMetalResources(directory, fileManager: fileManager)
    }
  }

  private static func directoryCanProvideMetalResources(
    _ directory: URL,
    fileManager: FileManager
  ) -> Bool {
    if fileManager.fileExists(atPath: directory.appendingPathComponent(defaultMetalLibraryFileName).path) {
      return true
    }

    return requiredSourceFileNames.allSatisfy {
      fileManager.fileExists(atPath: directory.appendingPathComponent($0).path)
    }
  }

  private static func preparedSourceDirectory(
    from sourceDirectory: URL,
    fileManager: FileManager,
    writableDirectory: URL?
  ) -> URL? {
    let sourceURL = sourceDirectory.appendingPathComponent(metalSourceFileName)
    let headerURL = sourceDirectory.appendingPathComponent(commonHeaderFileName)
    guard
      let source = try? String(contentsOf: sourceURL, encoding: .utf8),
      let header = try? String(contentsOf: headerURL, encoding: .utf8)
    else {
      return nil
    }

    guard source.contains(#"#include "ggml-common.h""#) else {
      return sourceDirectory
    }

    let preparedRoot = writableDirectory ?? fileManager.temporaryDirectory
      .appendingPathComponent("CepessaSessions-GGMLMetalResources", isDirectory: true)
    let preparedDirectory = preparedRoot
      .appendingPathComponent(safeDirectoryName(for: sourceDirectory), isDirectory: true)
    let preparedSourceURL = preparedDirectory.appendingPathComponent(metalSourceFileName)
    let preparedHeaderURL = preparedDirectory.appendingPathComponent(commonHeaderFileName)

    do {
      try fileManager.createDirectory(at: preparedDirectory, withIntermediateDirectories: true)
      let preparedSource = source.replacingOccurrences(
        of: "#include \"\(commonHeaderFileName)\"",
        with: header
      )
      try Data(preparedSource.utf8).write(to: preparedSourceURL, options: [.atomic])
      try Data(header.utf8).write(to: preparedHeaderURL, options: [.atomic])
      return preparedDirectory
    } catch {
      return nil
    }
  }

  private static func safeDirectoryName(for directory: URL) -> String {
    let safeScalars = directory.path.unicodeScalars.map { scalar in
      CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : "_"
    }
    return String(safeScalars.suffix(160))
  }

  static func candidateDirectories(
    mainBundle: Bundle = .main,
    fileManager: FileManager = .default
  ) -> [URL] {
    var directories: [URL] = []

    func append(_ url: URL?) {
      guard let url else { return }
      directories.append(url)
    }

    if let resourceURL = mainBundle.resourceURL {
      append(resourceURL)
      append(
        resourceURL.appendingPathComponent(
          "CepessaSessions_CepessaSessions.bundle", isDirectory: true))
      if let bundleURLs = try? fileManager.contentsOfDirectory(
        at: resourceURL,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
      ) {
        directories.append(contentsOf: bundleURLs.filter { $0.pathExtension == "bundle" })
      }
    }

    let executableDirectory = URL(fileURLWithPath: CommandLine.arguments[0])
      .deletingLastPathComponent()
    append(executableDirectory)
    append(
      executableDirectory.appendingPathComponent(
        "CepessaSessions_CepessaSessions.bundle", isDirectory: true))
    directories.append(contentsOf: developmentResourceDirectories(fileManager: fileManager))
    return uniqueCandidateDirectories(directories)
  }

  private static func developmentResourceDirectories(fileManager: FileManager) -> [URL] {
    let homeDirectory = fileManager.homeDirectoryForCurrentUser
    let userTypeWhisperHelperResources = homeDirectory
      .appendingPathComponent(
        "Applications/TypeWhisper.app/Contents/PlugIns/IvritASRPlugin.bundle/Contents/Resources/Helpers",
        isDirectory: true)
    return [
      userTypeWhisperHelperResources,
      URL(
        fileURLWithPath:
          "/Applications/TypeWhisper.app/Contents/PlugIns/IvritASRPlugin.bundle/Contents/Resources/Helpers",
        isDirectory: true),
      URL(
        fileURLWithPath:
          "/Users/ben/Documents/App/General/typewhisper-mac/IvritASRHelper/Resources",
        isDirectory: true),
      URL(
        fileURLWithPath:
          "/Users/ben/Documents/App/General/typewhisper-mac/Vendor/whisper.spm/Sources/whisper",
        isDirectory: true),
    ]
  }

  private static func uniqueCandidateDirectories(_ directories: [URL]) -> [URL] {
    var seen: Set<String> = []
    var unique: [URL] = []

    for directory in directories {
      let standardizedPath = directory.standardizedFileURL.path
      if seen.insert(standardizedPath).inserted {
        unique.append(directory)
      }
    }

    return unique
  }
}

typealias LocalMeetingTranscriptionSegment = LocalSessionTranscriptionSegment
typealias LocalMeetingTranscriptionResult = LocalSessionTranscriptionResult
typealias LocalMeetingTranscriptionServiceError = LocalSessionTranscriptionServiceError
typealias LocalMeetingTranscriptionService = LocalSessionTranscriptionService
