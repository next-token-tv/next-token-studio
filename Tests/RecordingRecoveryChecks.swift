import AVFoundation
import Darwin
@main struct RecordingRecoveryChecks {
    static func main() throws {
        if CommandLine.arguments.count > 1 {
            let url = URL(fileURLWithPath: CommandLine.arguments[1])
            let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channelLayout: AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | 4)!)
            let writer = try CaptureWriter(url: url, inputFormat: format, metadata: Data("{\"inputName\":\"test\"}".utf8))
            let block = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800)!
            block.frameLength = 4800
            for channel in 0..<4 { for frame in 0..<4800 { block.floatChannelData![channel][frame] = Float(channel + 1) * 0.05 } }
            for _ in 0..<70 { writer.append(block); precondition(writer.snapshot().failure == nil) }
            kill(getpid(), SIGKILL)
            return
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("interrupted.recording")
        let child = Process()
        child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        child.arguments = [original.path]
        try child.run(); child.waitUntilExit()
        precondition(child.terminationReason == .uncaughtSignal && child.terminationStatus == SIGKILL)
        let tracks = try RecordingAudioReader.sourceFiles(original)
        let damaged = try FileHandle(forWritingTo: tracks[0])
        try damaged.write(contentsOf: Data(repeating: 0, count: 56)); try damaged.close()
        let shorter = try FileHandle(forWritingTo: tracks[3])
        try shorter.truncate(atOffset: UInt64(56 + 6 * 48000 * 4)); try shorter.close()
        let originals = try tracks.map { try Data(contentsOf: $0) }
        let count = try RecordingRecovery.recover(in: root)
        precondition(count == 1)
        let recovered = root.appendingPathComponent("interrupted.recovered.recording")
        let reader = try RecordingAudioReader(forReading: recovered)
        precondition(reader.length == 240000 && reader.processingFormat.channelCount == 4)
        let block = AVAudioPCMBuffer(pcmFormat: reader.processingFormat, frameCapacity: 1024)!
        try reader.read(into: block, frameCount: 1024)
        for channel in 0..<4 { for frame in 0..<1024 { precondition(block.floatChannelData![channel][frame] == Float(channel + 1) * 0.05) } }
        for (index, track) in tracks.enumerated() { let data = try Data(contentsOf: track); precondition(data == originals[index], "Recovery must preserve originals") }
        let second = try RecordingRecovery.recover(in: root)
        precondition(second == 0)
        precondition(FileManager.default.fileExists(atPath: recovered.appendingPathExtension("json").path))
        print("PASS: SIGKILL at 7 seconds; synchronized 5-second checkpoint recovered, exact samples, original WAVs unchanged, metadata preserved, idempotent restart")
    }
}
