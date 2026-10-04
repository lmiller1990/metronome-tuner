import SwiftUI
import Foundation

/// Semicircular cents gauge for the tuner: -50…+50 cents with the needle pointing
/// straight up at 0 (flat points left, sharp points right).
///
/// Purely presentational: it reads a cents value and never performs audio or DSP work.
/// Direction is readable without colour — needle position, the FLAT/IN TUNE/SHARP row,
/// and the numeric scale.
struct TunerGauge: View {
    /// Cents deviation from the nearest note, or `nil` when no reliable pitch (idle).
    let cents: Double?

    private static let maxCents = 50.0
    private static let inTuneCents = 5.0

    private var isActive: Bool { cents != nil }
    private var clamped: Double { min(max(cents ?? 0, -Self.maxCents), Self.maxCents) }
    private var isInTune: Bool { isActive && abs(clamped) <= Self.inTuneCents }

    var body: some View {
        VStack(spacing: 4) {
            statusLabels
            GeometryReader { geo in
                let metrics = GaugeMetrics(size: geo.size)
                ZStack(alignment: .bottom) {
                    Canvas { context, _ in
                        drawStatic(in: &context, metrics: metrics)
                    }
                    needle(metrics)
                    hub(metrics)
                }
            }
        }
    }

    // MARK: - Labels

    private var statusLabels: some View {
        HStack(spacing: 0) {
            statusLabel("FLAT", highlighted: isActive && clamped < -Self.inTuneCents)
            Spacer(minLength: 4)
            statusLabel("IN TUNE", highlighted: isInTune)
            Spacer(minLength: 4)
            statusLabel("SHARP", highlighted: isActive && clamped > Self.inTuneCents)
        }
        .padding(.horizontal, 4)
    }

    private func statusLabel(_ text: String, highlighted: Bool) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .tracking(1.2)
            .foregroundStyle(highlighted ? Color.green : Color.white.opacity(0.35))
    }

    // MARK: - Needle

    private var needleColor: Color {
        isActive ? Self.tint(forCents: clamped) : Color.white.opacity(0.45)
    }

    private func needle(_ metrics: GaugeMetrics) -> some View {
        let degrees = 1.8 * clamped // ±50 cents ↔ ±90°
        return Capsule()
            .fill(needleColor)
            .frame(width: 3.5, height: max(12, metrics.radius - 12))
            .rotationEffect(.degrees(degrees), anchor: .bottom)
            .animation(.easeOut(duration: 0.15), value: degrees)
            .offset(y: -6)
            .opacity(isActive ? 1 : 0.55)
    }

    private func hub(_ metrics: GaugeMetrics) -> some View {
        Circle()
            .fill(needleColor)
            .frame(width: 12, height: 12)
            .position(x: metrics.center.x, y: metrics.center.y)
    }

    // MARK: - Static drawing

    private func drawStatic(in context: inout GraphicsContext, metrics: GaugeMetrics) {
        let center = metrics.center
        let radius = metrics.radius

        context.stroke(
            Self.arcPath(center: center, radius: radius, fromCents: -Self.maxCents, toCents: Self.maxCents),
            with: .color(Color.white.opacity(0.14)),
            style: StrokeStyle(lineWidth: 8, lineCap: .round)
        )

        context.stroke(
            Self.arcPath(center: center, radius: radius, fromCents: -Self.inTuneCents, toCents: Self.inTuneCents),
            with: .color(Color.green.opacity(isInTune ? 1.0 : 0.55)),
            style: StrokeStyle(lineWidth: 8)
        )

        for tick in stride(from: -50, through: 50, by: 5) {
            let major = tick % 10 == 0
            let angle = Self.angleRadians(forCents: Double(tick))
            let outer = radius - 5
            let inner = outer - (major ? 12 : 7)
            var line = Path()
            line.move(to: CGPoint(x: center.x + outer * CGFloat(cos(angle)),
                                  y: center.y + outer * CGFloat(sin(angle))))
            line.addLine(to: CGPoint(x: center.x + inner * CGFloat(cos(angle)),
                                     y: center.y + inner * CGFloat(sin(angle))))
            let color: Color = abs(tick) <= Int(Self.inTuneCents)
                ? Color.green.opacity(0.9)
                : Self.tint(forCents: Double(tick)).opacity(0.5)
            context.stroke(line,
                           with: .color(color),
                           style: StrokeStyle(lineWidth: major ? 2 : 1, lineCap: .round))
        }

        drawScaleNumber("-50¢", atCents: -Self.maxCents, radius: radius, center: center, in: &context)
        drawScaleNumber("+50¢", atCents: Self.maxCents, radius: radius, center: center, in: &context)
    }

    private func drawScaleNumber(_ text: String,
                                 atCents cents: Double,
                                 radius: CGFloat,
                                 center: CGPoint,
                                 in context: inout GraphicsContext) {
        let angle = Self.angleRadians(forCents: cents)
        let r = radius * 0.74
        let point = CGPoint(x: center.x + r * CGFloat(cos(angle)),
                            y: center.y + r * CGFloat(sin(angle)))
        let label = Text(text)
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(Color.white.opacity(0.4))
        context.draw(label, at: point)
    }

    // MARK: - Geometry

    /// Semi-transparent green when in tune, warm orange → red toward the extremes.
    private static func tint(forCents cents: Double) -> Color {
        let magnitude = min(abs(cents), maxCents)
        if magnitude <= inTuneCents { return .green }
        let t = (magnitude - inTuneCents) / (maxCents - inTuneCents)
        let hue = 0.11 * (1 - t) // orange → red
        return Color(hue: hue, saturation: 0.9, brightness: 1.0)
    }

    /// Screen angle for a cents value: -50 → 180° (left), 0 → 270° (up), +50 → 360° (right).
    private static func angleRadians(forCents cents: Double) -> Double {
        (270.0 + 1.8 * cents) * .pi / 180.0
    }

    /// Polyline approximation of an arc so the sweep direction is unambiguous.
    private static func arcPath(center: CGPoint, radius: CGFloat,
                                fromCents: Double, toCents: Double) -> Path {
        var path = Path()
        let steps = max(2, Int(abs(toCents - fromCents) * 2))
        for i in 0...steps {
            let t = Double(i) / Double(steps)
            let cents = fromCents + (toCents - fromCents) * t
            let angle = angleRadians(forCents: cents)
            let point = CGPoint(x: center.x + radius * CGFloat(cos(angle)),
                                y: center.y + radius * CGFloat(sin(angle)))
            if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        return path
    }

    private struct GaugeMetrics {
        let center: CGPoint
        let radius: CGFloat

        init(size: CGSize) {
            center = CGPoint(x: size.width / 2, y: size.height - 6)
            radius = max(40, min(size.width / 2 - 18, size.height - 34))
        }
    }
}
