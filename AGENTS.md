# Sub-Agent Build Plan — Violin Tuner + Metronome POC

This supplements `PLAN.md`. It fixes the module split, exact file tree, and public type
contracts up front so slices can be built in parallel and compose without renegotiation.

Read `PLAN.md` first. Where this file and PLAN.md conflict, this file wins (it is newer and
more precise about code layout and signatures).

---

## 0. Shared Context (given to every agent)

### Environment facts (verified)
- macOS, Xcode 27.0, Swift 6.4, Apple Silicon.
- Homebrew installed. `xcodegen` NOT installed. No iOS simulator runtime downloaded.
- Therefore: deterministic tests run on macOS via `swift test` (Swift Package). The iOS app is
  generated with XcodeGen and compile-verified with `xcodebuild build` (no simulator needed to
  *compile*; running requires a device or a downloaded runtime — that is the user's hardware step).

### Tooling decision
- **Runtime dependencies: zero.** No third-party code ships in the app.
- **Build tool (not a runtime dep): XcodeGen.** Install once: `brew install xcodegen`.
  Generates `ViolinPractice.xcodeproj` from `project.yml`. This avoids hand-writing `.pbxproj`.
- **Testability: Swift Package.** `Package.swift` defines a library target `ViolinPracticeCore`
  (platforms iOS 17+ and macOS 13+) holding all deterministic logic. `swift test` runs its unit
  tests natively on macOS. The iOS app target depends on this local package.

### Platform targets
- iOS 17+ only. iPhone only. Portrait only. No iPad, no landscape, no legacy-OS support.
- Swift 6.4, strict concurrency. Use `@Observable` + `@MainActor` for UI-observable state.

### Hard invariants (all agents)
1. **No audio/DSP work on the main thread.** Mic capture, YIN, smoothing, and click scheduling
   all run on background/realtime threads. Only the published `@Observable` results reach the
   main actor.
2. **Audio realtime-safety.** Inside `AVAudioEngine` tap/render callbacks: no allocation, no
   locks, no SwiftUI, no `DispatchQueue` hops, no ObjC messaging. Operate on pre-allocated
   `[Float]`/`UnsafeBufferPointer<Float>`. Publish results out-of-band via `Task { @MainActor }`
   or an `AsyncStream`.
3. **No DSP/logic inside SwiftUI views.** Views only read the engine's published state.
4. **Everything internal except the core package's app-consumed API**, which is `public`
   (the app target imports `ViolinPracticeCore` as a separate module).
5. **Zero third-party packages** in `Package.swift` and `project.yml`.
6. **A shared monotonic clock** (host time, e.g. `mach_absolute_time`/`AVAudioTime.hostTime`) is
   used for BOTH metronome click times and mic-capture frame times, so `ClickRejection` works.
   Do NOT mix input-node and output-node sample clocks (they drift).

### Fixed file tree (each task owns exactly the files listed)
```
metronome/
├── Package.swift
├── project.yml
├── .gitignore
├── README.md
├── Sources/ViolinPracticeCore/
│   ├── Models/Pitch.swift
│   ├── Models/MetronomeState.swift
│   ├── MusicTheory.swift
│   ├── PitchDetector.swift            # YIN
│   ├── PitchSmoother.swift
│   ├── ClickRejection.swift
│   └── MetronomeScheduler.swift       # pure timing math (no AVFoundation)
├── Tests/ViolinPracticeCoreTests/
│   ├── MusicTheoryTests.swift
│   ├── YinTests.swift
│   ├── PitchSmootherTests.swift
│   ├── ClickRejectionTests.swift
│   └── MetronomeSchedulerTests.swift
├── App/
│   ├── ViolinPracticeApp.swift
│   ├── Audio/AudioEngine.swift
│   ├── Audio/MetronomeEngine.swift
│   ├── Views/PracticeView.swift
│   ├── Views/TunerGauge.swift
│   ├── Views/NoteDisplay.swift
│   ├── Views/MetronomeControls.swift
│   ├── Views/PendulumView.swift
│   ├── Info.plist
│   └── Assets.xcassets/
```

### Shared public API contracts (in `ViolinPracticeCore`)
These signatures are the integration seams. Implement exactly these names/shapes; internal
details are each agent's own. Keep the pure parts deterministic and mic-free.

```swift
// MusicTheory.swift
public enum MusicTheory {
    public static let midiForA4 = 69
    public static let defaultA4Hz = 440.0
    /// Nearest MIDI note for a frequency (12-TET, rounded).
    public static func nearestMidiNote(frequencyHz: Double, referenceA4Hz: Double = defaultA4Hz) -> Int
    /// Cents from nearest note; negative = flat, positive = sharp, range (-50, +50].
    public static func cents(frequencyHz: Double, referenceA4Hz: Double = defaultA4Hz) -> Double
    /// Exact frequency of a MIDI note.
    public static func frequency(midiNote: Int, referenceA4Hz: Double = defaultA4Hz) -> Double
    /// Sharp spelling, e.g. 69 -> "A", 61 -> "C#".
    public static func noteName(midiNote: Int) -> String
    /// Scientific pitch notation, e.g. 69 -> "A4" (C4 = 60).
    public static func noteNameWithOctave(midiNote: Int) -> String
    /// Italian tempo marking for a BPM, e.g. 60 -> "Adagio" (used by the mockup label).
    public static func tempoMarking(bpm: Double) -> String
}

// Models/Pitch.swift
public struct PitchMeasurement: Equatable, Sendable {
    public var frequencyHz: Double?   // nil = no reliable pitch
    public var midiNote: Int?
    public var noteName: String?      // e.g. "A4"
    public var cents: Double          // 0 when frequencyHz == nil
    public var confidence: Double     // 0...1
    public init(frequencyHz: Double? = nil, midiNote: Int? = nil,
                noteName: String? = nil, cents: Double = 0, confidence: Double = 0)
    public static let idle = PitchMeasurement()
}

// Models/MetronomeState.swift
public struct MetronomeState: Equatable, Sendable {
    public var bpm: Double = 60
    public var beatsPerMeasure: Int = 4
    public var isRunning: Bool = false
    public var currentBeat: Int = 0     // 0 = not started; 1...beatsPerMeasure while running
    public var accentFirstBeat: Bool = true
    public init()
    public static let bpmRange: ClosedRange<Double> = 30...240
}

// PitchDetector.swift  (YIN)
public struct PitchDetector {
    public init(sampleRate: Double, threshold: Double = 0.15)
    /// Pure YIN. Returns (frequencyHz, confidence) or (nil, 0) if no periodicity detected.
    /// Operates on the passed mono buffer; retains no state.
    public static func yin(buffer: [Float], sampleRate: Double, threshold: Double) -> (frequencyHz: Double?, confidence: Double)
    /// Runs yin and converts to a PitchMeasurement (no smoothing/confidence gate here).
    public func measure(buffer: [Float]) -> PitchMeasurement
}

// PitchSmoother.swift
public struct PitchSmoother {
    public init(sampleRate: Double,
                minConfidence: Double = 0.9,
                silenceRMSThreshold: Double = 0.005,
                maxCentsJumpPerFrame: Double = 200,
                noteChangeConfirmationFrames: Int = 2,
                holdFramesWhenSilent: Int = 5)
    /// Feed one raw measurement (+ frame RMS). Returns the stabilized measurement for UI.
    public mutating func update(_ raw: PitchMeasurement, rms: Double) -> PitchMeasurement
    public mutating func reset()
}

// ClickRejection.swift
public struct ClickRejection {
    /// `windowSeconds` = rejection window after a click (default 0.025 = 25 ms; PLAN allows 10-30 ms).
    public init(windowSeconds: Double = 0.025)
    public mutating func registerClick(atSampleTime sampleTime: Double)   // shared monotonic clock
    public func shouldReject(atSampleTime sampleTime: Double) -> Bool
    public mutating func prune(nowSampleTime: Double)
}

// MetronomeScheduler.swift  (pure, no AVFoundation)
public struct BeatEvent: Equatable, Sendable {
    public var sampleIndex: Int
    public var beatNumber: Int    // 1...beatsPerMeasure
    public var isAccent: Bool
}
public struct MetronomeScheduler {
    public init(sampleRate: Double, bpm: Double, beatsPerMeasure: Int)
    public static func secondsPerBeat(bpm: Double) -> Double
    public mutating func setBPM(_ bpm: Double)
    /// Beats whose sampleIndex lies in [startSample, endSample), advancing internal phase.
    public mutating func beats(inSampleRange start: Int, _ end: Int) -> [BeatEvent]
}
```

### App-side seam (iOS target, imports `ViolinPracticeCore`)
```swift
// Audio/AudioEngine.swift
@Observable @MainActor
public final class AudioEngine {
    public private(set) var pitch: PitchMeasurement = .idle
    public private(set) var metronome: MetronomeState = .init()
    /// 0...1 progress through the current beat, for the pendulum swing.
    public private(set) var pendulumPhase: Double = 0
    public init()
    public func start()          // configure AVAudioSession + engine + mic tap
    public func startMetronome()
    public func stopMetronome()
    public func setBPM(_ bpm: Double)
}
```
`MetronomeEngine` (AVFoundation click rendering + sample-accurate scheduling) and the views are
internal to the app target; shapes are each agent's own, constrained only by the invariants.

---

## 1. Task Slices

Dependency order: **A** (scaffolding) defines the build; **B/C/D/E** are pure/parallel on top of
the fixed tree + contracts; **F** is the AVFoundation integration owner; **G** integrates/verifies.

### A. Scaffolding + package + app entry
- **Owns:** `Package.swift`, `project.yml`, `.gitignore`, `App/Info.plist`,
  `App/Assets.xcassets/`, `App/App/ViolinPracticeApp.swift`.
- **Package.swift:** library target `ViolinPracticeCore`, platforms `[.iOS(.v17), .macOS(.v13)]`,
  test target `ViolinPracticeCoreTests`; zero dependencies.
- **project.yml:** app target `ViolinPractice`, iOS 17+, `TARGETED_DEVICE_FAMILY = 1` (iPhone),
  portrait-only, depends on local package `ViolinPracticeCore` (path: `.`), includes `App/` sources
  + `Info.plist` + asset catalog; bundle id e.g. `com.example.ViolinPractice`. Scheme with the test
  action disabled (tests run via `swift test`).
- **Info.plist:** `NSMicrophoneUsageDescription` with a concise one-sentence explanation;
  `UILaunchScreen` empty dict; audio background not required for POC.
- **App entry:** `@main struct ViolinPracticeApp: App`, dark color scheme, hosts `PracticeView`,
  requests mic permission (`AVAudioApplication.requestRecordPermission` or the async variant) on
  first appear, then calls `engine.start()`.
- **Acceptance:** `swift test` lists the (initially empty/placeholder) test target and passes;
  `xcodegen generate` produces `ViolinPractice.xcodeproj`;
  `xcodebuild -project ViolinPractice.xcodeproj -scheme ViolinPractice -destination 'generic/platform=iOS' build` compiles the stub app.
- **Non-goals:** any DSP, audio engine, or view logic beyond the empty `PracticeView` placeholder.

### B. Core models + MusicTheory
- **Owns:** `Sources/ViolinPracticeCore/Models/Pitch.swift`,
  `Sources/ViolinPracticeCore/Models/MetronomeState.swift`, `Sources/ViolinPracticeCore/MusicTheory.swift`,
  `Tests/ViolinPracticeCoreTests/MusicTheoryTests.swift`.
- **Change:** implement the exact public API from §0. Chromatic (no violin-string restriction).
  12-TET, A4=440 default. `tempoMarking` maps BPM bands to conventional Italian terms (e.g. 30-40
  Grave, 40-60 Largo/Lento, 60-76 Adagio, 76-108 Andante, 108-120 Moderato, 120-156 Allegro,
  156-176 Vivace, 176+ Presto — use a defensible standard table).
- **Acceptance:** unit tests cover — A4=440→69; 442 Hz→A4 (near +8 cents); cents sign and range;
  `noteNameWithOctave` for A4/C#4/G3/E5; `frequency(midiNote:)` round-trips; `secondsPerBeat` not
  used here (that's C) but `bpmRange` clamps are tested in C. All green via `swift test`.

### C. YIN pitch detector + smoother + click rejection
- **Owns:** `PitchDetector.swift`, `PitchSmoother.swift`, `ClickRejection.swift`, and
  `Tests/.../YinTests.swift`, `PitchSmootherTests.swift`, `ClickRejectionTests.swift`.
- **Change:**
  - `PitchDetector`: implement YIN (difference function, CMNDF, absolute threshold, parabolic
    interpolation of the trough) on a mono Float buffer. Restrict search to a valid frequency range
    (e.g. 30–2000 Hz — covers G3 196 Hz through E5 659 Hz and beyond). Return frequency + a
    confidence derived from trough depth; return nil below confidence.
  - `PitchSmoother`: gate on RMS (reject silence) and min confidence; reject single-frame transient
    jumps larger than `maxCentsJumpPerFrame` (clamp or drop); exponential smoothing of cents;
    require `noteChangeConfirmationFrames` consistent frames before changing the displayed note;
    hold the last measurement for `holdFramesWhenSilent` frames after signal loss, then idle.
  - `ClickRejection`: maintain recent click times on the shared sample clock; `shouldReject`
    returns true while within `windowSeconds` after any registered click; `prune` drops stale ones.
- **Acceptance (all via `swift test`, synthetic audio only — no mic):**
  - YIN returns 440.0±0.5 Hz on a generated 440 Hz sine; correct notes for G3 (196.0), D4 (293.66),
    A4 (440), E5 (659.26); confidence ~1 on clean sine; nil/noisy on silence or white noise.
  - Smoother: noisy 440 Hz frames converge to a stable A4 with small cents; a burst of random
    measurements does not flicker the note; a single outlier frame is suppressed.
  - ClickRejection: `shouldReject` true within the window after `registerClick`, false after;
    `prune` removes stale entries without changing in-window behavior.

### D. Metronome scheduler (pure) + click synthesis spec
- **Owns:** `MetronomeScheduler.swift`, `Tests/.../MetronomeSchedulerTests.swift`.
- **Change:** implement `secondsPerBeat` and the stateful `beats(inSampleRange:)`. Beat 1 is accented
  every measure (`isAccent` true when `beatNumber == 1` and `accentFirstBeat`). `setBPM` must not
  skip/double beats when changed mid-run (recompute the next beat time from the current phase, not
  by resetting). Clamp BPM to `MetronomeState.bpmRange`.
- **Acceptance:** unit tests cover — `secondsPerBeat(60) == 1.0`; at 120 BPM/44.1 kHz, beat spacing
  is 22050 samples; `beats(inSampleRange:)` over an exact N-beat span returns N events with correct
  `beatNumber` cycling 1..4 and accent only on 1; `setBPM` mid-span changes spacing without an
  immediate double-fire.

### E. SwiftUI views + app-state bridging (UI only)
- **Owns:** all `App/Views/*.swift` except they must compile against the `AudioEngine` seam from §0
  (use a lightweight in-memory stub if F isn't merged yet — do NOT put fake audio logic in views).
- **Change:** dark, restrained UI per PLAN.md §4–§6 and the approved left-hand mockup.
  - Top bar: `☰` (no-op) · "Tuner · Metronome" title · `⚙` (no-op). Remove the segmented control.
    Below: static "A4 = 440 Hz" label (no interaction for POC).
  - `TunerGauge`: semicircular gauge, -50…+50 cents, needle smooth (`.animation(.easeOut)`), green
    in-tune band ±5 cents, neutral dim elsewhere, warm→red toward extremes; tick marks; "FLAT /
    IN TUNE / SHARP" text labels. Direction must be readable without color (needle position + labels).
  - `NoteDisplay`: dominant note letter (e.g. "A"), then "440.2 Hz" and "+2 cents". Idle state shows
    "—" and "Listening…" (never a random note).
  - `MetronomeControls`: tempo marking (from `MusicTheory.tempoMarking`), large BPM, −/+ buttons
    (tap = ±1 BPM; hold-to-repeat optional).
  - `PendulumView`: pendulum arm driven by `engine.pendulumPhase` via `TimelineView`/CADisplayLink;
    swing angle interpolates between the last and next beat — NOT an independent looping animation.
  - `PracticeView`: composes all of the above; Start/Stop button toggles `engine.startMetronome()/
    stopMetronome()` without touching tuner state.
- **Acceptance:** compiles in the app target; tuner/metronome regions occupy ~upper 45-50% / lower
  half; note + cents + Hz render; pendulum angle is a pure function of `pendulumPhase` (testable
  via a tiny helper mapping phase→angle if kept deterministic). UI look is verified on device/sim
  by the user (no runtime here).

### F. AVFoundation audio engine + metronome engine (integration owner)
- **Owns:** `App/Audio/AudioEngine.swift`, `App/Audio/MetronomeEngine.swift`. Depends on B/C/D APIs.
- **Change:**
  - `AudioEngine`: `AVAudioSession` category `.playAndRecord`, mode `.measurement`, option
    `.defaultToSpeaker` (metronome audibly through speaker while recording). Build the
    `AVAudioEngine` graph: input node → mic tap; player/source node → main mixer for the metronome.
    Mic tap installs a buffer (e.g. 2048/4096 frames); convert to `[Float]`, compute RMS, run
    `PitchDetector` + `PitchSmoother` on a background queue; if `ClickRejection.shouldReject` for
    that frame's host time, downweight/skip that frame's update. Publish `pitch` to `@MainActor`.
  - `MetronomeEngine`: sample-accurate scheduling on the audio timeline (AVAudioPlayerNode scheduled
    ahead, or AVAudioSourceNode render — NOT a `Timer`/`DispatchSourceTimer`). Short percussive click
    (accent = higher gain or different pitch); accent on beat 1. On each scheduled click, register
    its host time with the shared `ClickRejection` and publish `currentBeat` + beat host time so the
    pendulum phase can be derived. `setBPM` applies live while running.
  - Concurrency: realtime-safe callbacks (§0 invariant 2); background DSP → `Task { @MainActor }`.
- **Acceptance:** app compiles for iOS; architecture is inspectable for the hardware acceptance test
  (simultaneous speaker metronome + mic pitch detection). The actual "click doesn't destabilize a
  sustained pitch" verdict is a **user hardware test** (see G), not runnable here.

### G. Final integration, build, docs
- **Owns:** `README.md`, cross-file compile fixes, the final verification runs.
- **Change:** resolve any interface drift between slices; ensure `swift test` is fully green and
  `xcodebuild build` succeeds for `generic/platform=iOS` (and `generic/platform=iOS Simulator`).
  `README.md`: prerequisites (`brew install xcodegen`), `xcodegen generate`, `swift test`,
  `xcodebuild build`, open in Xcode, and a step-by-step **hardware acceptance checklist** from
  PLAN.md §8 (the key experiment: sustained violin note with metronome audible through the speaker;
  open G3/D4/A4/E5 recognition; click-rejection effectiveness; BPM change while running).
- **Acceptance:** both `swift test` and `xcodebuild build` exit 0; README complete; no dead
  scaffolds/placeholders/todos remain.

---

## 2. Verification ladder (what "done" means without hardware)
1. `swift test` — all deterministic DSP/model tests green on macOS (slices B/C/D).
2. `xcodegen generate` — project generated cleanly (slice A).
3. `xcodebuild -project ViolinPractice.xcodeproj -scheme ViolinPractice -destination 'generic/platform=iOS' build` — app compiles (slice G).
4. **Not runnable here:** simulator run (no runtime downloaded) and the real-hardware
   simultaneous-tuner+metronome experiment (PLAN.md §8). These are the user's final steps.

If an agent cannot meet an acceptance criterion without hardware, it must say so explicitly and
leave the code in a buildable, testable state rather than faking the behavior.
