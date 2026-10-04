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
        VStack(spacing: 8) {
            Text(MusicTheory.tempoMarking(bpm: bpm))
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .tracking(1.0)
                .foregroundStyle(Color.white.opacity(0.5))
                .animation(.easeOut(duration: 0.15), value: displayedBPM)

            HStack(spacing: 28) {
                StepButton(systemName: "minus", action: onDecrement)
                VStack(spacing: -2) {
                    Text("\(displayedBPM)")
                        .font(.system(size: 60, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .contentTransition(.numericText())
                        .animation(.easeOut(duration: 0.12), value: displayedBPM)
                    Text("BPM")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .tracking(2)
                        .foregroundStyle(Color.white.opacity(0.4))
                }
                .frame(minWidth: 116)
                StepButton(systemName: "plus", action: onIncrement)
            }
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
            .font(.system(size: 22, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 54, height: 54)
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
