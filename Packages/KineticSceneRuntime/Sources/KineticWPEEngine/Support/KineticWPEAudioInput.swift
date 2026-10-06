import Dispatch
import os

/// Host-fed audio spectrum for the complete engine. Kinetic owns any audio capture (Module 45); the engine
/// never captures. Like Wallpaper Engine's, the spectrum is process-wide: every scene reads the same
/// system spectrum through `g_AudioSpectrum*`, audio-responsive particles and `engine.registerAudioBuffers`.
public enum KineticWPEAudioInput {
    /// 64 stereo bins in 0...1 (out-of-range values are clamped). All-zero input switches the spectrum off so
    /// scenes read flat bars, as when nothing is playing.
    public static func publish(left: [Float], right: [Float]) {
        let frame = AudioSpectrumFrame(left: left, right: right, timestampNanos: DispatchTime.now().uptimeNanoseconds)
        let audible = frame.left.contains { $0 > 0 } || frame.right.contains { $0 > 0 }
        feeder.store(frame)
        SystemAudioCaptureManager.setHostSpectrumActive(audible)
        if !audible { SystemAudioCaptureManager.broker.resetToSilence() }
    }

    /// Whether scenes currently read a non-silent spectrum.
    public static var isActive: Bool { SystemAudioCaptureManager.isCapturing }

    private static let feeder: HostSpectrumFeeder = {
        let feeder = HostSpectrumFeeder()
        SystemAudioCaptureManager.broker.attachAnalyzer(feeder)
        return feeder
    }()
}

/// Hands the broker the latest published frame once; between publishes the broker keeps its cached frame.
final class HostSpectrumFeeder: AudioSpectrumAnalyzing, @unchecked Sendable {
    private let latest = OSAllocatedUnfairLock<AudioSpectrumFrame?>(initialState: nil)

    func store(_ frame: AudioSpectrumFrame) { latest.withLock { $0 = frame } }

    func analyzeIfDue(nowNanos _: UInt64) -> AudioSpectrumFrame? {
        latest.withLock { pending in
            defer { pending = nil }
            return pending
        }
    }
}
