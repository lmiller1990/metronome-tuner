import AVFoundation
import Foundation
import ViolinPracticeCore

/// Renders metronome clicks with sample-accurate scheduling on the audio render
/// timeline using an `AVAudioSourceNode` render block (never a `Timer` or
/// `DispatchSourceTimer` for click timing).
///
/// All mutable state is guarded by `UnfairLock` (an unfair, non-sleeping,
/// allocation-free lock). The render block holds the lock only long enough to
/// copy/advance a handful of scalars; it never allocates, never locks across the
/// sample mixing, and never touches SwiftUI or the main actor.
final class MetronomeEngine: @unchecked Sendable {

    private struct Schedule {
        var running = false
        var initialized = false
        /// Output sample position (render timeline) of the next click.
        var nextBeatSample: Double = 0
        var samplesPerBeat: Double = 44_100
        var beatNumber = 0            // 0 before the first click; 1...beatsPerMeasure after
        var beatsPerMeasure = 4
        var accentFirstBeat = true
        /// Host time (seconds) of the most recent click, for pendulum phase.
        var lastBeatHostSeconds: Double = 0
        /// Independent output gain for the clicks (0...1), applied in the render
        /// block. Kept here so it is read under the same lock as the schedule.
        var volume: Double = 1
        /// Index into the pre-rendered `accentBySound`/`normalBySound` arrays.
        var soundIndex = 0
        /// Number of preview clicks still to schedule (0 = no preview pending).
        var previewBeatsRemaining = 0
        /// Output sample position (render timeline) of the next preview click.
        var previewNextSample: Double = 0
        var previewInitialized = false
        var previewSoundIndex = 0
        /// Accents only the first preview beat, then flips to normal.
        var previewAccent = true
    }

    private struct RenderBeat {
        var offset: Double = 0        // frame offset into the current render buffer
        var accent = false
        var hostSeconds: Double = 0
        var soundIndex = 0
    }

    private let lock = UnfairLock()
    private var schedule = Schedule()
    private var pendingBeats: [RenderBeat] = (0..<16).map { _ in RenderBeat() }

    private let sampleRate: Double
    /// Pre-rendered click buffers, indexed by `Schedule.soundIndex` /
    /// `RenderBeat.soundIndex` in `MetronomeSound.allCases` order.
    private let accentBySound: [[Float]]
    private let normalBySound: [[Float]]
    /// `MetronomeSound -> array index`; consulted only off the render thread
    /// (in `setSound`/`preview`), never inside `render`.
    private let soundIndices: [MetronomeSound: Int]
    private let clickBox: ClickRejectionBox

    private(set) var sourceNode: AVAudioSourceNode?

    init(sampleRate: Double,
         clickBox: ClickRejectionBox,
         beatsPerMeasure: Int = 4,
         accentFirstBeat: Bool = true) {
        self.sampleRate = sampleRate
        self.clickBox = clickBox
        self.accentBySound = MetronomeSound.allCases.map { sound in
            MetronomeEngine.makeClick(sampleRate: sampleRate, sound: sound, accent: true)
        }
        self.normalBySound = MetronomeSound.allCases.map { sound in
            MetronomeEngine.makeClick(sampleRate: sampleRate, sound: sound, accent: false)
        }
        self.soundIndices = Dictionary(uniqueKeysWithValues:
            MetronomeSound.allCases.enumerated().map { ($0.element, $0.offset) })
        schedule.samplesPerBeat = max(1, sampleRate * MetronomeScheduler.secondsPerBeat(bpm: 60))
        schedule.beatsPerMeasure = beatsPerMeasure
        schedule.accentFirstBeat = accentFirstBeat
    }

    func attach(to engine: AVAudioEngine, format: AVAudioFormat) {
        let node = AVAudioSourceNode(format: format) { [weak self] isSilence, timestamp, frameCount, audioBufferList in
            guard let self else {
                return noErr
            }
            return self.render(isSilence: isSilence,
                               timestamp: timestamp,
                               frameCount: frameCount,
                               audioBufferList: audioBufferList)
        }
        sourceNode = node
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
    }

    func start() {
        lock.withLock {
            schedule.running = true
            schedule.initialized = false
            schedule.beatNumber = 0
            schedule.lastBeatHostSeconds = 0
        }
    }

    func stop() {
        lock.withLock {
            schedule.running = false
            schedule.initialized = false
            schedule.beatNumber = 0
            schedule.lastBeatHostSeconds = 0
        }
    }

