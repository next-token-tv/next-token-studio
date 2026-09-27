import AVFoundation

@main struct CaptureResilienceChecks {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channelLayout: AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | 5)!)
        let block = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2048)!
        block.frameLength = 2048
        for c in 0..<5 { for f in 0..<2048 { block.floatChannelData![c][f] = Float(c + 1) / 10 } }
        // Hold the consumer: snapshots must return while disk I/O is blocked.
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let url = root.appendingPathComponent("overflow.recording")
        let writer = try CaptureWriter(url: url, inputFormat: format, bufferSeconds: 0.08, beforeWrite: {
            entered.signal(); release.wait()
        })
        writer.append(block)
        precondition(entered.wait(timeout: .now() + 2) == .success)
        writer.append(block)
        let start = Date()
        precondition(writer.snapshot().queuedSeconds > 0.08)
        precondition(Date().timeIntervalSince(start) < 0.1)
        writer.append(block)
        precondition(writer.snapshot().failure != nil)
        release.signal(); release.signal(); writer.close()
        precondition(RecordingRecovery.state(in: url)?.status == "interrupted")
        precondition(RecordingRecovery.state(in: url)?.safeFrames == 4096)
        precondition(tryRecover(root) == 1)
        let reader = try RecordingAudioReader(forReading: root.appendingPathComponent("overflow.recovered.recording"))
        precondition(reader.length == 4096)
        let output = AVAudioPCMBuffer(pcmFormat: reader.processingFormat, frameCapacity: 4096)!
        try reader.read(into: output, frameCount: 4096)
        for c in 0..<5 { for f in 0..<4096 { precondition(output.floatChannelData![c][f] == Float(c + 1) / 10) } }
        print("PASS: stalled writer leaves UI responsive; overflow marked interrupted; all accepted samples recover exactly")

        let slowURL = root.appendingPathComponent("slow.recording")
        let slow = try CaptureWriter(url: slowURL, inputFormat: format, beforeWrite: { Thread.sleep(forTimeInterval: 0.003) })
        for _ in 0..<180 { slow.append(block) }
        precondition(slow.snapshot().failure == nil)
        slow.close()
        let slowReader = try RecordingAudioReader(forReading: slowURL)
        precondition(slowReader.length == 180 * 2048)
        precondition(RecordingRecovery.state(in: slowURL)?.status == "complete")
        print("PASS: 7.68-second producer burst drains through slow disk without dropping frames")

        let failedURL = root.appendingPathComponent("failed.recording")
        let failed = try CaptureWriter(url: failedURL, inputFormat: format, beforeWrite: { throw CocoaError(.fileWriteOutOfSpace) })
        failed.append(block); failed.flush()
        precondition(failed.snapshot().failure != nil)
        failed.close()
        precondition(RecordingRecovery.state(in: failedURL)?.status == "interrupted")
        print("PASS: injected disk-full write error cannot produce a complete recording")

        let disconnectedURL = root.appendingPathComponent("disconnected.recording")
        let disconnected = try CaptureWriter(url: disconnectedURL, inputFormat: format)
        disconnected.append(block)
        disconnected.markInterrupted("Device disconnected")
        disconnected.append(block)
        disconnected.close()
        precondition(RecordingRecovery.state(in: disconnectedURL)?.status == "interrupted")
        precondition(RecordingRecovery.state(in: disconnectedURL)?.safeFrames == 2048)
        precondition(tryRecover(root) == 1)
        print("PASS: device interruption drains accepted audio and rejects subsequent input")

        // Corrupt the first directory; a subsequent valid interrupted session must still recover.
        let bad = root.appendingPathComponent("aaa-broken.recording")
        try FileManager.default.createDirectory(at: bad, withIntermediateDirectories: false)
        try Data("invalid".utf8).write(to: bad.appendingPathComponent("recovery.json"))
        let fallback = root.appendingPathComponent("zzz-fallback.recording")
        try FileManager.default.copyItem(at: slowURL, to: fallback)
        try Data("invalid".utf8).write(to: fallback.appendingPathComponent("recovery.json"))
        let report = try RecordingRecovery.recoverReport(in: root)
        precondition(report.recovered == 1 && report.issues.count == 2)
        let recovered = try RecordingAudioReader(forReading: root.appendingPathComponent("zzz-fallback.recovered.recording"))
        precondition(recovered.length == 180 * 2048)
        let repeated = try RecordingRecovery.recoverReport(in: root)
        precondition(repeated.recovered == 0 && repeated.issues.count == 2)
        print("PASS: corrupt journal fallback; bad sessions isolated; retry remains idempotent")
    }
    static func tryRecover(_ root: URL) -> Int { try! RecordingRecovery.recover(in: root) }
}
