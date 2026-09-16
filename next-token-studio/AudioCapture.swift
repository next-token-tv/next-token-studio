@preconcurrency import AVFoundation
import CoreAudio
import AudioToolbox

struct InputDevice: Identifiable, Equatable {
    let id: AudioDeviceID
    let name: String
}

enum AudioInputs {
    static func available() -> [InputDevice] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            var streams = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
            var streamSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &streamSize) == noErr, streamSize > 0 else { return nil }
            var name: Unmanaged<CFString>?
            var nameSize = UInt32(MemoryLayout<CFString>.size)
            var property = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            guard AudioObjectGetPropertyData(id, &property, 0, nil, &nameSize, &name) == noErr else { return nil }
            guard let name else { return nil }
            return InputDevice(id: id, name: name.takeUnretainedValue() as String)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func defaultID() -> AudioDeviceID {
        var id: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        _ = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        return id
    }
}

// The tap and UI share only this locked state. Audio buffers never cross to the main actor.
nonisolated final class CaptureWriter: @unchecked Sendable {
    private let lock = NSLock()
    private var file: AVAudioFile?
    private let converter: AVAudioConverter
    private let format: AVAudioFormat
    private var paused = false
    private var frames: Int64 = 0
    private var peaks: [Float] = []
    private var peak: Float = 0
    private var binFrames = 0
    private var failure: String?

    init(url: URL, inputFormat: AVAudioFormat) throws {
        format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        guard let converter = AVAudioConverter(from: inputFormat, to: format) else {
            throw NSError(domain: "AudioStudio", code: 3, userInfo: [NSLocalizedDescriptionKey: "此输入设备的音频格式不受支持。"])
        }
        self.converter = converter
        file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1, AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue])
    }

    func append(_ input: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard !paused, failure == nil, let file else { return }
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * 48_000 / input.format.sampleRate)) + 128
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, state in
            if supplied { state.pointee = .noDataNow; return nil }
            supplied = true
            state.pointee = .haveData
            return input
        }
        guard status != .error else { failure = error?.localizedDescription ?? "音频转换失败"; return }
        guard output.frameLength > 0 else { return }
        do { try file.write(from: output) } catch { failure = error.localizedDescription; return }
        frames += Int64(output.frameLength)
        if let samples = output.floatChannelData?[0] {
            for index in 0..<Int(output.frameLength) {
                peak = max(peak, abs(samples[index]))
                binFrames += 1
                if binFrames == 1920 { // One peak per 40 ms; retain eight seconds.
                    peaks.append(min(1, peak))
                    peak = 0
                    binFrames = 0
                }
            }
            if peaks.count > 200 { peaks.removeFirst(peaks.count - 200) }
        }
    }

    func setPaused(_ value: Bool) { lock.lock(); paused = value; lock.unlock() }
    func snapshot() -> (TimeInterval, [Float], String?) {
        lock.lock()
        defer { lock.unlock() }
        return (Double(frames) / 48_000, peaks, failure)
    }
    func close() { lock.lock(); file = nil; lock.unlock() }
}