    func setBPM(_ bpm: Double) {
        let samples = max(1, sampleRate * MetronomeScheduler.secondsPerBeat(bpm: bpm))
        lock.withLock {
            schedule.samplesPerBeat = samples
        }
    }

    /// Sets the click output gain (clamped to 0...1). Safe to call while running.
    func setVolume(_ volume: Double) {
        let clamped = min(max(volume, 0), 1)
        lock.withLock {
            schedule.volume = clamped
        }
    }

    /// Selects the click timbre. Only mutates `Schedule` under the lock; the
    /// dictionary lookup happens here (off the render thread), so the render
    /// block itself indexes a pre-built `[[Float]]` array with an `Int`.
    func setSound(_ sound: MetronomeSound) {
        let index = soundIndices[sound] ?? 0
        lock.withLock {
            schedule.soundIndex = index
        }
    }

    /// Plays `beats` preview clicks immediately, independent of the running
    /// schedule. Does not touch `running`/`beatNumber`/`lastBeatHostSeconds`.
    func preview(_ sound: MetronomeSound, beats: Int) {
        let index = soundIndices[sound] ?? 0
        lock.withLock {
            schedule.previewBeatsRemaining = max(0, beats)
            schedule.previewInitialized = false
            schedule.previewSoundIndex = index
            schedule.previewAccent = true
        }
    }

    /// Snapshot for the main actor: last click's beat number + host time, the
    /// current beat spacing, and the running flag.
    func snapshot() -> (currentBeat: Int, beatHostSeconds: Double, samplesPerBeat: Double, running: Bool) {
        lock.withLock {
            (schedule.beatNumber, schedule.lastBeatHostSeconds, schedule.samplesPerBeat, schedule.running)
        }
    }

    // MARK: - Render block

    private func render(isSilence: UnsafeMutablePointer<ObjCBool>,
                        timestamp: UnsafePointer<AudioTimeStamp>,
                        frameCount: AVAudioFrameCount,
                        audioBufferList: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
        let ts = timestamp.pointee
        let sampleTime = ts.mSampleTime
        let hostSeconds = HostClock.seconds(fromHostTime: ts.mHostTime)
        let frames = Int(frameCount)

        var beatCount = 0
        var running = false
        var volume: Double = 1

        // 1. Advance the schedule under the lock; record this buffer's beats into
        //    the pre-allocated `pendingBeats`. No mixing or allocation here.
        lock.withLock {
            running = schedule.running
            volume = schedule.volume
            if running, !schedule.initialized {
                // First render after start(): place the first click a short lead
                // ahead so it fires promptly rather than a full beat later.
                schedule.nextBeatSample = sampleTime + min(schedule.samplesPerBeat, sampleRate * 0.05)
                schedule.initialized = true
                schedule.beatNumber = 0
            } else if running {
                let end = sampleTime + Double(frames)
                while schedule.nextBeatSample < end, beatCount < pendingBeats.count {
                    let offset = schedule.nextBeatSample - sampleTime
                    schedule.beatNumber = schedule.beatNumber % schedule.beatsPerMeasure + 1
                    let accent = schedule.accentFirstBeat && schedule.beatNumber == 1
                    let clickHostSeconds = hostSeconds + (schedule.nextBeatSample - sampleTime) / sampleRate
                    schedule.lastBeatHostSeconds = clickHostSeconds
                    pendingBeats[beatCount] = RenderBeat(offset: offset,
                                                         accent: accent,
                                                         hostSeconds: clickHostSeconds,
                                                         soundIndex: schedule.soundIndex)
                    beatCount += 1
                    schedule.nextBeatSample += schedule.samplesPerBeat
                }
            }

            // Preview beats: schedule immediately, independent of the running
            // metronome schedule. Reuses the same `pendingBeats` capacity guard.
            if schedule.previewBeatsRemaining > 0 {
                if !schedule.previewInitialized {
                    schedule.previewNextSample = sampleTime + min(schedule.samplesPerBeat, sampleRate * 0.05)
                    schedule.previewInitialized = true
                }
                let end = sampleTime + Double(frames)
                while schedule.previewBeatsRemaining > 0,
                      schedule.previewNextSample < end,
                      beatCount < pendingBeats.count {
                    let offset = schedule.previewNextSample - sampleTime
                    let accent = schedule.previewAccent
                    schedule.previewAccent = false
                    let clickHostSeconds = hostSeconds + (schedule.previewNextSample - sampleTime) / sampleRate
                    pendingBeats[beatCount] = RenderBeat(offset: offset,
                                                         accent: accent,
                                                         hostSeconds: clickHostSeconds,
                                                         soundIndex: schedule.previewSoundIndex)
                    beatCount += 1
                    schedule.previewNextSample += schedule.samplesPerBeat
                    schedule.previewBeatsRemaining -= 1
                }
            }
        }

        // 2. Mix clicks into the output (outside the lock) and register each
        //    click's host time with the shared ClickRejection.
        fillSilence(audioBufferList, frameCount: frames)
        if beatCount > 0 {
            let gain = Float(volume)
            for i in 0..<beatCount {
                let beat = pendingBeats[i]
                clickBox.register(atSeconds: beat.hostSeconds)
                guard gain > 0 else { continue }
                mix(click: beat.accent ? accentBySound[beat.soundIndex] : normalBySound[beat.soundIndex],
                    gain: gain,
                    at: beat.offset,
                    into: audioBufferList,
                    frameCount: frames)
            }
            isSilence.pointee = ObjCBool(volume <= 0)
        } else {
            isSilence.pointee = true
        }
        return noErr
    }

