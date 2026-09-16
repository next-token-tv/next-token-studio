import AVFoundation

@main
struct AudioExportChecks {
    static func main() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("audio-export-checks-" + UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        for count in [1, 4, 5] {
            for rate in [44_100.0, 48_000.0] {
                let source = root.appendingPathComponent("source-\(count)-\(Int(rate)).caf")
                let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | UInt32(count))!
                let format = AVAudioFormat(standardFormatWithSampleRate: rate, channelLayout: layout)
                let segmentFrames = Int(rate / 5)
                let length = segmentFrames * count
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(length))!
                buffer.frameLength = buffer.frameCapacity
                for channel in 0..<count {
                    for frame in 0..<length {
                        buffer.floatChannelData![channel][frame] = frame / segmentFrames == channel ? 0.25 * sin(2 * .pi * Float(330 + channel * 110) * Float(frame) / Float(rate)) : 0
                    }
                }
                do {
                    var settings = format.settings
                    settings[AVLinearPCMIsNonInterleaved] = false
                    let file = try AVAudioFile(forWriting: source, settings: settings)
                    try file.write(from: buffer)
                }
                let original = try Data(contentsOf: source)
                let tracks = root.appendingPathComponent("tracks-\(count)-\(Int(rate))", isDirectory: true)
                try AudioExport.splitWAV(source: source, names: (1...count).map { "Microphone \($0)" }, destination: tracks)
                let names = try manager.contentsOfDirectory(atPath: tracks.path)
                precondition(names.filter { $0.hasSuffix(".wav") }.count == count)
                let manifest = try JSONDecoder().decode(AudioExport.Manifest.self, from: Data(contentsOf: tracks.appendingPathComponent("channels.json")))
                precondition(manifest.channels.count == count && manifest.frames == length && manifest.sampleRate == rate)
                for channel in 0..<count {
                    let file = try AVAudioFile(forReading: tracks.appendingPathComponent(String(format: "host-ch%02d.wav", channel + 1)))
                    precondition(file.length == length && file.processingFormat.channelCount == 1 && file.processingFormat.sampleRate == rate)
                    precondition(file.fileFormat.streamDescription.pointee.mBitsPerChannel == 32)
                    let read = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 8192)!
                    var position = 0
                    while position < length {
                        try file.read(into: read, frameCount: AVAudioFrameCount(min(length - position, 8192)))
                        precondition(read.frameLength > 0)
                        for frame in 0..<Int(read.frameLength) {
                            precondition(read.floatChannelData![0][frame] == buffer.floatChannelData![channel][position + frame], "WAV must preserve exact samples and silence")
                        }
                        position += Int(read.frameLength)
                    }
                }
                let m4a = root.appendingPathComponent("mix-\(count)-\(Int(rate)).m4a")
                try AudioExport.mixedM4A(source: source, destination: m4a)
                let mixed = try AVAudioFile(forReading: m4a)
                precondition(mixed.fileFormat.streamDescription.pointee.mFormatID == kAudioFormatMPEG4AAC)
                precondition(mixed.processingFormat.channelCount == 2 && mixed.processingFormat.sampleRate == 48_000)
                precondition(abs(Double(mixed.length) / 48_000 - Double(length) / rate) < 0.025)
                let decoded = AVAudioPCMBuffer(pcmFormat: mixed.processingFormat, frameCapacity: AVAudioFrameCount(mixed.length))!
                try mixed.read(into: decoded, frameCount: AVAudioFrameCount(mixed.length))
                for channel in 0..<count {
                    let start = channel * 9600 + 2000
                    let end = min(start + 4000, Int(decoded.frameLength))
                    let peak = (start..<end).map { abs(decoded.floatChannelData![0][$0]) }.max() ?? 0
                    precondition(peak > 0.1, "Every source channel must be audible in M4A")
                    for frame in start..<end { precondition(abs(decoded.floatChannelData![0][frame] - decoded.floatChannelData![1][frame]) < 0.002) }
                }
                let untouched = try Data(contentsOf: source)
                precondition(original == untouched)
                print("PASS: \(count) tracks @ \(Int(rate)) Hz → exact mono WAV files + full stereo AAC M4A at 48 kHz")
            }
        }
        let source = root.appendingPathComponent("source-5-48000.caf")
        let existing = root.appendingPathComponent("mix-5-48000.m4a")
        do {
            try AudioExport.mixedM4A(source: source, destination: existing)
            preconditionFailure("Existing output must be protected")
        } catch { precondition((error as NSError).domain == "AudioExport") }
        try AudioExport.mixedM4A(source: source, destination: existing, replaceExisting: true)
        do {
            try AudioExport.mixedM4A(source: source, destination: source, replaceExisting: true)
            preconditionFailure("Source must never be overwritten")
        } catch { precondition((error as NSError).domain == "AudioExport") }
        let failed = root.appendingPathComponent("failed-tracks")
        do {
            try AudioExport.splitWAV(source: root.appendingPathComponent("missing.caf"), names: [], destination: failed)
            preconditionFailure("Missing input must fail")
        } catch { precondition(!manager.fileExists(atPath: failed.path)) }
        let leftovers = try manager.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix(".wav-export-") }
        precondition(leftovers.isEmpty)
        print("PASS: overwrite protection, approved replacement, source protection, failed-export cleanup")
    }
}
