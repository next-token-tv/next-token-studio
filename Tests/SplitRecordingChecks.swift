import AVFoundation
@main struct SplitRecordingChecks {
    static func main() throws {
        for channels in [1, 4, 5] {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".recording")
            let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channelLayout: AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | UInt32(channels))!)
            let writer = try CaptureWriter(url: folder, inputFormat: format, maximumSegmentBytes: 4000)
            let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1301)!
            input.frameLength = 1301
            for ch in 0..<channels { for i in 0..<1301 { input.floatChannelData![ch][i] = Float(ch + 1) * Float(i % 50) / 1000 } }
            writer.append(input)
            writer.setPaused(true); writer.append(input); writer.setPaused(false)
            writer.close()
            let segments = writer.outputURLs
            defer { for segment in segments { try? FileManager.default.removeItem(at: segment) } }
            precondition(segments.count == 2 && drainedSnapshot(writer).failure == nil)
            var offset = 0
            for segment in segments {
                let tracks = try RecordingAudioReader.sourceFiles(segment)
                precondition(tracks.count == channels)
                for track in tracks { let file = try AVAudioFile(forReading: track); precondition(file.processingFormat.channelCount == 1) }
                let reader = try RecordingAudioReader(forReading: segment)
                let buffer = AVAudioPCMBuffer(pcmFormat: reader.processingFormat, frameCapacity: 1301)!
                try reader.read(into: buffer, frameCount: 1301)
                for ch in 0..<channels { for i in 0..<Int(buffer.frameLength) { precondition(buffer.floatChannelData![ch][i] == input.floatChannelData![ch][offset + i]) } }
                offset += Int(buffer.frameLength)
                let overview = try PlaybackRender.analyze(source: segment)
                precondition(overview.waveforms.count == channels)
                reader.framePosition = 50
                try reader.read(into: buffer, frameCount: 10)
                precondition(buffer.frameLength == 10)
            }
            precondition(offset == 1301)
            let export = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
            defer { try? FileManager.default.removeItem(at: export) }
            try AudioExport.mixedM4A(source: segments[0], destination: export)
            let file = try AVAudioFile(forReading: export)
            precondition(file.processingFormat.channelCount == 2)
            let missing = try RecordingAudioReader.sourceFiles(segments[0]).last!
            try FileManager.default.removeItem(at: missing)
            do { _ = try RecordingAudioReader(forReading: segments[0]); preconditionFailure("Missing tracks must fail") } catch {}
            print("PASS: \(channels) separate WAVs, exact synchronized samples, pause, rollover, read/seek, overview, M4A export, missing track detection")
        }
        precondition(WaveformAmplitude.height(for: 0) == 0)
        precondition(WaveformAmplitude.height(for: .nan) == 0)
        precondition(WaveformAmplitude.height(for: 0.1) / WaveformAmplitude.height(for: 0.01) > 5.6)
        print("PASS: shared amplitude curve preserves clear strong/weak distinction")
    }
}

private func drainedSnapshot(_ writer: CaptureWriter) -> CaptureSnapshot { writer.flush(); return writer.snapshot() }