    // MARK: - Output helpers (allocation-free)

    private func fillSilence(_ audioBufferList: UnsafeMutablePointer<AudioBufferList>, frameCount: Int) {
        for buffer in UnsafeMutableAudioBufferListPointer(audioBufferList) {
            guard let data = buffer.mData else { continue }
            let count = min(frameCount, Int(buffer.mDataByteSize) / MemoryLayout<Float>.size)
            data.assumingMemoryBound(to: Float.self).update(repeating: 0, count: count)
        }
    }

    private func mix(click: [Float],
                     gain: Float,
                     at offset: Double,
                     into audioBufferList: UnsafeMutablePointer<AudioBufferList>,
                     frameCount: Int) {
        let start = Int(offset.rounded(.down))
        guard start < frameCount else { return }
        for buffer in UnsafeMutableAudioBufferListPointer(audioBufferList) {
            guard let data = buffer.mData else { continue }
            let maxFrames = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            let n = min(click.count, min(frameCount, maxFrames) - start)
            guard n > 0 else { continue }
            let floats = data.assumingMemoryBound(to: Float.self)
            for i in 0..<n {
                floats[start + i] += click[i] * gain
            }
        }
    }

    // MARK: - Click synthesis (runs once, off the audio thread)

    /// Pre-rendered click: a fast-decaying body tone plus a broadband noise
    /// attack transient, so the tick cuts through even at low system volume.
    /// Each sound has a distinct timbre; accent vs normal stays distinguishable
    /// by a brighter/higher frequency rather than amplitude alone. Every click
    /// is peak-normalized to 0.98 full scale.
    private static func makeClick(sampleRate: Double, sound: MetronomeSound, accent: Bool) -> [Float] {
        switch sound {
        case .clap: return makeClap(sampleRate: sampleRate, accent: accent)
        case .rimshot: return makeRimshot(sampleRate: sampleRate, accent: accent)
        case .classic, .woodblock, .beep, .digital:
            return makeTonalClick(sampleRate: sampleRate, sound: sound, accent: accent)
        }
    }

