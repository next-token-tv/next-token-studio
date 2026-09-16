import AVFoundation

@main
struct AudioCaptureChecks {
    static func main() throws {
        for channelCount in [1, 4, 5] {
            for rate in [44_100.0, 48_000.0] {
                let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("caf")
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
                    precondition(before.waveforms[channel].count == 200)
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
                    let preview = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("caf")
                    defer { try? FileManager.default.removeItem(at: preview) }
                    try ChannelPreview.render(source: url, channel: channel, destination: preview)
                    let solo = try AVAudioFile(forReading: preview)
                    precondition(solo.processingFormat.channelCount == 1)
                    precondition(solo.length == file.length)
                    let data = AVAudioPCMBuffer(pcmFormat: solo.processingFormat, frameCapacity: 512)!
                    try solo.read(into: data)
                    precondition(data.floatChannelData![0][0] == values[channel], "Solo must read the selected channel")
                }
                print("PASS: \(channelCount) channels @ \(Int(rate)) Hz; independent waveform, silent channel, pause/resume, lossless file, solo playback source")
            }
        }
    }
}
