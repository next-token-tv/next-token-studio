import AVFoundation

@main
struct AudioCaptureChecks {
    static func main() throws {
        let splitURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        let splitFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channelLayout: AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | 5)!)
        let splitWriter = try CaptureWriter(url: splitURL, inputFormat: splitFormat, maximumSegmentBytes: 2000)
        let input = AVAudioPCMBuffer(pcmFormat: splitFormat, frameCapacity: 257)!
        input.frameLength = 257
        for channel in 0..<5 { for frame in 0..<257 { input.floatChannelData![channel][frame] = Float(channel * 300 + frame) / 2000 } }
        splitWriter.append(input)
        splitWriter.close()
        let segments = splitWriter.outputURLs
        defer { for url in segments { try? FileManager.default.removeItem(at: url) } }
        precondition(segments.count == 3 && splitWriter.snapshot().failure == nil)
        var position = 0
        for url in segments {
            let file = try AVAudioFile(forReading: url)
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 257)!
            try file.read(into: buffer)
            for frame in 0..<Int(buffer.frameLength) {
                for channel in 0..<5 { precondition(buffer.floatChannelData![channel][frame] == input.floatChannelData![channel][position + frame]) }
            }
            position += Int(buffer.frameLength)
        }
        precondition(position == 257, "WAV rollover must not lose or duplicate any sample")
        print("PASS: WAV rollover preserves every sample across callback boundaries")
        // Alternating 10 ms pulses must remain distinct across callback boundaries and ring wrap.
        for rate in [44_100.0, 48_000.0] {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
            defer { try? FileManager.default.removeItem(at: url) }
            let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
            let writer = try CaptureWriter(url: url, inputFormat: format)
            let bin = Int(rate * 0.01)
            let total = bin * 825
            var offset = 0
            while offset < total {
                let count = min(1024, total - offset)
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
                buffer.frameLength = AVAudioFrameCount(count)
                for i in 0..<count {
                    buffer.floatChannelData![0][i] = (offset + i) / bin % 2 == 0 ? 0.1 : 0.01
                }
                writer.append(buffer)
                offset += count
            }
            let waveform = writer.snapshot().waveforms[0]
            precondition(waveform.count == 800)
            for i in waveform.indices {
                let expected: Float = (i + 25) % 2 == 0 ? 0.1 : 0.01
                precondition(waveform[i] == expected, "10 ms detail and chronological order must survive ring wrap")
            }
            writer.close()
            print("PASS: 10 ms detail and ring wrap @ \(Int(rate)) Hz")
        }
        for channelCount in [1, 4, 5] {
            for rate in [44_100.0, 48_000.0] {
                let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("wav")
                defer { try? FileManager.default.removeItem(at: url) }
                let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | UInt32(channelCount))!
                let format = AVAudioFormat(standardFormatWithSampleRate: rate, channelLayout: layout)
                let writer = try CaptureWriter(url: url, inputFormat: format)
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(rate * 0.1))!
                buffer.frameLength = buffer.frameCapacity
                // Opposite signs on adjacent channels detect accidental cancellation/downmixing.
                let values: [Float] = [0.1, -0.2, 0, 0.4, -0.5]
                for channel in 0..<channelCount {
                    for frame in 0..<Int(buffer.frameLength) { buffer.floatChannelData![channel][frame] = values[channel] }
                }
                for _ in 0..<85 { writer.append(buffer) }
                let before = writer.snapshot()
                precondition(before.failure == nil)
                precondition(before.waveforms.count == channelCount)
                for channel in 0..<channelCount {
                    precondition(before.waveforms[channel].count == 800)
                    precondition(before.waveforms[channel].allSatisfy { abs($0 - abs(values[channel])) < 0.000001 })
                }
                writer.setPaused(true)
                writer.append(buffer)
                precondition(writer.snapshot().elapsed == before.elapsed)
                writer.setPaused(false)
                writer.append(buffer)
                let after = writer.snapshot()
                precondition(after.elapsed > before.elapsed)
                writer.close()
                let file = try AVAudioFile(forReading: url)
                precondition(file.fileFormat.sampleRate == rate && file.fileFormat.channelCount == channelCount)
                precondition(abs(Double(file.length) / rate - after.elapsed) < 0.0001)
                let saved = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 512)!
                try file.read(into: saved)
                for channel in 0..<channelCount {
                    for frame in 0..<Int(saved.frameLength) {
                        precondition(saved.floatChannelData![channel][frame] == values[channel], "Saved samples must preserve all channels exactly")
                    }
                }

                print("PASS: \(channelCount) channels @ \(Int(rate)) Hz; independent waveform, silent channel, pause/resume, lossless file")
            }
        }
    }
}
