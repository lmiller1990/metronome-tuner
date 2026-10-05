import XCTest
@testable import ViolinPracticeCore

final class YinTests: XCTestCase {

    // MARK: - Helpers

    private let sampleRate = 44100.0

    /// Generate a mono sine wave (optionally with additive Gaussian-ish noise).
    private func makeSine(
        frequency: Double,
        length: Int = 4096,
        sampleRate: Double = 44100.0,
        noiseAmplitude: Double = 0.0
    ) -> [Float] {
        var rng = SystemRandomNumberGenerator()
        return (0..<length).map { i in
            let t = Double(i) / sampleRate
            let signal = sin(2.0 * .pi * frequency * t)
            let noise = noiseAmplitude * Double.random(in: -1...1, using: &rng)
            return Float(signal + noise)
        }
    }

    /// Generate white noise (uniform) of the given amplitude.
    private func makeNoise(length: Int = 4096, amplitude: Double = 0.5) -> [Float] {
        var rng = SystemRandomNumberGenerator()
        return (0..<length).map { _ in
            Float(amplitude * Double.random(in: -1...1, using: &rng))
        }
    }

    // MARK: - Pure sine accuracy

    func test440HzSineWithinHalfHz() {
        let buffer = makeSine(frequency: 440.0)
        let result = PitchDetector.yin(buffer: buffer, sampleRate: sampleRate, threshold: 0.15)
        XCTAssertNotNil(result.frequencyHz)
        XCTAssertEqual(result.frequencyHz!, 440.0, accuracy: 0.5)
        XCTAssertEqual(result.confidence, 1.0, accuracy: 0.15)
    }

    func testConfidenceNearOneOnCleanSine() {
        let buffer = makeSine(frequency: 440.0)
        let result = PitchDetector.yin(buffer: buffer, sampleRate: sampleRate, threshold: 0.15)
        XCTAssertNotNil(result.frequencyHz)
        XCTAssertGreaterThanOrEqual(result.confidence, 0.9)
    }

    func testCorrectNotesAcrossViolinRange() {
        let notes: [(frequency: Double, midi: Int, name: String)] = [
            (196.00, 55, "G3"),
            (293.66, 62, "D4"),
            (440.00, 69, "A4"),
            (659.26, 76, "E5"),
        ]
        for note in notes {
            let buffer = makeSine(frequency: note.frequency)
            let detector = PitchDetector(sampleRate: sampleRate)
            let measurement = detector.measure(buffer: buffer)
            XCTAssertNotNil(measurement.frequencyHz, "expected pitch for \(note.name)")
            if let frequencyHz = measurement.frequencyHz {
                XCTAssertEqual(frequencyHz, note.frequency, accuracy: 0.5, "frequency for \(note.name)")
            }
            XCTAssertEqual(measurement.midiNote, note.midi, "midi for \(note.name)")
            XCTAssertEqual(measurement.noteName, note.name)
            XCTAssertEqual(measurement.cents, 0.0, accuracy: 1.0, "cents for \(note.name)")
        }
    }

    func testMeasureIdleWhenNoPitch() {
        let detector = PitchDetector(sampleRate: sampleRate)
        let silence = [Float](repeating: 0, count: 4096)
        XCTAssertEqual(detector.measure(buffer: silence), .idle)
    }

    // MARK: - Silence / noise rejection

    func testSilenceReturnsNil() {
        let buffer = [Float](repeating: 0, count: 4096)
        let result = PitchDetector.yin(buffer: buffer, sampleRate: sampleRate, threshold: 0.15)
        XCTAssertNil(result.frequencyHz)
        XCTAssertEqual(result.confidence, 0.0)
    }

    func testWhiteNoiseReturnsNil() {
        let buffer = makeNoise()
        let result = PitchDetector.yin(buffer: buffer, sampleRate: sampleRate, threshold: 0.15)
        XCTAssertNil(result.frequencyHz, "white noise should not produce a spurious pitch")
    }

    // MARK: - Sample-rate independence

    func test440HzAt48kHz() {
        let buffer = makeSine(frequency: 440.0, sampleRate: 48000.0)
        let result = PitchDetector.yin(buffer: buffer, sampleRate: 48000.0, threshold: 0.15)
        XCTAssertNotNil(result.frequencyHz)
        XCTAssertEqual(result.frequencyHz!, 440.0, accuracy: 0.5)
    }

    // MARK: - Custom reference pitch

    func testMeasureRespectsCustomReference() {
        // A 442 Hz tone is exactly A4 (in tune) when A4 is set to 442 Hz.
        let buffer = makeSine(frequency: 442.0)
        let detector = PitchDetector(sampleRate: sampleRate, referenceA4Hz: 442)
        let measurement = detector.measure(buffer: buffer)
        XCTAssertNotNil(measurement.frequencyHz)
        XCTAssertEqual(measurement.midiNote, 69)
        XCTAssertEqual(measurement.noteName, "A4")
        XCTAssertEqual(measurement.cents, 0.0, accuracy: 1.0)
    }
}
