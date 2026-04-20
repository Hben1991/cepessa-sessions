import Foundation
import AVFoundation
import CoreAudio

final class LocalMeetingAudioCaptureService: @unchecked Sendable {
    typealias AudioChunkHandler = AudioCaptureService.AudioChunkHandler
    typealias AudioLevelHandler = AudioCaptureService.AudioLevelHandler
    typealias AudioCaptureError = AudioCaptureService.AudioCaptureError

    private let base: AudioCaptureService

    var onSilentMicDetected: (() -> Void)? {
        didSet {
            base.onSilentMicDetected = onSilentMicDetected
        }
    }

    init() {
        self.base = AudioCaptureService()
    }

    init(overrideDeviceID: AudioDeviceID) {
        self.base = AudioCaptureService(overrideDeviceID: overrideDeviceID)
    }

    static func checkPermission() -> Bool {
        AudioCaptureService.checkPermission()
    }

    static func isPermissionDenied() -> Bool {
        AudioCaptureService.isPermissionDenied()
    }

    static func authorizationStatus() -> AVAuthorizationStatus {
        AudioCaptureService.authorizationStatus()
    }

    static func requestPermission() async -> Bool {
        await AudioCaptureService.requestPermission()
    }

    static func isBluetoothTransport(deviceID: AudioDeviceID) -> Bool {
        AudioCaptureService.isBluetoothTransport(deviceID: deviceID)
    }

    static func findBuiltInMicDeviceID() -> AudioDeviceID? {
        AudioCaptureService.findBuiltInMicDeviceID()
    }

    func startCapture(onAudioChunk: @escaping AudioChunkHandler, onAudioLevel: AudioLevelHandler? = nil) async throws {
        try await base.startCapture(onAudioChunk: onAudioChunk, onAudioLevel: onAudioLevel)
    }

    func stopCapture() {
        base.stopCapture()
    }
}
