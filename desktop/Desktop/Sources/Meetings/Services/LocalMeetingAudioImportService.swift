import AVFoundation
import Foundation

protocol LocalSessionAudioImporting: Sendable {
    func importAudio(from sourceURL: URL, to destinationWavURL: URL) async throws
}

enum LocalSessionAudioImportError: LocalizedError {
    case unsupportedSource(String)
    case conversionFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedSource(let message), .conversionFailed(let message):
            return message
        }
    }
}

struct LocalSessionAudioImportService: LocalSessionAudioImporting {
    func importAudio(from sourceURL: URL, to destinationWavURL: URL) async throws {
        try await Task.detached(priority: .userInitiated) {
            try convertToCanonicalWav(sourceURL: sourceURL, destinationWavURL: destinationWavURL)
        }.value
    }

    private func convertToCanonicalWav(sourceURL: URL, destinationWavURL: URL) throws {
        let inputFile = try AVAudioFile(forReading: sourceURL)
        let inputFormat = inputFile.processingFormat
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ) else {
            throw LocalSessionAudioImportError.conversionFailed("Could not build the target audio format.")
        }

        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw LocalSessionAudioImportError.unsupportedSource(
                "Sessions could not convert this recording format."
            )
        }

        let sourceFrameCapacity: AVAudioFrameCount = 4_096
        let outputFrameCapacity = AVAudioFrameCount(
            max(1, Int(Double(sourceFrameCapacity) * (targetFormat.sampleRate / inputFormat.sampleRate)).advanced(by: 64))
        )
        let writer = try LocalMeetingWaveFileWriter(fileURL: destinationWavURL)
        defer { try? writer.close() }

        var reachedEndOfSource = false

        while true {
            guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputFrameCapacity) else {
                throw LocalSessionAudioImportError.conversionFailed("Could not allocate the converted audio buffer.")
            }

            var conversionError: NSError?
            let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
                if reachedEndOfSource {
                    outStatus.pointee = .endOfStream
                    return nil
                }

                let remainingFrames = max(0, inputFile.length - inputFile.framePosition)
                if remainingFrames == 0 {
                    reachedEndOfSource = true
                    outStatus.pointee = .endOfStream
                    return nil
                }

                let frameCount = min(sourceFrameCapacity, AVAudioFrameCount(remainingFrames))
                guard let buffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: frameCount) else {
                    outStatus.pointee = .noDataNow
                    return nil
                }

                do {
                    try inputFile.read(into: buffer, frameCount: frameCount)
                } catch {
                    outStatus.pointee = .noDataNow
                    return nil
                }

                if buffer.frameLength == 0 {
                    reachedEndOfSource = true
                    outStatus.pointee = .endOfStream
                    return nil
                }

                outStatus.pointee = .haveData
                return buffer
            }

            if let conversionError {
                throw LocalSessionAudioImportError.conversionFailed(conversionError.localizedDescription)
            }

            if outputBuffer.frameLength > 0 {
                try writer.append(samples: pcm16Samples(from: outputBuffer))
            }

            if status == .endOfStream {
                break
            }
        }
    }

    private func pcm16Samples(from buffer: AVAudioPCMBuffer) -> [Int16] {
        guard let floatChannelData = buffer.floatChannelData else { return [] }
        let samples = UnsafeBufferPointer(start: floatChannelData[0], count: Int(buffer.frameLength))
        return samples.map { sample in
            let scaled = Int((sample * 32_767.0).rounded())
            let clamped = max(Int(Int16.min), min(Int(Int16.max), scaled))
            return Int16(clamped)
        }
    }
}
