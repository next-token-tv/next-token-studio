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
    var hostIDs: [String?]? = nil
    var inputChannelNames: [String]? = nil
}

struct Recording: Identifiable, Hashable {
    var id: URL { url }
    let url: URL
    let createdAt: Date
    var metadata: RecordingMetadata? = nil
    var formatLabel: String { url.pathExtension == "recording" ? "WAV 分轨" : url.pathExtension.uppercased() }
    var name: String { url.deletingPathExtension().lastPathComponent }
}

@MainActor @Observable
final class AudioStudio: NSObject {
    let workspace = StudioWorkspace()
    var recordings: [Recording] = []
    var selectedID: URL?
    var isMatching = false
    var isRecording = false
    var isFinalizing = false
    private var finalizationTask: Task<Void, Never>?
    private var saveFailed = false
    var isPaused = false
    var isRequestingPermission = false
    var elapsed: TimeInterval = 0
    var playingID: URL?
    var errorMessage: String?
    var isExporting = false
    var exportStatus: String?
    var lastExportURL: URL?
    private var exportTask: Task<Void, Never>?
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
    var recordingHealth: String?
    var playbackWaveforms: [[Float]] = []
    var playbackPeaks: [Float] = []
    var playbackSampleRate: Double = 0
    var playbackChannelNames: [String] = []
    var isPreparingPlayback = false
    private var previewTask: Task<Void, Never>?
    private var previewGeneration = UUID()
    private var recordingStartedAt: Date?
    private var recordingActivity: NSObjectProtocol?
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
    private var player: StreamingPlayback?
    private var timer: Timer?

