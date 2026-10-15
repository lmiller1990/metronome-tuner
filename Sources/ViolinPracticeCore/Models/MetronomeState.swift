/// The click timbre selectable in Settings.
public enum MetronomeSound: String, CaseIterable, Identifiable, Sendable {
    case clap1
    case clap2

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .clap1: return "Clap 1"
        case .clap2: return "Clap 2"
        }
    }
}

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

    /// Output level of the metronome clicks, independent of the system volume.
    /// 0 = silent, 1 = unity (full-scale peak), up to 4 = boosted with soft
    /// limiting in the render block. Defaults to 1.
    public var volume: Double = 1

    /// Which click timbre the metronome plays. Defaults to `.clap1`.
    public var sound: MetronomeSound = .clap1

    public init() {}

    /// Supported tempo range for the POC.
    public static let bpmRange: ClosedRange<Double> = 30...240

    /// Supported metronome volume range. Values above 1 add gain and are
    /// soft-limited in the render block so the click stays audible without
    /// hard digital clipping.
    public static let volumeRange: ClosedRange<Double> = 0...4
}
