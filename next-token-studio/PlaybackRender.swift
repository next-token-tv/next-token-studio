@preconcurrency import AVFoundation

nonisolated struct PlaybackOverview: Sendable {
    let waveforms: [[Float]]
    let channelPeaks: [Float]
    let duration: TimeInterval
    let sampleRate: Double
    let mixGain: Float
}

nonisolated enum PlaybackRender {
    // Sum discrete microphone inputs explicitly, including channels labelled as surround/LFE.
    // A single gain for the whole file prevents clipping without changing relative channel levels.
    static func prepare(source: URL, destination: URL) throws -> PlaybackOverview {
        let input = try AVAudioFile(forReading: source)
        let format = input.processingFormat
        let channels = Int(format.channelCount)
        let length = input.length
        guard length > 0, channels > 0, format.sampleRate > 0 else {
            throw NSError(domain: "AudioStudio", code: 4, userInfo: [NSLocalizedDescriptionKey: "这段录音没有音频数据。"])
        }
        let binCount = min(1600, max(1, Int((length + 255) / 256)))
        var waveforms = Array(repeating: [Float](repeating: 0, count: binCount), count: channels)
        var peaks = [Float](repeating: 0, count: channels)
        var mixPeak: Float = 0
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192)!
        var position: AVAudioFramePosition = 0
        while position < length {
            try Task.checkCancellation()
            try input.read(into: buffer, frameCount: AVAudioFrameCount(min(length - position, 8192)))
            guard buffer.frameLength > 0 else { throw readError() }
            let samples = buffer.floatChannelData!
            for frame in 0..<Int(buffer.frameLength) {
                let bin = min(binCount - 1, Int((position + Int64(frame)) * Int64(binCount) / length))
                var sum: Float = 0
                for channel in 0..<channels {
                    let value = samples[channel][frame].isFinite ? samples[channel][frame] : 0
                    let peak = abs(value)
                    waveforms[channel][bin] = max(waveforms[channel][bin], peak)
                    peaks[channel] = max(peaks[channel], peak)
                    sum += value
                }
                mixPeak = max(mixPeak, abs(sum))
            }
            position += Int64(buffer.frameLength)
        }
        let gain: Float = mixPeak > 0.98 ? 0.98 / mixPeak : 1
        let monoFormat = AVAudioFormat(standardFormatWithSampleRate: format.sampleRate, channels: 1)!
        let output = try AVAudioFile(forWriting: destination, settings: monoFormat.settings)
        let mono = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: 8192)!
        let reader = try AVAudioFile(forReading: source)
        var remaining = length
        while remaining > 0 {
            try Task.checkCancellation()
            try reader.read(into: buffer, frameCount: AVAudioFrameCount(min(remaining, 8192)))
            guard buffer.frameLength > 0 else { throw readError() }
            mono.frameLength = buffer.frameLength
            for frame in 0..<Int(buffer.frameLength) {
                var sum: Float = 0
                for channel in 0..<channels {
                    let value = buffer.floatChannelData![channel][frame]
                    if value.isFinite { sum += value }
                }
                mono.floatChannelData![0][frame] = sum * gain
            }
            try output.write(from: mono)
            remaining -= Int64(buffer.frameLength)
        }
        return PlaybackOverview(waveforms: waveforms, channelPeaks: peaks, duration: Double(length) / format.sampleRate, sampleRate: format.sampleRate, mixGain: gain)
    }

    private static func readError() -> NSError {
        NSError(domain: "AudioStudio", code: 5, userInfo: [NSLocalizedDescriptionKey: "音频文件未能完整读取。"])
    }
}
