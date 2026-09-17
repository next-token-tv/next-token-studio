import Foundation

nonisolated struct StudioHost: Codable, Identifiable, Equatable {
    let id: String
    let name: String
    let avatar: String
    var aliases: [String]? = nil
}

nonisolated struct HostCatalog: Codable {
    let version: Int
    let hosts: [StudioHost]
}

nonisolated enum WorkspaceData {
    static func initialize(root: URL, seed: URL) throws {
        let fm = FileManager.default
        for folder in ["recordings", "exports", "cache", "hosts"] {
            try fm.createDirectory(at: root.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        let catalog = root.appendingPathComponent("hosts/hosts.json")
        if !fm.fileExists(atPath: catalog.path) {
            let source = seed.appendingPathComponent("hosts")
            let avatars = root.appendingPathComponent("hosts/avatars")
            try fm.createDirectory(at: avatars, withIntermediateDirectories: true)
            for file in try fm.contentsOfDirectory(at: source.appendingPathComponent("avatars"), includingPropertiesForKeys: nil) {
                let target = avatars.appendingPathComponent(file.lastPathComponent)
                if !fm.fileExists(atPath: target.path) { try fm.copyItem(at: file, to: target) }
            }
            try fm.copyItem(at: source.appendingPathComponent("hosts.json"), to: catalog)
        }
        let readme = root.appendingPathComponent("README.md")
        if !fm.fileExists(atPath: readme.path) { try fm.copyItem(at: seed.appendingPathComponent("README.md"), to: readme) }
    }

    static func readHosts(root: URL) throws -> [StudioHost] {
        let catalog = try JSONDecoder().decode(HostCatalog.self, from: Data(contentsOf: root.appendingPathComponent("hosts/hosts.json")))
        guard catalog.version == 1 else { throw failure("不支持的主播资料版本。") }
        var ids = Set<String>()
        for host in catalog.hosts {
            guard !host.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !host.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  ids.insert(host.id).inserted else { throw failure("主播 ID 和名字不能为空，ID 不能重复。") }
            let avatar = try avatarURL(host, root: root)
            guard FileManager.default.fileExists(atPath: avatar.path) else { throw failure("找不到 \(host.name) 的头像：\(host.avatar)") }
        }
        return catalog.hosts
    }

    static func avatarURL(_ host: StudioHost, root: URL) throws -> URL {
        let directory = root.appendingPathComponent("hosts").resolvingSymlinksInPath().standardizedFileURL
        let url = directory.appendingPathComponent(host.avatar).resolvingSymlinksInPath().standardizedFileURL
        guard !host.avatar.hasPrefix("/"), url.path.hasPrefix(directory.path + "/") else {
            throw failure("头像必须位于工作文件夹的 hosts 目录内。")
        }
        return url
    }

    // Moves are resumable after interruption; conflicts never overwrite an existing recording.
    static func migrateRecordings(from legacy: URL, to root: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: legacy.path) else { return }
        let destination = root.appendingPathComponent("recordings")
        let files = try fm.contentsOfDirectory(at: legacy, includingPropertiesForKeys: [.isRegularFileKey])
            .filter { ["caf", "m4a", "json"].contains($0.pathExtension) && (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
        for file in files {
            let target = destination.appendingPathComponent(file.lastPathComponent)
            guard !fm.fileExists(atPath: target.path) else { throw failure("迁移遇到同名文件，未覆盖：\(file.lastPathComponent)") }
        }
        for file in files { try fm.moveItem(at: file, to: destination.appendingPathComponent(file.lastPathComponent)) }
    }

    static func failure(_ message: String) -> NSError {
        NSError(domain: "StudioWorkspace", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
