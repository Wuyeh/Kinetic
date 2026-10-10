import Accelerate
import Foundation

struct StereoAudioSpectrum: Equatable, Sendable {
    var left: [Float]
    var right: [Float]
    static let silence = Self(left: .init(repeating: 0, count: 64), right: .init(repeating: 0, count: 64))
    var peak: Float { max(left.max() ?? 0, right.max() ?? 0) }
}

/// Queue-confined 2048-sample ring. No audio history beyond one FFT window is retained.
final class AudioSpectrumAnalyzer {
    static let size = 2048
    private let setup: FFTSetup
    private var left = [Float](repeating: 0, count: size), right = [Float](repeating: 0, count: size)
    private var window = [Float](repeating: 0, count: size)
    private var scratch = [Float](repeating: 0, count: size)
    private var real = [Float](repeating: 0, count: size / 2), imaginary = [Float](repeating: 0, count: size / 2)
    private var power = [Float](repeating: 0, count: size / 2)
    private var cursor = 0, count = 0
    private var lastAnalysis: TimeInterval?
    private var lastInput: TimeInterval?
    private var smoothed = StereoAudioSpectrum.silence
    init() {
        setup = vDSP_create_fftsetup(11, FFTRadix(kFFTRadix2))!
        vDSP_hann_window(&window, vDSP_Length(Self.size), Int32(vDSP_HANN_NORM))
    }
    deinit { vDSP_destroy_fftsetup(setup) }
    func consume(left inputLeft: [Float], right inputRight: [Float], sampleRate: Double, at time: TimeInterval) -> StereoAudioSpectrum? {
        guard inputLeft.count == inputRight.count, inputLeft.count <= 16_384,
              !inputLeft.isEmpty, sampleRate.isFinite, (8_000...192_000).contains(sampleRate), time.isFinite else { return nil }
        lastInput = time
        for (l, r) in zip(inputLeft, inputRight) {
            left[cursor] = l.isFinite ? min(1, max(-1, l)) : 0
            right[cursor] = r.isFinite ? min(1, max(-1, r)) : 0
            cursor = (cursor + 1) % Self.size; count = min(Self.size, count + 1)
        }
        guard count == Self.size, lastAnalysis.map({ time - $0 >= 1.0 / 30 }) ?? true else { return nil }
        let delta = min(0.25, max(1.0 / 30, time - (lastAnalysis ?? (time - 1.0 / 30))))
        lastAnalysis = time
        let l = transform(left, sampleRate: sampleRate), r = transform(right, sampleRate: sampleRate)
        for i in 0..<64 {
            smoothed.left[i] = smooth(smoothed.left[i], l[i], delta: delta)
            smoothed.right[i] = smooth(smoothed.right[i], r[i], delta: delta)
        }
        return smoothed
    }
    /// ScreenCaptureKit may stop sending packets when playback becomes silent.
    /// Decay the last spectrum rather than leaving bars stuck on the last sound.
    func silenceIfInputStopped(at time: TimeInterval) -> StereoAudioSpectrum? {
        guard time.isFinite, let lastInput, time - lastInput >= 0.2 else { return nil }
        let delta = min(0.25, max(1.0 / 30, time - (lastAnalysis ?? time)))
        lastAnalysis = time
        for i in 0..<64 {
            smoothed.left[i] = smooth(smoothed.left[i], 0, delta: delta)
            smoothed.right[i] = smooth(smoothed.right[i], 0, delta: delta)
        }
        for i in 0..<Self.size { left[i] = 0; right[i] = 0 }
        cursor = 0; count = 0
        return smoothed
    }
    private func smooth(_ old: Float, _ value: Float, delta: Double) -> Float {
        let tau = value > old ? 0.035 : 0.12
        let result = old + Float(1 - exp(-delta / tau)) * (value - old)
        return result < 0.002 ? 0 : result
    }
    private func transform(_ ring: [Float], sampleRate: Double) -> [Float] {
        for i in 0..<Self.size { scratch[i] = ring[(cursor + i) % Self.size] * window[i] }
        real.withUnsafeMutableBufferPointer { re in imaginary.withUnsafeMutableBufferPointer { im in
            var split = DSPSplitComplex(realp: re.baseAddress!, imagp: im.baseAddress!)
            scratch.withUnsafeBufferPointer { samples in
                samples.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: Self.size / 2) {
                    vDSP_ctoz($0, 2, &split, 1, vDSP_Length(Self.size / 2))
                }
            }
            vDSP_fft_zrip(setup, &split, 1, 11, FFTDirection(FFT_FORWARD))
            // Packed bin 0 also contains Nyquist. Neither belongs in the visible bass band.
            re[0] = 0; im[0] = 0
            vDSP_zvmags(&split, 1, &power, 1, vDSP_Length(Self.size / 2))
        } }
        let maximum = min(20_000, sampleRate * 0.48), minimum = 20.0
        let normalization = Float(Self.size) / 2
        return (0..<64).map { band in
            let low = minimum * pow(maximum / minimum, Double(band) / 64)
            let high = minimum * pow(maximum / minimum, Double(band + 1) / 64)
            let start = max(1, min(Self.size / 2 - 1, Int(low * Double(Self.size) / sampleRate)))
            let end = max(start + 1, min(Self.size / 2, Int(ceil(high * Double(Self.size) / sampleRate))))
            let magnitude = sqrt(power[start..<end].max() ?? 0) / normalization
            let decibels = 20 * log10(max(0.000_001, magnitude))
            return min(1, max(0, (decibels + 60) / 60))
        }
    }
}
