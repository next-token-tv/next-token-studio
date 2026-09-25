import Foundation

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
    static func recover(in root: URL) throws -> Int {
        let manager = FileManager.default
        var recovered = 0
        for folder in try manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) where folder.pathExtension == "recording" {
            guard var state = state(in: folder), state.status == "recording", state.safeFrames > 0 else { continue }
            let files = try RecordingAudioReader.sourceFiles(folder)
            let available = try files.map { url -> Int64 in
                let attributes = try manager.attributesOfItem(atPath: url.path)
                let bytes = (attributes[.size] as? NSNumber)?.int64Value ?? 0
                return max(0, (bytes - 56) / 4)
            }
            let frames = min(state.safeFrames, available.min() ?? 0)
            guard frames > 0 else { continue }
            // Deterministic destination makes recovery safe to retry after another crash.
            let destination = folder.deletingPathExtension().appendingPathExtension("recovered.recording")
            if !manager.fileExists(atPath: destination.path) {
                let staging = root.appendingPathComponent(".recovery-" + UUID().uuidString)
                try manager.createDirectory(at: staging, withIntermediateDirectories: false)
                defer { try? manager.removeItem(at: staging) }
                for source in files {
                    let target = staging.appendingPathComponent(source.lastPathComponent)
                    try manager.copyItem(at: source, to: target)
                    let handle = try FileHandle(forWritingTo: target)
                    defer { try? handle.close() }
                    try handle.truncate(atOffset: UInt64(56 + frames * 4))
                    try handle.seek(toOffset: 0)
                    try handle.write(contentsOf: DurableWAV.header(rate: state.sampleRate, frames: frames))
                    try handle.synchronize()
                }
                try manager.copyItem(at: folder.appendingPathComponent("tracks.json"), to: staging.appendingPathComponent("tracks.json"))
                try save(State(status: "complete", sampleRate: state.sampleRate, safeFrames: frames), in: staging)
                let metadata = folder.appendingPathExtension("json")
                if manager.fileExists(atPath: metadata.path) {
                    let bytes = try Data(contentsOf: metadata)
                    try bytes.write(to: destination.appendingPathExtension("json"), options: .atomic)
                }
                try manager.moveItem(at: staging, to: destination)
            }
            state.status = "recovered"
            try save(state, in: folder)
            recovered += 1
        }
        return recovered
    }
}
