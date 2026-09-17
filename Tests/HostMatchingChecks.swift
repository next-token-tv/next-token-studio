import Foundation
import AVFoundation

@main
struct HostMatchingChecks {
    static func main() throws {
        let hosts = [StudioHost(id: "yangpan", name: "杨攀", avatar: "x"), StudioHost(id: "guizang", name: "歸藏", avatar: "x"), StudioHost(id: "orange", name: "橘子", avatar: "x"), StudioHost(id: "qiaomu", name: "向阳乔木", avatar: "x", aliases: ["乔木"])]
        for (text, id) in [("大家好，我是杨攀。", "yangpan"), ("我叫归藏", "guizang"), ("我的名字是橘子", "orange"), ("我是乔木", "qiaomu"), ("歸藏", "guizang")] {
            precondition(HostNameMatcher.identify(text, hosts: hosts) == id, text)
        }
        for text in ["杨攀说得对", "我是杨攀，乔木在旁边", "我是新人", "", "不是杨攀"] {
            precondition(HostNameMatcher.identify(text, hosts: hosts) == nil, text)
        }
        var draft = BindingDraft(saved: [nil, nil, nil, nil, nil])
        precondition(draft.automaticallyAssign("yangpan", channel: 0))
        precondition(!draft.automaticallyAssign("yangpan", channel: 1))
        draft.manuallyAssign("yangpan", channel: 1)
        precondition(draft.hostIDs[0] == nil && draft.hostIDs[1] == "yangpan")
        precondition(!draft.automaticallyAssign("guizang", channel: 1))
        draft.manuallyAssign(nil, channel: 1)
        precondition(!draft.automaticallyAssign("yangpan", channel: 1))
        draft.allowAutomatic(channel: 1)
        precondition(draft.automaticallyAssign("guizang", channel: 1))
        print("PASS: Chinese introductions, traditional names and aliases; ambiguity rejection; manual precedence and uniqueness")

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("microphones.json")
        var catalog = try MicrophoneCatalog.read(from: url)
        let device = DeviceHostBindings(deviceUID: "A", channelNames: ["mic1", "mic2"], assignments: [ChannelHostBinding(channel: 0, hostID: "yangpan")])
        try catalog.save(device, to: url)
        try catalog.save(DeviceHostBindings(deviceUID: "B", channelNames: ["other"], assignments: []), to: url)
        let saved = try MicrophoneCatalog.read(from: url)
        precondition(saved.devices.count == 2)
        precondition(saved.devices[0].hostIDs(uid: "A", channels: ["mic1", "mic2"], hosts: hosts) == ["yangpan", nil])
        precondition(saved.devices[0].hostIDs(uid: "A", channels: ["mic2", "mic1"], hosts: hosts) == [nil, nil])
        precondition(saved.devices[0].hostIDs(uid: "B", channels: ["mic1", "mic2"], hosts: hosts) == [nil, nil])
        precondition(saved.devices[0].hostIDs(uid: "A", channels: ["mic1", "mic2"], hosts: []) == [nil, nil])
        try Data("broken".utf8).write(to: url)
        do { _ = try MicrophoneCatalog.read(from: url); fatalError("Corrupt catalog accepted") } catch {}
        print("PASS: persistent per-device bindings, changed topology and deleted hosts; corrupt data rejected")

        for rate in [44_100.0, 48_000.0] {
            for channels in [1, 4, 5] {
                let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | UInt32(channels))!
                let format = AVAudioFormat(standardFormatWithSampleRate: rate, channelLayout: layout)
                let capture = MatchingAudio(format: format)
                let selected = channels - 1
                func append(seconds: Double, amplitude: Float, crosstalk: Bool = false) -> [MatchingUtterance] {
                    var results: [MatchingUtterance] = []
                    var remaining = Int(rate * seconds)
                    while remaining > 0 {
                        let count = min(1024, remaining)
                        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
                        buffer.frameLength = AVAudioFrameCount(count)
                        for channel in 0..<channels {
                            for i in 0..<count { buffer.floatChannelData![channel][i] = amplitude * (channel == selected || crosstalk ? 1 : 0.1) }
                        }
                        if let result = capture.append(buffer) { results.append(result) }
                        remaining -= count
                    }
                    return results
                }
                precondition(append(seconds: 1, amplitude: 0).isEmpty)
                precondition(append(seconds: 0.5, amplitude: 0.1).isEmpty)
                let utterances = append(seconds: 0.8, amplitude: 0)
                precondition(utterances.count == 1 && utterances[0].channel == selected)
                precondition(utterances[0].samples.first == 0.1)
                if channels > 1 {
                    _ = append(seconds: 0.5, amplitude: 0.1, crosstalk: true)
                    let ambiguous = append(seconds: 0.8, amplitude: 0)
                    precondition(ambiguous.count == 1 && ambiguous[0].channel == nil)
                }
                let bounded = append(seconds: 8.5, amplitude: 0.1)
                precondition(bounded.count == 1 && bounded[0].samples.count == Int(rate * 8))
                print("PASS: \(channels) channels @ \(Int(rate)) Hz; dominant channel, silence, crosstalk rejection, 8 s bound")
            }
        }
    }
}
