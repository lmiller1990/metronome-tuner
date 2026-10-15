import Foundation

/// A single metronome beat scheduled on the shared audio sample timeline.
public struct BeatEvent: Equatable, Sendable {
    /// Absolute sample index (on the scheduler's sample clock) at which the beat occurs.
    public var sampleIndex: Int
    /// Beat within the measure, `1...beatsPerMeasure`. Beat 1 is the downbeat.
    public var beatNumber: Int
}

/// Pure sample-domain metronome timing.
///
/// This type holds no AVFoundation or wall-clock dependency: every position is an absolute
/// sample index, so the owner (e.g. `MetronomeEngine`) can feed it the current audio-timeline
/// window and get back the beats that fall inside it. All arithmetic is deterministic.
public struct MetronomeScheduler {
    private let sampleRate: Double
    private let beatsPerMeasure: Int

    /// Current tempo in BPM; always within `MetronomeState.bpmRange`.
    private var bpm: Double

    /// Absolute sample position of the next beat to emit.
    private var nextBeatSample: Double
    /// Beat number of `nextBeatSample`, in `1...beatsPerMeasure`.
    private var nextBeatNumber: Int
    /// Sample position up to which the caller has already advanced the phase.
    private var cursorSample: Double

    public init(sampleRate: Double, bpm: Double, beatsPerMeasure: Int) {
        self.sampleRate = sampleRate
        self.bpm = Self.clampedBPM(bpm)
        self.beatsPerMeasure = max(1, beatsPerMeasure)
        // The first beat of the timeline is the downbeat, at sample 0.
        self.nextBeatSample = 0
        self.nextBeatNumber = 1
        self.cursorSample = 0
    }

    /// Duration of one beat in seconds at `bpm`.
    public static func secondsPerBeat(bpm: Double) -> Double {
        60.0 / bpm
    }

    /// Samples between beats at the current tempo.
    private var samplesPerBeat: Double {
        sampleRate * Self.secondsPerBeat(bpm: bpm)
    }

    private static func clampedBPM(_ bpm: Double) -> Double {
        min(max(bpm, MetronomeState.bpmRange.lowerBound), MetronomeState.bpmRange.upperBound)
    }

    /// Change the tempo, clamped to `MetronomeState.bpmRange`.
    ///
    /// The phase of the current beat is preserved: the fraction of the beat already elapsed at
    /// the cursor is kept, so the next beat is re-timed under the new tempo rather than firing
    /// immediately or being skipped.
    public mutating func setBPM(_ bpm: Double) {
        let clamped = Self.clampedBPM(bpm)
        guard clamped != self.bpm else { return }

        let oldSamplesPerBeat = samplesPerBeat
        let remainingSamples = max(0, nextBeatSample - cursorSample)
        let remainingFraction = oldSamplesPerBeat > 0 ? remainingSamples / oldSamplesPerBeat : 0

        self.bpm = clamped
        nextBeatSample = cursorSample + remainingFraction * samplesPerBeat
    }

    /// Beats whose `sampleIndex` lies in `[startSample, endSample)`, advancing internal phase.
    ///
    /// Ranges are expected to advance monotonically; beats that fall entirely before `start` are
    /// consumed (advancing the measure count) without being emitted.
    public mutating func beats(inSampleRange start: Int, _ end: Int) -> [BeatEvent] {
        guard end > start else { return [] }
        let rangeStart = Double(start)
        let rangeEnd = Double(end)

        // Consume beats that already lie before the requested window.
        while nextBeatSample < rangeStart {
            advance()
        }

        var events: [BeatEvent] = []
        while nextBeatSample < rangeEnd {
            events.append(BeatEvent(sampleIndex: Int(nextBeatSample),
                                    beatNumber: nextBeatNumber))
            advance()
        }

        cursorSample = rangeEnd
        return events
    }

    private mutating func advance() {
        nextBeatSample += samplesPerBeat
        nextBeatNumber = nextBeatNumber % beatsPerMeasure + 1
    }
}
