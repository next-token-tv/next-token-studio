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

    static func preferredDevice(in devices: [InputDevice], defaultID: AudioDeviceID, preferredUID: String?) -> InputDevice? {
        // Core Audio creates temporary aggregates for running engines; these aren't user inputs.
        let candidates = devices.filter { device in
            let isBlackHole = [device.name, device.uid].contains { value in
                value.lowercased().filter { !$0.isWhitespace }.contains("blackhole")
            }
            return device.channelCount > 0 && !isBlackHole
                && !device.name.hasPrefix("CADefaultDeviceAggregate-")
                && !device.uid.hasPrefix("CADefaultDeviceAggregate-")
        }
        let maximum = candidates.map(\.channelCount).max() ?? 0
        guard maximum > 1 else {
            return candidates.first { $0.id == defaultID } ?? candidates.sorted { $0.uid < $1.uid }.first
        }
        let largest = candidates.filter { $0.channelCount == maximum }
        return largest.first { $0.uid == preferredUID }
            ?? largest.first { $0.id == defaultID }
            ?? largest.sorted { $0.uid < $1.uid }.first
    }

    static func captureFormat(input: AVAudioInputNode, device: InputDevice) throws -> AVAudioFormat {
        // Switching the AU device can leave the node's output format cached from the default device.
        // The input scope reflects hardware; explicitly apply matching channels/rate to the tap.
        let hardware = input.inputFormat(forBus: 0)
        guard hardware.sampleRate > 0, Int(hardware.channelCount) == device.channelCount,
              let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | hardware.channelCount) else {
            throw NSError(domain: "AudioStudio", code: 3, userInfo: [NSLocalizedDescriptionKey: "设备通道尚未就绪，请重新选择输入设备。"])
        }
        return AVAudioFormat(standardFormatWithSampleRate: hardware.sampleRate, channelLayout: layout)
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
    var failure: String?
    var lastBufferAt: Date?
    var queuedSeconds: Double = 0
    var safeElapsed: Double = 0
    var remainingSeconds: Double = 0
}

