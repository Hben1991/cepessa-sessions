import XCTest
@testable import Omi_Computer

final class LocalMeetingTranscriptionPreprocessingTests: XCTestCase {
    func testSpeechRegionDetectorSkipsLongSilentGap() {
        let detector = LocalMeetingSpeechRegionDetector()
        let samples = silence(duration: 1.0)
            + speech(duration: 1.0)
            + silence(duration: 2.4)
            + speech(duration: 1.2)

        let regions = detector.regions(in: samples)

        XCTAssertEqual(regions.count, 2)
        XCTAssertLessThan(abs(seconds(for: regions[0].startSample) - 0.84), 0.2)
        XCTAssertLessThan(abs(seconds(for: regions[0].endSample) - 2.24), 0.25)
        XCTAssertLessThan(abs(seconds(for: regions[1].startSample) - 4.24), 0.25)
        XCTAssertLessThan(abs(seconds(for: regions[1].endSample) - 5.84), 0.25)
    }

    func testSpeechRegionDetectorMergesShortPauseIntoSingleRegion() {
        let detector = LocalMeetingSpeechRegionDetector()
        let samples = silence(duration: 0.5)
            + speech(duration: 1.0)
            + silence(duration: 0.18)
            + speech(duration: 1.0)

        let regions = detector.regions(in: samples)

        XCTAssertEqual(regions.count, 1)
        XCTAssertLessThan(abs(seconds(for: regions[0].startSample) - 0.34), 0.2)
        XCTAssertLessThan(abs(seconds(for: regions[0].endSample) - 2.92), 0.25)
    }

    func testSpeechRegionDetectorReturnsNoRegionsForSilence() {
        let detector = LocalMeetingSpeechRegionDetector()
        let samples = Array(repeating: Float.zero, count: LocalMeetingSpeechRegionDetector.sampleRate * 3)

        XCTAssertTrue(detector.regions(in: samples).isEmpty)
    }

    private func silence(duration: Double) -> [Float] {
        Array(repeating: 0, count: Int(duration * Double(LocalMeetingSpeechRegionDetector.sampleRate)))
    }

    private func speech(duration: Double) -> [Float] {
        let sampleCount = Int(duration * Double(LocalMeetingSpeechRegionDetector.sampleRate))
        return (0..<sampleCount).map { index in
            let value = sin(Double(index) * 0.045) * 0.12
            return Float(value)
        }
    }

    private func seconds(for sampleOffset: Int) -> Double {
        Double(sampleOffset) / Double(LocalMeetingSpeechRegionDetector.sampleRate)
    }
}
