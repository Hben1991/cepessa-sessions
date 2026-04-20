import XCTest
@testable import OmiLocalMeetings

final class AudioMixerTests: XCTestCase {
    func testMixesTwoMonoPCM16BuffersBySummingAndClipping() throws {
        let micSamples: [Int16] = [1_000, 20_000, Int16.max]
        let systemSamples: [Int16] = [2_000, 15_000, 100]

        let mixed = AudioMixer.mixMono(
            micPCM16: Self.pcm16Data(from: micSamples),
            systemPCM16: Self.pcm16Data(from: systemSamples)
        )

        XCTAssertEqual(Self.int16Samples(from: mixed), [3_000, Int16.max, Int16.max])
    }

    func testSignalLevelTrackerReturnsNormalizedPeakLevel() throws {
        let samples: [Int16] = [0, -16_384, 8_192, -4_000]
        let level = SignalLevelTracker.normalizedLevel(from: Self.pcm16Data(from: samples))

        XCTAssertEqual(level, 16_384.0 / 32_767.0, accuracy: 0.0001)
    }

    func testSignalLevelTrackerReturnsZeroForEmptyData() throws {
        XCTAssertEqual(SignalLevelTracker.normalizedLevel(from: Data()), 0)
    }

    private static func pcm16Data(from samples: [Int16]) -> Data {
        var data = Data()
        data.reserveCapacity(samples.count * 2)
        for sample in samples {
            var littleEndian = sample.littleEndian
            withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    private static func int16Samples(from data: Data) -> [Int16] {
        data.withUnsafeBytes { rawBuffer in
            let words = rawBuffer.bindMemory(to: Int16.self)
            return words.map(Int16.init(littleEndian:))
        }
    }
}
