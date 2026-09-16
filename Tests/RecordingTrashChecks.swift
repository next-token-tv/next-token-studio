import Foundation

@main
struct RecordingTrashChecks {
    static func main() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        let audio = root.appendingPathComponent("test.caf")
        let metadata = audio.appendingPathExtension("json")
        let audioData = Data("synthetic audio fixture".utf8)
        let metadataData = Data("{\"channelNames\":[\"1\",\"2\"]}".utf8)
        try audioData.write(to: audio)
        try metadataData.write(to: metadata)
        let trash = root.appendingPathComponent("Trash", isDirectory: true)
        try RecordingTrash.move(audio) { bundle in try manager.moveItem(at: bundle, to: trash) }
        precondition(!manager.fileExists(atPath: audio.path) && !manager.fileExists(atPath: metadata.path))
        let trashedAudio = try Data(contentsOf: trash.appendingPathComponent(audio.lastPathComponent))
        let trashedMetadata = try Data(contentsOf: trash.appendingPathComponent(metadata.lastPathComponent))
        precondition(trashedAudio == audioData && trashedMetadata == metadataData)
        print("PASS: audio and metadata move together without changing their contents")

        try audioData.write(to: audio)
        try metadataData.write(to: metadata)
        do {
            try RecordingTrash.move(audio) { _ in throw NSError(domain: "ExpectedFailure", code: 1) }
            preconditionFailure("Trash failure must be reported")
        } catch { precondition((error as NSError).domain == "ExpectedFailure") }
        let restoredAudio = try Data(contentsOf: audio)
        let restoredMetadata = try Data(contentsOf: metadata)
        precondition(restoredAudio == audioData && restoredMetadata == metadataData)
        let leftovers = try manager.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix(".trash-") }
        precondition(leftovers.isEmpty)
        print("PASS: failed Trash operation restores both files")

        let legacy = root.appendingPathComponent("legacy.m4a")
        try audioData.write(to: legacy)
        try RecordingTrash.move(legacy) { bundle in try manager.moveItem(at: bundle, to: root.appendingPathComponent("LegacyTrash")) }
        precondition(!manager.fileExists(atPath: legacy.path))
        print("PASS: older recordings without channel metadata are supported")
    }
}
