import AVFoundation
import Darwin
import Foundation
import Observation
import os
import ViolinPracticeCore

// MARK: - Shared clock / locking helpers

/// Monotonic host-time clock shared by the mic tap and the metronome render
/// block. Invariant: click times and mic-frame times use the SAME clock, so
/// `ClickRejection` never mixes input-node and output-node sample clocks.
enum HostClock {
    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    /// Host ticks -> seconds.
    static func seconds(fromHostTime hostTime: UInt64) -> Double {
        Double(hostTime) * Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000.0
    }

    static var now: Double { seconds(fromHostTime: mach_absolute_time()) }
}

/// `os_unfair_lock` wrapper. An unfair lock never sleeps and never allocates, so
/// it is safe for the few-nanosecond critical sections shared with the audio
/// render thread (it is not a `NSLock`/semaphore that could block the thread).
final class UnfairLock: @unchecked Sendable {
    private var unfairLock = os_unfair_lock_s()

    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        os_unfair_lock_lock(&unfairLock)
        defer { os_unfair_lock_unlock(&unfairLock) }
        return try body()
    }
}

/// Lock-protected holder for the core `ClickRejection` value, shared between the
/// mic DSP path (reader) and the metronome render block (writer).
final class ClickRejectionBox: @unchecked Sendable {
    private let lock = UnfairLock()
    private var state: ClickRejection

    init(windowSeconds: Double) {
        state = ClickRejection(windowSeconds: windowSeconds)
    }

    func register(atSeconds seconds: Double) {
        lock.withLock { state.registerClick(atSampleTime: seconds) }
    }

    func shouldReject(atSeconds seconds: Double) -> Bool {
        lock.withLock { state.shouldReject(atSampleTime: seconds) }
    }
}

// MARK: - Mic DSP pipeline

/// Owns the mic capture -> RMS -> YIN -> smoothing pipeline on a background
/// queue. The mic tap only copies PCM into a pre-allocated pool buffer (no
/// allocation, no locks held across the copy, no dispatch hops) and hands off to
/// a dedicated serial DSP queue.
final class MicProcessor: @unchecked Sendable {
    private let sampleRate: Double
    private var detector: PitchDetector
    private var smoother: PitchSmoother
    private let clickBox: ClickRejectionBox
    private let publish: @Sendable (PitchMeasurement) -> Void
    private let dspQueue = DispatchQueue(label: "com.example.violinpractice.pitch", qos: .userInitiated)

    private let poolLock = UnfairLock()
    // `var` (not `let`) so `pool[index].withUnsafeMutableBufferPointer` can
    // write in place without triggering a copy-on-write onto a temporary.
    private var pool: [[Float]]
    private var freeIndices: [Int]

    init(sampleRate: Double,
         clickBox: ClickRejectionBox,
         referenceA4Hz: Double = MusicTheory.defaultA4Hz,
         publish: @escaping @Sendable (PitchMeasurement) -> Void) {
        self.sampleRate = sampleRate
        self.detector = PitchDetector(sampleRate: sampleRate, referenceA4Hz: referenceA4Hz)
        self.smoother = PitchSmoother(sampleRate: sampleRate, referenceA4Hz: referenceA4Hz)
        self.clickBox = clickBox
        self.publish = publish
        let bufferSize = 4096
        self.pool = (0..<4).map { _ in [Float](repeating: 0, count: bufferSize) }
        self.freeIndices = Array(0..<4)
    }

    /// Updates the A4 reference used by the detector and smoother. Dispatched onto
    /// the serial DSP queue so it cannot race `analyze(_:frames:hostSeconds:)`.
    func setReferenceA4Hz(_ hz: Double) {
        dspQueue.async { [self] in
            detector.referenceA4Hz = hz
            smoother.referenceA4Hz = hz
            // The displayed note/cents were derived under the old grid; clear them so
            // the next valid frame rebuilds under the new reference.
            smoother.reset()
        }
    }

