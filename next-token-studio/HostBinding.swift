import Foundation

nonisolated struct ChannelHostBinding: Codable, Equatable {
    let channel: Int
    let hostID: String
}

nonisolated struct DeviceHostBindings: Codable, Equatable {
    let deviceUID: String
    let channelNames: [String]
    let assignments: [ChannelHostBinding]

    func hostIDs(uid: String, channels: [String], hosts: [StudioHost]) -> [String?] {
        guard deviceUID == uid, channelNames == channels else { return Array(repeating: nil, count: channels.count) }
        let known = Set(hosts.map(\.id))
        return channels.indices.map { index in assignments.first { $0.channel == index && known.contains($0.hostID) }?.hostID }
    }
}

nonisolated struct MicrophoneCatalog: Codable {
    var version = 1
    var devices: [DeviceHostBindings] = []

    static func read(from url: URL) throws -> Self {
        guard FileManager.default.fileExists(atPath: url.path) else { return Self() }
        let value = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        guard value.version == 1, Set(value.devices.map(\.deviceUID)).count == value.devices.count else {
            throw WorkspaceData.failure("麦克风绑定文件版本无效，或设备 ID 重复。")
        }
        for device in value.devices {
            guard Set(device.assignments.map(\.channel)).count == device.assignments.count,
                  Set(device.assignments.map(\.hostID)).count == device.assignments.count,
                  device.assignments.allSatisfy({ device.channelNames.indices.contains($0.channel) && !$0.hostID.isEmpty }) else {
                throw WorkspaceData.failure("麦克风绑定文件中存在重复或无效的通道。")
            }
        }
        return value
    }

    mutating func save(_ device: DeviceHostBindings, to url: URL) throws {
        devices.removeAll { $0.deviceUID == device.deviceUID }
        devices.append(device)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

nonisolated enum HostNameMatcher {
    static func normalized(_ value: String) -> String {
        let simplified = value.applyingTransform(StringTransform("Traditional-Simplified"), reverse: false) ?? value
        return simplified.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
    }

    static func names(_ host: StudioHost) -> [String] {
        [host.name] + (host.aliases ?? [])
    }

    // A name mentioned in ordinary conversation isn't proof of the speaker's identity.
    static func identify(_ transcript: String, hosts: [StudioHost]) -> String? {
        let text = normalized(transcript)
        let mentioned = hosts.filter { host in
            names(host).contains { name in
                let name = normalized(name)
                return !name.isEmpty && text.contains(name)
            }
        }
        guard mentioned.count == 1, let host = mentioned.first else { return nil }
        let introductions = ["我是", "我叫", "我的名字是", "我是主播", "我是主理人"]
        let identifiesSelf = names(host).contains { name in
            let name = normalized(name)
            return text == name || introductions.contains { text.contains($0 + name) }
        }
        return identifiesSelf ? host.id : nil
    }
}

nonisolated struct BindingDraft {
    private(set) var hostIDs: [String?]
    private(set) var protectedChannels: Set<Int>

    init(saved: [String?]) {
        hostIDs = saved
        protectedChannels = Set(saved.indices.filter { saved[$0] != nil })
    }

    mutating func manuallyAssign(_ hostID: String?, channel: Int) {
        guard hostIDs.indices.contains(channel) else { return }
        if let hostID {
            for index in hostIDs.indices where index != channel && hostIDs[index] == hostID {
                hostIDs[index] = nil
                protectedChannels.insert(index)
            }
        }
        hostIDs[channel] = hostID
        protectedChannels.insert(channel)
    }

    mutating func allowAutomatic(channel: Int) {
        guard hostIDs.indices.contains(channel) else { return }
        hostIDs[channel] = nil
        protectedChannels.remove(channel)
    }

    mutating func automaticallyAssign(_ hostID: String, channel: Int) -> Bool {
        guard hostIDs.indices.contains(channel), !protectedChannels.contains(channel),
              hostIDs[channel] == nil || hostIDs[channel] == hostID,
              !hostIDs.indices.contains(where: { $0 != channel && hostIDs[$0] == hostID }) else { return false }
        hostIDs[channel] = hostID
        return true
    }
}
