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
        VStack(spacing: 20) {
            Label(studio.isRecording ? (studio.isPaused ? "录音已暂停" : "正在录音") : "准备录制", systemImage: "mic.fill")
                .font(.headline).foregroundStyle(studio.isRecording ? .red : .secondary)
            Text(studio.clock).font(.system(size: 54, weight: .light, design: .monospaced)).monospacedDigit()
            ProgressView(value: studio.level).tint(.red).frame(maxWidth: 320)
                .accessibilityLabel("麦克风音量")
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
                    }.buttonStyle(.borderedProminent).tint(.red).disabled(studio.isRequestingPermission)
                }
            }.controlSize(.large)
            Text("系统默认麦克风 · AAC / 48 kHz · 录音保存在本机")
                .font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity).padding(32)
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
                                Image(systemName: studio.playingID == recording.id ? "stop.fill" : "play.fill")
                            }.help(studio.playingID == recording.id ? "停止播放" : "播放录音").disabled(studio.isBusy)
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
