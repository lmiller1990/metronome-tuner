/// User-facing metronome configuration and playback state.
public struct MetronomeState: Equatable, Sendable {

    /// Tempo in beats per minute. Defaults to 60.
    public var bpm: Double = 60

    /// Beats per measure (4 = 4/4 time). Defaults to 4.
    public var beatsPerMeasure: Int = 4

    /// Whether the metronome is currently running.
    public var isRunning: Bool = false

    /// Current beat within the measure. 0 = not started; 1...beatsPerMeasure while running.
    public var currentBeat: Int = 0

    /// Whether beat 1 of each measure is accented. Defaults to true.
    public var accentFirstBeat: Bool = true

    public init() {}

    /// Supported tempo range for the POC.
    public static let bpmRange: ClosedRange<Double> = 30...240
}
