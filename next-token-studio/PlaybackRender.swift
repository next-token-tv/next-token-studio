@preconcurrency import AVFoundation
import CryptoKit

nonisolated struct PlaybackOverview: Sendable, Codable {
    let waveforms: [[Float]]
    let channelPeaks: [Float]
    let duration: TimeInterval
    let sampleRate: Double
    let mixGain: Float
}

nonisolated enum PlaybackRender {
    private struct CacheEntry: Codable {
        let signature: String
        let overview: PlaybackOverview
    }

    private static func cacheDirectory(source: URL, cache: URL) -> URL {
        let hash = SHA256.hash(data: Data(source.standardizedFileURL.path.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return cache.appendingPathComponent("waveforms-v2-" + hash, isDirectory: true)
    }

    private static func signature(_ source: URL) throws -> String {
        try RecordingAudioReader.sourceFiles(source).map { url in
            let values = try FileManager.default.attributesOfItem(atPath: url.path)
            guard let size = values[.size] as? NSNumber, let date = values[.modificationDate] as? Date else { throw readError() }
            return "\(url.lastPathComponent):\(size)-\(date.timeIntervalSince1970)"
        }.joined(separator: "|")
    }

    static func removeCache(source: URL, cache: URL) {
        try? FileManager.default.removeItem(at: cacheDirectory(source: source, cache: cache))
    }

    static func cached(source: URL, cache: URL) throws -> PlaybackOverview {
        let manager = FileManager.default
        let folder = cacheDirectory(source: source, cache: cache)
        let stamp = try signature(source)
        let index = folder.appendingPathComponent("waveforms.plist")
        if let data = try? Data(contentsOf: index),
           let entry = try? PropertyListDecoder().decode(CacheEntry.self, from: data),
           entry.signature == stamp, entry.overview.duration > 0,
           !entry.overview.waveforms.isEmpty,
           entry.overview.waveforms.count == entry.overview.channelPeaks.count,
           entry.overview.waveforms.allSatisfy({ !$0.isEmpty && $0.count <= 1600 && $0.allSatisfy { $0.isFinite } }) {
            return entry.overview
        }
        let overview = try analyze(source: source)
        try Task.checkCancellation()
        guard try signature(source) == stamp else { throw readError() }
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        try encoder.encode(CacheEntry(signature: stamp, overview: overview)).write(to: index, options: .atomic)
        return overview
    }

    // Sum discrete microphone inputs explicitly, including channels labelled as surround/LFE.
    // A single gain for the whole file prevents clipping without changing relative channel levels.
    static func analyze(source: URL) throws -> PlaybackOverview {
        let input = try RecordingAudioReader(forReading: source)
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
        return PlaybackOverview(waveforms: waveforms, channelPeaks: peaks, duration: Double(length) / format.sampleRate, sampleRate: format.sampleRate, mixGain: gain)
    }

    // File rendering is reserved for explicit export.
    static func prepare(source: URL, destination: URL) throws -> PlaybackOverview {
        let overview = try analyze(source: source)
        let reader = try RecordingAudioReader(forReading: source)
        let format = reader.processingFormat
        let channels = Int(format.channelCount)
        let length = reader.length
        let gain = overview.mixGain
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192)!
        let monoFormat = AVAudioFormat(standardFormatWithSampleRate: format.sampleRate, channels: 1)!
        let output = try AVAudioFile(forWriting: destination, settings: monoFormat.settings)
        let mono = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: 8192)!
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
        return overview
    }

    private static func readError() -> NSError {
        NSError(domain: "AudioStudio", code: 5, userInfo: [NSLocalizedDescriptionKey: "音频文件未能完整读取。"])
    }
}