    var isBusy: Bool { isRecording || isRequestingPermission || isMatching }
    var selectedInput: InputDevice? { inputDevices.first { $0.id == selectedInputID } }
    var displayedChannelNames: [String] { selectedInput.map { channelLabels(for: $0) } ?? [] }
    private func channelLabels(for device: InputDevice) -> [String] {
        let ids = workspace.hostIDs(for: device)
        return device.channelNames.enumerated().map { index, name in
            guard let id = ids[index], let host = workspace.hosts.first(where: { $0.id == id }) else { return name }
            return "\(host.name) · \(name)"
        }
    }
    func beginMatching() {
        guard !isBusy, !isExporting, workspace.root != nil else { return }
        refreshInputs()
        guard selectedInput != nil else { errorMessage = "没有可用的音频输入设备。"; return }
        workspace.reloadHosts()
        stopPlayback()
        selectedID = nil
        isMatching = true
    }
    var selected: Recording? { recordings.first { $0.id == selectedID } }
    var clock: String {
        let seconds = Int(elapsed)
        return String(format: "%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
    }
    private var directory: URL {
        get throws { try workspace.folder("recordings") }
    }

    func openWorkspace() async {
        await workspace.choose()
        if workspace.root != nil { await recoverRecordings(); reload() }
    }

    func restoreWorkspace() async {
        await workspace.restore()
        if workspace.root != nil { await recoverRecordings(); reload() }
    }

    override init() {
        super.init()
        refreshInputs()
        deviceTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshInputs() }
        }
    }

    func refreshInputs() {
        guard !isFinalizing else { return }
        inputDevices = AudioInputs.available()
        if !inputDevices.contains(where: { $0.id == selectedInputID }) {
            if isRecording {
                writer?.markInterrupted("输入设备已断开。")
                stopRecording()
                errorMessage = "输入设备已断开，正在保存已接收的录音。"
                return
            }
            choosePreferredInput()
        }
    }

    private func choosePreferredInput() {
        selectedInputID = AudioInputs.preferredDevice(in: inputDevices, defaultID: AudioInputs.defaultID(),
            preferredUID: UserDefaults.standard.string(forKey: "selectedInputUID"))?.id ?? 0
    }

    private func recoverRecordings() async {
        guard let root = try? directory else { return }
        isRequestingPermission = true
        defer { isRequestingPermission = false }
        do {
            let report = try await Task.detached { try RecordingRecovery.recoverReport(in: root) }.value
            if report.recovered > 0 || !report.issues.isEmpty {
                errorMessage = "已恢复 \(report.recovered) 段异常中断的录音。异常原文件保留在工作文件夹中。"
                    + (report.issues.isEmpty ? "" : "另有 \(report.issues.count) 段未能恢复，原文件保留，下次打开会重试。\n" + report.issues.joined(separator: "\n"))
            }
        } catch { errorMessage = "录音恢复未完成，原文件已保留：\(error.localizedDescription)" }
    }

    func reload() {
        guard workspace.root != nil else { return }
        do {
            recordings = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.creationDateKey])
                .filter { ["m4a", "caf", "wav", "recording"].contains($0.pathExtension) }
                .filter { url in
                    guard url.pathExtension == "recording" else { return true }
                    guard let state = RecordingRecovery.state(in: url) else { return false }
                    return state.status == "complete"
                }
                .map { url in
                    let metadata = (try? Data(contentsOf: url.appendingPathExtension("json"))).flatMap { try? JSONDecoder().decode(RecordingMetadata.self, from: $0) }
                    return Recording(url: url, createdAt: (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast, metadata: metadata)
                }
                .sorted { $0.createdAt > $1.createdAt }
        } catch { errorMessage = "无法读取录音：\(error.localizedDescription)" }
    }

    func startRecording() async {
        guard !isBusy, workspace.root != nil else { return }
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
            let url = try directory.appendingPathComponent(name).appendingPathExtension("recording")
            refreshInputs()
            guard let device = selectedInput else { throw NSError(domain: "AudioStudio", code: 1, userInfo: [NSLocalizedDescriptionKey: "没有可用的音频输入设备。"] ) }
            let engine = AVAudioEngine()
            let input = engine.inputNode
            try input.auAudioUnit.setDeviceID(device.id)
            guard input.auAudioUnit.deviceID == device.id else { throw NSError(domain: "AudioStudio", code: 1, userInfo: [NSLocalizedDescriptionKey: "音频引擎未能连接所选设备。"] ) }
            let format = try AudioInputs.captureFormat(input: input, device: device)
            guard format.sampleRate > 0, Int(format.channelCount) == device.channelCount else {
                throw NSError(domain: "AudioStudio", code: 1, userInfo: [NSLocalizedDescriptionKey: "设备提供 \(device.channelCount) 路输入，但音频引擎只打开了 \(format.channelCount) 路。请检查音频 MIDI 设置后重试。"])
            }
            let metadata = RecordingMetadata(inputName: device.name, channelNames: channelLabels(for: device), sampleRate: format.sampleRate, hostIDs: workspace.hostIDs(for: device), inputChannelNames: device.channelNames)
            let writer = try CaptureWriter(url: url, inputFormat: format, metadata: JSONEncoder().encode(metadata))
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
            recordingActivity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "正在录制音频")
            isRecording = true
            isPaused = false
            elapsed = 0
            waveforms = Array(repeating: [], count: device.channelCount)
            channelPeaks = Array(repeating: 0, count: device.channelCount)
            signalStatus = nil
            recordingStartedAt = Date()
            recordingMetadata = metadata
            configurationObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.isRecording, self.engine?.isRunning == false else { return }
                    self.writer?.markInterrupted("音频设备配置发生变化。")
                    self.stopRecording()
                    self.errorMessage = "音频设备配置发生变化，正在保存已接收的录音。"
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
        recordingHealth = String(format: "已写入 %.1f 秒 · 已同步 %.1f 秒 · 缓冲 %.1f 秒 · 磁盘约剩 %.0f 分钟", snapshot.elapsed, snapshot.safeElapsed, snapshot.queuedSeconds, snapshot.remainingSeconds / 60)
        elapsed = snapshot.elapsed
        waveforms = snapshot.waveforms
        channelPeaks = snapshot.peaks
        if isFinalizing { return }
        if !isPaused, Date().timeIntervalSince(recordingStartedAt ?? Date()) > 2 {
            if snapshot.lastBufferAt == nil || Date().timeIntervalSince(snapshot.lastBufferAt!) > 2 {
                signalStatus = "未收到音频数据，请检查输入设备连接。"
            } else if snapshot.peaks.allSatisfy({ $0 < 0.00001 }) {
                signalStatus = "所有通道均无有效信号，请检查麦克风静音、接收器和设备通道路由。"
            } else if snapshot.queuedSeconds > 2 {
                signalStatus = "磁盘写入延迟增加，正在使用录音缓冲。"
            } else { signalStatus = nil }
        }
        if let failure = snapshot.failure {
            stopRecording()
            errorMessage = "录音出现错误：\(failure)"
        }
    }

    func togglePause() {
        guard let writer, isRecording, !isFinalizing else { return }
        isPaused.toggle()
        writer.setPaused(isPaused)
    }

    func stopRecording() {
        guard isRecording, !isFinalizing else { return }
        isFinalizing = true
        saveFailed = false
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil
        engine?.stop()
        engine?.inputNode.removeTap(onBus: 0)
        let closingWriter = writer
        finalizationTask = Task {
            await Task.detached(priority: .userInitiated) { closingWriter?.close() }.value
            finishRecording()
        }
    }

    func waitForRecordingSave() async -> Bool {
        await finalizationTask?.value
        return !saveFailed
    }

    private func finishRecording() {
        if let snapshot = writer?.snapshot() {
            elapsed = snapshot.elapsed; waveforms = snapshot.waveforms; channelPeaks = snapshot.peaks
            if let failure = snapshot.failure {
                saveFailed = true
                errorMessage = "录音异常中断，原文件已保留，重新打开工作文件夹时会尝试恢复：\(failure)"
            }
        }
        writer = nil
        engine = nil
        timer?.invalidate()
        timer = nil
        if let recordingActivity { ProcessInfo.processInfo.endActivity(recordingActivity) }
        recordingActivity = nil
        isRecording = false
        isFinalizing = false
        isPaused = false
        signalStatus = nil
        recordingHealth = nil
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
            do {
                let cache = try workspace.folder("cache")
                let render = Task.detached { try PlaybackRender.cached(source: recording.url, cache: cache) }
                let prepared = try await withTaskCancellationHandler(operation: { try await render.value }, onCancel: { render.cancel() })
                try Task.checkCancellation()
                guard generation == previewGeneration else { return }
                let overview = prepared
                let audio = try StreamingPlayback(source: recording.url, gain: overview.mixGain)
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
                        if player.hasEnded { self.isPlaying = false }
                        if let error = player.playbackError {
                            self.isPlaying = false
                            self.errorMessage = "播放中断：\(error.localizedDescription)"
                        }
                    }
                }
            } catch {
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
        playbackChannelNames = []
        playbackWaveforms = []
        playbackPeaks = []
        playbackSampleRate = 0
        playingID = nil
        isPlaying = false
        playbackTime = 0
        playbackDuration = 0
    }

    func deleteRecording(_ recording: Recording) {
        guard !isBusy, !isExporting, recordings.contains(where: { $0.id == recording.id }) else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "将这段录音移到废纸篓？"
        alert.informativeText = "“\(recording.name)”\n\n此录音的全部音轨和通道资料将一起移到废纸篓，可在 Finder 的废纸篓中恢复。"
        let cancel = alert.addButton(withTitle: "取消")
        cancel.keyEquivalent = "\r"
        let confirm = alert.addButton(withTitle: "移到废纸篓")
        confirm.hasDestructiveAction = true
        confirm.keyEquivalent = ""
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        guard !isBusy, !isExporting, recordings.contains(where: { $0.id == recording.id }) else { return }
        if playingID == recording.id { stopPlayback() }
        do {
            try RecordingTrash.move(recording.url)
            if let cache = try? workspace.folder("cache") {
                PlaybackRender.removeCache(source: recording.url, cache: cache)
            }
            if selectedID == recording.id { selectedID = nil }
            reload()
        } catch {
            errorMessage = "无法删除录音：\(error.localizedDescription)"
        }
    }

    private func exportBaseName(_ recording: Recording) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "next-token-\(formatter.string(from: recording.createdAt))"
    }

    func exportWAV(_ recording: Recording) {
        exportToWorkspace(recording, split: true)
    }

    func exportM4A(_ recording: Recording) {
        exportToWorkspace(recording, split: false)
    }

    private func exportToWorkspace(_ recording: Recording, split: Bool) {
        guard !isBusy, !isExporting else { return }
        do {
            let parent = try workspace.folder("exports")
            let name = "\(exportBaseName(recording))-\(UUID().uuidString.prefix(6).lowercased())"
            let destination = parent.appendingPathComponent(split ? name + "-tracks" : name + ".m4a")
            runExport(recording, destination: destination, access: parent, split: split)
        } catch { errorMessage = error.localizedDescription }
    }

    private func runExport(_ recording: Recording, destination: URL, access: URL, split: Bool) {
        guard !isExporting else { return }
        isExporting = true
        lastExportURL = nil
        exportStatus = split ? "正在导出分轨 WAV…" : "正在导出混音 M4A…"
        let scoped = access.startAccessingSecurityScopedResource()
        let source = recording.url
        let names = recording.metadata?.channelNames ?? []
        exportTask = Task { @MainActor [weak self] in
            guard let self else { if scoped { access.stopAccessingSecurityScopedResource() }; return }
            defer {
                isExporting = false
                exportTask = nil
                if scoped { access.stopAccessingSecurityScopedResource() }
            }
            do {
                let cache = try workspace.folder("cache")
                let work = Task.detached {
                    if split { try AudioExport.splitWAV(source: source, names: names, destination: destination) }
                    else { try AudioExport.mixedM4A(source: source, destination: destination, replaceExisting: false, temporaryDirectory: cache) }
                }
                try await withTaskCancellationHandler(operation: { try await work.value }, onCancel: { work.cancel() })
                lastExportURL = destination
                exportStatus = split ? "分轨 WAV 已导出" : "混音 M4A 已导出"
            } catch {
                exportStatus = nil
                if !(error is CancellationError) { errorMessage = "导出失败：\(error.localizedDescription)" }
            }
        }
    }

    func cancelExport() { exportTask?.cancel() }

    func revealExport() {
        if let lastExportURL { NSWorkspace.shared.activateFileViewerSelecting([lastExportURL]) }
    }
}
