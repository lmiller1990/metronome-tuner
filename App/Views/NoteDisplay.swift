import SwiftUI
import Foundation
import ViolinPracticeCore

/// Dominant detected note plus its frequency and cents deviation.
///
/// Shows a neutral idle state (`—` / `Listening…`) so an unreliable signal never
/// renders a random note. Presentational only.
struct NoteDisplay: View {
    let pitch: PitchMeasurement

    private static let inTuneCents = 5.0

    private var isActive: Bool { pitch.frequencyHz != nil && pitch.noteName != nil }
    private var isInTune: Bool { isActive && abs(pitch.cents) <= Self.inTuneCents }

    private var letter: String {
        if let midi = pitch.midiNote {
            return MusicTheory.noteName(midiNote: midi)
        }
        // Fall back to stripping the octave from e.g. "A4".
        guard let name = pitch.noteName else { return "—" }
        return name.trimmingCharacters(in: CharacterSet(charactersIn: "0123456789"))
    }

    var body: some View {
        VStack(spacing: 2) {
            Text(isActive ? letter : "—")
                .font(.system(size: 76, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(isActive ? Color.white : Color.white.opacity(0.3))
                .contentTransition(.numericText())
                .animation(.easeOut(duration: 0.15), value: pitch.noteName)

            if isActive {
                Text(frequencyText)
                    .font(.system(size: 20, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Color.white.opacity(0.85))
                Text(centsText)
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(isInTune ? Color.green : Color.white.opacity(0.6))
            } else {
                Text("Listening…")
                    .font(.system(size: 18, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.45))
            }
        }
        .frame(maxWidth: .infinity)
        .animation(.easeOut(duration: 0.15), value: isActive)
    }

    private var frequencyText: String {
        guard let hz = pitch.frequencyHz else { return "-- Hz" }
        return String(format: "%.1f Hz", hz)
    }

    private var centsText: String {
        if abs(pitch.cents) < 0.5 { return "0 cents" }
        return String(format: "%+.0f cents", pitch.cents)
    }
}
