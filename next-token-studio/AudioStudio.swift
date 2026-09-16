import AppKit
import AVFoundation
import Observation
import CoreAudio
import AudioToolbox

struct Recording: Identifiable, Hashable {
    var id: URL { url }
    let url: URL
    let createdAt: Date
    var name: String { url.deletingPathExtension().lastPathComponent }
}

@MainActor @Observable
final class AudioStudio: NSObject, AVAudioPlayerDelegate {
    var recordings: [Recording] = []
    var selectedID: URL?
    var isRecording = false
    var isPaused = false
    var isRequestingPermission = false
    var elapsed: TimeInterval = 0
    var level: Double = 0
    var playingID: URL?
    var errorMessage: String?
    var inputDevices: [InputDevice] = []
    var selectedInputID: AudioDeviceID = 0
    var waveform: [Float] = []
    var isPlaying = false
    var playbackTime: TimeInterval = 0
    var playbackDuration: TimeInterval = 0
    private var engine: AVAudioEngine?
    private var writer: CaptureWriter?
    private var recordingURL: URL?
    private var playbackTimer: Timer?
    private var deviceTimer: Timer?
    private var configurationObserver: NSObjectProtocol?
    private var player: AVAudioPlayer?
    private var timer: Timer?

    var isBusy: Bool { isRecording || isRequestingPermission }
    var selected: Recording? { recordings.first { $0.id == selectedID } }
    var clock: String {
        let seconds = Int(elapsed)
        return String(format: "%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
    }
    private var directory: URL {
        get throws {
            let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let folder = root.appendingPathComponent("NextTokenStudio/Recordings", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            return folder
        }
    }

    override init() {
        super.init()
        reload()
        refreshInputs()
        deviceTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshInputs() }
        }
    }

    func refreshInputs() {
        inputDevices = AudioInputs.available()
        if !inputDevices.contains(where: { $0.id == selectedInputID }) {
            if isRecording {
                stopRecording()
                errorMessage = "输入设备已断开，已有录音已保存。请选择输入设备后重新录音。"
            }
            let defaultID = AudioInputs.defaultID()
            selectedInputID = inputDevices.first(where: { $0.id == defaultID })?.id ?? inputDevices.first?.id ?? 0
        }
    }

    func reload() {
        do {
            recordings = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.creationDateKey])
                .filter { $0.pathExtension == "m4a" }
                .map { Recording(url: $0, createdAt: (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast) }
                .sorted { $0.createdAt > $1.createdAt }
        } catch { errorMessage = "无法读取录音：\(error.localizedDescription)" }
    }

    func startRecording() async {
        guard !isBusy else { return }
        isRequestingPermission = true
        defer { isRequestingPermission = false }
        let allowed = await AVCaptureDevice.requestAccess(for: .audio)
        guard allowed else {
            errorMessage = "请在系统设置 → 隐私与安全性 → 麦克风中允许 Next Token Studio 使用麦克风。"
            return
        }
        stopPlayback()
        do {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
            let name = "录音 \(formatter.string(from: Date()))-\(UUID().uuidString.prefix(4))"
            let url = try directory.appendingPathComponent(name).appendingPathExtension("m4a")
            refreshInputs()
            guard selectedInputID != 0 else { throw NSError(domain: "AudioStudio", code: 1, userInfo: [NSLocalizedDescriptionKey: "没有可用的音频输入设备。"] ) }
            let engine = AVAudioEngine()
            let input = engine.inputNode
            guard let unit = input.audioUnit else { throw NSError(domain: "AudioStudio", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法访问音频输入。"]) }
            var deviceID = selectedInputID
            let result = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size))
            guard result == noErr else { throw NSError(domain: "AudioStudio", code: Int(result), userInfo: [NSLocalizedDescriptionKey: "无法使用所选输入设备。"] ) }
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else { throw NSError(domain: "AudioStudio", code: 1, userInfo: [NSLocalizedDescriptionKey: "输入设备没有可用的音频通道。"] ) }
            let writer = try CaptureWriter(url: url, inputFormat: format)
            input.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, _ in writer.append(buffer) }
            do { try engine.start() } catch {
                input.removeTap(onBus: 0)
                writer.close()
                try? FileManager.default.removeItem(at: url)
                throw error
            }
            self.engine = engine
            self.writer = writer
            recordingURL = url
            isRecording = true
            isPaused = false
            elapsed = 0
            waveform = []
            configurationObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.isRecording, self.engine?.isRunning == false else { return }
                    self.stopRecording()
                    self.errorMessage = "音频设备配置发生变化，已有录音已保存。请重新开始录音。"
                }
            }
            timer = Timer.scheduledTimer(withTimeInterval: 0.04, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in self?.updateMeter() }
            }
        } catch { errorMessage = "录音失败：\(error.localizedDescription)" }
    }

    private func updateMeter() {
        guard let writer, isRecording else { return }
        let snapshot = writer.snapshot()
        elapsed = snapshot.0
        waveform = snapshot.1
        level = isPaused ? 0 : Double(waveform.last ?? 0)
        if let failure = snapshot.2 {
            stopRecording()
            errorMessage = "录音出现错误：\(failure)"
        }
    }

    func togglePause() {
        guard let writer, isRecording else { return }
        isPaused.toggle()
        writer.setPaused(isPaused)
        level = 0
    }

    func stopRecording() {
        guard isRecording else { return }
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil
        engine?.stop()
        engine?.inputNode.removeTap(onBus: 0)
        if let snapshot = writer?.snapshot() { elapsed = snapshot.0; waveform = snapshot.1 }
        writer?.close()
        writer = nil
        engine = nil
        timer?.invalidate()
        timer = nil
        isRecording = false
        isPaused = false
        level = 0
        reload()
        selectedID = recordingURL
        recordingURL = nil
    }

    func togglePlayback(_ recording: Recording) {
        guard !isBusy else { return }
        if playingID == recording.id, let player {
            if isPlaying {
                player.pause()
                isPlaying = false
            } else {
                if player.currentTime >= player.duration { player.currentTime = 0 }
                isPlaying = player.play()
            }
            playbackTime = player.currentTime
            return
        }
        stopPlayback()
        do {
            let audio = try AVAudioPlayer(contentsOf: recording.url)
            audio.delegate = self
            guard audio.play() else { throw NSError(domain: "AudioStudio", code: 2, userInfo: [NSLocalizedDescriptionKey: "无法播放此文件。"]) }
            player = audio
            playingID = recording.id
            selectedID = recording.id
            isPlaying = true
            playbackDuration = audio.duration
            playbackTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.isPlaying, let player = self.player else { return }
                    self.playbackTime = player.currentTime
                }
            }
        } catch { errorMessage = "播放失败：\(error.localizedDescription)" }
    }

    func seek(to time: TimeInterval) {
        guard let player else { return }
        playbackTime = min(max(0, time), playbackDuration)
        player.currentTime = playbackTime
    }

    func stopPlayback() {
        playbackTimer?.invalidate()
        playbackTimer = nil
        player?.stop()
        player = nil
        playingID = nil
        isPlaying = false
        playbackTime = 0
        playbackDuration = 0
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self, self.player === player else { return }
            self.isPlaying = false
            self.playbackTime = self.playbackDuration
            if !flag { self.errorMessage = "播放中断，请重新播放。" }
        }
    }

    func export(_ recording: Recording) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Audio]
        panel.nameFieldStringValue = recording.url.lastPathComponent
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                let data = try Data(contentsOf: recording.url)
                try data.write(to: url, options: .atomic)
            } catch { self.errorMessage = "导出失败：\(error.localizedDescription)" }
        }
    }
}
