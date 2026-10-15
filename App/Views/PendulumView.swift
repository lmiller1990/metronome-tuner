import SwiftUI
import Foundation

/// Deterministic mapping from a beat phase to a pendulum swing angle.
///
/// Kept separate (and free of any state or animation) so the phase → angle mapping
/// is a pure, testable function of its input.
enum PendulumGeometry {
    static let maxAngleDegrees = 42.0

    /// `phase` is 0…1 progress through the current beat, from `AudioEngine.pendulumPhase`.
    /// The arm performs one full, continuous left→right→left swing per beat: it is at an
    /// extreme (±`maxAngleDegrees`) exactly when the beat sounds (phase 0) and is vertical
    /// at mid-beat, returning to the same extreme at phase 1 so there is no discontinuity
    /// when the phase wraps at the next beat. Values outside 0…1 are clamped.
    static func angleDegrees(forPhase phase: Double) -> Double {
        let clamped = min(max(phase, 0), 1)
        return maxAngleDegrees * cos(2 * .pi * clamped)
    }
}

/// Physical-metronome pendulum. The arm angle is derived solely from `phase` — there is
/// no independent looping animation, so the visual motion tracks the audible beat timing.
struct PendulumView: View {
    /// 0…1 progress through the current beat (`AudioEngine.pendulumPhase`).
    let phase: Double

    private var angle: Double { PendulumGeometry.angleDegrees(forPhase: phase) }

    var body: some View {
        GeometryReader { geo in
            let length = max(60, min(geo.size.height - 16, geo.size.width * 0.62))
            ZStack(alignment: .top) {
                tickMarks(length: length)
                arm(length: length)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Arm

    private func arm(length: CGFloat) -> some View {
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                Capsule()
                    .fill(Color.white.opacity(0.85))
                    .frame(width: 5, height: max(28, length - 30))
                Circle()
                    .fill(Color.green)
                    .frame(width: 24, height: 24)
                    .shadow(color: Color.green.opacity(0.4), radius: 8)
            }
            .frame(width: 28, height: length, alignment: .top)
            .rotationEffect(.degrees(angle), anchor: .top)

            Circle()
                .fill(Color.white.opacity(0.7))
                .frame(width: 14, height: 14)
        }
    }

    // MARK: - Ticks

    private func tickMarks(length: CGFloat) -> some View {
        let radius = length * 0.9
        let values = stride(from: -PendulumGeometry.maxAngleDegrees,
                            through: PendulumGeometry.maxAngleDegrees,
                            by: 7).map { $0 }

        return ZStack(alignment: .top) {
            ForEach(values, id: \.self) { value in
                let isCentre = abs(value) < 0.1
                Capsule()
                    .fill(Color.white.opacity(isCentre ? 0.30 : 0.16))
                    .frame(width: 2.5, height: isCentre ? 14 : 9)
                    .frame(width: 2.5, height: radius, alignment: .bottom)
                    .rotationEffect(.degrees(value), anchor: .top)
            }
        }
    }
}
