import XCTest
@testable import ViolinPracticeCore

final class MusicTheoryTests: XCTestCase {

    // MARK: - nearestMidiNote

    func testA4At440IsMidi69() {
        XCTAssertEqual(MusicTheory.nearestMidiNote(frequencyHz: 440), 69)
    }

    func testNearestMidiNoteMapsCommonViolinFrequencies() {
        XCTAssertEqual(MusicTheory.nearestMidiNote(frequencyHz: 196.00), 55)   // G3
        XCTAssertEqual(MusicTheory.nearestMidiNote(frequencyHz: 293.66), 62)   // D4
        XCTAssertEqual(MusicTheory.nearestMidiNote(frequencyHz: 440.00), 69)   // A4
        XCTAssertEqual(MusicTheory.nearestMidiNote(frequencyHz: 659.26), 76)   // E5
    }

    func testNearestMidiNoteAcrossOctaves() {
        XCTAssertEqual(MusicTheory.nearestMidiNote(frequencyHz: 110.0), 45)    // A2
        XCTAssertEqual(MusicTheory.nearestMidiNote(frequencyHz: 220.0), 57)    // A3
        XCTAssertEqual(MusicTheory.nearestMidiNote(frequencyHz: 880.0), 81)    // A5
    }

    func testNearestMidiNoteIsStableJustEitherSideOfExactPitch() {
        // A4 = 440; the A4/A#4 boundary is ~452.9 Hz, so these are all still A.
        XCTAssertEqual(MusicTheory.nearestMidiNote(frequencyHz: 438), 69)
        XCTAssertEqual(MusicTheory.nearestMidiNote(frequencyHz: 445), 69)
    }

    func testNearestMidiNoteRespectsCustomReference() {
        XCTAssertEqual(MusicTheory.nearestMidiNote(frequencyHz: 442, referenceA4Hz: 442), 69)
    }

    // MARK: - cents

    func testCentsIsZeroOnExactNotes() {
        for midi in [40, 55, 60, 62, 69, 76, 100] {
            let hz = MusicTheory.frequency(midiNote: midi)
            XCTAssertEqual(MusicTheory.cents(frequencyHz: hz), 0, accuracy: 1e-9, "midi \(midi)")
        }
    }

    func testCentsSignIsPositiveWhenSharpAndNegativeWhenFlat() {
        XCTAssertGreaterThan(MusicTheory.cents(frequencyHz: 445), 0)
        XCTAssertLessThan(MusicTheory.cents(frequencyHz: 435), 0)
        XCTAssertEqual(MusicTheory.cents(frequencyHz: 445), 19.56, accuracy: 0.05)
        XCTAssertEqual(MusicTheory.cents(frequencyHz: 435), -19.79, accuracy: 0.05)
    }

    func test442HzIsA4AboutEightCentsSharp() {
        XCTAssertEqual(MusicTheory.nearestMidiNote(frequencyHz: 442), 69)
        let cents = MusicTheory.cents(frequencyHz: 442)
        XCTAssertEqual(cents, 7.85, accuracy: 0.1)
        XCTAssertGreaterThan(cents, 0)
    }

    func testCentsStaysWithinOpenClosedRangeAcrossOctaves() {
        // Sweep ±49 cents around every note over a wide MIDI span.
        for midi in 20...110 {
            let base = MusicTheory.frequency(midiNote: midi)
            for delta in stride(from: -49.0, through: 49.0, by: 0.25) {
                let hz = base * pow(2.0, delta / 1200.0)
                let cents = MusicTheory.cents(frequencyHz: hz)
                XCTAssertGreaterThan(cents, -50.0, "midi \(midi) delta \(delta)")
                XCTAssertLessThanOrEqual(cents, 50.0, "midi \(midi) delta \(delta)")
            }
        }
    }

    func testCentsApproachesPositiveFiftyTowardsUpperNote() {
        // 0.499 semitones above A4 is just under +50 cents and still spells A4.
        let hz = MusicTheory.frequency(midiNote: 69) * pow(2.0, 0.499 / 12.0)
        XCTAssertEqual(MusicTheory.nearestMidiNote(frequencyHz: hz), 69)
        XCTAssertEqual(MusicTheory.cents(frequencyHz: hz), 49.9, accuracy: 0.01)
    }

    func testCentsUsesCustomReference() {
        XCTAssertEqual(MusicTheory.cents(frequencyHz: 442, referenceA4Hz: 442), 0, accuracy: 1e-9)
        XCTAssertEqual(MusicTheory.cents(frequencyHz: 440, referenceA4Hz: 442), -7.85, accuracy: 0.05)
    }

    // MARK: - frequency

