import XCTest
@testable import OmiLocalMeetings

final class WaveFileWriterTests: XCTestCase {
    func testFinalizesWaveHeaderWithCorrectChunkSizes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("mix.wav")

        let writer = try WaveFileWriter(fileURL: fileURL)
        try writer.append(samples: [0, 1_000, -1_000, Int16.max])
        try writer.close()

        let data = try Data(contentsOf: fileURL)
        XCTAssertEqual(data.count, 44 + 8)
        XCTAssertEqual(Self.fourCC(data, offset: 0), "RIFF")
        XCTAssertEqual(Self.fourCC(data, offset: 8), "WAVE")
        XCTAssertEqual(Self.fourCC(data, offset: 12), "fmt ")
        XCTAssertEqual(Self.fourCC(data, offset: 36), "data")

        XCTAssertEqual(Self.uint32LE(data, offset: 4), 36 + 8)
        XCTAssertEqual(Self.uint32LE(data, offset: 16), 16)
        XCTAssertEqual(Self.uint16LE(data, offset: 20), 1)
        XCTAssertEqual(Self.uint16LE(data, offset: 22), 1)
        XCTAssertEqual(Self.uint32LE(data, offset: 24), 16_000)
        XCTAssertEqual(Self.uint32LE(data, offset: 28), 16_000 * 2)
        XCTAssertEqual(Self.uint16LE(data, offset: 32), 2)
        XCTAssertEqual(Self.uint16LE(data, offset: 34), 16)
        XCTAssertEqual(Self.uint32LE(data, offset: 40), 8)

        let payload = data.dropFirst(44)
        XCTAssertEqual(payload, Self.pcm16Data(from: [0, 1_000, -1_000, Int16.max]))
    }

    private static func fourCC(_ data: Data, offset: Int) -> String {
        let bytes = data[offset..<(offset + 4)]
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func uint16LE(_ data: Data, offset: Int) -> UInt16 {
        let value = data.withUnsafeBytes { $0.load(fromByteOffset: offset, as: UInt16.self) }
        return UInt16(littleEndian: value)
    }

    private static func uint32LE(_ data: Data, offset: Int) -> UInt32 {
        let value = data.withUnsafeBytes { $0.load(fromByteOffset: offset, as: UInt32.self) }
        return UInt32(littleEndian: value)
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
}
