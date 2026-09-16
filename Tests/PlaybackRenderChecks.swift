import AVFoundation

@main
struct PlaybackRenderChecks {
    static func main() throws {
        for channels in [1, 4, 5] {
            let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".caf")
            let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".caf")
            defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: destination) }
            let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | UInt32(channels))!
            let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channelLayout: layout)
            let length = (channels + 2) * 1024 + 17
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(length))!
            buffer.frameLength = buffer.frameCapacity
            for channel in 0..<channels {
                for frame in 0..<length {
                    let region = frame / 1024
                    let value: Float = region == channel ? Float(channel + 1) * 0.1 : (region == channels ? 0.8 : 0)
                    buffer.floatChannelData![channel][frame] = value
                }
            }
            do {
                var settings = format.settings
                settings[AVLinearPCMIsNonInterleaved] = false
                let file = try AVAudioFile(forWriting: source, settings: settings)
                try file.write(from: buffer)
            }
            let original = try Data(contentsOf: source)
            let overview = try PlaybackRender.prepare(source: source, destination: destination)
            precondition(overview.waveforms.count == channels)
            precondition(overview.waveforms.allSatisfy { $0.count <= 1600 })
            precondition(overview.channelPeaks.allSatisfy { abs($0 - 0.8) < 0.000001 })
            precondition(abs(overview.duration - Double(length) / 48_000) < 0.000001)
            let mix = try AVAudioFile(forReading: destination)
            precondition(mix.length == length && mix.processingFormat.channelCount == 1)
            let audio = AVAudioPCMBuffer(pcmFormat: mix.processingFormat, frameCapacity: AVAudioFrameCount(length))!
            try mix.read(into: audio, frameCount: AVAudioFrameCount(length))
            for frame in 0..<length {
                let sum = (0..<channels).reduce(Float(0)) { $0 + buffer.floatChannelData![$1][frame] }
                let expected = sum * min(1, 0.98 / (Float(channels) * 0.8))
                precondition(abs(audio.floatChannelData![0][frame] - expected) < 0.000001, "Every input channel must be audible in the mix, including the last channel")
                precondition(abs(audio.floatChannelData![0][frame]) <= 0.981, "Mix must not clip")
            }
            for channel in 0..<channels {
                let bin = (channel * 1024 + 512) * overview.waveforms[channel].count / length
                precondition(abs(overview.waveforms[channel][bin] - Float(channel + 1) * 0.1) < 0.000001, "Waveform must align with source time and channel")
                precondition(overview.waveforms[channel].last == 0, "Silent tail must stay silent")
            }
            let unchanged = try Data(contentsOf: source)
            precondition(unchanged == original, "Mixing must not modify the source")
            print("PASS: \(channels) channels; full mix, clipping protection, aligned per-channel waveform, exact duration, unchanged source")
        }
    }
}
