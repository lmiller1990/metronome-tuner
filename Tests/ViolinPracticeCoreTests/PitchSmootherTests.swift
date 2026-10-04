import XCTest
@testable import ViolinPracticeCore

final class PitchSmootherTests: XCTestCase {

    private let sampleRate = 44100.0

    /// Build a raw measurement for `frequencyHz` with the given confidence.
    private func rawMeasurement(frequencyHz: Double, confidence: Double = 1.0) -> PitchMeasurement {
        let note = MusicTheory.nearestMidiNote(frequencyHz: frequencyHz)
        return PitchMeasurement(
            frequencyHz: frequencyHz,
            midiNote: note,
            noteName: MusicTheory.noteNameWithOctave(midiNote: note),
            cents: MusicTheory.cents(frequencyHz: frequencyHz),
            confidence: confidence
        )
    }

    /// A normal speaking/singing RMS level, well above the silence gate.
    private let voiceRMS = 0.1

    // MARK: - Convergence

    func testNoisy440ConvergesToStableA4() {
        var smoother = PitchSmoother(sampleRate: sampleRate)
        // Deterministic LCG so the test is reproducible across runs.
        var state: UInt64 = 0x9E3779B97F4A7C15
        func nextUniform() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) * (1.0 / 9007199254740992.0)
        }
        var last: PitchMeasurement = .idle
        for _ in 0..<120 {
            // 440 Hz plus ~±3 Hz of "measurement" jitter.
            let jitter = (nextUniform() * 6.0) - 3.0
            let raw = rawMeasurement(frequencyHz: 440.0 + jitter)
            last = smoother.update(raw, rms: voiceRMS)
        }
        XCTAssertNotNil(last.frequencyHz)
        XCTAssertEqual(last.midiNote, 69)
        XCTAssertEqual(last.noteName, "A4")
        if let frequencyHz = last.frequencyHz {
            XCTAssertEqual(frequencyHz, 440.0, accuracy: 1.5)
        }
        XCTAssertEqual(last.cents, 0.0, accuracy: 10.0)
    }

    // MARK: - Note-change confirmation (no flicker)

    func testSingleDifferentFrameDoesNotChangeNote() {
        var smoother = PitchSmoother(sampleRate: sampleRate)
        for _ in 0..<20 {
            _ = smoother.update(rawMeasurement(frequencyHz: 440.0), rms: voiceRMS)
        }
        // One isolated Bb4 frame must not move the display off A4.
        let out = smoother.update(rawMeasurement(frequencyHz: 466.16), rms: voiceRMS)
        XCTAssertEqual(out.noteName, "A4")
    }

    func testNoteChangesOnlyAfterConfirmationFrames() {
        var smoother = PitchSmoother(sampleRate: sampleRate, noteChangeConfirmationFrames: 3)
        for _ in 0..<20 {
            _ = smoother.update(rawMeasurement(frequencyHz: 440.0), rms: voiceRMS)
        }
        // Two Bb4 frames: still below the confirmation count.
        XCTAssertEqual(smoother.update(rawMeasurement(frequencyHz: 466.16), rms: voiceRMS).noteName, "A4")
        XCTAssertEqual(smoother.update(rawMeasurement(frequencyHz: 466.16), rms: voiceRMS).noteName, "A4")
        // Third consecutive Bb4 frame confirms the change.
        XCTAssertEqual(smoother.update(rawMeasurement(frequencyHz: 466.16), rms: voiceRMS).noteName, "A#4")
    }

    func testAlternatingBurstDoesNotFlickerNote() {
        var smoother = PitchSmoother(sampleRate: sampleRate, noteChangeConfirmationFrames: 2)
        for _ in 0..<20 {
            _ = smoother.update(rawMeasurement(frequencyHz: 440.0), rms: voiceRMS)
        }
        // Strictly alternating non-A4 notes never repeat consecutively, so the 2-frame
        // confirmation requirement keeps the display pinned on A4 throughout.
        let alternating = [466.16, 415.30, 523.25, 392.00, 493.88, 349.23]
        for i in 0..<30 {
            let frequencyHz = alternating[i % alternating.count]
            let out = smoother.update(rawMeasurement(frequencyHz: frequencyHz), rms: voiceRMS)
            XCTAssertEqual(out.noteName, "A4", "note flickered during alternating burst")
        }
    }

    // MARK: - Transient outlier suppression

    func testSingleOutlierFrameIsSuppressed() {
        // Tight jump guard so a single ~60-cent outlier is rejected as a transient.
        var smoother = PitchSmoother(sampleRate: sampleRate, maxCentsJumpPerFrame: 50)
        for _ in 0..<10 {
            _ = smoother.update(rawMeasurement(frequencyHz: 440.0), rms: voiceRMS)
        }
        // ~+60 cents from A4 (440 Hz) ≈ 455.4 Hz.
        let outlier = smoother.update(rawMeasurement(frequencyHz: 455.4), rms: voiceRMS)
        XCTAssertNotNil(outlier.frequencyHz)
        if let frequencyHz = outlier.frequencyHz {
            // The outlier frame is suppressed; the display stays near 440.
            XCTAssertEqual(frequencyHz, 440.0, accuracy: 5.0)
        }
        // Subsequent clean frames keep it pinned near 440.
        for _ in 0..<5 {
            _ = smoother.update(rawMeasurement(frequencyHz: 440.0), rms: voiceRMS)
        }
        let final = smoother.update(rawMeasurement(frequencyHz: 440.0), rms: voiceRMS)
        XCTAssertNotNil(final.frequencyHz)
        if let frequencyHz = final.frequencyHz {
            XCTAssertEqual(frequencyHz, 440.0, accuracy: 1.0)
        }
    }

    // MARK: - Silence gating

    func testSilenceProducesIdle() {
        var smoother = PitchSmoother(sampleRate: sampleRate)
        _ = smoother.update(rawMeasurement(frequencyHz: 440.0), rms: voiceRMS)
        // Feed silent (low RMS) frames; after the hold window the output should go idle.
        var out: PitchMeasurement = .idle
        for _ in 0..<10 {
            out = smoother.update(rawMeasurement(frequencyHz: 440.0), rms: 0.0001)
        }
        XCTAssertNil(out.frequencyHz)
        XCTAssertEqual(out, .idle)
    }

    func testHoldThenIdleAfterSignalLoss() {
        var smoother = PitchSmoother(sampleRate: sampleRate)
        let stable = smoother.update(rawMeasurement(frequencyHz: 440.0), rms: voiceRMS)
        XCTAssertEqual(stable.noteName, "A4")
        // First hold frames keep the last measurement.
        let held = smoother.update(rawMeasurement(frequencyHz: 440.0), rms: 0.0001)
        XCTAssertEqual(held.noteName, "A4")
        // After holdFramesWhenSilent + 1 the smoother goes idle.
        for _ in 0..<6 {
            _ = smoother.update(rawMeasurement(frequencyHz: 440.0), rms: 0.0001)
        }
        let final = smoother.update(rawMeasurement(frequencyHz: 440.0), rms: 0.0001)
        XCTAssertNil(final.frequencyHz)
    }

    func testResetReturnsToIdle() {
        var smoother = PitchSmoother(sampleRate: sampleRate)
        _ = smoother.update(rawMeasurement(frequencyHz: 440.0), rms: voiceRMS)
        smoother.reset()
        let out = smoother.update(rawMeasurement(frequencyHz: 440.0), rms: 0.0001)
        XCTAssertNil(out.frequencyHz)
    }
}
