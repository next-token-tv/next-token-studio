import AppKit
import AVFoundation
import Observation

struct Recording: Identifiable, Hashable {
    var id: URL { url }
    let url: URL
    let createdAt: Date
    var name: String { url.deletingPathExtension().lastPathComponent }
}

@MainActor @Observable
final class AudioStudio: NSObject, AVAudioRecorderDelegate, AVAudioPlayerDelegate {
    var recordings: [Recording] = []
    var selectedID: URL?
    var isRecording = false
    var isPaused = false
    var isRequestingPermission = false
    var elapsed: TimeInterval = 0
    var level: Double = 0
    var playingID: URL?
    var errorMessage: String?
    private var recorder: AVAudioRecorder?
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
            let recording = try AVAudioRecorder(url: url, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
            ])
            recording.delegate = self
            recording.isMeteringEnabled = true
            guard recording.prepareToRecord(), recording.record() else {
                try? FileManager.default.removeItem(at: url)
                throw NSError(domain: "AudioStudio", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法启动麦克风，请检查输入设备。"])
            }
            recorder = recording
            isRecording = true
            isPaused = false
            elapsed = 0
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in self?.updateMeter() }
            }
        } catch { errorMessage = "录音失败：\(error.localizedDescription)" }
    }

    private func updateMeter() {
        guard let recorder, isRecording, !isPaused else { return }
        elapsed = recorder.currentTime
        recorder.updateMeters()
        level = max(0, min(1, pow(10, Double(recorder.averagePower(forChannel: 0)) / 20)))
    }

    func togglePause() {
        guard let recorder, isRecording else { return }
        if isPaused {
            guard recorder.record() else { errorMessage = "无法继续录音，请停止并保存。"; return }
        } else { recorder.pause() }
        isPaused.toggle()
        level = 0
    }

    func stopRecording() {
        guard isRecording else { return }
        recorder?.stop()
        finishRecording()
    }

    private func finishRecording() {
        timer?.invalidate()
        timer = nil
        isRecording = false
        isPaused = false
        level = 0
    }

    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        let url = recorder.url
        Task { @MainActor [weak self] in
            guard let self else { return }
            finishRecording()
            self.recorder = nil
            if flag {
                reload()
                selectedID = url
            } else { errorMessage = "录音未能完整保存，请检查可用磁盘空间。" }
        }
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: (any Error)?) {
        let message = error?.localizedDescription ?? "编码失败"
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.recorder?.stop()
            finishRecording()
            errorMessage = "录音出现错误：\(message)"
        }
    }

    func togglePlayback(_ recording: Recording) {
        guard !isBusy else { return }
        if playingID == recording.id { stopPlayback(); return }
        stopPlayback()
        do {
            let audio = try AVAudioPlayer(contentsOf: recording.url)
            audio.delegate = self
            guard audio.play() else { throw NSError(domain: "AudioStudio", code: 2, userInfo: [NSLocalizedDescriptionKey: "无法播放此文件。"]) }
            player = audio
            playingID = recording.id
        } catch { errorMessage = "播放失败：\(error.localizedDescription)" }
    }

    func stopPlayback() { player?.stop(); player = nil; playingID = nil }
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in self?.stopPlayback() }
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
