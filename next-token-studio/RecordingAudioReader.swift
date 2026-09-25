@preconcurrency import AVFoundation

// A recording folder contains synchronized mono WAVs. Legacy single-file recordings
// use the same reader so playback and export never need an intermediate audio file.
nonisolated final class RecordingAudioReader {
    let processingFormat: AVAudioFormat
    let length: AVAudioFramePosition
    private let files: [AVAudioFile]
    private let split: Bool
    var framePosition: AVAudioFramePosition {
        get { files[0].framePosition }
        set { for file in files { file.framePosition = newValue } }
    }
    static func sourceFiles(_ source: URL) throws -> [URL] {
        guard source.pathExtension == "recording" else { return [source] }
        let names = try JSONDecoder().decode([String].self, from: Data(contentsOf: source.appendingPathComponent("tracks.json")))
        guard !names.isEmpty, names.enumerated().allSatisfy({ index, name in
            name == String(format: "track-%02d.wav", index + 1)
        }) else { throw invalid() }
        let tracks = names.map { source.appendingPathComponent($0) }
        return tracks
    }
    init(forReading source: URL) throws {
        split = source.pathExtension == "recording"
        files = try Self.sourceFiles(source).map { try AVAudioFile(forReading: $0) }
        let first = files[0]
        let frameLength = first.length
        length = frameLength
        if split {
            guard files.allSatisfy({ $0.length == frameLength && $0.processingFormat.channelCount == 1 && $0.processingFormat.sampleRate == first.processingFormat.sampleRate }),
                  let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | UInt32(files.count)) else { throw Self.invalid() }
            processingFormat = AVAudioFormat(standardFormatWithSampleRate: first.processingFormat.sampleRate, channelLayout: layout)
        } else { processingFormat = first.processingFormat }
    }
    func read(into buffer: AVAudioPCMBuffer, frameCount: AVAudioFrameCount) throws {
        guard split else { try files[0].read(into: buffer, frameCount: frameCount); return }
        let count = min(frameCount, buffer.frameCapacity, AVAudioFrameCount(max(0, min(Int64(UInt32.max), length - framePosition))))
        buffer.frameLength = count
        guard count > 0 else { return }
        let mono = AVAudioPCMBuffer(pcmFormat: files[0].processingFormat, frameCapacity: count)!
        for (channel, file) in files.enumerated() {
            try file.read(into: mono, frameCount: count)
            guard mono.frameLength == count else { throw Self.invalid() }
            buffer.floatChannelData![channel].update(from: mono.floatChannelData![0], count: Int(count))
        }
    }
    private static func invalid() -> NSError {
        NSError(domain: "RecordingAudioReader", code: 1, userInfo: [NSLocalizedDescriptionKey: "录音轨道缺失，或各轨道时长、采样率不一致。"])
    }
}
