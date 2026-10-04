import SwiftUI
import ViolinPracticeCore

/// Single practice screen: top bar, tuner (upper ~half) and metronome (lower half).
///
/// Reads all audio state through the `AudioEngine` seam and never performs DSP or audio
/// work. The tuner and metronome are always visible and functional simultaneously; the
/// Start/Stop button affects only the metronome.
@MainActor
struct PracticeView: View {
    @State private var engine: AudioEngine

    init(engine: AudioEngine) {
        _engine = State(initialValue: engine)
    }

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                topBar
                referenceLabel
                tuner
                    .frame(height: max(200, geo.size.height * 0.44))
                metronome
                    .frame(maxHeight: .infinity)
            }
            .background(Color.black.ignoresSafeArea())
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.6))
                .accessibilityHidden(true)
            Spacer()
            Text("Tuner · Metronome")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
            Spacer()
            Image(systemName: "gearshape")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.6))
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 2)
    }

    private var referenceLabel: some View {
        Text("A4 = 440 Hz")
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .foregroundStyle(Color.white.opacity(0.35))
            .padding(.bottom, 4)
    }

    // MARK: - Tuner

    private var tuner: some View {
        VStack(spacing: 2) {
            TunerGauge(cents: engine.pitch.frequencyHz == nil ? nil : engine.pitch.cents)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            NoteDisplay(pitch: engine.pitch)
        }
        .padding(.horizontal, 20)
    }

    // MARK: - Metronome

    private var metronome: some View {
        VStack(spacing: 6) {
            MetronomeControls(
                bpm: engine.metronome.bpm,
                onDecrement: { step(-1) },
                onIncrement: { step(1) }
            )
            .padding(.top, 4)

            HStack(spacing: 0) {
                Text("\(engine.metronome.beatsPerMeasure)/4")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.4))
                Spacer(minLength: 0)
                PendulumView(phase: engine.pendulumPhase)
                    .frame(maxWidth: 240, maxHeight: .infinity)
                Spacer(minLength: 0)
                Image(systemName: "speaker.wave.2")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.4))
                    .accessibilityHidden(true)
            }
            .frame(maxHeight: .infinity)
            .padding(.horizontal, 24)

            startStopButton
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
    }

    private var startStopButton: some View {
        let running = engine.metronome.isRunning
        return Button {
            if running {
                engine.stopMetronome()
            } else {
                engine.startMetronome()
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: running ? "stop.fill" : "play.fill")
                Text(running ? "Stop" : "Start")
            }
            .font(.system(size: 19, weight: .bold, design: .rounded))
            .foregroundStyle(.black)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(running ? Color.red.opacity(0.9) : Color.green)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Actions

    /// Steps the tempo by ±1 BPM, clamped to the metronome's supported range.
    private func step(_ delta: Double) {
        let range = MetronomeState.bpmRange
        let next = min(max(engine.metronome.bpm + delta, range.lowerBound), range.upperBound)
        guard next != engine.metronome.bpm else { return }
        engine.setBPM(next)
    }
}
