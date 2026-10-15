import SwiftUI
import ViolinPracticeCore

/// Dark, restrained sheet for configuring the A4 reference pitch, metronome sound,
/// and metronome volume.
///
/// Presentational only: it reports the chosen frequency through `onSelectReference`,
/// the chosen sound through `onSelectSound`, the chosen volume through `onSelectVolume`,
/// and previews through `onPreviewSound`; it never touches audio state directly.
/// Presets cover common concert standards; the slider and stepper allow fine
/// adjustment across `MusicTheory.referenceA4HzRange`.
struct TuningSettingsView: View {
    /// Common concert A4 standards (Hz). 415 = baroque, 440 = ISO 16, 442/443/444 = sharp orchestral.
    private static let presets: [Double] = [415, 432, 440, 442, 443, 444]
    private static let stepHz: Double = 0.5

    private let onSelectReference: (Double) -> Void
    private let onSelectSound: (MetronomeSound) -> Void
    private let onSelectVolume: (Double) -> Void
    private let onPreviewSound: (MetronomeSound) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedHz: Double
    @State private var selectedSound: MetronomeSound
    @State private var selectedVolume: Double

    init(referenceA4Hz: Double,
         sound: MetronomeSound,
         volume: Double,
         onSelectReference: @escaping (Double) -> Void,
         onSelectSound: @escaping (MetronomeSound) -> Void,
         onSelectVolume: @escaping (Double) -> Void,
         onPreviewSound: @escaping (MetronomeSound) -> Void) {
        self.onSelectReference = onSelectReference
        self.onSelectSound = onSelectSound
        self.onSelectVolume = onSelectVolume
        self.onPreviewSound = onPreviewSound
        _selectedHz = State(initialValue: referenceA4Hz)
        _selectedSound = State(initialValue: sound)
        _selectedVolume = State(initialValue: volume)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 28) {
                currentValue
                presetsRow
                fineControls
                soundSection
                volumeSection
                Spacer(minLength: 0)
            }
            .padding(24)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(.white)
                }
            }
        }
        .preferredColorScheme(.dark)
        .onChange(of: selectedHz) { _, newValue in
            onSelectReference(newValue)
        }
        .onChange(of: selectedVolume) { _, newValue in
            onSelectVolume(newValue)
        }
    }

    // MARK: - Current value

    private var currentValue: some View {
        VStack(spacing: 0) {
            Text("A4 Reference")
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .tracking(1.2)
                .foregroundStyle(Color.white.opacity(0.5))
            Text("\(Self.formatted(selectedHz)) Hz")
                .font(.system(size: 52, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
                .contentTransition(.numericText())
                .animation(.easeOut(duration: 0.12), value: selectedHz)
        }
        .padding(.top, 8)
    }

    // MARK: - Presets

    private var presetsRow: some View {
        VStack(spacing: 10) {
            Text("PRESETS")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .tracking(1.5)
                .foregroundStyle(Color.white.opacity(0.4))
            HStack(spacing: 10) {
                ForEach(Self.presets, id: \.self) { preset in
                    presetChip(preset)
                }
            }
        }
    }

    private func presetChip(_ preset: Double) -> some View {
        let isSelected = abs(selectedHz - preset) < 0.01
        return Button {
            selectedHz = preset
        } label: {
            Text(Self.formatted(preset))
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(isSelected ? Color.black : Color.white.opacity(0.8))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(isSelected ? Color.green : Color.white.opacity(0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(isSelected ? Color.green : Color.white.opacity(0.12), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.12), value: isSelected)
    }

    // MARK: - Fine controls

    private var fineControls: some View {
        VStack(spacing: 12) {
            Slider(
                value: $selectedHz,
                in: MusicTheory.referenceA4HzRange,
                step: Self.stepHz
            )
            .tint(Color.green)

            HStack {
                Text(Self.formatted(MusicTheory.referenceA4HzRange.lowerBound))
                Spacer()
                Stepper(
                    "Adjust",
                    value: $selectedHz,
                    in: MusicTheory.referenceA4HzRange,
                    step: Self.stepHz
                )
                .labelsHidden()
                Spacer()
                Text(Self.formatted(MusicTheory.referenceA4HzRange.upperBound))
            }
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(Color.white.opacity(0.4))
        }
    }

    // MARK: - Metronome sound

    private var soundSection: some View {
        VStack(spacing: 10) {
            Text("METRONOME SOUND")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .tracking(1.5)
                .foregroundStyle(Color.white.opacity(0.4))
            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)],
                spacing: 10
            ) {
                ForEach(MetronomeSound.allCases) { sound in
                    soundChip(sound)
                }
            }
            Button {
                onPreviewSound(selectedSound)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "play.circle.fill")
                    Text("Preview")
                }
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.white.opacity(0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Metronome volume

    private var volumeSection: some View {
        VStack(spacing: 10) {
            Text("METRONOME VOLUME")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .tracking(1.5)
                .foregroundStyle(Color.white.opacity(0.4))
            HStack(spacing: 12) {
                Image(systemName: volumeSymbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.5))
                    .frame(width: 22)
                    .accessibilityHidden(true)
                Slider(value: $selectedVolume, in: MetronomeState.volumeRange)
                    .tint(Color.green)
                    .accessibilityLabel("Metronome volume")
                    .accessibilityValue("\(Int((selectedVolume * 100).rounded())) percent")
            }
        }
    }

    private var volumeSymbol: String {
        switch selectedVolume {
        case ..<0.01: return "speaker.slash.fill"
        case ..<0.5: return "speaker.wave.1.fill"
        default: return "speaker.wave.2.fill"
        }
    }

    private func soundChip(_ sound: MetronomeSound) -> some View {
        let isSelected = selectedSound == sound
        return Button {
            selectedSound = sound
            onSelectSound(sound)
        } label: {
            Text(sound.displayName)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(isSelected ? Color.black : Color.white.opacity(0.8))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(isSelected ? Color.green : Color.white.opacity(0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(isSelected ? Color.green : Color.white.opacity(0.12), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.12), value: isSelected)
    }

    // MARK: - Formatting

    /// Whole hertz values drop the decimal point; fractional values show one decimal place.
    private static func formatted(_ hz: Double) -> String {
        if hz.rounded() == hz {
            return String(Int(hz))
        }
        return String(format: "%.1f", hz)
    }
}
