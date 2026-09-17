import Foundation

@main
struct WorkspaceChecks {
    static func main() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("studio-workspace-check-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: base) }
        let root = base.appendingPathComponent("workspace")
        let seed = URL(fileURLWithPath: CommandLine.arguments[1])
        try WorkspaceData.initialize(root: root, seed: seed)
        let hosts = try WorkspaceData.readHosts(root: root)
        precondition(hosts.map(\.name) == ["杨攀", "歸藏", "橘子", "向阳乔木"])
        let catalog = root.appendingPathComponent("hosts/hosts.json")
        let custom = StudioHost(id: "guest", name: "新主播", avatar: hosts[0].avatar)
        let updated = try JSONEncoder().encode(HostCatalog(version: 1, hosts: hosts + [custom]))
        try updated.write(to: catalog)
        try WorkspaceData.initialize(root: root, seed: seed)
        let reread = try WorkspaceData.readHosts(root: root)
        precondition(reread.last == custom)
        let preserved = try Data(contentsOf: catalog)
        precondition(preserved == updated)
        print("PASS: seed and file-based additions; initialization preserves edits")
        for invalid in [HostCatalog(version: 1, hosts: [hosts[0], hosts[0]]),
                        HostCatalog(version: 1, hosts: [StudioHost(id: "x", name: "x", avatar: "../../outside.png")]),
                        HostCatalog(version: 1, hosts: [StudioHost(id: "x", name: "x", avatar: "missing.png")]),
                        HostCatalog(version: 2, hosts: [])] {
            try JSONEncoder().encode(invalid).write(to: catalog)
            do { _ = try WorkspaceData.readHosts(root: root); fatalError("Invalid catalog accepted") }
            catch {}
        }
        print("PASS: duplicate IDs, outside paths, missing avatars and versions rejected")
        let legacy = base.appendingPathComponent("legacy")
        try fm.createDirectory(at: legacy, withIntermediateDirectories: true)
        let audio = legacy.appendingPathComponent("sample.caf")
        let sidecar = legacy.appendingPathComponent("sample.caf.json")
        try Data("audio".utf8).write(to: audio)
        try Data("metadata".utf8).write(to: sidecar)
        try WorkspaceData.migrateRecordings(from: legacy, to: root)
        try WorkspaceData.migrateRecordings(from: legacy, to: root)
        let saved = try Data(contentsOf: root.appendingPathComponent("recordings/sample.caf"))
        precondition(saved == Data("audio".utf8))
        precondition(!fm.fileExists(atPath: audio.path))
        precondition(fm.fileExists(atPath: root.appendingPathComponent("recordings/sample.caf.json").path))
        try Data("different".utf8).write(to: audio)
        do { try WorkspaceData.migrateRecordings(from: legacy, to: root); fatalError("Conflict overwritten") }
        catch {}
        let retained = try Data(contentsOf: audio)
        precondition(retained == Data("different".utf8))
        print("PASS: resumable migration preserves audio and metadata; conflicts preserve both files")
    }
}
