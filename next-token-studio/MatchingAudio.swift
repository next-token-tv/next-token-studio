@preconcurrency import AVFoundation
import Foundation

nonisolated struct MatchingUtterance: Sendable {
    let samples: [Float]
    let sampleRate: Double
    let channel: Int?
}

// Bounded memory; the recognition service is called outside the audio callback.
nonisolated final class MatchingAudio: @unchecked Sendable {
    private let lock = NSLock()
    private let rate: Double
    private let channels: Int
    private let capacity: Int
    private var samples: [[Float]]
    private var energy: [Double]
    private var peaks: [Float]
    private var frames = 0
    private var voiceFrames = 0
    private var quietFrames = 0
    private var lastInput = Date()
    private var formatChanged = false

    init(format: AVAudioFormat) {
        rate = format.sampleRate
        channels = Int(format.channelCount)
        capacity = Int(rate * 8)
        samples = Array(repeating: Array(repeating: 0, count: capacity), count: channels)
        energy = Array(repeating: 0, count: channels)
        peaks = Array(repeating: 0, count: channels)
    }

    func append(_ buffer: AVAudioPCMBuffer) -> MatchingUtterance? {
        lock.lock()
        defer { lock.unlock() }
        guard buffer.format.sampleRate == rate, Int(buffer.format.channelCount) == channels,
              buffer.format.commonFormat == .pcmFormatFloat32, !buffer.format.isInterleaved,
              let data = buffer.floatChannelData else { formatChanged = true; return nil }
        lastInput = Date()
        let count = Int(buffer.frameLength)
        guard count > 0 else { return nil }
        var powers = [Double](repeating: 0, count: channels)
        for channel in 0..<channels {
            var peak: Float = 0
            for frame in 0..<count {
                let value = data[channel][frame]
                peak = max(peak, abs(value))
                powers[channel] += Double(value) * Double(value)
            }
            peaks[channel] = peak
        }
        let voiced = powers.contains { sqrt($0 / Double(count)) >= 0.006 }
        guard frames > 0 || voiced else { return nil }
        let copied = min(count, capacity - frames)
        for channel in 0..<channels {
            for frame in 0..<copied { samples[channel][frames + frame] = data[channel][frame] }
            energy[channel] += powers[channel]
        }
        frames += copied
        if voiced { voiceFrames += copied; quietFrames = 0 } else { quietFrames += copied }
        guard quietFrames >= Int(rate * 0.65) || frames == capacity else { return nil }
        defer { frames = 0; voiceFrames = 0; quietFrames = 0; energy = Array(repeating: 0, count: channels) }
        guard voiceFrames >= Int(rate * 0.2) else { return nil }
        let ranked = energy.indices.sorted { energy[$0] > energy[$1] }
        let strongest = ranked[0]
        // Require at least 6 dB separation from the next microphone to reject crosstalk.
        let clear = channels == 1 || energy[strongest] >= energy[ranked[1]] * 4
        return MatchingUtterance(samples: clear ? Array(samples[strongest].prefix(frames)) : [], sampleRate: rate, channel: clear ? strongest : nil)
    }

    func snapshot() -> (peaks: [Float], lastInput: Date, formatChanged: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (peaks, lastInput, formatChanged)
    }
}
