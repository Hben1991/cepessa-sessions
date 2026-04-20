import XCTest
import CoreAudio
@testable import Omi_Computer

final class LocalMeetingRecorderRoutingTests: XCTestCase {
    func testInitialMicrophoneRouteUsesSystemDefaultInput() {
        XCTAssertEqual(LocalMeetingMicrophoneRoute.initialRoute(), .systemDefault)
        XCTAssertNil(LocalMeetingMicrophoneRoute.initialRoute().overrideDeviceID)
    }

    func testSilentMicFallbackUsesBuiltInMicOnceWhenAvailable() {
        let route = LocalMeetingMicrophoneRoute.fallbackRoute(
            builtInMicID: AudioDeviceID(42),
            hasAlreadyFallenBack: false
        )

        XCTAssertEqual(route, .builtIn(AudioDeviceID(42)))
        XCTAssertEqual(route?.overrideDeviceID, AudioDeviceID(42))
    }

    func testSilentMicFallbackDoesNotRepeatOrFabricateMissingDevice() {
        XCTAssertNil(
            LocalMeetingMicrophoneRoute.fallbackRoute(
                builtInMicID: nil,
                hasAlreadyFallenBack: false
            )
        )
        XCTAssertNil(
            LocalMeetingMicrophoneRoute.fallbackRoute(
                builtInMicID: AudioDeviceID(7),
                hasAlreadyFallenBack: true
            )
        )
    }
}
