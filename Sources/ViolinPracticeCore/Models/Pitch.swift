/// A single pitch reading produced by the detector/smoother pipeline.
///
/// `frequencyHz == nil` means no reliable pitch was found (silence or unvoiced input);
/// in that case `midiNote`/`noteName` are also `nil` and `cents` is 0.
public struct PitchMeasurement: Equatable, Sendable {

    /// Measured fundamental frequency in hertz, or `nil` when no reliable pitch exists.
    public var frequencyHz: Double?

    /// MIDI note number nearest to `frequencyHz`, or `nil` when no pitch exists.
    public var midiNote: Int?

    /// Scientific pitch name (e.g. "A4"), or `nil` when no pitch exists.
    public var noteName: String?

    /// Signed cents from the nearest note; negative = flat, positive = sharp. 0 when no pitch.
    public var cents: Double

    /// Detector confidence in the range 0...1.
    public var confidence: Double

    public init(frequencyHz: Double? = nil, midiNote: Int? = nil,
                noteName: String? = nil, cents: Double = 0, confidence: Double = 0) {
        self.frequencyHz = frequencyHz
        self.midiNote = midiNote
        self.noteName = noteName
        self.cents = cents
        self.confidence = confidence
    }

    /// The "no pitch" reading used before any analysis has produced a result.
    public static let idle = PitchMeasurement()
}
