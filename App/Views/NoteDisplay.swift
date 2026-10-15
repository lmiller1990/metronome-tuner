import SwiftUI
import Foundation
import ViolinPracticeCore

/// Dominant detected note plus its frequency.
///
/// Shows a neutral idle state (`—`) so an unreliable signal never renders a random
/// note. Presentational only.
struct NoteDisplay: View {
    let pitch: PitchMeasurement

    private var isActive: Bool { pitch.frequencyHz != nil && pitch.noteName != nil }

    private var letter: String {
        if let midi = pitch.midiNote {
            return MusicTheory.noteName(midiNote: midi)
        }
        // Fall back to stripping the octave from e.g. "A4".
        guard let name = pitch.noteName else { return "—" }
        return name.trimmingCharacters(in: CharacterSet(charactersIn: "0123456789"))
    }

    var body: some View {
        VStack(spacing: 4) {
            Text(isActive ? letter : "—")
                .font(.system(size: 76, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(isActive ? Color.white : Color.white.opacity(0.3))
                .contentTransition(.numericText())
                .animation(.easeOut(duration: 0.15), value: pitch.noteName)

            Text(frequencyText)
                .font(.system(size: 22, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Color.white.opacity(0.85))
                .opacity(isActive ? 1 : 0)
        }
        .frame(maxWidth: .infinity)
        .animation(.easeOut(duration: 0.15), value: isActive)
    }

    private var frequencyText: String {
        guard let hz = pitch.frequencyHz else { return "-- Hz" }
        return String(format: "%.1f Hz", hz)
    }

}
