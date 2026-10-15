import SwiftUI
import UIKit
import ViolinPracticeCore

/// Single practice screen: top bar, tuner (upper ~half) and metronome (lower half).
///
/// Reads all audio state through the `AudioEngine` seam and never performs DSP or audio
/// work. The tuner and metronome are always visible and functional simultaneously; the
/// Start/Stop button affects only the metronome.
@MainActor
struct PracticeView: View {
    @State private var engine: AudioEngine
    @State private var showSettings = false

    init(engine: AudioEngine) {
        _engine = State(initialValue: engine)
    }

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                topBar
                referenceLabel
                tuner
                    .frame(height: geo.size.height * 0.43)
                divider
                pendulum
                    .frame(height: geo.size.height * 0.35)
                controls
                    .frame(maxHeight: .infinity)
            }
            .background(Color.black.ignoresSafeArea())
        }
        .preferredColorScheme(.dark)
        .onAppear {
            // Keep the screen from auto-locking while the practice screen is up
            // (the whole point of the app). Restored on disappear so the device
            // still sleeps normally elsewhere.
            UIApplication.shared.isIdleTimerDisabled = true
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
        }
        .sheet(isPresented: $showSettings) {
            TuningSettingsView(
                referenceA4Hz: engine.referenceA4Hz,
                sound: engine.metronome.sound,
                volume: engine.metronome.volume,
                onSelectReference: { engine.setReferenceA4Hz($0) },
                onSelectSound: { engine.setMetronomeSound($0) },
                onSelectVolume: { engine.setMetronomeVolume($0) },
                onPreviewSound: { engine.previewMetronomeSound($0) }
            )
        }
    }

    // MARK: - Top bar

    private var topBar: some View {
        ZStack {
            Text("Tuner · Metronome")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.6))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Tuning settings")
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 2)
    }

    private var referenceLabel: some View {
        Text("A4 = \(Self.formatHz(engine.referenceA4Hz)) Hz")
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .foregroundStyle(Color.white.opacity(0.35))
            .padding(.bottom, 2)
    }

    /// Formats a hertz value without trailing noise: whole numbers drop the
    /// decimal point, others show one decimal place.
    private static func formatHz(_ hz: Double) -> String {
        if hz.rounded() == hz {
            return String(Int(hz))
        }
        return String(format: "%.1f", hz)
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

    /// Thin separator between the tuner and metronome regions.
    private var divider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.08))
            .frame(height: 1)
            .padding(.horizontal, 20)
    }

    // MARK: - Metronome

    private var pendulum: some View {
        PendulumView(phase: engine.pendulumPhase)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 24)
    }

    private var controls: some View {
        VStack(spacing: 12) {
            HStack(spacing: 16) {
                MetronomeControls(
                    bpm: engine.metronome.bpm,
                    onDecrement: { step(-1) },
                    onIncrement: { step(1) }
                )
                Text("\(engine.metronome.beatsPerMeasure)/4")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Color.white.opacity(0.4))
            }
            startStopButton
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 16)
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
            .font(.system(size: 17, weight: .bold, design: .rounded))
            .foregroundStyle(.black)
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
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
