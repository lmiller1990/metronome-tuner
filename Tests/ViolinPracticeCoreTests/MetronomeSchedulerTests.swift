import XCTest
@testable import ViolinPracticeCore

final class MetronomeSchedulerTests: XCTestCase {

    func testSecondsPerBeatAtSixtyBPM() {
        XCTAssertEqual(MetronomeScheduler.secondsPerBeat(bpm: 60), 1.0, accuracy: 1e-12)
    }

    func testSecondsPerBeatIsProportionalToTempo() {
        XCTAssertEqual(MetronomeScheduler.secondsPerBeat(bpm: 120), 0.5, accuracy: 1e-12)
        XCTAssertEqual(MetronomeScheduler.secondsPerBeat(bpm: 240), 0.25, accuracy: 1e-12)
    }

    func testBeatSpacingAt120BPM44100Hz() {
        var scheduler = MetronomeScheduler(sampleRate: 44100, bpm: 120, beatsPerMeasure: 4)
        let events = scheduler.beats(inSampleRange: 0, 44100)
        XCTAssertEqual(events.map(\.sampleIndex), [0, 22050])
    }

    func testExactFourBeatSpanCyclesNumbersAndAccents() {
        var scheduler = MetronomeScheduler(sampleRate: 44100, bpm: 120, beatsPerMeasure: 4)
        let events = scheduler.beats(inSampleRange: 0, 4 * 22050)

        XCTAssertEqual(events.count, 4)
        XCTAssertEqual(events.map(\.sampleIndex), [0, 22050, 44100, 66150])
        XCTAssertEqual(events.map(\.beatNumber), [1, 2, 3, 4])
        XCTAssertEqual(events.map(\.isAccent), [true, false, false, false])
    }

    func testBeatNumbersCycleAcrossMeasuresWithAccentOnlyOnBeatOne() {
        var scheduler = MetronomeScheduler(sampleRate: 44100, bpm: 120, beatsPerMeasure: 4)
        let events = scheduler.beats(inSampleRange: 0, 8 * 22050)

        XCTAssertEqual(events.map(\.beatNumber), [1, 2, 3, 4, 1, 2, 3, 4])
        XCTAssertEqual(events.filter(\.isAccent).map(\.beatNumber), [1, 1])
    }

    func testSetBPMMidSpanPreservesPhaseWithoutDoubleFire() {
        var scheduler = MetronomeScheduler(sampleRate: 44100, bpm: 120, beatsPerMeasure: 4)

        // One beat fires at 0; the window ends half a beat later.
        XCTAssertEqual(scheduler.beats(inSampleRange: 0, 11025).map(\.sampleIndex), [0])

        // Half a beat remains at the cursor, so at 60 BPM the next beat is 22050 samples later.
        scheduler.setBPM(60)

        // No immediate re-fire anywhere in the remainder of the old beat.
        XCTAssertTrue(scheduler.beats(inSampleRange: 11025, 22050).isEmpty)
        XCTAssertEqual(scheduler.beats(inSampleRange: 22050, 34000).map(\.sampleIndex), [33075])
    }

    func testSetBPMIncreasesTempoWithoutSkipping() {
        var scheduler = MetronomeScheduler(sampleRate: 44100, bpm: 60, beatsPerMeasure: 4)

        XCTAssertEqual(scheduler.beats(inSampleRange: 0, 22050).map(\.sampleIndex), [0])

        // Half a beat of 44100 remains at the cursor; at 120 BPM that is 11025 samples.
        scheduler.setBPM(120)

        XCTAssertEqual(scheduler.beats(inSampleRange: 22050, 44100).map(\.sampleIndex), [33075])
    }

    func testBPMIsClampedToMetronomeStateRange() {
        XCTAssertEqual(MetronomeState.bpmRange, 30...240)

        // 1 BPM clamps up to 30 BPM -> 2 s/beat -> 200 samples at 100 Hz.
        var low = MetronomeScheduler(sampleRate: 100, bpm: 1, beatsPerMeasure: 4)
        XCTAssertEqual(low.beats(inSampleRange: 0, 400).map(\.sampleIndex), [0, 200])

        // 1000 BPM clamps down to 240 BPM -> 0.25 s/beat -> 25 samples at 100 Hz.
        var high = MetronomeScheduler(sampleRate: 100, bpm: 1000, beatsPerMeasure: 4)
        XCTAssertEqual(high.beats(inSampleRange: 0, 100).map(\.sampleIndex), [0, 25, 50, 75])

        // setBPM clamps too: from 120 down to 30 (50 -> 200 samples per beat at 100 Hz), phase
        // preserved. After one beat at 0 and a window ending at sample 10, 0.8 of a beat remains:
        // 10 + 0.8 * 200 = 170, then 370.
        var changed = MetronomeScheduler(sampleRate: 100, bpm: 120, beatsPerMeasure: 4)
        XCTAssertEqual(changed.beats(inSampleRange: 0, 10).map(\.sampleIndex), [0])
        changed.setBPM(0)
        XCTAssertEqual(changed.beats(inSampleRange: 10, 500).map(\.sampleIndex), [170, 370])
    }

    func testRepeatedQueriesOverSameRangeDoNotDuplicateBeats() {
        var scheduler = MetronomeScheduler(sampleRate: 44100, bpm: 120, beatsPerMeasure: 4)
        XCTAssertEqual(scheduler.beats(inSampleRange: 0, 22050).map(\.sampleIndex), [0])
        XCTAssertTrue(scheduler.beats(inSampleRange: 0, 22050).isEmpty)
    }

    func testEmptyOrInvertedRangeReturnsNoBeats() {
        var scheduler = MetronomeScheduler(sampleRate: 44100, bpm: 120, beatsPerMeasure: 4)
        XCTAssertTrue(scheduler.beats(inSampleRange: 100, 100).isEmpty)
        XCTAssertTrue(scheduler.beats(inSampleRange: 100, 50).isEmpty)
    }
}
