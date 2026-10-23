import AVFoundation

// Export-only dialogue leveling. Gated RMS is not an EBU/BS.1770 LUFS measurement.
nonisolated enum ExportMix {
    static func render(source: URL, destination: URL) throws {
        let reader = try RecordingAudioReader(forReading: source)
        let rate = reader.processingFormat.sampleRate
        let channels = Int(reader.processingFormat.channelCount)
        guard reader.length > 0, rate > 0, channels > 0 else { throw CocoaError(.fileReadCorruptFile) }
        let buffer = AVAudioPCMBuffer(pcmFormat: reader.processingFormat, frameCapacity: 8192)!
        let window = max(1, Int(rate * 0.4))
        var energies: [(Double, Int)] = []
        var energy = 0.0, count = 0
        func mixed(_ frame: Int) -> Float {
            var sum: Float = 0
            for c in 0..<channels {
                let value = buffer.floatChannelData![c][frame]
                if value.isFinite { sum += value }
            }
            return sum.isFinite ? sum : 0
        }
        while reader.framePosition < reader.length {
            try Task.checkCancellation()
            try reader.read(into: buffer, frameCount: 8192)
            guard buffer.frameLength > 0 else { throw CocoaError(.fileReadCorruptFile) }
            for f in 0..<Int(buffer.frameLength) {
                let value = Double(mixed(f)); energy += value * value; count += 1
                if count == window { energies.append((energy, count)); energy = 0; count = 0 }
            }
        }
        if count > 0 { energies.append((energy, count)) }
        let absolute = energies.filter { $0.0 / Double($0.1) > 1e-6 }
        let average = absolute.reduce(0) { $0 + $1.0 } / Double(max(1, absolute.reduce(0) { $0 + $1.1 }))
        let active = absolute.filter { $0.0 / Double($0.1) >= average * 0.01 }
        let rms = sqrt(active.reduce(0) { $0 + $1.0 } / Double(max(1, active.reduce(0) { $0 + $1.1 })))
        // -19 dBFS active mono RMS; limit noise amplification to +12 dB.
        let gain = rms > 0 ? Float(min(pow(10, 12.0 / 20), pow(10, -19.0 / 20) / rms)) : 1
        let mono = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        let output = try AVAudioFile(forWriting: destination, settings: mono.settings)
        let rendered = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: 8192)!
        var limiter = LookaheadLimiter(sampleRate: rate)
        var outputCount = 0
        func emit(_ sample: Float?) throws {
            guard let sample else { return }
            rendered.floatChannelData![0][outputCount] = sample
            outputCount += 1
            if outputCount == 8192 {
                rendered.frameLength = 8192; try output.write(from: rendered); outputCount = 0
            }
        }
        reader.framePosition = 0
        while reader.framePosition < reader.length {
            try Task.checkCancellation()
            try reader.read(into: buffer, frameCount: 8192)
            guard buffer.frameLength > 0 else { throw CocoaError(.fileReadCorruptFile) }
            for f in 0..<Int(buffer.frameLength) { try emit(limiter.process(mixed(f) * gain)) }
        }
        for _ in 0..<limiter.delay { try emit(limiter.process(0)) }
        if outputCount > 0 { rendered.frameLength = AVAudioFrameCount(outputCount); try output.write(from: rendered) }
    }
}

// A monotonic peak queue bounds memory and work regardless of recording length.
nonisolated struct LookaheadLimiter {
    let delay: Int
    private let ceiling: Float = 0.7943282 // -2 dBFS, leaving headroom for AAC reconstruction.
    private let release: Float
    private var samples: [Float]
    private var positions: [Int]
    private var values: [Float]
    private var head = 0, tail = 0, index = 0
    private var gain: Float = 1
    init(sampleRate: Double) {
        delay = max(1, Int(sampleRate * 0.005))
        release = Float(exp(-1 / (sampleRate * 0.1)))
        samples = Array(repeating: 0, count: delay + 1)
        positions = Array(repeating: 0, count: delay + 2)
        values = Array(repeating: 0, count: delay + 2)
    }
    mutating func process(_ input: Float) -> Float? {
        let size = values.count
        let sample = input.isFinite ? input : 0
        samples[index % samples.count] = sample
        while head != tail && positions[head] < index - delay { head = (head + 1) % size }
        while head != tail {
            let previous = (tail + size - 1) % size
            if values[previous] > abs(sample) { break }
            tail = previous
        }
        positions[tail] = index; values[tail] = abs(sample); tail = (tail + 1) % size
        let required = min(1, ceiling / max(ceiling, values[head]))
        gain = min(required, 1 - (1 - gain) * release)
        defer { index += 1 }
        guard index >= delay else { return nil }
        return samples[(index - delay) % samples.count] * gain
    }
}
