import SwiftUI

struct ContentView: View {
    @Bindable var studio: AudioStudio
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    private var isPlayback: Bool { studio.playingID != nil }
    private var activeRecording: Recording? { studio.recordings.first { $0.id == studio.playingID } }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                Button { studio.showRecorder() } label: {
                    Label("录制新音频", systemImage: "mic.badge.plus")
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 7)
                }
                .buttonStyle(.bordered).controlSize(.large).padding(14)
                .disabled(studio.isBusy)
                List(selection: $studio.selectedID) {
                    Section {
                        ForEach(studio.recordings) { recording in
                            VStack(alignment: .leading, spacing: 7) {
                                HStack(spacing: 7) {
                                    Image(systemName: studio.playingID == recording.id && studio.isPlaying ? "speaker.wave.2.fill" : "waveform")
                                        .foregroundStyle(studio.playingID == recording.id ? Color.accentColor : .secondary)
                                    Text(recording.createdAt, format: .dateTime.month().day().hour().minute().second())
                                        .font(.system(size: 13, weight: .medium))
                                }
                                HStack {
                                    Text(recording.metadata.map { "\($0.channelNames.count) 路录音" } ?? "录音")
                                    Spacer()
                                    Text(recording.formatLabel)
                                }.font(.caption).foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 8).tag(recording.id)
                            .help(recording.name)
                            .contextMenu {
                                Button("导出分轨 WAV…") { studio.exportWAV(recording) }
                                    .disabled(studio.isBusy || studio.isExporting)
                                Button("导出混音 M4A…") { studio.exportM4A(recording) }
                                    .disabled(studio.isBusy || studio.isExporting)
                                Divider()
                                Button(role: .destructive) { studio.deleteRecording(recording) } label: {
                                    Label("移到废纸篓", systemImage: "trash")
                                }.disabled(studio.isBusy || studio.isExporting)
                            }
                        }
                    } header: {
                        HStack { Text("录音资料库"); Spacer(); Text("\(studio.recordings.count)") }
                    }
                }.listStyle(.sidebar).disabled(studio.isBusy)
                if studio.recordings.isEmpty {
                    Text("录制的音频会保存在这里")
                        .font(.caption).foregroundStyle(.secondary).padding()
                }
                if studio.workspace.root != nil {
                    Divider()
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("主播").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button { studio.workspace.reloadHosts() } label: { Image(systemName: "arrow.clockwise") }
                                .buttonStyle(.plain).help("重新读取主播资料")
                                .accessibilityLabel("重新读取主播资料")
                        }
                        Button { studio.beginMatching() } label: {
                            Label("匹配麦克风", systemImage: "person.wave.2")
                        }.disabled(studio.isBusy || studio.isExporting || studio.selectedInput == nil || studio.workspace.hosts.isEmpty)
                        if let error = studio.workspace.bindingError {
                            Text(error).font(.caption).foregroundStyle(.orange)
                        }
                        ScrollView {
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(studio.workspace.hosts) { host in
                                    HStack(spacing: 10) {
                                        if let image = studio.workspace.avatars[host.id] {
                                            Image(nsImage: image).resizable().scaledToFill()
                                                .frame(width: 30, height: 30).clipShape(Circle())
                                                .accessibilityHidden(true)
                                        }
                                        Circle().fill(HostPalette.color(host.color, scheme: colorScheme)).frame(width: 7, height: 7)
                                        Text(host.name).font(.callout)
                                    }
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.frame(maxHeight: 170)
                        if let error = studio.workspace.hostError {
                            Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                        }
                    }.padding(14)
                    Button { studio.workspace.reveal() } label: {
                        Label("打开工作文件夹", systemImage: "folder")
                    }.buttonStyle(.plain).font(.caption).padding(14)
                }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 320)
        } detail: {
            VStack(spacing: 0) {
                if studio.workspace.root == nil {
                    ContentUnavailableView {
                        Label("打开工作文件夹", systemImage: "folder")
                    } description: {
                        Text("录音、主播资料和导出保存在 Documents/Next Token Studio。")
                    } actions: {
                        Button(studio.workspace.isConnecting ? "正在准备…" : "选择工作文件夹") {
                            Task { await studio.openWorkspace() }
                        }.disabled(studio.workspace.isConnecting)
                        if let error = studio.workspace.error { Text(error).font(.caption).foregroundStyle(.red) }
                    }
                } else {
                workspaceHeader
                Divider()
                if studio.isPreparingPlayback {
                    VStack(spacing: 14) {
                        ProgressView()
                        Text("正在准备音频与波形…").font(.callout).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    TrackWorkspace(
                        names: isPlayback ? studio.playbackChannelNames : studio.displayedChannelNames,
                        waveforms: isPlayback ? studio.playbackWaveforms : studio.waveforms,
                        peaks: isPlayback ? studio.playbackPeaks : studio.channelPeaks,
                        hostColors: trackHostColors,
                        isPlayback: isPlayback,
                        paused: studio.isPaused,
                        duration: studio.playbackDuration,
                        position: studio.playbackTime,
                        seek: { studio.seek(to: $0) }
                    )
                }
                if let status = studio.signalStatus, !isPlayback {
                    Label(status, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 24).padding(.bottom, 12)
                }
                Divider()
                if isPlayback { playbackTransport } else { recordingTransport }
                if let status = studio.exportStatus {
                    HStack(spacing: 10) {
                        if studio.isExporting { ProgressView().controlSize(.small) }
                        else { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                        Text(status).font(.caption)
                        Spacer()
                        if studio.isExporting { Button("取消") { studio.cancelExport() } }
                        else {
                            Button("在 Finder 中显示") { studio.revealExport() }
                            Button { studio.exportStatus = nil } label: { Image(systemName: "xmark") }
                                .help("关闭导出提示")
                        }
                    }.padding(.horizontal, 24).padding(.vertical, 10).background(.bar)
                }
                }
            }
            .background(Color(nsColor: .windowBackgroundColor))
            .navigationTitle("Next Token Studio")
            .toolbar {
                ToolbarItem {
                    Button(role: .destructive) {
                        if let recording = studio.selected { studio.deleteRecording(recording) }
                    } label: { Label("删除录音", systemImage: "trash") }
                    .help("将所选录音和通道信息移到废纸篓")
                    .keyboardShortcut(.delete, modifiers: [.command])
                    .disabled(studio.selected == nil || studio.isBusy || studio.isExporting)
                }
                ToolbarItem {
                    Menu {
                        Button("导出分轨 WAV…") {
                            if let recording = studio.selected { studio.exportWAV(recording) }
                        }
                        Button("导出混音 M4A…") {
                            if let recording = studio.selected { studio.exportM4A(recording) }
                        }
                    } label: { Label("导出音频", systemImage: "square.and.arrow.up") }
                    .disabled(studio.selected == nil || studio.isBusy || studio.isExporting)
                }
            }
        }
        .sheet(isPresented: $studio.isMatching) {
            if let device = studio.selectedInput { HostMatchingView(studio: studio, device: device) }
        }
        .task { await studio.restoreWorkspace() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { studio.workspace.reloadHosts() }
        }
        .onChange(of: studio.selectedID) { _, selection in
            if let recording = studio.recordings.first(where: { $0.id == selection }) {
                studio.openRecording(recording)
            }
        }
        .alert("无法完成操作", isPresented: Binding(get: { studio.errorMessage != nil }, set: { if !$0 { studio.errorMessage = nil } })) {
            Button("好") { studio.errorMessage = nil }
        } message: { Text(studio.errorMessage ?? "") }
    }

    private var trackHostColors: [String?] {
        let ids: [String?]
        if isPlayback {
            // A recording retains its original identities even after the live device is rebound.
            ids = activeRecording?.metadata?.hostIDs ?? []
        } else {
            ids = studio.selectedInput.map { studio.workspace.hostIDs(for: $0) } ?? []
        }
        return ids.map { id in studio.workspace.hosts.first { $0.id == id }?.color }
    }

    private var workspaceHeader: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 7) {
                    Text(isPlayback ? "录音回放" : "多轨录音")
                        .font(.system(size: 23, weight: .semibold))
                    Text(isPlayback ? (activeRecording?.name ?? "录音") : "每一路输入，独立记录")
                        .font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if isPlayback {
                    Label("全部通道混合输出", systemImage: "speaker.wave.2")
                        .font(.caption).foregroundStyle(.blue).padding(.horizontal, 11).padding(.vertical, 7)
                        .background(.blue.opacity(0.08), in: Capsule())
                } else {
                    Label(studio.isRecording ? (studio.isPaused ? "已暂停" : "正在录音") : "准备录制", systemImage: studio.isRecording ? "record.circle" : "mic")
                        .font(.callout).foregroundStyle(studio.isRecording ? .red : .secondary)
                }
            }
            if isPlayback {
                HStack(spacing: 16) {
                    Label("\(studio.playbackChannelNames.count) 路音轨", systemImage: "waveform")
                    if let recording = activeRecording { Text(recording.formatLabel) }
                    if studio.playbackSampleRate > 0 { Text(String(format: "%.1f kHz", studio.playbackSampleRate / 1000)) }
                    Spacer()
                    Text("点击波形定位播放")
                }.font(.caption).foregroundStyle(.secondary)
            } else {
                HStack {
                    Picker("输入设备", selection: $studio.selectedInputID) {
                        if studio.inputDevices.isEmpty { Text("没有可用输入").tag(UInt32(0)) }
                        ForEach(studio.inputDevices) { device in
                            Text("\(device.name)（\(device.channelCount) 路）").tag(device.id)
                        }
                    }.disabled(studio.isBusy)
                    Spacer(minLength: 10)
                }
            }
        }.padding(24)
    }

    private var recordingTransport: some View {
        HStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text(studio.clock).font(.system(size: 27, weight: .medium, design: .monospaced)).monospacedDigit()
                Text("全部通道无损保存").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if studio.isRecording {
                Button { studio.togglePause() } label: {
                    Label(studio.isPaused ? "继续录音" : "暂停", systemImage: studio.isPaused ? "play.fill" : "pause.fill")
                }
                Button(role: .destructive) { studio.stopRecording() } label: {
                    Label("停止并保存", systemImage: "stop.fill")
                }.buttonStyle(.borderedProminent).tint(.red)
            } else {
                Button { Task { await studio.startRecording() } } label: {
                    Label(studio.isRequestingPermission ? "等待授权…" : "开始录音", systemImage: "record.circle")
                }.buttonStyle(.borderedProminent).tint(.red)
                    .disabled(studio.isRequestingPermission || studio.inputDevices.isEmpty)
            }
        }.controlSize(.large).padding(24).background(.bar)
    }

    private var playbackTransport: some View {
        VStack(spacing: 16) {
            HStack(spacing: 12) {
                Text(timeLabel(studio.playbackTime)).monospacedDigit().frame(width: 65, alignment: .leading)
                Slider(value: Binding(get: { studio.playbackTime }, set: { studio.seek(to: $0) }), in: 0...max(studio.playbackDuration, 0.01))
                    .accessibilityLabel("播放进度")
                Text(timeLabel(studio.playbackDuration)).monospacedDigit().frame(width: 65, alignment: .trailing).foregroundStyle(.secondary)
            }.font(.caption)
            HStack(spacing: 18) {
                Label("\(studio.playbackChannelNames.count) 路混合回放", systemImage: "speaker.wave.2.fill")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button { studio.rewindPlayback() } label: { Image(systemName: "backward.end.fill") }
                    .help("回到开头").accessibilityLabel("回到开头")
                Button {
                    if let recording = activeRecording { studio.togglePlayback(recording) }
                } label: {
                    Label(studio.isPlaying ? "暂停" : "播放", systemImage: studio.isPlaying ? "pause.fill" : "play.fill")
                        .frame(width: 80)
                }.buttonStyle(.borderedProminent).controlSize(.large)
                    .keyboardShortcut(.space, modifiers: [])
                Spacer()
                Text(studio.isPlaying ? "正在播放" : (studio.playbackTime >= studio.playbackDuration && studio.playbackDuration > 0 ? "播放结束" : "已暂停"))
                    .font(.caption).foregroundStyle(.secondary).frame(width: 90, alignment: .trailing)
            }
        }.disabled(studio.isPreparingPlayback).padding(24).background(.bar)
    }
}

func timeLabel(_ time: TimeInterval) -> String {
    let total = max(0, Int(time.isFinite ? time : 0))
    if total >= 3600 { return String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60) }
    return String(format: "%02d:%02d", total / 60, total % 60)
}
