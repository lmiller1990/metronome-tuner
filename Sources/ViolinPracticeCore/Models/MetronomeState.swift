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

    /// Output level of the metronome clicks, independent of the system volume.
    /// 0 = silent, 1 = full. Defaults to 1.
    public var volume: Double = 1

    public init() {}

    /// Supported tempo range for the POC.
    public static let bpmRange: ClosedRange<Double> = 30...240

    /// Supported metronome volume range.
    public static let volumeRange: ClosedRange<Double> = 0...1
}
