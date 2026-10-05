import Foundation

/// YIN monophonic pitch detector operating on a mono `[Float]` buffer.
///
/// Implements the classic YIN algorithm: the difference function, the cumulative-mean
/// normalized difference function (CMNDF), an absolute threshold to locate the fundamental
/// period, and parabolic interpolation of the trough for sub-sample period refinement.
///
/// The detector is pure and stateless: it retains no audio between calls. All heavy lifting
/// happens in the static `yin` function so it can run on a background (non-main) thread.
public struct PitchDetector: Sendable {
    /// Sample rate in Hz of the buffers that will be measured.
    public let sampleRate: Double
    /// Absolute threshold (0...1) applied to the normalized difference function. A candidate
    /// period is only accepted when its CMNDF trough falls below this value.
    public let threshold: Double

    /// Frequency search range (Hz). Covers G3 (196 Hz) through E5 (659 Hz) and beyond.
    public static let minFrequencyHz: Double = 30.0
    public static let maxFrequencyHz: Double = 2000.0

    /// Reference pitch for A4, in hertz. Controls how measured frequencies map to
    /// MIDI notes and cents (e.g. 442 Hz for orchestras that tune sharp).
    public var referenceA4Hz: Double

    /// Minimum lag (in samples) to consider, derived from `maxFrequencyHz`. Parabolic
    /// interpolation needs one neighbor on each side, so the smallest allowed lag is 2.
    private var tauMin: Int {
        let tau = Int((sampleRate / Self.maxFrequencyHz).rounded(.down))
        return max(2, tau)
    }

    public init(sampleRate: Double,
                threshold: Double = 0.15,
                referenceA4Hz: Double = MusicTheory.defaultA4Hz) {
        self.sampleRate = sampleRate
        self.threshold = threshold
        self.referenceA4Hz = referenceA4Hz
    }

    /// Pure YIN. Returns `(frequencyHz, confidence)` or `(nil, 0)` when no reliable
    /// periodicity is detected (silence, noise, or an out-of-range pitch).
    ///
    /// - Parameters:
    ///   - buffer: mono audio samples.
    ///   - sampleRate: sample rate in Hz.
    ///   - threshold: absolute CMNDF threshold used to accept a candidate period.
    /// - Returns: the estimated fundamental frequency (Hz) and a confidence in 0...1.
    public static func yin(
        buffer: [Float],
        sampleRate: Double,
        threshold: Double
    ) -> (frequencyHz: Double?, confidence: Double) {
        let n = buffer.count
        // Need at least a couple of samples and room for the period search.
        guard n >= 4 else { return (nil, 0) }

        // Half the buffer (rounded down) is the largest lag we can difference.
        let w = n / 2
        guard w >= 2 else { return (nil, 0) }

        let tauMin = max(2, Int((sampleRate / maxFrequencyHz).rounded(.down)))
        let tauMax = min(w - 1, Int((sampleRate / minFrequencyHz).rounded(.down)))
        guard tauMax >= tauMin else { return (nil, 0) }

        // Difference function d(tau) = sum (x[i] - x[i+tau])^2.
        var d = [Double](repeating: 0, count: w)
        d.withUnsafeMutableBufferPointer { dp in
            buffer.withUnsafeBufferPointer { bp in
                for tau in 0..<w {
                    var sum = 0.0
                    var i = 0
                    while i < w {
                        let diff = Double(bp[i]) - Double(bp[i + tau])
                        sum += diff * diff
                        i += 1
                    }
                    dp[tau] = sum
                }
            }
        }

        // Cumulative-mean normalized difference function.
        var cmndf = [Double](repeating: 0, count: w)
        cmndf[0] = 1.0
        var runningSum = 0.0
        for tau in 1..<w {
            runningSum += d[tau]
            cmndf[tau] = runningSum > 0 ? d[tau] * Double(tau) / runningSum : 1.0
        }

        // Absolute threshold: find the FIRST local minimum (dip) of the CMNDF that falls
        // below `threshold`, scanning from short lags upward. This yields the fundamental
        // period rather than a subharmonic (a later, deeper trough at a multiple of the
        // period would otherwise win an absolute-minimum search).
        var minTau = -1
        var minValue = Double.greatestFiniteMagnitude
        for tau in tauMin...(tauMax - 1) {
            let v = cmndf[tau]
            if v < threshold && v <= cmndf[tau - 1] && v <= cmndf[tau + 1] {
                minTau = tau
                minValue = v
                break
            }
        }

        // No dip below threshold means no reliable periodicity (silence or noise).
        guard minTau >= 0 else { return (nil, 0) }

        // Parabolic interpolation of the trough for sub-sample precision.
        let refinedTau: Double
        if minTau > tauMin && minTau < tauMax {
            let x0 = cmndf[minTau - 1]
            let x1 = cmndf[minTau]
            let x2 = cmndf[minTau + 1]
            let denominator = x0 - 2 * x1 + x2
            if denominator > 1e-12 {
                let offset = 0.5 * (x0 - x2) / denominator
                // Guard against a wildly extrapolated offset.
                if abs(offset) < 1.0 {
                    refinedTau = Double(minTau) + offset
                } else {
                    refinedTau = Double(minTau)
                }
            } else {
                refinedTau = Double(minTau)
            }
        } else {
            refinedTau = Double(minTau)
        }

        guard refinedTau >= Double(tauMin) else { return (nil, 0) }

        let frequencyHz = sampleRate / refinedTau
        guard frequencyHz >= minFrequencyHz, frequencyHz <= maxFrequencyHz else {
            return (nil, 0)
        }

        // Confidence derived from trough depth: a trough at 0 -> confidence 1, at threshold -> 0.
        let confidence = (1.0 - minValue) / (1.0 - threshold)
        let clamped = min(1.0, max(0.0, confidence))
        return (frequencyHz, clamped)
    }

    /// Runs YIN on `buffer` and converts the result into a `PitchMeasurement`.
    ///
    /// No smoothing or confidence gating happens here; that is `PitchSmoother`'s job. When no
    /// reliable pitch is found the returned measurement is `.idle`.
    public func measure(buffer: [Float]) -> PitchMeasurement {
        let result = Self.yin(buffer: buffer, sampleRate: sampleRate, threshold: threshold)
        guard let frequencyHz = result.frequencyHz else {
            return .idle
        }
        let midiNote = MusicTheory.nearestMidiNote(frequencyHz: frequencyHz, referenceA4Hz: referenceA4Hz)
        return PitchMeasurement(
            frequencyHz: frequencyHz,
            midiNote: midiNote,
            noteName: MusicTheory.noteNameWithOctave(midiNote: midiNote),
            cents: MusicTheory.cents(frequencyHz: frequencyHz, referenceA4Hz: referenceA4Hz),
            confidence: result.confidence
        )
    }
}
