@preconcurrency import AVFoundation
import CoreAudio
import AudioToolbox

struct InputDevice: Identifiable, Equatable {
    let id: AudioDeviceID
    let name: String
    let uid: String
    let channelNames: [String]
    var channelCount: Int { channelNames.count }
}

enum AudioInputs {
    static func available() -> [InputDevice] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            let count = channelCount(id)
            guard count > 0, let name = string(id, selector: kAudioObjectPropertyName) else { return nil }
            let uid = string(id, selector: kAudioDevicePropertyDeviceUID) ?? String(id)
            return InputDevice(id: id, name: name, uid: uid, channelNames: channelNames(id, count: count))
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func channelCount(_ id: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let storage = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { storage.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, storage) == noErr else { return 0 }
        return UnsafeMutableAudioBufferListPointer(storage.assumingMemoryBound(to: AudioBufferList.self)).reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    static func string(_ id: AudioObjectID, selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<CFString>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        guard let text = value?.takeRetainedValue() as String?, !text.isEmpty else { return nil }
        return text
    }

    private static func channelNames(_ id: AudioDeviceID, count: Int) -> [String] {
        // Aggregate channels follow the active subdevices in stream order.
        var address = AudioObjectPropertyAddress(mSelector: kAudioAggregateDevicePropertyActiveSubDeviceList, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        if AudioObjectHasProperty(id, &address), AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 {
            var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
            if AudioObjectGetPropertyData(id, &address, 0, nil, &size, &devices) == noErr {
                let names = devices.flatMap { device -> [String] in
                    let name = string(device, selector: kAudioObjectPropertyName) ?? "输入"
                    return (0..<channelCount(device)).map { "\(name) · \($0 + 1)" }
                }
                if names.count == count { return names }
            }
        }
        return (1...count).map { channel in
            string(id, selector: kAudioObjectPropertyElementName, scope: kAudioDevicePropertyScopeInput, element: UInt32(channel)) ?? "输入 \(channel)"
        }
    }

    static func defaultID() -> AudioDeviceID {
        var id: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        _ = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        return id
    }
}

nonisolated struct CaptureSnapshot {
    let elapsed: TimeInterval
    let waveforms: [[Float]]
    let peaks: [Float]
    let failure: String?
    let lastBufferAt: Date?
}

// The tap and UI share only this locked state. Preserve every input channel without a downmix.
nonisolated final class CaptureWriter: @unchecked Sendable {
    private let lock = NSLock()
    private var file: AVAudioFile?
    private let format: AVAudioFormat
    private var paused = false
    private var frames: Int64 = 0
    private var histories: [[Float]]
    private var peaks: [Float]
    private var latestPeaks: [Float]
    private var binFrames = 0
    private let binLength: Int
    private var failure: String?
    private var lastBufferAt: Date?

    init(url: URL, inputFormat: AVAudioFormat) throws {
        guard inputFormat.commonFormat == .pcmFormatFloat32, !inputFormat.isInterleaved, inputFormat.channelCount > 0, inputFormat.sampleRate > 0 else {
            throw NSError(domain: "AudioStudio", code: 3, userInfo: [NSLocalizedDescriptionKey: "此输入设备的音频格式不受支持。"])
        }
        format = inputFormat
        histories = Array(repeating: [], count: Int(format.channelCount))
        peaks = Array(repeating: 0, count: Int(format.channelCount))
        latestPeaks = peaks
        binLength = max(1, Int(format.sampleRate * 0.04))
        var settings = format.settings
        settings[AVLinearPCMIsNonInterleaved] = false
        file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    }

    func append(_ input: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard failure == nil, let file else { return }
        lastBufferAt = Date()
        guard !paused, input.frameLength > 0 else { return }
        guard input.format.channelCount == format.channelCount, input.format.sampleRate == format.sampleRate,
              input.format.commonFormat == .pcmFormatFloat32, !input.format.isInterleaved, let samples = input.floatChannelData else {
            failure = "输入通道或采样率已改变，请重新开始录音。"
            return
        }
        do { try file.write(from: input) } catch { failure = error.localizedDescription; return }
        frames += Int64(input.frameLength)
        for index in 0..<Int(input.frameLength) {
            for channel in peaks.indices {
                peaks[channel] = max(peaks[channel], abs(samples[channel][index]))
            }
            binFrames += 1
            if binFrames >= binLength {
                latestPeaks = peaks
                for channel in peaks.indices {
                    histories[channel].append(peaks[channel])
                    if histories[channel].count > 200 { histories[channel].removeFirst(histories[channel].count - 200) }
                    peaks[channel] = 0
                }
                binFrames = 0
            }
        }
    }

    func setPaused(_ value: Bool) { lock.lock(); paused = value; lock.unlock() }
    func snapshot() -> CaptureSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return CaptureSnapshot(elapsed: Double(frames) / format.sampleRate, waveforms: histories, peaks: latestPeaks, failure: failure, lastBufferAt: lastBufferAt)
    }
    func close() { lock.lock(); file = nil; lock.unlock() }
}
