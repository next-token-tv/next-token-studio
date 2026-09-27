import AVFoundation

// Accelerated file-volume test, not a wall-clock hardware soak test.
@main struct LongRecordingChecks {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channelLayout: AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | 5)!)
        let seconds = 10800
        let required = Int64(seconds) * 48000 * 5 * 4 + 5_000_000_000
        let disk = try FileManager.default.attributesOfFileSystem(forPath: root.path)
        guard (disk[.systemFreeSize] as? NSNumber)?.int64Value ?? 0 > required else { throw CocoaError(.fileWriteOutOfSpace) }
        let url = root.appendingPathComponent("three-hours.recording")
        // A smaller segment limit also exercises rollover repeatedly.
        let writer = try CaptureWriter(url: url, inputFormat: format, maximumSegmentBytes: 200_000_000)
        let block = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48000)!
        block.frameLength = 48000
        for c in 0..<5 { for f in 0..<48000 { block.floatChannelData![c][f] = Float((f % 997) - 498) * Float(c + 1) / 4096 } }
        let start = Date()
        for second in 0..<seconds {
            writer.append(block); writer.flush()
            precondition(writer.snapshot().failure == nil)
            if second % 1800 == 0 { print("Written \(second / 60) minutes of audio"); fflush(stdout) }
        }
        writer.close()
        var total: Int64 = 0
        for segment in writer.outputURLs {
            let tracks = try RecordingAudioReader.sourceFiles(segment)
            var segmentLength: Int64 = 0
            for (channel, track) in tracks.enumerated() {
                let file = try AVAudioFile(forReading: track)
                precondition(file.processingFormat.channelCount == 1 && file.processingFormat.sampleRate == 48000)
                segmentLength = file.length
                let read = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 65536)!
                var offset: Int64 = 0
                while offset < file.length {
                    try file.read(into: read)
                    precondition(read.frameLength > 0)
                    for f in 0..<Int(read.frameLength) {
                        let sourceFrame = Int((total + offset + Int64(f)) % 48000)
                        let expected = Float((sourceFrame % 997) - 498) * Float(channel + 1) / 4096
                        precondition(read.floatChannelData![0][f] == expected)
                    }
                    offset += Int64(read.frameLength)
                }
                precondition(RecordingRecovery.state(in: segment)?.safeFrames == file.length)
            }
            total += segmentLength
        }
        precondition(total == Int64(seconds * 48000))
        print("PASS: 3 hours × 5 tracks × 48 kHz; 10.368 GB written; every sample verified across \(writer.outputURLs.count) segments in \(Int(Date().timeIntervalSince(start))) wall-clock seconds")
    }
}
