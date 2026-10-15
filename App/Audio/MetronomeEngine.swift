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
        /// Host time (seconds) of the most recent click, for pendulum phase.
        var lastBeatHostSeconds: Double = 0
        /// Independent output gain for the clicks (0...4), applied in the render
        /// block; >1 is soft-limited. Kept here so it is read under the same lock
        /// as the schedule.
        var volume: Double = 1
        /// Index into the pre-rendered `clicksBySound` array.
        var soundIndex = 0
        /// Number of preview clicks still to schedule (0 = no preview pending).
        var previewBeatsRemaining = 0
        /// Output sample position (render timeline) of the next preview click.
        var previewNextSample: Double = 0
        var previewInitialized = false
        var previewSoundIndex = 0
    }

    private struct RenderBeat {
        var offset: Double = 0        // frame offset into the current render buffer
        var hostSeconds: Double = 0
        var soundIndex = 0
    }

    /// A click whose tail extends past the current render buffer. Render-thread
    /// only (no lock); `position` is the number of samples already written.
    private struct ActiveClick {
        var soundIndex = 0
        var position = 0
        var active = false
    }

    private let lock = UnfairLock()
    private var schedule = Schedule()
    private var pendingBeats: [RenderBeat] = (0..<16).map { _ in RenderBeat() }
    private var activeClicks: [ActiveClick] = (0..<8).map { _ in ActiveClick() }

    private let sampleRate: Double
    /// Pre-rendered click buffers, indexed by `Schedule.soundIndex` /
    /// `RenderBeat.soundIndex` in `MetronomeSound.allCases` order.
    private let clicksBySound: [[Float]]
    /// `MetronomeSound -> array index`; consulted only off the render thread
    /// (in `setSound`/`preview`), never inside `render`.
    private let soundIndices: [MetronomeSound: Int]
    private let clickBox: ClickRejectionBox

    private(set) var sourceNode: AVAudioSourceNode?

    init(sampleRate: Double,
         clickBox: ClickRejectionBox,
         beatsPerMeasure: Int = 4) {
        self.sampleRate = sampleRate
        self.clickBox = clickBox
        self.clicksBySound = MetronomeSound.allCases.map { sound in
            MetronomeEngine.makeClick(sampleRate: sampleRate, sound: sound)
        }
        self.soundIndices = Dictionary(uniqueKeysWithValues:
            MetronomeSound.allCases.enumerated().map { ($0.element, $0.offset) })
        schedule.samplesPerBeat = max(1, sampleRate * MetronomeScheduler.secondsPerBeat(bpm: 60))
        schedule.beatsPerMeasure = beatsPerMeasure
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

    /// Sets the click output gain (clamped to `MetronomeState.volumeRange`).
    /// Values above 1 are boosted and soft-limited in the render block. Safe to
    /// call while running.
    func setVolume(_ volume: Double) {
        let clamped = min(max(volume, MetronomeState.volumeRange.lowerBound),
                          MetronomeState.volumeRange.upperBound)
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
                    let clickHostSeconds = hostSeconds + (schedule.nextBeatSample - sampleTime) / sampleRate
                    schedule.lastBeatHostSeconds = clickHostSeconds
                    pendingBeats[beatCount] = RenderBeat(offset: offset,
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
                    let clickHostSeconds = hostSeconds + (schedule.previewNextSample - sampleTime) / sampleRate
                    pendingBeats[beatCount] = RenderBeat(offset: offset,
                                                         hostSeconds: clickHostSeconds,
                                                         soundIndex: schedule.previewSoundIndex)
                    beatCount += 1
                    schedule.previewNextSample += schedule.samplesPerBeat
                    schedule.previewBeatsRemaining -= 1
                }
            }
        }

        // 2. Mix clicks into the output (outside the lock) and register each
        //    click's host time with the shared ClickRejection. Clicks longer than
        //    one render buffer carry their remainder into `activeClicks` and are
        //    finished on subsequent renders, so a 0.4 s sample plays in full.
        fillSilence(audioBufferList, frameCount: frames)
        let gain = Float(volume)
        var producedAudio = false

        // New clicks starting in this buffer.
        for i in 0..<beatCount {
            let beat = pendingBeats[i]
            clickBox.register(atSeconds: beat.hostSeconds)
            guard gain > 0 else { continue }
            let click = clicksBySound[beat.soundIndex]
            let consumed = mixClick(click,
                                    gain: gain,
                                    clickStart: 0,
                                    outStart: max(0, Int(beat.offset.rounded(.down))),
                                    into: audioBufferList,
                                    frameCount: frames)
            if consumed > 0 { producedAudio = true }
            if consumed < click.count {
                if let slot = activeClicks.firstIndex(where: { !$0.active }) {
                    activeClicks[slot] = ActiveClick(soundIndex: beat.soundIndex,
                                                     position: consumed,
                                                     active: true)
                }
            }
        }

        // Continue tails started in previous buffers.
        if gain > 0 {
            for i in activeClicks.indices where activeClicks[i].active {
                let click = clicksBySound[activeClicks[i].soundIndex]
                let consumed = mixClick(click,
                                        gain: gain,
                                        clickStart: activeClicks[i].position,
                                        outStart: 0,
                                        into: audioBufferList,
                                        frameCount: frames)
                if consumed > 0 { producedAudio = true }
                activeClicks[i].position += consumed
                if activeClicks[i].position >= click.count {
                    activeClicks[i].active = false
                }
            }
        }

        isSilence.pointee = ObjCBool(!producedAudio)
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

    /// Mixes `click[clickStart...]` into the output from `outStart`, writing at
    /// most the samples that fit in this buffer. Returns the number of click
    /// samples consumed. Gains above unity soft-clip (`tanhf` is allocation- and
    /// lock-free, safe on the render thread).
    private func mixClick(_ click: [Float],
                          gain: Float,
                          clickStart: Int,
                          outStart: Int,
                          into audioBufferList: UnsafeMutablePointer<AudioBufferList>,
                          frameCount: Int) -> Int {
        guard outStart < frameCount, clickStart < click.count else { return 0 }
        let softClip = gain > 1.0
        let n = min(click.count - clickStart, frameCount - outStart)
        guard n > 0 else { return 0 }
        for buffer in UnsafeMutableAudioBufferListPointer(audioBufferList) {
            guard let data = buffer.mData else { continue }
            let maxFrames = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            guard outStart < maxFrames else { continue }
            let count = min(n, maxFrames - outStart)
            let floats = data.assumingMemoryBound(to: Float.self)
            for i in 0..<count {
                var sample = click[clickStart + i] * gain
                if softClip { sample = tanhf(sample) }
                floats[outStart + i] += sample
            }
        }
        return n
    }

    // MARK: - Click synthesis (runs once, off the audio thread)

    /// Pre-rendered click buffer per sound. Tonal sounds are synthesised; the two
    /// claps are loaded from bundled `.wav` samples. Every beat renders the same
    /// click (no downbeat accent), and each buffer is peak-normalized to 0.98.
    private static func makeClick(sampleRate: Double, sound: MetronomeSound) -> [Float] {
        switch sound {
        case .clap1: return loadClap("clap1", sampleRate: sampleRate)
        case .clap2: return loadClap("clap2", sampleRate: sampleRate)
        case .rimshot: return makeRimshot(sampleRate: sampleRate)
        case .classic, .woodblock, .beep, .digital:
            return makeTonalClick(sampleRate: sampleRate, sound: sound)
        }
    }

    /// Tonal clicks: a deep decaying body tone, a low thump for weight, and a
    /// broadband noise attack transient. The body decays slowly enough to carry
    /// real energy (louder perceived level) without bleeding into the next beat
    /// at the maximum tempo. One uniform synthesis — no downbeat accent.
    private static func makeTonalClick(sampleRate: Double, sound: MetronomeSound) -> [Float] {
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
        let thumpFreq: Double
        let thumpAmp: Double

        switch sound {
        case .classic:
            dur = 0.07; freq = 800; decay = 45
            noiseDur = 0.004; noiseAmt = 0.45; harmonic2 = 0.25
            thumpFreq = 130; thumpAmp = 1.0
        case .woodblock:
            dur = 0.09; freq = 550; decay = 28
            noiseDur = 0.006; noiseAmt = 0.7; harmonic2 = 0.4
            thumpFreq = 110; thumpAmp = 1.0
        case .beep:
            dur = 0.16; freq = 650; decay = 10
            noiseDur = 0.003; noiseAmt = 0.08; harmonic2 = 0.0
            thumpFreq = 150; thumpAmp = 0.35
        case .digital:
            dur = 0.045; freq = 1100; decay = 100
            noiseDur = 0.002; noiseAmt = 0.5; harmonic2 = 0.0
            thumpFreq = 180; thumpAmp = 0.8
        case .clap1, .clap2, .rimshot:
            fatalError("makeTonalClick does not support \(sound)")
        }

        let n = max(1, Int(sampleRate * dur))
        let thumpDecay = dur * 0.6
        var s = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let t = Double(i) / sampleRate
            let body = sin(2 * .pi * freq * t) + harmonic2 * sin(4 * .pi * freq * t)
            let env = exp(-decay * t)
            let noiseEnv = exp(-t / noiseDur) * noiseAmt
            let thump = thumpAmp * sin(2 * .pi * thumpFreq * t) * exp(-t / thumpDecay)
            s[i] = Float(body * env + thump + Double(nextNoise()) * noiseEnv)
        }
        return normalizePeak(s, to: 0.98)
    }

    /// Loads a bundled `.wav` clap, converts it to mono Float32 at the engine's
    /// sample rate, and peak-normalizes it. Runs once at init (off the render
    /// thread), so the higher-level AVAudioFile/AVAudioConverter APIs are safe
    /// here. Returns a short silent buffer if the asset is missing or undecodable,
    /// so a missing file degrades to silence instead of crashing the render block.
    private static func loadClap(_ resource: String, sampleRate: Double) -> [Float] {
        let silent = { [Float](repeating: 0, count: max(1, Int(sampleRate * 0.05))) }

        guard let url = Bundle.main.url(forResource: resource, withExtension: "wav"),
              let file = try? AVAudioFile(forReading: url) else { return silent() }

        let srcFormat = file.processingFormat
        let srcFrames = AVAudioFrameCount(file.length)
        guard let srcBuffer = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: srcFrames) else {
            return silent()
        }
        do { try file.read(into: srcBuffer, frameCount: srcFrames) } catch { return silent() }

        guard let dstFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let converter = AVAudioConverter(from: srcFormat, to: dstFormat) else { return silent() }

        let ratio = sampleRate / srcFormat.sampleRate
        let dstCapacity = AVAudioFrameCount((Double(srcFrames) * ratio).rounded(.up) + 1024)
        guard let dstBuffer = AVAudioPCMBuffer(pcmFormat: dstFormat, frameCapacity: dstCapacity) else {
            return silent()
        }

        // Streaming conversion — supports sample-rate conversion, unlike the
        // whole-buffer `convert(to:from:)`. The input block hands over the full
        // source buffer once, then signals end-of-stream.
        var fed = false
        var error: NSError?
        let status = converter.convert(to: dstBuffer, error: &error) { _, inStatus in
            if fed {
                inStatus.pointee = .endOfStream
                return nil
            }
            fed = true
            inStatus.pointee = .haveData
            return srcBuffer
        }
        guard status == .haveData || status == .endOfStream else { return silent() }

        let frames = Int(dstBuffer.frameLength)
        guard frames > 0, let channel = dstBuffer.floatChannelData?[0] else { return silent() }
        return normalizePeak(Array(UnsafeBufferPointer(start: channel, count: frames)), to: 0.98)
    }

    /// Rimshot: a sharp "stick" click (very short bright noise) plus a
    /// fast-decaying high metallic ring.
    private static func makeRimshot(sampleRate: Double) -> [Float] {
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

        let dur = 0.055
        let n = max(1, Int(sampleRate * dur))
        var s = [Float](repeating: 0, count: n)

        let ringFreq = 4400.0
        let ring2 = ringFreq * 1.5
        let ringAmp = 0.8
        let ringDecay = 0.011

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
