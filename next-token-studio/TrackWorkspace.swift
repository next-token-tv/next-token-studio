import SwiftUI

struct TrackWorkspace: View {
    let names: [String]
    let waveforms: [[Float]]
    let peaks: [Float]
    let isPlayback: Bool
    let paused: Bool
    let duration: TimeInterval
    let position: TimeInterval
    let seek: (TimeInterval) -> Void
    private let labelWidth: CGFloat = 185
    private let colors: [Color] = [.blue, .teal, .purple, .orange, .pink, .indigo]
    private var progress: Double { duration > 0 ? min(1, max(0, position / duration)) : 0 }

    var body: some View {
        GeometryReader { geometry in
            if names.isEmpty {
                ContentUnavailableView("没有可用音轨", systemImage: "waveform", description: Text("选择输入设备，或从左侧打开一段录音。"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                let rowHeight = max(54, min(110, (geometry.size.height - 100) / CGFloat(names.count)))
                ScrollView {
                    VStack(spacing: 0) {
                        HStack(spacing: 0) {
                            Text(isPlayback ? "音轨 / 峰值" : "输入 / 实时电平")
                                .frame(width: labelWidth, alignment: .leading)
                            HStack {
                                ForEach(0..<5) { tick in
                                    Text(isPlayback ? timeLabel(duration * Double(tick) / 4) : (tick == 4 ? "当前" : "−\(8 - tick * 2)s"))
                                    if tick < 4 { Spacer(minLength: 0) }
                                }
                            }
                        }.font(.caption2).foregroundStyle(.secondary).frame(height: 32)
                        VStack(spacing: 0) {
                            ForEach(names.indices, id: \.self) { index in
                                HStack(spacing: 0) {
                                    channelLabel(index)
                                        .frame(width: labelWidth, alignment: .leading)
                                    TrackWaveform(samples: waveforms.indices.contains(index) ? waveforms[index] : [], live: !isPlayback, color: colors[index % colors.count], progress: progress)
                                        .contentShape(Rectangle())
                                        .gesture(DragGesture(minimumDistance: 0).onChanged { event in
                                            guard isPlayback, duration > 0 else { return }
                                            let width = max(1, geometry.size.width - 48 - labelWidth)
                                            seek(min(1, max(0, event.location.x / width)) * duration)
                                        })
                                        .accessibilityLabel("通道 \(index + 1)，\(names[index])，\(isPlayback ? "完整录音波形" : "实时波形")")
                                        .accessibilityValue(isPlayback ? "播放位置 \(timeLabel(position))" : levelLabel(index))
                                }.frame(height: rowHeight)
                                Divider()
                            }
                        }
                        .overlay(alignment: .topLeading) {
                            if isPlayback {
                                GeometryReader { tracks in
                                    let x = labelWidth + (tracks.size.width - labelWidth) * progress
                                    Path { path in
                                        path.move(to: CGPoint(x: x, y: 0))
                                        path.addLine(to: CGPoint(x: x, y: tracks.size.height))
                                    }.stroke(Color.primary.opacity(0.7), lineWidth: 1)
                                    Image(systemName: "arrowtriangle.down.fill")
                                        .font(.system(size: 9)).foregroundStyle(.primary)
                                        .position(x: x, y: 0)
                                }.allowsHitTesting(false)
                            }
                        }
                        HStack {
                            Text(isPlayback ? "各路波形与播放位置同步" : "最近 8 秒")
                            Spacer()
                            Text("对数波形 · −60 至 0 dBFS")
                        }.font(.caption2).foregroundStyle(.secondary).padding(.top, 14)
                    }.padding(.horizontal, 24).padding(.top, 12).padding(.bottom, 16)
                }
            }
        }
    }

    private func channelLabel(_ index: Int) -> some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2).fill(colors[index % colors.count]).frame(width: 3, height: 36)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    Text("\(index + 1)").font(.system(size: 11, weight: .semibold)).foregroundStyle(colors[index % colors.count])
                    Text(names[index]).font(.system(size: 12, weight: .medium)).lineLimit(2)
                }
                Text(levelLabel(index)).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
        }
    }

    private func levelLabel(_ index: Int) -> String {
        guard peaks.indices.contains(index) else { return "等待录音" }
        let peak = peaks[index]
        if peak < 0.00001 { return "无信号" }
        let value = String(format: "%.1f dBFS", 20 * log10(peak))
        return isPlayback ? "峰值 \(value)" : (paused ? "已暂停" : value)
    }
}

private struct TrackWaveform: View {
    let samples: [Float]
    let live: Bool
    let color: Color
    let progress: Double

    var body: some View {
        Canvas { context, size in
            let center = size.height / 2
            var grid = Path()
            for tick in 0...4 {
                let x = size.width * CGFloat(tick) / 4
                grid.move(to: CGPoint(x: x, y: 0))
                grid.addLine(to: CGPoint(x: x, y: size.height))
            }
            context.stroke(grid, with: .color(.secondary.opacity(0.13)), lineWidth: 1)
            var baseline = Path()
            baseline.move(to: CGPoint(x: 0, y: center))
            baseline.addLine(to: CGPoint(x: size.width, y: center))
            context.stroke(baseline, with: .color(color.opacity(0.22)), lineWidth: 1)
            let slots = live ? CaptureWriter.waveformCapacity : max(1, samples.count)
            let columns = min(slots, max(1, Int(size.width)))
            let step = size.width / CGFloat(columns)
            var played = Path()
            var remaining = Path()
            for column in 0..<columns {
                let from = column * slots / columns
                let to = max(from + 1, (column + 1) * slots / columns)
                var peak: Float = 0
                for slot in from..<min(to, slots) {
                    let index = live ? slot - (CaptureWriter.waveformCapacity - samples.count) : slot
                    if samples.indices.contains(index) { peak = max(peak, samples[index]) }
                }
                guard peak > 0.000001 else { continue }
                let level = max(0, min(1, (20 * log10(peak) + 60) / 60))
                let height = max(1, CGFloat(level) * (size.height - 18))
                let x = (CGFloat(column) + 0.5) * step
                var bar = Path()
                bar.move(to: CGPoint(x: x, y: center - height / 2))
                bar.addLine(to: CGPoint(x: x, y: center + height / 2))
                if !live && x <= size.width * progress { played.addPath(bar) } else { remaining.addPath(bar) }
            }
            let style = StrokeStyle(lineWidth: max(1, step * 0.65), lineCap: .round)
            context.stroke(remaining, with: .color(color.opacity(live ? 0.9 : 0.45)), style: style)
            context.stroke(played, with: .color(color), style: style)
        }
        .background(color.opacity(0.035))
        .clipped()
    }
}