// The tap uses a bounded PCM pool; disk work publishes independent UI snapshots.
nonisolated final class CaptureWriter: @unchecked Sendable {
    static let waveformCapacity = 800
    private let lock = NSLock()
    private let writeQueue = DispatchQueue(label: "tv.nexttoken.capture-write", qos: .userInitiated)
    private let pendingLock = NSLock()
    private var pendingFrames = 0
    private var availableBuffers: [AVAudioPCMBuffer] = []
    private var accepting = true
    private var receivedAt: Date?
    private let snapshotLock = NSLock()
    private var published: CaptureSnapshot
    private let beforeWrite: (@Sendable () throws -> Void)?
    private var completedFrames: Int64 = 0
    private var overloaded = false
    private var interruption: String?
    private var remainingSeconds: Double = 0
    private var file: AVAudioFile?
    private var trackFiles: [DurableWAV] = []
    private var checkpointFrames: Int64 = 0
    private let metadata: Data?
    private var splitTracks: Bool { baseURL.pathExtension == "recording" }
    private let baseURL: URL
    private let segmentFrameLimit: Int64
    private var segmentFrames: Int64 = 0
    private var urls: [URL]
    var outputURLs: [URL] { lock.lock(); defer { lock.unlock() }; return urls }
    private let format: AVAudioFormat
    private var paused = false
    private var frames: Int64 = 0
    private var histories: [[Float]]
    private var historyCursor = 0
    private var historyCount = 0
    private var peaks: [Float]
    private var latestPeaks: [Float]
    private var binFrames = 0
    private let binLength: Int
    private var failure: String?
    private var lastBufferAt: Date?

    init(url: URL, inputFormat: AVAudioFormat, maximumSegmentBytes: Int64 = 3_900_000_000, metadata: Data? = nil, bufferSeconds: Double = 10, beforeWrite: (@Sendable () throws -> Void)? = nil) throws {
        guard inputFormat.commonFormat == .pcmFormatFloat32, !inputFormat.isInterleaved, inputFormat.channelCount > 0, inputFormat.sampleRate > 0 else {
            throw NSError(domain: "AudioStudio", code: 3, userInfo: [NSLocalizedDescriptionKey: "此输入设备的音频格式不受支持。"])
        }
        self.beforeWrite = beforeWrite
        published = CaptureSnapshot(elapsed: 0, waveforms: [], peaks: [], failure: nil, lastBufferAt: nil)
        self.metadata = metadata
        baseURL = url
        urls = [url]
        segmentFrameLimit = max(1, maximumSegmentBytes / (url.pathExtension == "recording" ? 4 : Int64(inputFormat.channelCount) * 4))
        format = inputFormat
        histories = Array(repeating: Array(repeating: 0, count: Self.waveformCapacity), count: Int(format.channelCount))
        peaks = Array(repeating: 0, count: Int(format.channelCount))
        latestPeaks = peaks
        binLength = max(1, Int(format.sampleRate * 0.01))
        for _ in 0..<max(1, Int(ceil(inputFormat.sampleRate * bufferSeconds / 2048))) {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: 2048) else { throw CocoaError(.fileWriteOutOfSpace) }
            availableBuffers.append(buffer)
        }
        try openSegment(url)

    }

    func append(_ input: AVAudioPCMBuffer) {
        pendingLock.lock()
        defer { pendingLock.unlock() }
        guard accepting, !overloaded else { return }
        receivedAt = Date()
        guard input.format.channelCount == format.channelCount, input.format.sampleRate == format.sampleRate,
              input.format.commonFormat == .pcmFormatFloat32, !input.format.isInterleaved,
              let source = input.floatChannelData else {
            overloaded = true
            return
        }
        let required = (Int(input.frameLength) + 2047) / 2048
        guard availableBuffers.count >= required else { overloaded = true; return }
        var offset = 0
        while offset < Int(input.frameLength) {
            let copy = availableBuffers.removeLast()
            let count = min(2048, Int(input.frameLength) - offset)
            copy.frameLength = AVAudioFrameCount(count)
            for channel in 0..<Int(format.channelCount) {
                copy.floatChannelData![channel].update(from: source[channel] + offset, count: count)
            }
            pendingFrames += count
            writeQueue.async { [self] in
                appendNow(copy)
                pendingLock.lock()
                pendingFrames -= count
                availableBuffers.append(copy)
                pendingLock.unlock()
                publishSnapshot()
            }
            offset += count
        }
    }

    private func appendNow(_ input: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard failure == nil, file != nil || !trackFiles.isEmpty else { return }
        lastBufferAt = Date()
        guard !paused, input.frameLength > 0 else { return }
        guard input.format.channelCount == format.channelCount, input.format.sampleRate == format.sampleRate,
              input.format.commonFormat == .pcmFormatFloat32, !input.format.isInterleaved, let samples = input.floatChannelData else {
            failure = "输入通道或采样率已改变，请重新开始录音。"
            return
        }
        do { try beforeWrite?(); try writeSegments(input) } catch { failure = error.localizedDescription; return }
        frames += Int64(input.frameLength)
        for index in 0..<Int(input.frameLength) {
            for channel in peaks.indices {
                peaks[channel] = max(peaks[channel], abs(samples[channel][index]))
            }
            binFrames += 1
            if binFrames >= binLength {
                latestPeaks = peaks
                for channel in peaks.indices {
                    histories[channel][historyCursor] = peaks[channel]
                    peaks[channel] = 0
                }
                historyCursor = (historyCursor + 1) % Self.waveformCapacity
                historyCount = min(historyCount + 1, Self.waveformCapacity)
                binFrames = 0
            }
        }
    }

    private func checkDiskSpace(_ url: URL) throws {
        let attributes = try FileManager.default.attributesOfFileSystem(forPath: url.deletingLastPathComponent().path)
        if let available = attributes[.systemFreeSize] as? NSNumber {
            remainingSeconds = Double(max(0, available.int64Value - 100_000_000)) / (format.sampleRate * Double(format.channelCount) * 4)
        }
        if let available = attributes[.systemFreeSize] as? NSNumber, available.int64Value < 100_000_000 {
            throw NSError(domain: "AudioCapture", code: 5, userInfo: [NSLocalizedDescriptionKey: "磁盘剩余空间不足 100 MB，已停止录音以保留现有数据。"])
        }
    }
    private func openSegment(_ url: URL) throws {
        try checkDiskSpace(url)
        if splitTracks {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            do {
                let names = (0..<Int(format.channelCount)).map { String(format: "track-%02d.wav", $0 + 1) }
                try JSONEncoder().encode(names).write(to: url.appendingPathComponent("tracks.json"), options: .atomic)
                try metadata?.write(to: url.appendingPathExtension("json"), options: .atomic)
                try RecordingRecovery.save(.init(status: "recording", sampleRate: format.sampleRate, safeFrames: 0), in: url)
                trackFiles = try (0..<Int(format.channelCount)).map { channel in
                    try DurableWAV(url: url.appendingPathComponent(String(format: "track-%02d.wav", channel + 1)), sampleRate: format.sampleRate)
                }
            } catch {
                trackFiles = []
                try? FileManager.default.removeItem(at: url)
                throw error
            }
        } else {
            var settings = format.settings
            settings[AVLinearPCMIsNonInterleaved] = false
            file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        }
    }

    private func writeSegments(_ input: AVAudioPCMBuffer) throws {
        var offset = 0
        while offset < Int(input.frameLength) {
            if segmentFrames == segmentFrameLimit {
                try checkpoint(complete: true)
                file = nil
                trackFiles = []
                let next = baseURL.deletingPathExtension()
                    .appendingPathExtension("part-\(String(format: "%03d", urls.count + 1)).\(baseURL.pathExtension)")
                try openSegment(next)
                urls.append(next)
                completedFrames += segmentFrames
                segmentFrames = 0
                checkpointFrames = 0
            }
            let count = min(Int(input.frameLength) - offset, Int(segmentFrameLimit - segmentFrames))
            if splitTracks {
                for channel in trackFiles.indices {
                    try trackFiles[channel].append(input.floatChannelData![channel] + offset, count: count)
                }
            } else if offset == 0 && count == Int(input.frameLength) {
                try file!.write(from: input)
            } else {
                let slice = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
                slice.frameLength = AVAudioFrameCount(count)
                for channel in 0..<Int(format.channelCount) {
                    slice.floatChannelData![channel].update(from: input.floatChannelData![channel] + offset, count: count)
                }
                try file!.write(from: slice)
            }
            segmentFrames += Int64(count)
            offset += count
            if splitTracks && segmentFrames - checkpointFrames >= Int64(format.sampleRate * 5) {
                try checkpoint(complete: false)
            }
        }
    }

    private func checkpoint(complete: Bool) throws {
        guard splitTracks, !trackFiles.isEmpty, let folder = urls.last else { return }
        for file in trackFiles { try file.checkpoint() }
        let safeFrames = trackFiles.map(\.frames).min() ?? 0
        pendingLock.lock(); let interrupted = overloaded || interruption != nil || failure != nil; pendingLock.unlock()
        try RecordingRecovery.save(.init(status: interrupted ? "interrupted" : (complete ? "complete" : "recording"), sampleRate: format.sampleRate, safeFrames: safeFrames), in: folder)
        checkpointFrames = segmentFrames
        if !complete { try checkDiskSpace(folder) }
    }

    func setPaused(_ value: Bool) { writeQueue.async { self.paused = value } }

    // Explicit barrier for offline callers and tests; the UI never drains the disk queue.
    func flush() { writeQueue.sync {} }

    private func publishSnapshot() {
        let ordered = histories.map { history in
            historyCount < Self.waveformCapacity
                ? Array(history.prefix(historyCount))
                : Array(history[historyCursor...]) + Array(history[..<historyCursor])
        }
        let value = CaptureSnapshot(elapsed: Double(frames) / format.sampleRate, waveforms: ordered,
            peaks: latestPeaks, failure: failure, lastBufferAt: lastBufferAt,
            safeElapsed: Double(completedFrames + checkpointFrames) / format.sampleRate, remainingSeconds: remainingSeconds)
        snapshotLock.lock(); published = value; snapshotLock.unlock()
    }

    func snapshot() -> CaptureSnapshot {
        snapshotLock.lock(); var value = published; snapshotLock.unlock()
        pendingLock.lock()
        value.queuedSeconds = Double(pendingFrames) / format.sampleRate
        value.lastBufferAt = receivedAt
        if overloaded { value.failure = "录音缓冲已满或输入格式改变，已停止接收新音频；录音将标记为异常中断。" }
        if let interruption { value.failure = interruption }
        pendingLock.unlock()
        return value
    }
    func markInterrupted(_ reason: String) {
        pendingLock.lock(); interruption = reason; accepting = false; pendingLock.unlock()
    }

    func close() {
        pendingLock.lock(); accepting = false; pendingLock.unlock()
        writeQueue.sync {
            do { try checkpoint(complete: failure == nil) } catch { failure = error.localizedDescription }
            file = nil; trackFiles = []
            publishSnapshot()
        }
    }
}
