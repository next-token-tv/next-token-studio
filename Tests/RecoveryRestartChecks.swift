import Foundation
import Darwin
@main struct RecoveryRestartChecks {
 static func main() throws {
  if CommandLine.arguments.count > 1 {
   _ = try RecordingRecovery.recoverReport(in: URL(fileURLWithPath: CommandLine.arguments[1]), afterCopy: { kill(getpid(), SIGKILL) })
   fatalError("Expected SIGKILL")
  }
  let fm = FileManager.default
  let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try fm.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? fm.removeItem(at: root) }
  let original = root.appendingPathComponent("test.recording")
  try fm.createDirectory(at: original, withIntermediateDirectories: false)
  try JSONEncoder().encode(["track-01.wav"]).write(to: original.appendingPathComponent("tracks.json"))
  do {
   let file = try DurableWAV(url: original.appendingPathComponent("track-01.wav"), sampleRate: 48000)
   let samples = [Float](repeating: 0.25, count: 48000)
   try samples.withUnsafeBufferPointer { try file.append($0.baseAddress!, count: $0.count) }
   try file.checkpoint()
  }
  try RecordingRecovery.save(.init(status: "recording", sampleRate: 48000, safeFrames: 48000), in: original)
  let bytes = try Data(contentsOf: original.appendingPathComponent("track-01.wav"))
  let unknown = root.appendingPathComponent(".recovery-" + UUID().uuidString)
  try fm.createDirectory(at: unknown, withIntermediateDirectories: false)
  for _ in 0..<2 {
   let child = Process(); child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]); child.arguments = [root.path]
   try child.run(); child.waitUntilExit()
   precondition(child.terminationReason == .uncaughtSignal && child.terminationStatus == SIGKILL)
   let scratch = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix(".recovery-") && $0.lastPathComponent != unknown.lastPathComponent }
   precondition(scratch.count == 1, "Retry must clean the prior owned copy")
  }
  let count = try RecordingRecovery.recover(in: root)
  precondition(count == 1)
  precondition(fm.fileExists(atPath: unknown.path))
  let unchanged = try Data(contentsOf: original.appendingPathComponent("track-01.wav")); precondition(bytes == unchanged)
  let reader = try RecordingAudioReader(forReading: root.appendingPathComponent("test.recovered.recording"))
  precondition(reader.length == 48000)
  let blocked = root.appendingPathComponent(".recovery-" + UUID().uuidString)
  let removable = root.appendingPathComponent(".recovery-" + UUID().uuidString)
  for url in [blocked, removable] {
   try fm.createDirectory(at: url, withIntermediateDirectories: false)
   try JSONSerialization.data(withJSONObject: ["version": 1, "directory": url.lastPathComponent]).write(to: url.appendingPathComponent(".studio-recovery-owner.json"))
  }
  let issues = try RecordingRecovery.cleanStaging(in: root) { url in
   if url.lastPathComponent == blocked.lastPathComponent { throw CocoaError(.fileWriteNoPermission) }
   try fm.removeItem(at: url)
  }
  precondition(issues.count == 1 && fm.fileExists(atPath: blocked.path) && !fm.fileExists(atPath: removable.path))
  precondition(fm.fileExists(atPath: unknown.path))
  print("PASS: failed cleanup isolated; other owned staging removed; unknown directory retained")
  print("PASS: repeated SIGKILL during recovery; bounded staging; original and unowned directory preserved")
 }
}
