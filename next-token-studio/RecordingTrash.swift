import Foundation

nonisolated enum RecordingTrash {
    // Keep the audio and its channel metadata together in one recoverable Trash folder.
    static func move(_ audio: URL, recycle: (URL) throws -> Void = { url in
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }) throws {
        let manager = FileManager.default
        let metadata = audio.appendingPathExtension("json")
        let staging = audio.deletingLastPathComponent().appendingPathComponent(".trash-\(UUID().uuidString)", isDirectory: true)
        let bundle = staging.appendingPathComponent(audio.deletingPathExtension().lastPathComponent, isDirectory: true)
        try manager.createDirectory(at: bundle, withIntermediateDirectories: true)
        var moved: [(original: URL, staged: URL)] = []
        do {
            for original in [audio, metadata] {
                if original == metadata && !manager.fileExists(atPath: original.path) { continue }
                let staged = bundle.appendingPathComponent(original.lastPathComponent)
                try manager.moveItem(at: original, to: staged)
                moved.append((original, staged))
            }
            try recycle(bundle)
        } catch {
            let trashError = error
            do {
                for item in moved.reversed() { try manager.moveItem(at: item.staged, to: item.original) }
                try? manager.removeItem(at: staging)
            } catch {
                throw NSError(domain: "RecordingTrash", code: 2, userInfo: [NSLocalizedDescriptionKey: "无法移到废纸篓，文件保留在 \(bundle.path)。恢复失败：\(error.localizedDescription)"])
            }
            throw trashError
        }
        try? manager.removeItem(at: staging)
    }
}
