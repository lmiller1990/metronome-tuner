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
    }

    private struct RenderBeat {
        var offset: Double = 0        // frame offset into the current render buffer
        var accent = false
        var hostSeconds: Double = 0
    }

    private let lock = UnfairLock()
    private var schedule = Schedule()
    private var pendingBeats: [RenderBeat] = (0..<16).map { _ in RenderBeat() }

    private let sampleRate: Double
    private let clickAccent: [Float]
    private let clickNormal: [Float]
    private let clickBox: ClickRejectionBox

    private(set) var sourceNode: AVAudioSourceNode?

    init(sampleRate: Double,
         clickBox: ClickRejectionBox,
         beatsPerMeasure: Int = 4,
         accentFirstBeat: Bool = true) {
        self.sampleRate = sampleRate
        self.clickBox = clickBox
        self.clickAccent = MetronomeEngine.makeClick(sampleRate: sampleRate, accent: true)
        self.clickNormal = MetronomeEngine.makeClick(sampleRate: sampleRate, accent: false)
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

        // 1. Advance the schedule under the lock; record this buffer's beats into
        //    the pre-allocated `pendingBeats`. No mixing or allocation here.
        lock.withLock {
            running = schedule.running
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
                                                         hostSeconds: clickHostSeconds)
                    beatCount += 1
                    schedule.nextBeatSample += schedule.samplesPerBeat
                }
            }
        }

        // 2. Mix clicks into the output (outside the lock) and register each
        //    click's host time with the shared ClickRejection.
        fillSilence(audioBufferList, frameCount: frames)
        if running, beatCount > 0 {
            for i in 0..<beatCount {
                let beat = pendingBeats[i]
                clickBox.register(atSeconds: beat.hostSeconds)
                mix(click: beat.accent ? clickAccent : clickNormal,
                    at: beat.offset,
                    into: audioBufferList,
                    frameCount: frames)
            }
            isSilence.pointee = false
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
                floats[start + i] += click[i]
            }
        }
    }

    // MARK: - Click synthesis (runs once, off the audio thread)

    /// Short percussive click: a fast-decaying high sine. Accent is louder and
    /// brighter so beat 1 is distinguishable without relying on pitch.
    private static func makeClick(sampleRate: Double, accent: Bool) -> [Float] {
        let length = Int(sampleRate * 0.03) // ~30 ms
        var samples = [Float](repeating: 0, count: length)
        let baseFreq = accent ? 2200.0 : 1600.0
        let gain = accent ? 0.9 : 0.55
        let decay = accent ? 160.0 : 120.0
        for i in 0..<length {
            let t = Double(i) / sampleRate
            let envelope = exp(-decay * t)
            let osc = sin(2 * Double.pi * baseFreq * t)
            samples[i] = Float(gain * envelope * osc)
        }
        return samples
    }
}
