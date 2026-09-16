import SwiftUI

struct ContentView: View {
    @Bindable var studio: AudioStudio
    @State private var section: String? = "record"

    var body: some View {
        NavigationSplitView {
            List(selection: $section) {
                Section("工作区") {
                    Label("音频录制", systemImage: "mic").tag("record")
                }
                Section("资料库") {
                    Label("所有录音", systemImage: "waveform").badge(studio.recordings.count).tag("library")
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 300)
            .safeAreaInset(edge: .bottom) {
                Label("Next Token Studio", systemImage: "waveform.circle")
                    .font(.footnote).foregroundStyle(.secondary).padding()
            }
        } detail: {
            VStack(spacing: 0) {
                if section == "record" { recorderPanel }
                recordingList
                if studio.playingID != nil { playerPanel }
            }
            .navigationTitle(section == "record" ? "音频录制" : "所有录音")
            .toolbar {
                ToolbarItem {
                    Button { Task { await studio.startRecording() } } label: {
                        Label("新建录音", systemImage: "mic.badge.plus")
                    }.disabled(studio.isBusy)
                }
                ToolbarItem {
                    Button {
                        if let recording = studio.selected { studio.export(recording) }
                    } label: { Label("导出录音", systemImage: "square.and.arrow.up") }
                    .disabled(studio.selected == nil)
                }
            }
        }
        .alert("无法完成操作", isPresented: Binding(get: { studio.errorMessage != nil }, set: { if !$0 { studio.errorMessage = nil } })) {
            Button("好") { studio.errorMessage = nil }
        } message: { Text(studio.errorMessage ?? "") }
    }

    private var recorderPanel: some View {
        VStack(spacing: 16) {
            Picker("输入音源", selection: $studio.selectedInputID) {
                if studio.inputDevices.isEmpty { Text("没有可用的输入设备").tag(UInt32(0)) }
                ForEach(studio.inputDevices) { device in Text(device.name).tag(device.id) }
            }
            .frame(maxWidth: 420)
            .disabled(studio.isBusy)
            Label(studio.isRecording ? (studio.isPaused ? "录音已暂停" : "正在录音") : "准备录制", systemImage: "mic.fill")
                .font(.headline).foregroundStyle(studio.isRecording ? .red : .secondary)
            Text(studio.clock).font(.system(size: 54, weight: .light, design: .monospaced)).monospacedDigit()
            VStack(spacing: 6) {
                LiveWaveform(samples: studio.waveform, paused: studio.isPaused)
                    .frame(height: 88)
                    .accessibilityLabel("所选音源最近八秒的录音波形")
                HStack {
                    Text("−8 秒")
                    Spacer()
                    Text(studio.isPaused ? "已暂停" : "当前")
                }.font(.caption2).foregroundStyle(.secondary)
            }.frame(maxWidth: 620)
            HStack(spacing: 14) {
                if studio.isRecording {
                    Button { studio.togglePause() } label: {
                        Label(studio.isPaused ? "继续" : "暂停", systemImage: studio.isPaused ? "play.fill" : "pause.fill")
                    }
                    Button(role: .destructive) { studio.stopRecording() } label: {
                        Label("停止并保存", systemImage: "stop.fill")
                    }.buttonStyle(.borderedProminent).tint(.red)
                } else {
                    Button { Task { await studio.startRecording() } } label: {
                        Label(studio.isRequestingPermission ? "等待麦克风授权…" : "开始录音", systemImage: "record.circle")
                    }.buttonStyle(.borderedProminent).tint(.red).disabled(studio.isRequestingPermission || studio.inputDevices.isEmpty)
                }
            }.controlSize(.large)
            Text("AAC / 48 kHz · 录音保存在本机")
                .font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity).padding(32)
    }

    private var playerPanel: some View {
        VStack(spacing: 12) {
            Divider()
            HStack(spacing: 16) {
                Button {
                    if let recording = studio.recordings.first(where: { $0.id == studio.playingID }) {
                        studio.togglePlayback(recording)
                    }
                } label: {
                    Image(systemName: studio.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title2).frame(width: 36, height: 36)
                }
                .buttonStyle(.borderedProminent)
                .clipShape(Circle())
                .help(studio.isPlaying ? "暂停播放" : "继续播放")
                VStack(alignment: .leading, spacing: 8) {
                    Text(studio.playingID?.deletingPathExtension().lastPathComponent ?? "录音")
                        .font(.headline).lineLimit(1)
                    Slider(value: Binding(get: { studio.playbackTime }, set: { studio.seek(to: $0) }), in: 0...max(studio.playbackDuration, 0.01))
                        .accessibilityLabel("播放进度")
                    HStack {
                        Text(playbackClock(studio.playbackTime))
                        Spacer()
                        Text(playbackClock(studio.playbackDuration))
                    }.font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                Button { studio.stopPlayback() } label: { Image(systemName: "stop.fill") }
                    .help("停止播放")
            }.padding(.horizontal, 24).padding(.bottom, 18)
        }.background(.bar)
    }

    private func playbackClock(_ time: TimeInterval) -> String {
        let seconds = Int(max(0, time))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    private var recordingList: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider()
            Text("录音资料库").font(.headline).padding()
            if studio.recordings.isEmpty {
                ContentUnavailableView("还没有录音", systemImage: "waveform", description: Text("开始录音，停止后会自动保存到这里。"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $studio.selectedID) {
                    ForEach(studio.recordings) { recording in
                        HStack(spacing: 12) {
                            Image(systemName: "waveform").foregroundStyle(.red).font(.title2)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(recording.name)
                                Text(recording.createdAt, format: .dateTime.year().month().day().hour().minute())
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button { studio.togglePlayback(recording) } label: {
                                Image(systemName: studio.playingID == recording.id && studio.isPlaying ? "pause.fill" : "play.fill")
                            }.help(studio.playingID == recording.id && studio.isPlaying ? "暂停播放" : "播放录音").disabled(studio.isBusy)
                        }.padding(.vertical, 6).tag(recording.id)
                        .contextMenu {
                            Button("导出录音…") { studio.export(recording) }
                        }
                    }
                }
            }
        }
    }
}


private struct LiveWaveform: View {
    let samples: [Float]
    let paused: Bool

    var body: some View {
        Canvas { context, size in
            let center = size.height / 2
            var baseline = Path()
            baseline.move(to: CGPoint(x: 0, y: center))
            baseline.addLine(to: CGPoint(x: size.width, y: center))
            context.stroke(baseline, with: .color(.secondary.opacity(0.25)), lineWidth: 1)
            let step = size.width / 200
            var bars = Path()
            for (index, amplitude) in samples.suffix(200).enumerated() {
                let x = CGFloat(200 - min(samples.count, 200) + index) * step
                let height = max(1, CGFloat(amplitude) * (size.height - 12))
                bars.move(to: CGPoint(x: x, y: center - height / 2))
                bars.addLine(to: CGPoint(x: x, y: center + height / 2))
            }
            context.stroke(bars, with: .color(paused ? .secondary : .red), style: StrokeStyle(lineWidth: max(1, step * 0.65), lineCap: .round))
        }
        .padding(.horizontal, 10)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }
}
