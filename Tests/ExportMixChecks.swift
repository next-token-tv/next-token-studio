import AVFoundation
@main struct ExportMixChecks {
 static func main() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }
  for rate in [44100.0, 48000.0] {
   let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
   let length = Int(rate * 3)
   let source = root.appendingPathComponent("source-\(rate).wav")
   let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(length))!
   buffer.frameLength = AVAudioFrameCount(length)
   for f in 0..<length { buffer.floatChannelData![0][f] = Float(0.04 * sin(Double(f) * 2 * .pi * 440 / rate)) }
   buffer.floatChannelData![0][Int(rate)] = 3
   do { let file = try AVAudioFile(forWriting: source, settings: format.settings); try file.write(from: buffer) }
   let destination = root.appendingPathComponent("mix-\(rate).caf")
   try ExportMix.render(source: source, destination: destination)
   let result = try AVAudioFile(forReading: destination)
   precondition(result.length == length)
   try result.read(into: buffer)
   var peak: Float = 0, energy = 0.0
   for f in 0..<length { let v = buffer.floatChannelData![0][f]; precondition(v.isFinite); peak = max(peak, abs(v)); if f > Int(rate * 2) { energy += Double(v * v) } }
   precondition(peak <= 0.794329)
   precondition(sqrt(energy / rate) > 0.09, "A brief transient must not attenuate the rest of the recording")
   print("PASS: \(rate) Hz exact duration, bounded peak, recovered dialogue level after transient")
  }
  var limiter = LookaheadLimiter(sampleRate: 48000)
  for _ in 0..<10000 { if let value = limiter.process(0) { precondition(value == 0) } }
  print("PASS: silence remains silent")
 }
}
