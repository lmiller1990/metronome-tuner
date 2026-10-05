import Foundation

/// Pure music-theory math for the chromatic tuner.
///
/// Uses 12-tone equal temperament with a configurable reference pitch
/// (A4 = 440 Hz by default; MIDI note 69, C4 = 60).
public enum MusicTheory {

    /// MIDI note number of the A4 reference (69 corresponds to 440 Hz by default).
    public static let midiForA4 = 69

    /// Default reference pitch for A4, in hertz.
    public static let defaultA4Hz = 440.0

    /// Supported reference pitch range for A4, in hertz. Covers common concert
    /// standards (baroque 415 Hz through 466 Hz) used by the settings screen.
    public static let referenceA4HzRange: ClosedRange<Double> = 415...466

    /// Sharp note spellings for pitch classes 0...11 (C-based).
    private static let sharpNames = [
        "C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"
    ]

    /// Nearest MIDI note for a frequency (12-TET, rounded).
    ///
    /// Rounding is "half down": a frequency exactly midway between two notes resolves
    /// to the lower note. This keeps ``cents(frequencyHz:referenceA4Hz:)`` inside the
    /// documented `(-50, +50]` range instead of producing `-50`.
    ///
    /// - Parameters:
    ///   - frequencyHz: Measured frequency in hertz. Non-positive values return A4.
    ///   - referenceA4Hz: Reference frequency for A4. Defaults to 440 Hz.
    /// - Returns: The MIDI note number nearest to `frequencyHz`.
    public static func nearestMidiNote(frequencyHz: Double, referenceA4Hz: Double = defaultA4Hz) -> Int {
        guard frequencyHz > 0, referenceA4Hz > 0 else { return midiForA4 }
        let exactMidi = Double(midiForA4) + 12.0 * log2(frequencyHz / referenceA4Hz)
        return Int((exactMidi - 0.5).rounded(.up))
    }

    /// Cents from the nearest note; negative = flat, positive = sharp.
    ///
    /// The result lies in the half-open interval `(-50, +50]`.
    ///
    /// - Parameters:
    ///   - frequencyHz: Measured frequency in hertz. Non-positive values return 0.
    ///   - referenceA4Hz: Reference frequency for A4. Defaults to 440 Hz.
    /// - Returns: Signed devation from the nearest note, in cents.
    public static func cents(frequencyHz: Double, referenceA4Hz: Double = defaultA4Hz) -> Double {
        guard frequencyHz > 0, referenceA4Hz > 0 else { return 0 }
        let midi = nearestMidiNote(frequencyHz: frequencyHz, referenceA4Hz: referenceA4Hz)
        let noteHz = frequency(midiNote: midi, referenceA4Hz: referenceA4Hz)
        return 1200.0 * log2(frequencyHz / noteHz)
    }

    /// Exact frequency of a MIDI note under 12-TET.
    ///
    /// - Parameters:
    ///   - midiNote: The MIDI note number.
    ///   - referenceA4Hz: Reference frequency for A4. Defaults to 440 Hz.
    /// - Returns: Frequency in hertz.
    public static func frequency(midiNote: Int, referenceA4Hz: Double = defaultA4Hz) -> Double {
        referenceA4Hz * pow(2.0, Double(midiNote - midiForA4) / 12.0)
    }

    /// Sharp spelling of a note's pitch class, e.g. 69 -> "A", 61 -> "C#".
    ///
    /// Works for any integer MIDI note value (wraps every octave).
    public static func noteName(midiNote: Int) -> String {
        sharpNames[((midiNote % 12) + 12) % 12]
    }

    /// Scientific pitch notation, e.g. 69 -> "A4" (C4 = 60).
    public static func noteNameWithOctave(midiNote: Int) -> String {
        noteName(midiNote: midiNote) + String(octave(for: midiNote))
    }

    /// Conventional Italian tempo marking for a BPM value.
    ///
    /// Bands: <40 Grave, 40..<60 Largo, 60..<76 Adagio, 76..<108 Andante,
    /// 108..<120 Moderato, 120..<156 Allegro, 156..<176 Vivace, >=176 Presto.
    public static func tempoMarking(bpm: Double) -> String {
        switch bpm {
        case ..<40: return "Grave"
        case ..<60: return "Largo"
        case ..<76: return "Adagio"
        case ..<108: return "Andante"
        case ..<120: return "Moderato"
        case ..<156: return "Allegro"
        case ..<176: return "Vivace"
        default: return "Presto"
        }
    }

    /// Octave number for scientific pitch notation (C4 = 60 -> 4), floor-divided
    /// so negative MIDI notes behave correctly.
    private static func octave(for midiNote: Int) -> Int {
        Int(floor(Double(midiNote) / 12.0)) - 1
    }
}
