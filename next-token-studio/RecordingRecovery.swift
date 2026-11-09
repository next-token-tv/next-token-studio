import Foundation
import Darwin
import AVFoundation

// Fixed-layout IEEE Float WAV: RIFF, fmt, fact, data. All integers are little endian.
nonisolated final class DurableWAV {
    private let handle: FileHandle
    private let rate: Double
    private(set) var frames: Int64 = 0
    init(url: URL, sampleRate: Double) throws {
        rate = sampleRate
        guard FileManager.default.createFile(atPath: url.path, contents: Self.header(rate: rate, frames: 0)) else { throw CocoaError(.fileWriteUnknown) }
        handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
    }
    func append(_ samples: UnsafePointer<Float>, count: Int) throws {
        try handle.write(contentsOf: Data(bytes: samples, count: count * 4))
        frames += Int64(count)
    }
    func checkpoint() throws {
        let end = try handle.offset()
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: Self.header(rate: rate, frames: frames))
        try handle.seek(toOffset: end)
        try handle.synchronize()
    }
    static func header(rate: Double, frames: Int64) -> Data {
        var data = Data()
        func text(_ s: String) { data.append(contentsOf: s.utf8) }
        func u32(_ v: UInt32) { var v = v.littleEndian; withUnsafeBytes(of: &v) { data.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { var v = v.littleEndian; withUnsafeBytes(of: &v) { data.append(contentsOf: $0) } }
        let bytes = UInt32(frames * 4)
        text("RIFF"); u32(48 + bytes); text("WAVEfmt "); u32(16)
        u16(3); u16(1); u32(UInt32(rate)); u32(UInt32(rate) * 4); u16(4); u16(32)
        text("fact"); u32(4); u32(UInt32(frames)); text("data"); u32(bytes)
        return data
    }
}

nonisolated enum RecordingRecovery {
    struct State: Codable {
        var status: String
        let sampleRate: Double
        var safeFrames: Int64
    }
    static func save(_ state: State, in folder: URL) throws {
        let url = folder.appendingPathComponent("recovery.json")
        try JSONEncoder().encode(state).write(to: url, options: .atomic)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.synchronize()
    }
    static func state(in folder: URL) -> State? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("recovery.json")) else { return nil }
        return try? JSONDecoder().decode(State.self, from: data)
    }
    struct Report: Sendable {
        var recovered = 0
        var issues: [String] = []
    }
    static func recover(in root: URL) throws -> Int { try recoverReport(in: root).recovered }

    static func recoverReport(in root: URL, afterCopy: (() -> Void)? = nil) throws -> Report {
        let fd = open(root.appendingPathComponent(".recovery.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            return Report(issues: ["Another recovery is already running."])
        }
        defer { flock(fd, LOCK_UN) }
        try cleanStaging(in: root)
        var report = Report()
        for folder in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where folder.pathExtension == "recording" {
            let status = state(in: folder)?.status
            if status == "complete" || status == "recovered" { continue }
            do { if try recoverFolder(folder, root: root, afterCopy: afterCopy) { report.recovered += 1 } }
            catch { report.issues.append("\(folder.lastPathComponent)：\(error.localizedDescription)") }
        }
        return report
    }

    private struct StagingOwner: Codable {
        let version: Int
        let directory: String
    }

    private static func cleanStaging(in root: URL) throws {
        let manager = FileManager.default
        for url in try manager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey]) {
            guard url.lastPathComponent.hasPrefix(".recovery-"),
                  UUID(uuidString: String(url.lastPathComponent.dropFirst(10))) != nil else { continue }
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { continue }
            let marker = url.appendingPathComponent(".studio-recovery-owner.json")
            guard (try? marker.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
                  let data = try? Data(contentsOf: marker),
                  let owner = try? JSONDecoder().decode(StagingOwner.self, from: data),
                  owner.version == 1, owner.directory == url.lastPathComponent else { continue }
            try manager.removeItem(at: url)
        }
    }

    private static func recoverFolder(_ folder: URL, root: URL, afterCopy: (() -> Void)?) throws -> Bool {
        let manager = FileManager.default
        let files = try RecordingAudioReader.sourceFiles(folder)
        var checkpoint = state(in: folder)
        // A corrupt journal may use only verified fixed-layout WAV headers, never guess from raw bytes.
        if checkpoint == nil {
            let headers = try files.map { url -> (Double, Int64) in
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                guard let bytes = try handle.read(upToCount: 56), bytes.count == 56 else { throw CocoaError(.fileReadCorruptFile) }
                func u32(_ offset: Int) -> UInt32 {
                    (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[offset + $1]) << ($1 * 8) }
                }
                let rate = Double(u32(24)), frames = Int64(u32(52) / 4)
                guard rate >= 8000, rate <= 384000, bytes == DurableWAV.header(rate: rate, frames: frames) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                return (rate, frames)
            }
            guard let rate = headers.first?.0, headers.allSatisfy({ $0.0 == rate }) else { throw CocoaError(.fileReadCorruptFile) }
            checkpoint = State(status: "interrupted", sampleRate: rate, safeFrames: headers.map { $0.1 }.min() ?? 0)
        }
        guard var checkpoint, checkpoint.sampleRate.isFinite, (8000...384000).contains(checkpoint.sampleRate),
              checkpoint.safeFrames > 0, checkpoint.safeFrames <= (Int64(UInt32.max) - 48) / 4 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let available = try files.map { url -> Int64 in
            let attributes = try manager.attributesOfItem(atPath: url.path)
            return max(0, ((attributes[.size] as? NSNumber)?.int64Value ?? 0) - 56) / 4
        }
        let frames = min(checkpoint.safeFrames, available.min() ?? 0)
        guard frames > 0 else { throw CocoaError(.fileReadCorruptFile) }
        let destination = folder.deletingPathExtension().appendingPathExtension("recovered.recording")
        if manager.fileExists(atPath: destination.path) {
            let reader = try RecordingAudioReader(forReading: destination)
            guard state(in: destination)?.status == "complete", reader.length == frames,
                  reader.processingFormat.sampleRate == checkpoint.sampleRate,
                  Int(reader.processingFormat.channelCount) == files.count else { throw CocoaError(.fileReadCorruptFile) }
        } else {
            let required = (56 + frames * 4) * Int64(files.count) + 100_000_000
            let disk = try manager.attributesOfFileSystem(forPath: root.path)
            guard let free = disk[.systemFreeSize] as? NSNumber, free.int64Value >= required else { throw CocoaError(.fileWriteOutOfSpace) }
            let staging = root.appendingPathComponent(".recovery-" + UUID().uuidString)
            try manager.createDirectory(at: staging, withIntermediateDirectories: false)
            defer { try? manager.removeItem(at: staging) }
            let marker = staging.appendingPathComponent(".studio-recovery-owner.json")
            try JSONEncoder().encode(StagingOwner(version: 1, directory: staging.lastPathComponent)).write(to: marker, options: .atomic)
            let markerHandle = try FileHandle(forWritingTo: marker)
            try markerHandle.synchronize()
            try markerHandle.close()
            for source in files {
                let target = staging.appendingPathComponent(source.lastPathComponent)
                guard manager.createFile(atPath: target.path, contents: DurableWAV.header(rate: checkpoint.sampleRate, frames: frames)) else { throw CocoaError(.fileWriteUnknown) }
                let input = try FileHandle(forReadingFrom: source)
                defer { try? input.close() }
                let output = try FileHandle(forWritingTo: target)
                defer { try? output.close() }
                try input.seek(toOffset: 56); try output.seekToEnd()
                var remaining = frames * 4
                while remaining > 0 {
                    guard let data = try input.read(upToCount: Int(min(remaining, 1_048_576))), !data.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
                    try output.write(contentsOf: data)
                    remaining -= Int64(data.count)
                }
                try output.synchronize()
                afterCopy?()
            }
            try manager.copyItem(at: folder.appendingPathComponent("tracks.json"), to: staging.appendingPathComponent("tracks.json"))
            try save(State(status: "complete", sampleRate: checkpoint.sampleRate, safeFrames: frames), in: staging)
            let metadata = folder.appendingPathExtension("json")
            if manager.fileExists(atPath: metadata.path) {
                try Data(contentsOf: metadata).write(to: destination.appendingPathExtension("json"), options: .atomic)
            }
            try manager.moveItem(at: staging, to: destination)
        }
        checkpoint.status = "recovered"
        try save(checkpoint, in: folder)
        return true
    }
}
