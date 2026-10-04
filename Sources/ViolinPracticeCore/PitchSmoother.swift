import Foundation

/// Stabilizes raw pitch measurements for UI display.
///
/// The smoother gates out silence (by RMS) and low-confidence frames, rejects
/// single-frame transient jumps, exponentially smooths the cents offset within a note, and
/// requires several consecutive frames on a new note before switching the displayed note.
/// After signal loss it holds the last measurement briefly before going idle, so the tuner
/// needle and note do not flicker.
public struct PitchSmoother {
    public let sampleRate: Double
    /// Frames below this confidence are discarded.
    public let minConfidence: Double
    /// Frames whose RMS is below this are treated as silence.
    public let silenceRMSThreshold: Double
    /// A single-frame jump larger than this many cents is rejected as a transient.
    public let maxCentsJumpPerFrame: Double
    /// Number of consecutive frames on a new note required before switching the display.
    public let noteChangeConfirmationFrames: Int
    /// Number of frames to keep showing the last measurement after signal loss before idling.
    public let holdFramesWhenSilent: Int

    /// Exponential smoothing factor for the cents offset (0...1; 1 = no smoothing).
    private let centsAlpha: Double = 0.35

    // Internal state.
    private var display: PitchMeasurement = .idle
    private var displayNote: Int?
    private var smoothedCents: Double = 0
    private var lastRawNote: Int?
    private var lastRawCents: Double = 0
    private var candidateNote: Int?
    private var candidateCount: Int = 0
    private var holdCount: Int = 0

    public init(sampleRate: Double,
                minConfidence: Double = 0.9,
                silenceRMSThreshold: Double = 0.005,
                maxCentsJumpPerFrame: Double = 200,
                noteChangeConfirmationFrames: Int = 2,
                holdFramesWhenSilent: Int = 5) {
        self.sampleRate = sampleRate
        self.minConfidence = minConfidence
        self.silenceRMSThreshold = silenceRMSThreshold
        self.maxCentsJumpPerFrame = maxCentsJumpPerFrame
        self.noteChangeConfirmationFrames = max(1, noteChangeConfirmationFrames)
        self.holdFramesWhenSilent = max(0, holdFramesWhenSilent)
    }

    /// Feed one raw measurement (+ frame RMS). Returns the stabilized measurement for UI.
    ///
    /// - Parameters:
    ///   - raw: a single `PitchMeasurement` from `PitchDetector.measure`.
    ///   - rms: the frame's root-mean-square level (0 = silence).
    /// - Returns: the measurement to show on screen.
    public mutating func update(_ raw: PitchMeasurement, rms: Double) -> PitchMeasurement {
        // Gate 1: silence / very low input.
        // Gate 2: insufficient confidence or missing frequency.
        let gated = rms < silenceRMSThreshold
            || raw.confidence < minConfidence
            || raw.frequencyHz == nil

        if gated {
            holdCount += 1
            if holdCount > holdFramesWhenSilent {
                // Held long enough: go idle and clear any in-flight note transition.
                display = .idle
                displayNote = nil
                smoothedCents = 0
                candidateNote = nil
                candidateCount = 0
            }
            return display
        }

        // Valid frame: reset the hold timer.
        holdCount = 0

        let frequencyHz = raw.frequencyHz!
        let note = MusicTheory.nearestMidiNote(frequencyHz: frequencyHz)
        let cents = MusicTheory.cents(frequencyHz: frequencyHz)

        // First valid frame after idle: adopt immediately (no confirmation window).
        guard let current = displayNote else {
            displayNote = note
            smoothedCents = cents
            lastRawNote = note
            lastRawCents = cents
            candidateNote = nil
            candidateCount = 0
            display = buildDisplay(note: note, centsOffset: smoothedCents, confidence: raw.confidence)
            return display
        }

        if note == current {
            // Same note: cancel any pending note change and smooth.
            candidateNote = nil
            candidateCount = 0

            // Reject a single-frame transient jump within the note.
            if let lastNote = lastRawNote, lastNote == note {
                let jump = abs(cents - lastRawCents)
                if jump > maxCentsJumpPerFrame {
                    // Suppress this frame but keep the last valid raw for the next comparison.
                    lastRawCents = cents
                    return display
                }
            }

            smoothedCents = centsAlpha * cents + (1 - centsAlpha) * smoothedCents
            lastRawNote = note
            lastRawCents = cents
            display = buildDisplay(note: note, centsOffset: smoothedCents, confidence: raw.confidence)
            return display
        }

        // Different note: require confirmation frames before switching.
        lastRawNote = note
        lastRawCents = cents
        if candidateNote == note {
            candidateCount += 1
            if candidateCount >= noteChangeConfirmationFrames {
                displayNote = note
                smoothedCents = cents
                candidateNote = nil
                candidateCount = 0
                display = buildDisplay(note: note, centsOffset: smoothedCents, confidence: raw.confidence)
                return display
            }
        } else {
            candidateNote = note
            candidateCount = 1
        }
        // Still confirming (or just reset): keep showing the current note.
        return display
    }

    /// Reset to idle, clearing all smoothing and note-transition state.
    public mutating func reset() {
        display = .idle
        displayNote = nil
        smoothedCents = 0
        lastRawNote = nil
        lastRawCents = 0
        candidateNote = nil
        candidateCount = 0
        holdCount = 0
    }

    /// Build the measurement for `note` at the given cents offset from its exact frequency.
    private func buildDisplay(note: Int, centsOffset: Double, confidence: Double) -> PitchMeasurement {
        let noteHz = MusicTheory.frequency(midiNote: note)
        let frequencyHz = noteHz * pow(2.0, centsOffset / 1200.0)
        return PitchMeasurement(
            frequencyHz: frequencyHz,
            midiNote: note,
            noteName: MusicTheory.noteNameWithOctave(midiNote: note),
            cents: centsOffset,
            confidence: confidence
        )
    }
}
