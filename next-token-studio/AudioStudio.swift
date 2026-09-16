import AppKit
import AVFoundation
import Observation
import CoreAudio
import AudioToolbox
import UniformTypeIdentifiers

nonisolated struct RecordingMetadata: Codable, Hashable {
    let inputName: String
    let channelNames: [String]
    let sampleRate: Double
}

struct Recording: Identifiable, Hashable {
    var id: URL { url }
    let url: URL
    let createdAt: Date
    var metadata: RecordingMetadata? = nil
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
    var playingID: URL?
    var errorMessage: String?
    var inputDevices: [InputDevice] = []
    var selectedInputID: AudioDeviceID = 0 {
        didSet {
            guard !isRecording, selectedInputID != oldValue else { return }
            waveforms = []
            channelPeaks = []
            if let device = selectedInput { UserDefaults.standard.set(device.uid, forKey: "selectedInputUID") }
        }
    }
    var waveforms: [[Float]] = []
    var channelPeaks: [Float] = []
    var signalStatus: String?
    var playbackWaveforms: [[Float]] = []
    var playbackPeaks: [Float] = []
    var playbackSampleRate: Double = 0
    var playbackChannelNames: [String] = []
    var isPreparingPlayback = false
    private var previewURL: URL?
    private var previewTask: Task<Void, Never>?
    private var previewGeneration = UUID()
    private var recordingStartedAt: Date?
    private var recordingMetadata: RecordingMetadata?
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
    var selectedInput: InputDevice? { inputDevices.first { $0.id == selectedInputID } }
    var displayedChannelNames: [String] { selectedInput?.channelNames ?? [] }
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
            let savedUID = UserDefaults.standard.string(forKey: "selectedInputUID")
            let defaultID = AudioInputs.defaultID()
            selectedInputID = inputDevices.first(where: { $0.uid == savedUID })?.id ?? inputDevices.first(where: { $0.id == defaultID })?.id ?? inputDevices.first?.id ?? 0
        }
    }

    func reload() {
        do {
            recordings = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.creationDateKey])
                .filter { ["m4a", "caf"].contains($0.pathExtension) }
                .map { url in
                    let metadata = (try? Data(contentsOf: url.appendingPathExtension("json"))).flatMap { try? JSONDecoder().decode(RecordingMetadata.self, from: $0) }
                    return Recording(url: url, createdAt: (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast, metadata: metadata)
                }
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
        selectedID = nil
        do {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
            let name = "录音 \(formatter.string(from: Date()))-\(UUID().uuidString.prefix(4))"
            let url = try directory.appendingPathComponent(name).appendingPathExtension("caf")
            refreshInputs()
            guard let device = selectedInput else { throw NSError(domain: "AudioStudio", code: 1, userInfo: [NSLocalizedDescriptionKey: "没有可用的音频输入设备。"] ) }
            let engine = AVAudioEngine()
            let input = engine.inputNode
            try input.auAudioUnit.setDeviceID(device.id)
            guard input.auAudioUnit.deviceID == device.id else { throw NSError(domain: "AudioStudio", code: 1, userInfo: [NSLocalizedDescriptionKey: "音频引擎未能连接所选设备。"] ) }
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, Int(format.channelCount) == device.channelCount else {
                throw NSError(domain: "AudioStudio", code: 1, userInfo: [NSLocalizedDescriptionKey: "设备提供 \(device.channelCount) 路输入，但音频引擎只打开了 \(format.channelCount) 路。请检查音频 MIDI 设置后重试。"])
            }
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
            waveforms = Array(repeating: [], count: device.channelCount)
            channelPeaks = Array(repeating: 0, count: device.channelCount)
            signalStatus = nil
            recordingStartedAt = Date()
            recordingMetadata = RecordingMetadata(inputName: device.name, channelNames: device.channelNames, sampleRate: format.sampleRate)
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
        elapsed = snapshot.elapsed
        waveforms = snapshot.waveforms
        channelPeaks = snapshot.peaks
        if !isPaused, Date().timeIntervalSince(recordingStartedAt ?? Date()) > 2 {
            if snapshot.lastBufferAt == nil || Date().timeIntervalSince(snapshot.lastBufferAt!) > 2 {
                signalStatus = "未收到音频数据，请检查输入设备连接。"
            } else if snapshot.peaks.allSatisfy({ $0 < 0.00001 }) {
                signalStatus = "所有通道均无有效信号，请检查麦克风静音、接收器和设备通道路由。"
            } else { signalStatus = nil }
        }
        if let failure = snapshot.failure {
            stopRecording()
            errorMessage = "录音出现错误：\(failure)"
        }
    }

    func togglePause() {
        guard let writer, isRecording else { return }
        isPaused.toggle()
        writer.setPaused(isPaused)
    }

    func stopRecording() {
        guard isRecording else { return }
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil
        engine?.stop()
        engine?.inputNode.removeTap(onBus: 0)
        if let snapshot = writer?.snapshot() { elapsed = snapshot.elapsed; waveforms = snapshot.waveforms; channelPeaks = snapshot.peaks }
        writer?.close()
        writer = nil
        engine = nil
        timer?.invalidate()
        timer = nil
        isRecording = false
        isPaused = false
        signalStatus = nil
        if let recordingURL, let recordingMetadata {
            do { try JSONEncoder().encode(recordingMetadata).write(to: recordingURL.appendingPathExtension("json"), options: .atomic) }
            catch { errorMessage = "录音已保存，但通道名称保存失败：\(error.localizedDescription)" }
        }
        recordingMetadata = nil
        reload()
        selectedID = recordingURL
        recordingURL = nil
    }

    func showRecorder() {
        guard !isBusy else { return }
        stopPlayback()
        selectedID = nil
    }

    func openRecording(_ recording: Recording) {
        guard !isBusy, playingID != recording.id else { return }
        stopPlayback()
        playingID = recording.id
        selectedID = recording.id
        preparePlayback(recording, autoPlay: false)
    }

    func togglePlayback(_ recording: Recording) {
        guard !isBusy, !isPreparingPlayback else { return }
        if playingID == recording.id, let player {
            if isPlaying {
                player.pause()
                isPlaying = false
            } else {
                if playbackTime >= playbackDuration { player.currentTime = 0 }
                isPlaying = player.play()
                if !isPlaying { errorMessage = "无法开始播放，请检查输出设备。" }
            }
            playbackTime = player.currentTime
            return
        }
        stopPlayback()
        playingID = recording.id
        selectedID = recording.id
        preparePlayback(recording, autoPlay: true)
    }

    private func preparePlayback(_ recording: Recording, autoPlay: Bool) {
        previewGeneration = UUID()
        let generation = previewGeneration
        isPreparingPlayback = true
        playbackChannelNames = recording.metadata?.channelNames ?? []
        previewTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let output = FileManager.default.temporaryDirectory.appendingPathComponent("mix-\(UUID().uuidString).caf")
            do {
                let render = Task.detached { try PlaybackRender.prepare(source: recording.url, destination: output) }
                let overview = try await withTaskCancellationHandler(operation: { try await render.value }, onCancel: { render.cancel() })
                try Task.checkCancellation()
                guard generation == previewGeneration else { try? FileManager.default.removeItem(at: output); return }
                let audio = try AVAudioPlayer(contentsOf: output)
                audio.delegate = self
                guard audio.prepareToPlay() else { throw NSError(domain: "AudioStudio", code: 2, userInfo: [NSLocalizedDescriptionKey: "无法准备播放此文件。"] ) }
                previewURL = output
                player = audio
                playbackWaveforms = overview.waveforms
                playbackPeaks = overview.channelPeaks
                playbackSampleRate = overview.sampleRate
                if playbackChannelNames.count != overview.waveforms.count {
                    playbackChannelNames = overview.waveforms.indices.map { "输入 \($0 + 1)" }
                }
                playbackTime = 0
                playbackDuration = audio.duration
                if autoPlay {
                    guard audio.play() else { throw NSError(domain: "AudioStudio", code: 2, userInfo: [NSLocalizedDescriptionKey: "无法播放此文件。"] ) }
                    isPlaying = true
                }
                isPreparingPlayback = false
                playbackTimer = Timer.scheduledTimer(withTimeInterval: 0.04, repeats: true) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        guard let self, self.isPlaying, let player = self.player else { return }
                        self.playbackTime = player.currentTime
                    }
                }
            } catch {
                try? FileManager.default.removeItem(at: output)
                guard generation == previewGeneration else { return }
                stopPlayback()
                selectedID = nil
                if !(error is CancellationError) { errorMessage = "播放失败：\(error.localizedDescription)" }
            }
        }
    }

    func rewindPlayback() {
        seek(to: 0)
    }

    func seek(to time: TimeInterval) {
        guard let player else { return }
        playbackTime = min(max(0, time), playbackDuration)
        player.currentTime = playbackTime
    }

    func stopPlayback() {
        previewGeneration = UUID()
        previewTask?.cancel()
        previewTask = nil
        isPreparingPlayback = false
        playbackTimer?.invalidate()
        playbackTimer = nil
        player?.stop()
        player = nil
        if let previewURL { try? FileManager.default.removeItem(at: previewURL) }
        previewURL = nil
        playbackChannelNames = []
        playbackWaveforms = []
        playbackPeaks = []
        playbackSampleRate = 0
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

    func deleteRecording(_ recording: Recording) {
        guard !isBusy, recordings.contains(where: { $0.id == recording.id }) else { return }
        if playingID == recording.id { stopPlayback() }
        do {
            try RecordingTrash.move(recording.url)
            if selectedID == recording.id { selectedID = nil }
            reload()
        } catch {
            errorMessage = "无法删除录音：\(error.localizedDescription)"
        }
    }

    func export(_ recording: Recording) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: recording.url.pathExtension) ?? .audio]
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
