import Foundation

enum SignalLevelTracker {
    static func normalizedLevel(from pcm16Data: Data) -> Double {
        guard !pcm16Data.isEmpty else { return 0 }

        let peak = pcm16Data.withUnsafeBytes { rawBuffer -> Double in
            let words = rawBuffer.bindMemory(to: Int16.self)
            guard !words.isEmpty else { return 0 }
            let maxMagnitude = words.reduce(Int16.zero) { current, sample in
                let magnitude = sample == Int16.min ? Int16.max : Int16(sample.magnitude)
                return max(current, magnitude)
            }
            return Double(maxMagnitude) / Double(Int16.max)
        }

        return min(max(peak, 0), 1)
    }
}
