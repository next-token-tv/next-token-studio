import AppKit
@preconcurrency import AVFoundation
@preconcurrency import Speech
import Observation

@MainActor @Observable
final class HostMatchingSession {
    let device: InputDevice
    let hosts: [StudioHost]
    private(set) var draft: BindingDraft
    var peaks: [Float]
    var transcripts: [String]
    var notes: [String]
    var status = "正在准备麦克风…"
    var error: String?
    private(set) var isListening = false
    private(set) var isStarting = false
    private var engine: AVAudioEngine?
    private var capture: MatchingAudio?
    private var timer: Timer?
    private var recognizer: SFSpeechRecognizer?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var timeout: Task<Void, Never>?
    private var pending: [MatchingUtterance] = []
    private var activeChannel: Int?
    private var activeText = ""
    private var generation = UUID()
    private var recognitionID = UUID()

    init(device: InputDevice, hosts: [StudioHost], saved: [String?]) {
        self.device = device
        self.hosts = hosts
        draft = BindingDraft(saved: saved)
        peaks = Array(repeating: 0, count: device.channelCount)
        transcripts = Array(repeating: "", count: device.channelCount)
        notes = saved.map { $0 == nil ? "等待自我介绍" : "已保存的绑定" }
    }

    func start() async {
        guard !isStarting, !isListening else { return }
        isStarting = true
        let token = UUID()
        generation = token
        defer { if generation == token { isStarting = false } }
        let mic = await AVCaptureDevice.requestAccess(for: .audio)
        guard generation == token else { return }
        guard mic else { error = "麦克风权限未开启，可以先手工选择主播。"; status = "麦克风不可用"; return }
        let authorization = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard generation == token else { return }
        guard authorization == .authorized else {
            error = "请在系统设置 → 隐私与安全性 → 语音识别中允许 Next Token Studio；也可以手工匹配。"
            status = "语音识别未授权"
            return
        }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN")), recognizer.isAvailable else {
            error = "系统中文语音识别暂不可用，请稍后重试或手工匹配。"
            status = "语音识别不可用"
            return
        }
        do {
            guard AudioInputs.available().contains(where: { $0 == device }) else { throw WorkspaceData.failure("输入设备或通道已改变，请关闭后重新选择设备。") }
            let engine = AVAudioEngine()
            let input = engine.inputNode
            try input.auAudioUnit.setDeviceID(device.id)
            let format = try AudioInputs.captureFormat(input: input, device: device)
            guard input.auAudioUnit.deviceID == device.id, Int(format.channelCount) == device.channelCount,
                  format.sampleRate > 0, format.sampleRate <= 192_000,
                  format.commonFormat == .pcmFormatFloat32, !format.isInterleaved else {
                throw WorkspaceData.failure("无法打开所选设备的全部通道。")
            }
            let capture = MatchingAudio(format: format)
            input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
                if let utterance = capture.append(buffer) {
                    Task { @MainActor [weak self] in
                        guard let self, self.generation == token else { return }
                        self.enqueue(utterance)
                    }
                }
            }
            do { try engine.start() } catch { input.removeTap(onBus: 0); throw error }
            self.engine = engine
            self.capture = capture
            self.recognizer = recognizer
            error = nil
            isListening = true
            status = "正在聆听，请依次说出自己的名字"
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in self?.updateLevels() }
            }
        } catch { self.error = error.localizedDescription; status = "无法开始自动匹配" }
    }

    private func updateLevels() {
        guard let capture else { return }
        let snapshot = capture.snapshot()
        peaks = snapshot.peaks
        if snapshot.formatChanged || engine?.isRunning == false || Date().timeIntervalSince(snapshot.lastInput) > 3 {
            stop()
            error = "麦克风输入中断或格式已改变，请检查设备后重新打开匹配。已有结果仍可手工调整。"
        }
    }

    private func enqueue(_ utterance: MatchingUtterance) {
        guard isListening else { return }
        guard let channel = utterance.channel else {
            status = "多路声音接近，请靠近自己的麦克风并依次说话"
            return
        }
        guard !draft.protectedChannels.contains(channel) else { return }
        guard pending.count < 2 else { status = "正在处理前面的自我介绍，请稍候再说"; return }
        pending.append(utterance)
        processNext()
    }

    private func processNext() {
        guard isListening, activeChannel == nil, !pending.isEmpty, let recognizer else { return }
        let utterance = pending.removeFirst()
        guard let channel = utterance.channel else { processNext(); return }
        guard !draft.protectedChannels.contains(channel) else { processNext(); return }
        let format = AVAudioFormat(standardFormatWithSampleRate: utterance.sampleRate, channels: 1)!
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(utterance.samples.count)) else { return }
        buffer.frameLength = buffer.frameCapacity
        utterance.samples.withUnsafeBufferPointer { source in
            if let source = source.baseAddress { buffer.floatChannelData![0].update(from: source, count: utterance.samples.count) }
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .confirmation
        request.contextualStrings = Array(Set(hosts.flatMap { host in
            HostNameMatcher.names(host).flatMap { name in
                let simplified = HostNameMatcher.normalized(name)
                return [name, simplified, "我是" + simplified, "我叫" + simplified]
            }
        })).sorted()
        // Let the system choose online or on-device recognition; no mode selection is needed.
        self.request = request
        activeChannel = channel
        activeText = ""
        let id = UUID()
        recognitionID = id
        status = "正在识别通道 \(channel + 1)…"
        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let final = result?.isFinal == true
            let message = error?.localizedDescription
            Task { @MainActor [weak self] in
                guard let self, self.recognitionID == id, self.activeChannel == channel else { return }
                if let text { self.activeText = text; self.transcripts[channel] = text }
                if final { self.completeRecognition(channel: channel, text: self.activeText, error: nil) }
                else if let message { self.completeRecognition(channel: channel, text: nil, error: message) }
            }
        }
        request.append(buffer)
        request.endAudio()
        timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(15)) } catch { return }
            guard let self, self.recognitionID == id else { return }
            self.completeRecognition(channel: channel, text: nil, error: "识别超时，请重说或手工选择。")
        }
    }

    private func completeRecognition(channel: Int, text: String?, error: String?) {
        recognitionID = UUID()
        timeout?.cancel(); timeout = nil
        recognitionTask?.cancel(); recognitionTask = nil
        request = nil
        activeChannel = nil
        if let text, let hostID = HostNameMatcher.identify(text, hosts: hosts) {
            if draft.automaticallyAssign(hostID, channel: channel) {
                notes[channel] = "自动匹配成功"
            } else if !draft.protectedChannels.contains(channel) {
                notes[channel] = "识别结果与已有绑定冲突，请手工确认"
            }
        } else if !draft.protectedChannels.contains(channel) {
            notes[channel] = error.map { "识别失败：\($0)" } ?? "未确认姓名，请说「我是…」或手工选择"
        }
        status = "正在聆听，请依次说出自己的名字"
        processNext()
    }

    func manuallyAssign(_ id: String?, channel: Int) {
        let previous = draft.hostIDs
        draft.manuallyAssign(id, channel: channel)
        for index in previous.indices where index != channel && previous[index] != draft.hostIDs[index] {
            notes[index] = "该主播已移到其他通道"
        }
        notes[channel] = id == nil ? "手工设为未绑定" : "手工绑定，不会被自动覆盖"
    }

    func retry(channel: Int) {
        pending.removeAll { $0.channel == channel }
        if activeChannel == channel {
            recognitionID = UUID()
            timeout?.cancel(); timeout = nil
            recognitionTask?.cancel(); recognitionTask = nil
            request = nil
            activeChannel = nil
        }
        draft.allowAutomatic(channel: channel)
        notes[channel] = "等待自我介绍"
        transcripts[channel] = ""
        processNext()
    }

    func stop() {
        generation = UUID()
        recognitionID = UUID()
        isStarting = false
        isListening = false
        engine?.stop()
        engine?.inputNode.removeTap(onBus: 0)
        engine = nil
        capture = nil
        timer?.invalidate(); timer = nil
        timeout?.cancel(); timeout = nil
        recognitionTask?.cancel(); recognitionTask = nil
        request?.endAudio(); request = nil
        recognizer = nil
        pending = []
        activeChannel = nil
        peaks = Array(repeating: 0, count: device.channelCount)
        status = "已停止聆听"
    }
}
