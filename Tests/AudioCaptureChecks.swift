import AVFoundation

@main
struct AudioCaptureChecks {
    static func main() throws {
        for rate in [44_100.0, 48_000.0] {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("m4a")
            defer { try? FileManager.default.removeItem(at: url) }
            let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
            let writer = try CaptureWriter(url: url, inputFormat: format)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4410)!
            buffer.frameLength = buffer.frameCapacity
            for channel in 0..<2 {
                for frame in 0..<Int(buffer.frameLength) {
                    buffer.floatChannelData![channel][frame] = 0.5 * sin(2 * .pi * 440 * Float(frame) / Float(rate))
                }
            }
            for _ in 0..<110 { writer.append(buffer) }
            let before = writer.snapshot()
            precondition(before.2 == nil, "Unexpected conversion/write error")
            precondition(before.1.count == 200, "Waveform history must be bounded to eight seconds")
            precondition(before.1.allSatisfy { $0 > 0.4 && $0 < 0.6 }, "Waveform must reflect captured samples")
            writer.setPaused(true)
            writer.append(buffer)
            precondition(writer.snapshot().0 == before.0, "Pause must not write audio")
            writer.setPaused(false)
            writer.append(buffer)
            let after = writer.snapshot()
            precondition(after.0 > before.0, "Resume must write audio")
            writer.close()
            let audio = try AVAudioPlayer(contentsOf: url)
            precondition(abs(audio.duration - after.0) < 0.15, "Saved duration must match captured frames")
            let file = try AVAudioFile(forReading: url)
            precondition(file.fileFormat.sampleRate == 48_000 && file.fileFormat.channelCount == 1)
            print("PASS: \(Int(rate)) Hz stereo → 48 kHz mono AAC, bounded waveform, pause/resume, saved duration")
        }
    }
}