    func testFrequencyOfReferenceNotes() {
        XCTAssertEqual(MusicTheory.frequency(midiNote: 69), 440.0, accuracy: 1e-9)   // A4
        XCTAssertEqual(MusicTheory.frequency(midiNote: 57), 220.0, accuracy: 1e-9)   // A3
        XCTAssertEqual(MusicTheory.frequency(midiNote: 81), 880.0, accuracy: 1e-9)   // A5
        XCTAssertEqual(MusicTheory.frequency(midiNote: 60), 261.6255653, accuracy: 1e-6) // C4
        XCTAssertEqual(MusicTheory.frequency(midiNote: 55), 195.9977180, accuracy: 1e-6) // G3
        XCTAssertEqual(MusicTheory.frequency(midiNote: 76), 659.2551138, accuracy: 1e-6) // E5
    }

    func testFrequencyRoundTripsThroughNearestNote() {
        for midi in 21...108 {
            let hz = MusicTheory.frequency(midiNote: midi)
            XCTAssertEqual(MusicTheory.nearestMidiNote(frequencyHz: hz), midi)
            XCTAssertEqual(MusicTheory.cents(frequencyHz: hz), 0, accuracy: 1e-9, "midi \(midi)")
        }
    }

    func testFrequencyWithCustomReference() {
        XCTAssertEqual(MusicTheory.frequency(midiNote: 69, referenceA4Hz: 442), 442, accuracy: 1e-9)
        XCTAssertEqual(MusicTheory.frequency(midiNote: 81, referenceA4Hz: 442), 884, accuracy: 1e-9)
    }

    func testReferenceA4HzRangeCoversCommonStandards() {
        XCTAssertEqual(MusicTheory.referenceA4HzRange.lowerBound, 415)
        XCTAssertEqual(MusicTheory.referenceA4HzRange.upperBound, 466)
        XCTAssertTrue(MusicTheory.referenceA4HzRange.contains(440))
        XCTAssertTrue(MusicTheory.referenceA4HzRange.contains(442))
        XCTAssertFalse(MusicTheory.referenceA4HzRange.contains(414))
        XCTAssertFalse(MusicTheory.referenceA4HzRange.contains(467))
    }

    // MARK: - noteName

    func testNoteNamesUseSharpSpelling() {
        XCTAssertEqual(MusicTheory.noteName(midiNote: 69), "A")
        XCTAssertEqual(MusicTheory.noteName(midiNote: 61), "C#")
        XCTAssertEqual(MusicTheory.noteName(midiNote: 60), "C")
        XCTAssertEqual(MusicTheory.noteName(midiNote: 66), "F#")
        XCTAssertEqual(MusicTheory.noteName(midiNote: 70), "A#")
        XCTAssertEqual(MusicTheory.noteName(midiNote: 59), "B")
        XCTAssertEqual(MusicTheory.noteName(midiNote: 62), "D")
    }

    func testNoteNameWrapsForOutOfRangeMidiValues() {
        XCTAssertEqual(MusicTheory.noteName(midiNote: -1), "B")
        XCTAssertEqual(MusicTheory.noteName(midiNote: 12), "C")
        XCTAssertEqual(MusicTheory.noteName(midiNote: 129), "A")
    }

    // MARK: - noteNameWithOctave

    func testNoteNameWithOctaveSamples() {
        XCTAssertEqual(MusicTheory.noteNameWithOctave(midiNote: 69), "A4")
        XCTAssertEqual(MusicTheory.noteNameWithOctave(midiNote: 61), "C#4")
        XCTAssertEqual(MusicTheory.noteNameWithOctave(midiNote: 55), "G3")
        XCTAssertEqual(MusicTheory.noteNameWithOctave(midiNote: 76), "E5")
    }

    func testNoteNameWithOctaveConventions() {
        XCTAssertEqual(MusicTheory.noteNameWithOctave(midiNote: 60), "C4")   // middle C
        XCTAssertEqual(MusicTheory.noteNameWithOctave(midiNote: 0), "C-1")
        XCTAssertEqual(MusicTheory.noteNameWithOctave(midiNote: 127), "G9")
    }

    // MARK: - tempoMarking

    func testTempoMarkingSamples() {
        XCTAssertEqual(MusicTheory.tempoMarking(bpm: 30), "Grave")
        XCTAssertEqual(MusicTheory.tempoMarking(bpm: 40), "Largo")
        XCTAssertEqual(MusicTheory.tempoMarking(bpm: 60), "Adagio")
        XCTAssertEqual(MusicTheory.tempoMarking(bpm: 80), "Andante")
        XCTAssertEqual(MusicTheory.tempoMarking(bpm: 110), "Moderato")
        XCTAssertEqual(MusicTheory.tempoMarking(bpm: 120), "Allegro")
        XCTAssertEqual(MusicTheory.tempoMarking(bpm: 160), "Vivace")
        XCTAssertEqual(MusicTheory.tempoMarking(bpm: 200), "Presto")
    }

