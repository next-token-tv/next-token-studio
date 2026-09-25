import Foundation

nonisolated enum WaveformAmplitude {
    // One fixed curve for every track and both live/playback views. A 20 dB
    // difference remains a 5.6x height difference, without per-track normalization.
    static func height(for peak: Float) -> Float {
        guard peak.isFinite, peak > 0 else { return 0 }
        return pow(min(1, peak), 0.75)
    }
}