    /// Called on the mic tap (realtime) thread.
    func process(buffer: AVAudioPCMBuffer, time: AVAudioTime) {
        let frames = Int(buffer.frameLength)
        guard frames > 0, let channel = buffer.floatChannelData?[0] else { return }

        let hostSeconds = time.isHostTimeValid
            ? HostClock.seconds(fromHostTime: time.hostTime)
            : HostClock.now

        let index = poolLock.withLock { () -> Int in
            guard let i = freeIndices.popLast() else { return -1 }
            return i
        }
        guard index >= 0 else { return } // pool momentarily exhausted; drop this frame

        let count = min(frames, pool[index].count)
        pool[index].withUnsafeMutableBufferPointer { dst in
            guard let base = dst.baseAddress else { return }
            base.update(from: channel, count: count)
        }

        dspQueue.async { [weak self] in
            self?.analyze(bufferIndex: index, frames: count, hostSeconds: hostSeconds)
        }
    }

    /// Runs on the serial DSP queue (off the audio thread).
    private func analyze(bufferIndex: Int, frames: Int, hostSeconds: Double) {
        defer { poolLock.withLock { freeIndices.append(bufferIndex) } }
        guard frames > 0 else { return }

        // Downweight/skip frames that overlap our own metronome click transient.
        if clickBox.shouldReject(atSeconds: hostSeconds) { return }

        let samples = pool[bufferIndex]
        var sumSquares = 0.0
        for i in 0..<frames {
            let v = Double(samples[i])
            sumSquares += v * v
        }
        let rms = sqrt(sumSquares / Double(frames))

        let raw = detector.measure(buffer: Array(samples[0..<frames]))
        let stable = smoother.update(raw, rms: rms)
        publish(stable)
    }
}

// MARK: - Audio engine (public seam)

/// Tuner + metronome audio engine. All published state is main-actor isolated
/// (`@Observable`); DSP and scheduling run on background/realtime threads.
@Observable @MainActor
public final class AudioEngine {
    public private(set) var pitch: PitchMeasurement = .idle
    public private(set) var metronome: MetronomeState = .init()
    /// 0...1 progress through the current beat, for the pendulum swing.
    public private(set) var pendulumPhase: Double = 0
    /// A4 reference pitch in hertz (e.g. 440 or 442). Drives the tuner's 12-TET grid.
    public private(set) var referenceA4Hz: Double = MusicTheory.defaultA4Hz

    private static let referenceA4HzKey = "referenceA4Hz"

    private let engine = AVAudioEngine()
    private var metronomeEngine: MetronomeEngine?
    private var micProcessor: MicProcessor?
    private var phaseTimer: Timer?
    private var sampleRate: Double = 48_000
    private var didBuild = false

    public init() {
        // Restore the persisted reference pitch (falls back to 440 when unset),
        // clamped to the supported range so a bad stored value can't produce an
        // out-of-range tuning grid.
        let stored = UserDefaults.standard.object(forKey: Self.referenceA4HzKey) as? Double
        referenceA4Hz = stored.map(Self.clampReference) ?? MusicTheory.defaultA4Hz
    }

    // MARK: Public surface

    public func start() {
        configureSession()
        buildGraph()
        if !engine.isRunning {
            try? engine.start()
        }
        startPhaseTicker()
    }

    public func startMetronome() {
        if !didBuild {
            start()
        }
        setBPM(metronome.bpm) // sync schedule to current BPM before running
        metronome.isRunning = true
        metronome.currentBeat = 0
        metronomeEngine?.start()
    }

    public func stopMetronome() {
        metronome.isRunning = false
        metronome.currentBeat = 0
        pendulumPhase = 0
        metronomeEngine?.stop()
    }

    public func setBPM(_ bpm: Double) {
        let clamped = clampBPM(bpm)
        metronome.bpm = clamped
        metronomeEngine?.setBPM(clamped)
    }

