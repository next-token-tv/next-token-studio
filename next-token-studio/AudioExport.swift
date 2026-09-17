@preconcurrency import AVFoundation
import Foundation

nonisolated enum AudioExport {
    struct Channel: Codable {
        let file: String
        let channel: Int
        let inputName: String
    }
    struct Manifest: Codable {
        let sourceFile: String
        let sourceTimeline: String
        let sampleRate: Double
        let frames: Int64
        let channels: [Channel]
    }

    static func splitWAV(source: URL, names: [String], destination: URL) throws {
        let manager = FileManager.default
        guard !manager.fileExists(atPath: destination.path) else { throw failure("目标文件夹已存在，请选择一个新名称。") }
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".wav-export-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: staging) }
        let manifest = try writeTracks(source: source, names: names, directory: staging)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: staging.appendingPathComponent("channels.json"))
        try Task.checkCancellation()
        try manager.moveItem(at: staging, to: destination)
    }

    private static func writeTracks(source: URL, names: [String], directory: URL) throws -> Manifest {
        let input = try AVAudioFile(forReading: source)
        let format = input.processingFormat
        let count = Int(format.channelCount)
        guard input.length > 0, count > 0 else { throw failure("这段录音没有音频数据。") }
        guard input.length < (Int64(UInt32.max) - 4096) / 4 else {
            throw failure("单路音频超过普通 WAV 的 4 GB 上限，请先将录音分段。")
        }
        let mono = AVAudioFormat(standardFormatWithSampleRate: format.sampleRate, channels: 1)!
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let channels = (0..<count).map { channel in
            Channel(file: String(format: "host-ch%02d.wav", channel + 1), channel: channel + 1,
                    inputName: names.indices.contains(channel) ? names[channel] : "Input \(channel + 1)")
        }
        let outputs = try channels.map { try AVAudioFile(forWriting: directory.appendingPathComponent($0.file), settings: settings) }
        let inputBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192)!
        let channelBuffer = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: 8192)!
        let length = input.length
        var remaining = length
        while remaining > 0 {
            try Task.checkCancellation()
            try input.read(into: inputBuffer, frameCount: AVAudioFrameCount(min(remaining, 8192)))
            guard inputBuffer.frameLength > 0 else { throw failure("录音未能完整读取。") }
            channelBuffer.frameLength = inputBuffer.frameLength
            for channel in 0..<count {
                channelBuffer.floatChannelData![0].update(from: inputBuffer.floatChannelData![channel], count: Int(inputBuffer.frameLength))
                try outputs[channel].write(from: channelBuffer)
            }
            remaining -= Int64(inputBuffer.frameLength)
        }
        return Manifest(sourceFile: source.lastPathComponent, sourceTimeline: "recording", sampleRate: format.sampleRate, frames: length, channels: channels)
    }

    static func mixedM4A(source: URL, destination: URL, replaceExisting: Bool = false, temporaryDirectory: URL = FileManager.default.temporaryDirectory) throws {
        let manager = FileManager.default
        guard source.resolvingSymlinksInPath().standardizedFileURL != destination.resolvingSymlinksInPath().standardizedFileURL else {
            throw failure("导出文件不能覆盖原始录音。")
        }
        guard replaceExisting || !manager.fileExists(atPath: destination.path) else { throw failure("目标文件已存在，请选择一个新名称。") }
        let workspace = temporaryDirectory.appendingPathComponent("m4a-export-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: workspace, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: workspace) }
        let mixed = workspace.appendingPathComponent("mix.caf")
        _ = try PlaybackRender.prepare(source: source, destination: mixed)
        let encoded = workspace.appendingPathComponent("mix.m4a")
        try encodeAAC(source: mixed, destination: encoded)
        try Task.checkCancellation()
        // The save panel authorizes replacement; stage on the destination volume before committing.
        let replacement = try manager.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: destination, create: true)
        defer { try? manager.removeItem(at: replacement) }
        let staged = replacement.appendingPathComponent("mix.m4a")
        try manager.copyItem(at: encoded, to: staged)
        try Task.checkCancellation()
        if manager.fileExists(atPath: destination.path) {
            guard replaceExisting else { throw failure("目标文件已存在，请选择一个新名称。") }
            _ = try manager.replaceItemAt(destination, withItemAt: staged)
        } else { try manager.moveItem(at: staged, to: destination) }
    }

    private static func encodeAAC(source: URL, destination: URL) throws {
        let input = try AVAudioFile(forReading: source)
        let mono = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let stereo = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        guard let converter = AVAudioConverter(from: input.processingFormat, to: mono) else { throw failure("无法转换此录音的采样率。") }
        let output = try AVAudioFile(forWriting: destination, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 320_000,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ])
        let sourceBuffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 8192)!
        let converted = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: 8192)!
        let stereoBuffer = AVAudioPCMBuffer(pcmFormat: stereo, frameCapacity: 8192)!
        var sourceRemaining = input.length
        var outputRemaining = Int64((Double(input.length) * 48_000 / input.processingFormat.sampleRate).rounded())
        while outputRemaining > 0 {
            try Task.checkCancellation()
            var conversionError: NSError?
            var readError: Error?
            let status = converter.convert(to: converted, error: &conversionError) { requested, state in
                guard sourceRemaining > 0 else { state.pointee = .endOfStream; return nil }
                do {
                    try input.read(into: sourceBuffer, frameCount: AVAudioFrameCount(min(sourceRemaining, Int64(min(requested, 8192)))))
                    guard sourceBuffer.frameLength > 0 else { throw failure("录音未能完整读取。") }
                    sourceRemaining -= Int64(sourceBuffer.frameLength)
                    state.pointee = .haveData
                    return sourceBuffer
                } catch { readError = error; state.pointee = .endOfStream; return nil }
            }
            if let readError { throw readError }
            if status == .error { throw conversionError ?? failure("音频采样率转换失败。") }
            let frames = AVAudioFrameCount(min(outputRemaining, Int64(converted.frameLength)))
            guard frames > 0 else { throw failure("音频转换提前结束，导出未完成。") }
            stereoBuffer.frameLength = frames
            for channel in 0..<2 {
                stereoBuffer.floatChannelData![channel].update(from: converted.floatChannelData![0], count: Int(frames))
            }
            try output.write(from: stereoBuffer)
            outputRemaining -= Int64(frames)
        }
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "AudioExport", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