    /// Tonal clicks: a fast-decaying body tone plus a broadband noise attack
    /// transient, so the tick cuts through even at low system volume. Each of the
    /// four tonal sounds has a distinct timbre; accent vs normal stays
    /// distinguishable by a brighter/higher frequency rather than amplitude alone.
    private static func makeTonalClick(sampleRate: Double, sound: MetronomeSound, accent: Bool) -> [Float] {
        var seed: UInt64 = 0x9E3779B97F4A7C15
        func nextNoise() -> Float {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            // Logical shift on the UInt64 keeps the sample in [0, 1), so the noise
            // spans [-1, 1) as intended. An Int64 arithmetic shift would yield
            // negatives and skew the distribution (and, in the clap/rimshot
            // `nextUnit`, fed negative sample indices).
            let v = Float(seed >> 40) / Float(1 << 24)
            return v * 2 - 1
        }

        let dur: Double
        let freq: Double
        let decay: Double
        let noiseDur: Double
        let noiseAmt: Double
        let harmonic2: Double

        switch sound {
        case .classic:
            dur = 0.032; freq = accent ? 2200 : 1700; decay = 160
            noiseDur = 0.004; noiseAmt = 0.6; harmonic2 = 0.0
        case .woodblock:
            dur = 0.05; freq = accent ? 1150 : 880; decay = 70
            noiseDur = 0.006; noiseAmt = 0.9; harmonic2 = 0.35
        case .beep:
            dur = 0.09; freq = accent ? 1200 : 950; decay = 26
            noiseDur = 0.003; noiseAmt = 0.12; harmonic2 = 0.0
        case .digital:
            dur = 0.022; freq = accent ? 3400 : 2800; decay = 240
            noiseDur = 0.002; noiseAmt = 0.7; harmonic2 = 0.0
        case .clap, .rimshot:
            fatalError("makeTonalClick does not support \(sound)")
        }

        let n = max(1, Int(sampleRate * dur))
        var s = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let t = Double(i) / sampleRate
            let body = sin(2 * .pi * freq * t) + harmonic2 * sin(4 * .pi * freq * t)
            let env = exp(-decay * t)
            let noiseEnv = exp(-t / noiseDur) * noiseAmt
            s[i] = Float(body * env + Double(nextNoise()) * noiseEnv)
        }
        return normalizePeak(s, to: 0.98)
    }

    /// Hand clap: several short bright-noise "finger" transients clustered in the
    /// first ~20 ms, plus a damped "room" tail.
    private static func makeClap(sampleRate: Double, accent: Bool) -> [Float] {
        var seed: UInt64 = 0x9E3779B97F4A7C15
        func nextUnit() -> Float {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            // Logical shift on the UInt64 keeps the result in [0, 1). Shifting an
            // Int64 (arithmetic shift) would yield negatives here, which fed
            // negative sample indices into the transient loop (index-out-of-range).
            return Float(seed >> 40) / Float(1 << 24)
        }
        func nextNoise() -> Float {
            nextUnit() * 2 - 1
        }

        let dur = accent ? 0.14 : 0.11
        let n = max(1, Int(sampleRate * dur))
        var s = [Float](repeating: 0, count: n)

        let transientCount = accent ? 7 : 4
        for _ in 0..<transientCount {
            let start = 0.004 + Double(nextUnit()) * 0.014
            let amp = 0.55 + nextUnit() * 0.45
            let burstLen = Int(sampleRate * (0.004 + Double(nextUnit()) * 0.006))
            var prev: Float = 0
            for j in 0..<burstLen {
                let idx = Int(start * sampleRate) + j
                if idx >= n { break }
                let t = Double(j) / sampleRate
                let w = nextNoise()
                let bright = w - prev
                prev = w
                s[idx] += bright * Float(exp(-t / 0.004)) * amp
            }
        }

        var prev: Float = 0
        let tailDecay = accent ? 0.035 : 0.028
        for i in 0..<n {
            let t = Double(i) / sampleRate
            let w = nextNoise()
            let bright = w - prev
            prev = w
            s[i] += bright * Float(exp(-t / tailDecay)) * 0.30
        }

        return normalizePeak(s, to: 0.98)
    }

    /// Rimshot: a sharp "stick" click (very short bright noise) plus a
    /// fast-decaying high metallic ring.
    private static func makeRimshot(sampleRate: Double, accent: Bool) -> [Float] {
        var seed: UInt64 = 0x9E3779B97F4A7C15
        func nextUnit() -> Float {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            // Logical shift on the UInt64 keeps the result in [0, 1). Shifting an
            // Int64 (arithmetic shift) would yield negatives here, which fed
            // negative sample indices into the transient loop (index-out-of-range).
            return Float(seed >> 40) / Float(1 << 24)
        }
        func nextNoise() -> Float {
            nextUnit() * 2 - 1
        }

        let dur = accent ? 0.06 : 0.05
        let n = max(1, Int(sampleRate * dur))
        var s = [Float](repeating: 0, count: n)

        let ringFreq = accent ? 5200.0 : 4200.0
        let ring2 = ringFreq * 1.5
        let ringAmp = accent ? 0.85 : 0.7
        let ringDecay = accent ? 0.010 : 0.012

        var prev: Float = 0
        for i in 0..<n {
            let t = Double(i) / sampleRate
            let w = nextNoise()
            let bright = w - prev
            prev = w
            let stick = bright * Float(exp(-t / 0.0025)) * 1.0
            let ring = sin(2 * .pi * ringFreq * t) + 0.35 * sin(2 * .pi * ring2 * t)
            let ringEnv = Float(exp(-t / ringDecay)) * Float(ringAmp)
            s[i] = stick + Float(ring) * ringEnv
        }

        return normalizePeak(s, to: 0.98)
    }

    private static func normalizePeak(_ samples: [Float], to target: Float) -> [Float] {
        var peak: Float = 0
        for v in samples { peak = max(peak, abs(v)) }
        guard peak > 0 else { return samples }
        let scale = target / peak
        return samples.map { $0 * scale }
    }
}
