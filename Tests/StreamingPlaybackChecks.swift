import AVFoundation
@main struct StreamingPlaybackChecks {
    static func main() throws {
        for channels in [1, 4, 5] {
            let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
            defer { try? FileManager.default.removeItem(at: source) }
            let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channelLayout: AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | UInt32(channels))!)
            do {
                var settings = format.settings
                settings[AVLinearPCMIsNonInterleaved] = false
                let file = try AVAudioFile(forWriting: source, settings: settings)
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48000)!
                buffer.frameLength = 48000
                for channel in 0..<channels { for frame in 0..<48000 { buffer.floatChannelData![channel][frame] = Float(channel + 1) * 0.03 } }
                try file.write(from: buffer)
            }
            let engine = AVAudioEngine()
            let mono = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
            try engine.enableManualRenderingMode(.offline, format: mono, maximumFrameCount: 1024)
            let player = try StreamingPlayback(source: source, gain: 0.5, engine: engine)
            precondition(player.play())
            let buffer = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: 1024)!
            var total = 0
            while total < 45000 {
                let status = try engine.renderOffline(1024, to: buffer)
                if status == .success {
                    let expected = Float(channels * (channels + 1) / 2) * 0.03 * 0.5
                    for frame in 0..<Int(buffer.frameLength) { precondition(abs(buffer.floatChannelData![0][frame] - expected) < 0.00001, "channel count \(channels), frame \(total + frame), got \(buffer.floatChannelData![0][frame]), expected \(expected)") }
                    total += Int(buffer.frameLength)
                }
                // Synchronize the producer between offline render blocks.
                Thread.sleep(forTimeInterval: 0.001)
                _ = player.playbackError
            }
            let beforePause = player.currentTime
            player.pause()
            precondition(abs(player.currentTime - beforePause) < 0.03, "Pause must preserve position")
            player.currentTime = 0.5
            precondition(abs(player.currentTime - 0.5) < 0.03)
            precondition(player.play())
            player.stop()
            print("PASS: \(channels)-channel streaming mix, bounded refill, seek and transport")
        }
    }
}