    func testTempoMarkingBandBoundaries() {
        XCTAssertEqual(MusicTheory.tempoMarking(bpm: 39.9), "Grave")
        XCTAssertEqual(MusicTheory.tempoMarking(bpm: 40), "Largo")
        XCTAssertEqual(MusicTheory.tempoMarking(bpm: 59.9), "Largo")
        XCTAssertEqual(MusicTheory.tempoMarking(bpm: 60), "Adagio")
        XCTAssertEqual(MusicTheory.tempoMarking(bpm: 75.9), "Adagio")
        XCTAssertEqual(MusicTheory.tempoMarking(bpm: 76), "Andante")
        XCTAssertEqual(MusicTheory.tempoMarking(bpm: 107.9), "Andante")
        XCTAssertEqual(MusicTheory.tempoMarking(bpm: 108), "Moderato")
        XCTAssertEqual(MusicTheory.tempoMarking(bpm: 119.9), "Moderato")
        XCTAssertEqual(MusicTheory.tempoMarking(bpm: 120), "Allegro")
        XCTAssertEqual(MusicTheory.tempoMarking(bpm: 155.9), "Allegro")
        XCTAssertEqual(MusicTheory.tempoMarking(bpm: 156), "Vivace")
        XCTAssertEqual(MusicTheory.tempoMarking(bpm: 175.9), "Vivace")
        XCTAssertEqual(MusicTheory.tempoMarking(bpm: 176), "Presto")
    }

    func testTempoMarkingCoversBPMRange() {
        for bpm in stride(from: MetronomeState.bpmRange.lowerBound,
                          through: MetronomeState.bpmRange.upperBound, by: 1) {
            XCTAssertFalse(MusicTheory.tempoMarking(bpm: bpm).isEmpty, "bpm \(bpm)")
        }
    }

    // MARK: - PitchMeasurement

    func testPitchMeasurementDefaultsMatchIdle() {
        let measurement = PitchMeasurement()
        XCTAssertNil(measurement.frequencyHz)
        XCTAssertNil(measurement.midiNote)
        XCTAssertNil(measurement.noteName)
        XCTAssertEqual(measurement.cents, 0)
        XCTAssertEqual(measurement.confidence, 0)
        XCTAssertEqual(measurement, PitchMeasurement.idle)
    }

    func testPitchMeasurementEquatable() {
        let a = PitchMeasurement(frequencyHz: 440.0, midiNote: 69, noteName: "A4",
                                 cents: 0, confidence: 0.97)
        let b = PitchMeasurement(frequencyHz: 440.0, midiNote: 69, noteName: "A4",
                                 cents: 0, confidence: 0.97)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, PitchMeasurement(frequencyHz: 441.0, midiNote: 69, noteName: "A4",
                                              cents: 3.9, confidence: 0.97))
    }

    func testPitchMeasurementIsSendable() {
        func requireSendable<T: Sendable>(_ value: T) -> T { value }
        XCTAssertEqual(requireSendable(PitchMeasurement.idle), PitchMeasurement())
    }

    // MARK: - MetronomeState

    func testMetronomeStateDefaults() {
        let state = MetronomeState()
        XCTAssertEqual(state.bpm, 60)
        XCTAssertEqual(state.beatsPerMeasure, 4)
        XCTAssertFalse(state.isRunning)
        XCTAssertEqual(state.currentBeat, 0)
    }

    func testMetronomeStateBPMRange() {
        XCTAssertEqual(MetronomeState.bpmRange.lowerBound, 30)
        XCTAssertEqual(MetronomeState.bpmRange.upperBound, 240)
        XCTAssertTrue(MetronomeState.bpmRange.contains(30))
        XCTAssertTrue(MetronomeState.bpmRange.contains(240))
        XCTAssertTrue(MetronomeState.bpmRange.contains(60))
        XCTAssertFalse(MetronomeState.bpmRange.contains(29.9))
        XCTAssertFalse(MetronomeState.bpmRange.contains(240.1))
    }

    func testMetronomeStateEquatable() {
        XCTAssertEqual(MetronomeState(), MetronomeState())
        var modified = MetronomeState()
        modified.bpm = 120
        XCTAssertNotEqual(modified, MetronomeState())
    }

    func testMetronomeStateIsSendable() {
        func requireSendable<T: Sendable>(_ value: T) -> T { value }
        XCTAssertEqual(requireSendable(MetronomeState()), MetronomeState())
    }
}
