import SwiftUI

struct HostMatchingView: View {
    @Bindable var studio: AudioStudio
    @State private var session: HostMatchingSession
    @State private var saveError: String?
    @Environment(\.dismiss) private var dismiss

    init(studio: AudioStudio, device: InputDevice) {
        self.studio = studio
        _session = State(initialValue: HostMatchingSession(device: device, hosts: studio.workspace.hosts, saved: studio.workspace.hostIDs(for: device)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("匹配主播与麦克风").font(.title2.bold())
                    Text("\(session.device.name) · \(session.device.channelCount) 路输入").foregroundStyle(.secondary)
                }
                Spacer()
                Label(session.isListening ? "正在聆听" : "手工匹配", systemImage: session.isListening ? "mic.fill" : "person.crop.circle")
                    .font(.caption).foregroundStyle(session.isListening ? .green : .secondary)
            }
            Text("请各位依次对自己的麦克风说「我是\(session.hosts.first?.name ?? "主播姓名")」并停顿一下。识别后会自动选择主播，也可以直接手工调整。")
                .font(.callout).foregroundStyle(.secondary)
            ScrollView {
                VStack(spacing: 12) {
                    ForEach(session.device.channelNames.indices, id: \.self) { channel in channelRow(channel) }
                }
            }
            Text(session.status).font(.caption).foregroundStyle(.secondary)
            if let error = saveError ?? session.error ?? studio.workspace.bindingError {
                Text(error).font(.callout).foregroundStyle(.orange).textSelection(.enabled)
            }
            Divider()
            HStack {
                if session.isListening || session.isStarting {
                    Button("停止聆听") { session.stop() }
                } else {
                    Button("开始自动匹配") { Task { await session.start() } }
                }
                Text("手工选择不会被自动覆盖").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("取消") { session.stop(); dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存绑定") { save() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(session.isStarting)
            }
        }
        .padding(24)
        .frame(width: 800, height: min(760, max(470, CGFloat(session.device.channelCount) * 120 + 260)))
        .task { await session.start() }
        .onDisappear { session.stop(); studio.isMatching = false }
        .interactiveDismissDisabled()
    }

    private func channelRow(_ channel: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("通道 \(channel + 1)").font(.headline)
                    Text(session.device.channelNames[channel]).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }.frame(width: 180, alignment: .leading)
                VStack(spacing: 4) {
                    ProgressView(value: level(session.peaks[channel])).tint(.green)
                    Text(session.peaks[channel] > 0.00001 ? String(format: "%.1f dBFS", 20 * log10(session.peaks[channel])) : "无信号")
                        .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                }.frame(width: 90)
                if let id = session.draft.hostIDs[channel], let image = studio.workspace.avatars[id] {
                    Image(nsImage: image).resizable().scaledToFill().frame(width: 34, height: 34).clipShape(Circle())
                } else {
                    Image(systemName: "person.crop.circle.dashed").font(.system(size: 30)).foregroundStyle(.tertiary).frame(width: 34)
                }
                Picker("主播", selection: Binding(get: { session.draft.hostIDs[channel] ?? "" }, set: { session.manuallyAssign($0.isEmpty ? nil : $0, channel: channel) })) {
                    Text("未绑定").tag("")
                    ForEach(session.hosts) { host in Text(host.name).tag(host.id) }
                }.labelsHidden().accessibilityLabel("通道 \(channel + 1) 的主播")
                Button { session.retry(channel: channel) } label: { Image(systemName: "arrow.clockwise") }
                    .help("清除此路绑定，重新识别").accessibilityLabel("重新识别通道 \(channel + 1)")
            }
            if !session.transcripts[channel].isEmpty {
                Text("“\(session.transcripts[channel])”").font(.callout).lineLimit(2).textSelection(.enabled)
            }
            Text(session.notes[channel]).font(.caption).foregroundStyle(.secondary)
        }.padding(14).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }

    private func level(_ peak: Float) -> Double {
        guard peak > 0 else { return 0 }
        return min(1, max(0, (20 * log10(Double(peak)) + 60) / 60))
    }

    private func save() {
        guard AudioInputs.available().contains(session.device) else {
            saveError = "输入设备或通道已改变，请重新打开匹配。"
            return
        }
        do {
            try studio.workspace.saveBindings(session.draft.hostIDs, for: session.device)
            session.stop()
            dismiss()
        } catch { saveError = error.localizedDescription }
    }
}
