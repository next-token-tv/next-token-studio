import AppKit
import Observation
import Darwin

@MainActor @Observable
final class StudioWorkspace {
    private(set) var root: URL?
    private(set) var hosts: [StudioHost] = []
    private(set) var avatars: [String: NSImage] = [:]
    var hostError: String?
    var bindingError: String?
    private(set) var microphoneCatalog = MicrophoneCatalog()
    var error: String?
    private(set) var isConnecting = false
    private var access: URL?
    private let bookmarkKey = "studioWorkspaceBookmark"

    static var expectedRoot: URL {
        let home = getpwuid(getuid()).map { String(cString: $0.pointee.pw_dir) } ?? NSHomeDirectory()
        return URL(fileURLWithPath: home).appendingPathComponent("Documents/Next Token Studio", isDirectory: true)
    }

    func restore() async {
        guard root == nil, !isConnecting, let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return }
        do {
            var stale = false
            let url = try URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale)
            try await connect(url)
        } catch { self.error = "无法打开工作文件夹，请重新授权：\(error.localizedDescription)" }
    }

    func choose() async {
        guard !isConnecting, root == nil else { return }
        let panel = NSOpenPanel()
        panel.title = "打开 Next Token Studio 工作文件夹"
        panel.message = "请选择 Documents 中的 Next Token Studio 文件夹，录音、主播资料和导出均保存在这里。"
        panel.prompt = "使用工作文件夹"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = Self.expectedRoot
        guard await panel.begin() == .OK, let url = panel.url else { return }
        do { try await connect(url) }
        catch { self.error = error.localizedDescription }
    }

    private func connect(_ url: URL) async throws {
        guard url.resolvingSymlinksInPath().standardizedFileURL == Self.expectedRoot.resolvingSymlinksInPath().standardizedFileURL else {
            throw WorkspaceData.failure("请选择 \(Self.expectedRoot.path)。")
        }
        isConnecting = true
        defer { isConnecting = false }
        let scoped = url.startAccessingSecurityScopedResource()
        do {
            let bookmark = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
            guard let seed = Bundle.main.resourceURL?.appendingPathComponent("WorkspaceSeed"), FileManager.default.fileExists(atPath: seed.path) else {
                throw WorkspaceData.failure("App 缺少默认主播资料。")
            }
            let legacy = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false).appendingPathComponent("NextTokenStudio/Recordings")
            try await Task.detached {
                try WorkspaceData.initialize(root: url, seed: seed)
                try WorkspaceData.migrateRecordings(from: legacy, to: url)
            }.value
            UserDefaults.standard.set(bookmark, forKey: bookmarkKey)
            access = scoped ? url : nil
            root = url
            error = nil
            reloadHosts()
        } catch {
            if scoped { url.stopAccessingSecurityScopedResource() }
            throw error
        }
    }

    func folder(_ name: String) throws -> URL {
        guard let root else { throw WorkspaceData.failure("请先打开工作文件夹。") }
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func reloadHosts() {
        guard let root else { return }
        do {
            let loaded = try WorkspaceData.readHosts(root: root)
            var images: [String: NSImage] = [:]
            for host in loaded {
                let url = try WorkspaceData.avatarURL(host, root: root)
                guard let image = NSImage(contentsOf: url) else { throw WorkspaceData.failure("无法读取 \(host.name) 的头像。") }
                images[host.id] = image
            }
            hosts = loaded
            avatars = images
            hostError = nil
            reloadBindings()
        } catch { hostError = "主播资料读取失败：\(error.localizedDescription)" }
    }

    func reloadBindings() {
        guard let root else { return }
        do {
            microphoneCatalog = try MicrophoneCatalog.read(from: root.appendingPathComponent("hosts/microphones.json"))
            bindingError = nil
        } catch {
            microphoneCatalog = MicrophoneCatalog()
            bindingError = "麦克风绑定读取失败：\(error.localizedDescription)"
        }
    }

    func hostIDs(for device: InputDevice) -> [String?] {
        microphoneCatalog.devices.first { $0.deviceUID == device.uid }?
            .hostIDs(uid: device.uid, channels: device.channelNames, hosts: hosts)
            ?? Array(repeating: nil, count: device.channelCount)
    }

    func saveBindings(_ ids: [String?], for device: InputDevice) throws {
        guard let root, ids.count == device.channelCount else { throw WorkspaceData.failure("麦克风通道已改变，请重新匹配。") }
        let known = Set(hosts.map(\.id))
        let assigned = ids.compactMap { $0 }
        guard Set(assigned).count == assigned.count, assigned.allSatisfy({ known.contains($0) }) else {
            throw WorkspaceData.failure("主播资料已改变，或同一主播被分配到多路，请检查绑定。")
        }
        let url = root.appendingPathComponent("hosts/microphones.json")
        var catalog = try MicrophoneCatalog.read(from: url)
        let assignments = ids.enumerated().compactMap { index, id in id.map { ChannelHostBinding(channel: index, hostID: $0) } }
        try catalog.save(DeviceHostBindings(deviceUID: device.uid, channelNames: device.channelNames, assignments: assignments), to: url)
        microphoneCatalog = catalog
        bindingError = nil
    }

    func reveal() { if let root { NSWorkspace.shared.open(root) } }
}
