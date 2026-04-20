import Foundation

final class WaveFileWriter {
    private let fileHandle: FileHandle
    private let fileURL: URL
    private var dataSize: UInt32 = 0
    private var closed = false

    init(fileURL: URL) throws {
        self.fileURL = fileURL
        try Data(repeating: 0, count: 44).write(to: fileURL, options: .atomic)
        self.fileHandle = try FileHandle(forWritingTo: fileURL)
        try fileHandle.seekToEnd()
    }

    func append(samples: [Int16]) throws {
        try append(pcm16Data: pcm16Data(from: samples))
    }

    func append(pcm16Data: Data) throws {
        guard !closed else { return }
        try fileHandle.write(contentsOf: pcm16Data)
        dataSize += UInt32(pcm16Data.count)
    }

    func close() throws {
        guard !closed else { return }
        closed = true

        try writeHeader()
        try fileHandle.close()
    }

    deinit {
        if !closed {
            try? close()
        }
    }

    private func writeHeader() throws {
        let header = makeHeader(dataSize: dataSize)
        let headerData = pcmHeaderData(from: header)
        let writableHandle = try FileHandle(forWritingTo: fileURL)
        try writableHandle.write(contentsOf: headerData)
        try writableHandle.close()
    }

    private func makeHeader(dataSize: UInt32) -> WaveHeader {
        WaveHeader(
            chunkID: ("R", "I", "F", "F"),
            chunkSize: 36 + dataSize,
            format: ("W", "A", "V", "E"),
            subchunk1ID: ("f", "m", "t", " "),
            subchunk1Size: 16,
            audioFormat: 1,
            channelCount: 1,
            sampleRate: 16_000,
            byteRate: 16_000 * 2,
            blockAlign: 2,
            bitsPerSample: 16,
            subchunk2ID: ("d", "a", "t", "a"),
            subchunk2Size: dataSize
        )
    }

    private func pcm16Data(from samples: [Int16]) -> Data {
        var data = Data()
        data.reserveCapacity(samples.count * 2)

        for sample in samples {
            var littleEndian = sample.littleEndian
            withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
        }

        return data
    }

    private func pcmHeaderData(from header: WaveHeader) -> Data {
        var data = Data()
        data.reserveCapacity(44)
        appendFourCC(header.chunkID, to: &data)
        appendLE(header.chunkSize, to: &data)
        appendFourCC(header.format, to: &data)
        appendFourCC(header.subchunk1ID, to: &data)
        appendLE(header.subchunk1Size, to: &data)
        appendLE(header.audioFormat, to: &data)
        appendLE(header.channelCount, to: &data)
        appendLE(header.sampleRate, to: &data)
        appendLE(header.byteRate, to: &data)
        appendLE(header.blockAlign, to: &data)
        appendLE(header.bitsPerSample, to: &data)
        appendFourCC(header.subchunk2ID, to: &data)
        appendLE(header.subchunk2Size, to: &data)
        return data
    }

    private func appendFourCC(_ code: (Character, Character, Character, Character), to data: inout Data) {
        let string = String([code.0, code.1, code.2, code.3])
        data.append(contentsOf: string.utf8)
    }

    private func appendLE<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }
}

private struct WaveHeader {
    let chunkID: (Character, Character, Character, Character)
    let chunkSize: UInt32
    let format: (Character, Character, Character, Character)
    let subchunk1ID: (Character, Character, Character, Character)
    let subchunk1Size: UInt32
    let audioFormat: UInt16
    let channelCount: UInt16
    let sampleRate: UInt32
    let byteRate: UInt32
    let blockAlign: UInt16
    let bitsPerSample: UInt16
    let subchunk2ID: (Character, Character, Character, Character)
    let subchunk2Size: UInt32
}
