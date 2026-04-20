import Foundation
import whisper

protocol LocalSessionTranscribing: Sendable {
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
        case transcribing(percent: Int)
        case extractingSegments
    }

    let stage: Stage
}

struct LocalSessionTranscriptionSegment: Sendable, Codable, Equatable {
    let startTime: TimeInterval
    let endTime: TimeInterval
    let text: String
}

struct LocalSessionTranscriptionResult: Sendable, Codable, Equatable {
    let text: String
    let detectedLanguage: String?
    let segments: [LocalSessionTranscriptionSegment]
    let modelPath: String
    let warnings: [String]

    init(
        text: String,
        detectedLanguage: String?,
        segments: [LocalSessionTranscriptionSegment],
        modelPath: String,
        warnings: [String] = []
    ) {
        self.text = text
        self.detectedLanguage = detectedLanguage
        self.segments = segments
        self.modelPath = modelPath
        self.warnings = warnings
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
    private let cache = LocalMeetingWhisperContextCache()

    func transcribe(
        wavURL: URL,
        modelURL: URL,
        language: String = "he",
        prompt: String? = nil,
        translateToEnglish: Bool = false,
        onProgress: (@Sendable (LocalSessionTranscriptionProgress) async -> Void)? = nil
    ) async throws -> LocalSessionTranscriptionResult {
        if let onProgress {
            await onProgress(.init(stage: .decodingAudio))
        }
        let samples = try decodePCM16MonoWav(from: wavURL)
        if let onProgress {
            await onProgress(.init(stage: .loadingModel))
        }
        let context = try cache.context(for: modelURL)
        let segments = try await transcribe(
            samples: samples,
            context: context,
            modelURL: modelURL,
            language: language,
            prompt: prompt,
            translateToEnglish: translateToEnglish,
            onProgress: onProgress
        )
        let transcript = segments.items.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)

        return LocalSessionTranscriptionResult(
            text: transcript,
            detectedLanguage: segments.detectedLanguage,
            segments: segments.items,
            modelPath: modelURL.path
        )
    }

    func transcriptText(
        wavURL: URL,
        modelURL: URL,
        language: String = "he",
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
        let chunks = regions.isEmpty
            ? [LocalMeetingSpeechChunk(startSample: 0, samples: samples)]
            : regions.map { region in
                LocalMeetingSpeechChunk(
                    startSample: region.startSample,
                    samples: Array(samples[region.startSample..<region.endSample])
                )
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
                    let completedSamples = Double(consumedChunkSamples) + (Double(chunkSampleCount) * Double(chunkProgress) / 100.0)
                    let overallProgress = Int((completedSamples / Double(totalChunkSamples) * 100.0).rounded())
                    Task {
                        await onProgress(.init(stage: .transcribing(percent: overallProgress)))
                    }
                }
            )

            let timeOffset = Double(chunkStartSample) / Double(LocalMeetingSpeechRegionDetector.sampleRate)
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

        return (allItems, detectedLanguage)
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

        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.print_realtime = false
        params.print_progress = false
        params.print_timestamps = false
        params.print_special = false
        params.translate = translateToEnglish
        params.no_context = true
        params.no_timestamps = false
        params.single_segment = false
        params.n_threads = Int32(max(1, ProcessInfo.processInfo.activeProcessorCount - 2))

        let normalizedLanguage = language.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let shouldDetectLanguage = normalizedLanguage.isEmpty || normalizedLanguage == "auto"

        var languagePointer: UnsafeMutablePointer<CChar>?
        if shouldDetectLanguage {
            params.detect_language = true
            params.language = nil
        } else {
            let languageCode = normalizedLanguage == "hebrew" ? "he" : normalizedLanguage
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
            let relay = Unmanaged<LocalMeetingWhisperProgressRelay>.fromOpaque(userData).takeUnretainedValue()
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

    private func decodePCM16MonoWav(from url: URL) throws -> [Float] {
        let data = try Data(contentsOf: url)
        guard data.count >= 44 else {
            throw LocalSessionTranscriptionServiceError.invalidAudio("WAV file is too small.")
        }

        guard String(data: data.prefix(4), encoding: .ascii) == "RIFF",
              String(data: data[8..<12], encoding: .ascii) == "WAVE" else {
            throw LocalSessionTranscriptionServiceError.invalidAudio("Only RIFF/WAVE files are supported.")
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
            throw LocalSessionTranscriptionServiceError.invalidAudio("Expected 16 kHz audio, got \(sampleRate ?? 0) Hz.")
        }
        guard bitsPerSample == 16 else {
            throw LocalSessionTranscriptionServiceError.invalidAudio("Only 16-bit WAV files are supported.")
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

struct LocalMeetingSpeechRegion: Equatable {
    let startSample: Int
    let endSample: Int
}

private struct LocalMeetingSpeechChunk {
    let startSample: Int
    let samples: [Float]
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
                self.resetTracking(currentStart: &currentStart, consecutiveSilenceFrames: &consecutiveSilenceFrames)
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

    private func merge(regions: [(startFrame: Int, endFrame: Int)]) -> [(startFrame: Int, endFrame: Int)] {
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
            throw LocalSessionTranscriptionServiceError.modelLoadFailed("Failed to load whisper model at \(modelURL.path).")
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
        let current = ProcessInfo.processInfo.environment["GGML_METAL_PATH_RESOURCES"]
        if let current, !current.isEmpty {
            return
        }

        let resourcePath = Bundle.main.resourcePath
            ?? URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().path
        setenv("GGML_METAL_PATH_RESOURCES", resourcePath, 1)
    }
}

typealias LocalMeetingTranscriptionSegment = LocalSessionTranscriptionSegment
typealias LocalMeetingTranscriptionResult = LocalSessionTranscriptionResult
typealias LocalMeetingTranscriptionServiceError = LocalSessionTranscriptionServiceError
typealias LocalMeetingTranscriptionService = LocalSessionTranscriptionService
