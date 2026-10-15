import SwiftUI
import ViolinPracticeCore

/// Tempo readout and step controls for the metronome.
///
/// Tap −/+ steps by 1 BPM; press and hold repeats. Presentational only — the caller
/// decides how the change reaches `AudioEngine.setBPM(_:)`.
struct MetronomeControls: View {
    let bpm: Double
    let onDecrement: () -> Void
    let onIncrement: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            StepButton(systemName: "minus", action: onDecrement)
            VStack(spacing: -2) {
                Text("\(displayedBPM)")
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .contentTransition(.numericText())
                    .animation(.easeOut(duration: 0.12), value: displayedBPM)
                Text(MusicTheory.tempoMarking(bpm: bpm))
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .tracking(1.2)
                    .foregroundStyle(Color.white.opacity(0.5))
            }
            .frame(minWidth: 76)
            StepButton(systemName: "plus", action: onIncrement)
        }
    }

    private var displayedBPM: Int { Int(bpm.rounded()) }
}

/// Circular step button: fires once on touch-down, then repeats while held.
@MainActor
private struct StepButton: View {
    let systemName: String
    let action: () -> Void

    @State private var repeatTask: Task<Void, Never>?

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 36, height: 36)
            .background(Circle().fill(Color.white.opacity(0.08)))
            .overlay(Circle().stroke(Color.white.opacity(0.12), lineWidth: 1))
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in beginPress() }
                    .onEnded { _ in endPress() }
            )
            .accessibilityLabel(systemName == "plus" ? "Increase tempo" : "Decrease tempo")
    }

    private func beginPress() {
        guard repeatTask == nil else { return }
        action()
        repeatTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(450))
            while !Task.isCancelled {
                action()
                try? await Task.sleep(for: .milliseconds(80))
            }
        }
    }

    private func endPress() {
        repeatTask?.cancel()
        repeatTask = nil
    }
}
