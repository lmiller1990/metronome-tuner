import SwiftUI
import ViolinPracticeCore

/// Dark, restrained sheet for configuring the A4 reference pitch.
///
/// Presentational only: it reports the chosen frequency through `onSelect` and never
/// touches audio state directly. Presets cover common concert standards; the slider and
/// stepper allow fine adjustment across `MusicTheory.referenceA4HzRange`.
struct TuningSettingsView: View {
    /// Common concert A4 standards (Hz). 415 = baroque, 440 = ISO 16, 442/443/444 = sharp orchestral.
    private static let presets: [Double] = [415, 432, 440, 442, 443, 444]
    private static let stepHz: Double = 0.5

    private let onSelect: (Double) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedHz: Double

    init(referenceA4Hz: Double, onSelect: @escaping (Double) -> Void) {
        self.onSelect = onSelect
        _selectedHz = State(initialValue: referenceA4Hz)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 28) {
                currentValue
                presetsRow
                fineControls
                Spacer(minLength: 0)
            }
            .padding(24)
            .navigationTitle("Tuning")
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
            onSelect(newValue)
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

    // MARK: - Formatting

    /// Whole hertz values drop the decimal point; fractional values show one decimal place.
    private static func formatted(_ hz: Double) -> String {
        if hz.rounded() == hz {
            return String(Int(hz))
        }
        return String(format: "%.1f", hz)
    }
}
