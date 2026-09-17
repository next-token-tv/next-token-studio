@preconcurrency import AVFoundation

// File reads and mixing run on a serial producer queue, never on the audio render thread.
// Four short buffers bound memory use independently of recording duration.
nonisolated final class StreamingPlayback: @unchecked Sendable {
    private let engine: AVAudioEngine
    private let node = AVAudioPlayerNode()
    private let queue = DispatchQueue(label: "tv.nexttoken.playback", qos: .userInitiated)
    private let file: AVAudioFile
    private let gain: Float
    private let monoFormat: AVAudioFormat
    private var generation = 0
    private var offset: Double = 0
    private var heldTime: Double = 0
    private var ended = false
    private var failure: Error?
    let duration: Double

    init(source: URL, gain: Float, engine: AVAudioEngine = AVAudioEngine()) throws {
        self.engine = engine
        file = try AVAudioFile(forReading: source)
        self.gain = gain
        duration = Double(file.length) / file.processingFormat.sampleRate
        monoFormat = AVAudioFormat(standardFormatWithSampleRate: file.processingFormat.sampleRate, channels: 1)!
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: monoFormat)
        engine.prepare()
        try engine.start()
        try queue.sync { try prime(at: 0) }
    }

    var currentTime: Double {
        get { queue.sync { position() } }
        set {
            queue.sync {
                let resume = node.isPlaying
                do { try prime(at: newValue); if resume { node.play() } }
                catch { failure = error }
            }
        }
    }
    var playbackError: Error? { queue.sync { failure } }
    var hasEnded: Bool { queue.sync { ended } }
    func play() -> Bool {
        queue.sync {
            guard failure == nil else { return false }
            do { if !engine.isRunning { try engine.start() }; node.play(); return true }
            catch { failure = error; return false }
        }
    }
    private func position() -> Double {
        if ended { return duration }
        guard node.isPlaying, let render = node.lastRenderTime,
              let time = node.playerTime(forNodeTime: render) else { return heldTime }
        return min(duration, offset + Double(time.sampleTime) / time.sampleRate)
    }
    func pause() { queue.sync { heldTime = position(); node.pause() } }
    func stop() { queue.sync { generation += 1; node.stop(); engine.stop() } }

    private func prime(at seconds: Double) throws {
        generation += 1
        node.stop()
        offset = min(max(0, seconds), duration)
        heldTime = offset
        ended = offset >= duration
        failure = nil
        file.framePosition = min(file.length, AVAudioFramePosition(offset * file.processingFormat.sampleRate))
        for _ in 0..<4 { try enqueue(generation: generation) }
    }

    private func enqueue(generation token: Int) throws {
        guard token == generation, file.framePosition < file.length else { return }
        let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 8192)!
        try file.read(into: input, frameCount: AVAudioFrameCount(min(8192, file.length - file.framePosition)))
        guard input.frameLength > 0 else { throw NSError(domain: "StreamingPlayback", code: 1, userInfo: [NSLocalizedDescriptionKey: "音频读取中断。"]) }
        let output = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: input.frameLength)!
        output.frameLength = input.frameLength
        for frame in 0..<Int(input.frameLength) {
            var sum: Float = 0
            for channel in 0..<Int(input.format.channelCount) {
                let sample = input.floatChannelData![channel][frame]
                if sample.isFinite { sum += sample }
            }
            output.floatChannelData![0][frame] = sum * gain
        }
        let last = file.framePosition == file.length
        node.scheduleBuffer(output, completionCallbackType: last ? .dataPlayedBack : .dataConsumed) { [weak self] _ in
            guard let self else { return }
            self.queue.async { [weak self] in
                guard let self, token == self.generation else { return }
                if last { self.ended = true; return }
                do { try self.enqueue(generation: token) }
                catch { self.failure = error; self.node.pause() }
            }
        }
    }
}
