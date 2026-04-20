import Foundation
import AVFoundation
import CoreAudio

@available(macOS 14.4, *)
final class LocalMeetingSystemAudioCaptureService: @unchecked Sendable {
    typealias AudioChunkHandler = SystemAudioCaptureService.AudioChunkHandler
    typealias AudioLevelHandler = SystemAudioCaptureService.AudioLevelHandler
    typealias SystemAudioCaptureError = SystemAudioCaptureService.SystemAudioCaptureError

    private let base = SystemAudioCaptureService()

    static func checkPermission() -> Bool {
        SystemAudioCaptureService.checkPermission()
    }

    static func requestPermission() async -> Bool {
        await SystemAudioCaptureService.requestPermission()
    }

    func startCapture(onAudioChunk: @escaping AudioChunkHandler, onAudioLevel: AudioLevelHandler? = nil) async throws {
        try await base.startCapture(onAudioChunk: onAudioChunk, onAudioLevel: onAudioLevel)
    }

    func stopCapture() {
        base.stopCapture()
    }
}
