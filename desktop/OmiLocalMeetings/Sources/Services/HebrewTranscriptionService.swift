import Foundation
import whisper

public struct HebrewTranscriptionSegment: Sendable, Codable, Equatable {
    public let startTime: TimeInterval
    public let endTime: TimeInterval
    public let text: String

    public init(startTime: TimeInterval, endTime: TimeInterval, text: String) {
        self.startTime = startTime
        self.endTime = endTime
        self.text = text
    }
}

public struct HebrewTranscriptionResult: Sendable, Codable, Equatable {
    public let text: String
    public let detectedLanguage: String?
    public let segments: [HebrewTranscriptionSegment]
    public let modelPath: String
    public let warnings: [String]

    public init(
        text: String,
        detectedLanguage: String?,
        segments: [HebrewTranscriptionSegment],
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

public enum HebrewTranscriptionServiceError: LocalizedError {
    case invalidAudio(String)
    case modelLoadFailed(String)
    case transcriptionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidAudio(let message),
             .modelLoadFailed(let message),
             .transcriptionFailed(let message):
            return message
        }
    }
}

public actor HebrewTranscriptionService {
    private let cache = WhisperContextCache()

    public init() {}

    public func transcribe(
        wavURL: URL,
        modelURL: URL,
        language: String = "he",
        prompt: String? = nil,
        translateToEnglish: Bool = false
    ) async throws -> HebrewTranscriptionResult {
        let samples = try decodePCM16MonoWav(from: wavURL)
        let context = try cache.context(for: modelURL)
        let segments = try transcribe(
            samples: samples,
            context: context,
            modelURL: modelURL,
            language: language,
            prompt: prompt,
            translateToEnglish: translateToEnglish
        )
        let transcript = segments.items.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)

        return HebrewTranscriptionResult(
            text: transcript,
            detectedLanguage: segments.detectedLanguage,
            segments: segments.items,
            modelPath: modelURL.path
        )
    }

    public func transcriptText(
        wavURL: URL,
        modelURL: URL,
        language: String = "he",
        prompt: String? = nil,
        translateToEnglish: Bool = false
    ) async throws -> String {
        try await transcribe(
            wavURL: wavURL,
            modelURL: modelURL,
            language: language,
            prompt: prompt,
            translateToEnglish: translateToEnglish
        ).text
    }

    private func transcribe(
        samples: [Float],
        context: OpaquePointer,
        modelURL: URL,
        language: String,
        prompt: String?,
        translateToEnglish: Bool
    ) throws -> (items: [HebrewTranscriptionSegment], detectedLanguage: String?) {
        guard !samples.isEmpty else {
            throw HebrewTranscriptionServiceError.invalidAudio("WAV file contains no PCM samples.")
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

        let runResult = samples.withUnsafeBufferPointer { buffer -> Int32 in
            guard let baseAddress = buffer.baseAddress else { return -1 }
            return whisper_full(context, params, baseAddress, Int32(buffer.count))
        }

        guard runResult == 0 else {
            throw HebrewTranscriptionServiceError.transcriptionFailed(
                "whisper.cpp failed with exit code \(runResult) for \(modelURL.path)."
            )
        }

        let segmentCount = Int(whisper_full_n_segments(context))
        var items: [HebrewTranscriptionSegment] = []
        items.reserveCapacity(segmentCount)

        for index in 0..<segmentCount {
            let start = Double(whisper_full_get_segment_t0(context, Int32(index))) / 100.0
            let end = Double(whisper_full_get_segment_t1(context, Int32(index))) / 100.0
            let text = String(cString: whisper_full_get_segment_text(context, Int32(index)))
                .trimmingCharacters(in: .whitespacesAndNewlines)

            guard !text.isEmpty else { continue }
            items.append(HebrewTranscriptionSegment(startTime: start, endTime: end, text: text))
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
            throw HebrewTranscriptionServiceError.invalidAudio("WAV file is too small.")
        }

        guard String(data: data.prefix(4), encoding: .ascii) == "RIFF",
              String(data: data[8..<12], encoding: .ascii) == "WAVE" else {
            throw HebrewTranscriptionServiceError.invalidAudio("Only RIFF/WAVE files are supported.")
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
                throw HebrewTranscriptionServiceError.invalidAudio("WAV chunk is truncated.")
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
            throw HebrewTranscriptionServiceError.invalidAudio("Only PCM WAV files are supported.")
        }
        guard channelCount == 1 else {
            throw HebrewTranscriptionServiceError.invalidAudio("Only mono WAV files are supported.")
        }
        guard sampleRate == 16_000 else {
            throw HebrewTranscriptionServiceError.invalidAudio("Expected 16 kHz audio, got \(sampleRate ?? 0) Hz.")
        }
        guard bitsPerSample == 16 else {
            throw HebrewTranscriptionServiceError.invalidAudio("Only 16-bit WAV files are supported.")
        }
        guard let pcmData else {
            throw HebrewTranscriptionServiceError.invalidAudio("WAV file is missing a data chunk.")
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

private final class WhisperContextCache {
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
            throw HebrewTranscriptionServiceError.modelLoadFailed("Failed to load whisper model at \(modelURL.path).")
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