    public func setReferenceA4Hz(_ hz: Double) {
        let clamped = Self.clampReference(hz)
        guard clamped != referenceA4Hz else { return }
        referenceA4Hz = clamped
        UserDefaults.standard.set(clamped, forKey: Self.referenceA4HzKey)
        micProcessor?.setReferenceA4Hz(clamped)
    }

    // MARK: Setup

    private func configureSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker])
        try? session.setActive(true)
    }

    private func buildGraph() {
        guard !didBuild else { return }
        didBuild = true

        let input = engine.inputNode
        var inputFormat = input.outputFormat(forBus: 0)
        // The input node can report a placeholder format with a zero (invalid)
        // sample rate before the session is fully established. Fall back to the
        // session's hardware rate, then a sane hardware default, so we never
        // build the graph with a 0 Hz rate (which makes `AVAudioFormat(...)`
        // return nil and force-unwrap below crash).
        var rate = inputFormat.sampleRate
        if rate <= 0 {
            rate = AVAudioSession.sharedInstance().sampleRate
        }
        if rate <= 0 {
            rate = 44_100
        }
        if rate <= 0 || !rate.isFinite {
            rate = 44_100
        }
        sampleRate = rate
        inputFormat = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)
            ?? inputFormat

        let clickBox = ClickRejectionBox(windowSeconds: 0.025)

        let metronome = MetronomeEngine(sampleRate: sampleRate,
                                        clickBox: clickBox,
                                        beatsPerMeasure: metronome.beatsPerMeasure,
                                        accentFirstBeat: metronome.accentFirstBeat)
        metronomeEngine = metronome
        guard let outputFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else {
            // Cannot happen now (rate is a positive finite value), but degrade
            // gracefully instead of trapping if it ever did.
            return
        }
        metronome.attach(to: engine, format: outputFormat)

        let publish: @Sendable (PitchMeasurement) -> Void = { [weak self] measurement in
            Task { @MainActor in
                self?.pitch = measurement
            }
        }
        let processor = MicProcessor(sampleRate: sampleRate, clickBox: clickBox, referenceA4Hz: referenceA4Hz, publish: publish)
        micProcessor = processor

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { @Sendable buffer, time in
            // This closure runs on AVFoundation's realtime messenger queue, NOT
            // the main actor. It must be non-isolated: capture only the
            // @unchecked Sendable `processor`, never `@MainActor` state here.
            processor.process(buffer: buffer, time: time)
        }

        engine.prepare()
    }

    // MARK: Pendulum phase

    private func startPhaseTicker() {
        guard phaseTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            // The Timer fires on the main run loop, but hop explicitly rather
            // than `assumeIsolated`: if the block itself is ever scheduled off
            // the main thread, `assumeIsolated` traps and crashes the app.
            Task { @MainActor in
                self?.updatePendulumPhase()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        phaseTimer = timer
    }

    private func updatePendulumPhase() {
        guard metronome.isRunning, let metronomeEngine else {
            if pendulumPhase != 0 { pendulumPhase = 0 }
            return
        }
        let snap = metronomeEngine.snapshot()
        metronome.currentBeat = snap.currentBeat
        guard snap.running, snap.beatHostSeconds > 0 else {
            if pendulumPhase != 0 { pendulumPhase = 0 }
            return
        }
        let secondsPerBeat = snap.samplesPerBeat / sampleRate
        var phase = (HostClock.now - snap.beatHostSeconds) / secondsPerBeat
        phase -= phase.rounded(.down)
        if phase != pendulumPhase { pendulumPhase = phase }
    }

    private func clampBPM(_ bpm: Double) -> Double {
        min(max(bpm, MetronomeState.bpmRange.lowerBound), MetronomeState.bpmRange.upperBound)
    }

    private static func clampReference(_ hz: Double) -> Double {
        min(max(hz, MusicTheory.referenceA4HzRange.lowerBound), MusicTheory.referenceA4HzRange.upperBound)
    }
}
