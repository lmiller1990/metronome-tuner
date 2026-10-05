# Violin Tuner + Metronome (POC)

A single-screen iOS proof-of-concept that runs a real-time chromatic tuner and a
sample-accurate metronome **simultaneously**, so a violinist can practise with an
audible beat while watching their intonation.

Key design goals (see `PLAN.md` and `AGENTS.md` for the full spec):

- **Accurate, responsive pitch detection** — YIN algorithm, monophonic, chromatic
  (no violin-string restriction).
- **Very stable metronome timing** — driven by the audio render timeline
  (`AVAudioSourceNode`), never SwiftUI timers.
- **Click rejection** — the tuner down-weights microphone frames overlapping the
  app's own metronome clicks (≈25 ms window) so speaker clicks don't destabilise a
  sustained note.
- **Polished single dark screen** — tuner gauge in the upper half, pendulum
  metronome in the lower half.

Zero third-party runtime dependencies. Deterministic DSP/model logic lives in a
Swift Package (`ViolinPracticeCore`) and is unit-tested on macOS; the iOS app
target imports that package.

---

## Layout

```
Sources/ViolinPracticeCore/   pure, testable logic (YIN, smoothing, click rejection,
                              metronome scheduling, music theory, models)
Tests/ViolinPracticeCoreTests/  unit tests (59, run via `swift test`)
App/                          the iOS app target
  ViolinPracticeApp.swift     app entry (@main, mic permission, engine.start())
  Audio/AudioEngine.swift     @Observable @MainActor engine (session, mic tap, DSP queue)
  Audio/MetronomeEngine.swift AVAudioSourceNode sample-accurate click rendering
  Views/*.swift               SwiftUI (PracticeView, TunerGauge, NoteDisplay,
                              MetronomeControls, PendulumView)
project.yml                   XcodeGen spec
Package.swift                 SPM manifest for the core library + tests
```

---

## Prerequisites

- macOS with Xcode (project built against Swift 6).
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`

The iOS app target has **no third-party packages** and **no runtime dependencies**.

---

## Build

```bash
# 1. Generate the Xcode project from project.yml
xcodegen generate

# 2. Run the deterministic core test suite (macOS-native)
swift test

# 3. Compile-verify the iOS app (no simulator runtime required)
xcodebuild -project ViolinPractice.xcodeproj -scheme ViolinPractice \
  -destination 'generic/platform=iOS' build

# 4. Open in Xcode to run on a device or simulator
open ViolinPractice.xcodeproj
```

### Code signing

For the compile-only step you can disable signing:

```bash
xcodebuild -project ViolinPractice.xcodeproj -scheme ViolinPractice \
  -destination 'generic/platform=iOS' build CODE_SIGNING_ALLOWED=NO
```

To **deploy to a physical iPhone** (the only way to test audio):

1. In Xcode, select the **ViolinPractice** target → **Signing & Capabilities**.
2. Enable **"Automatically manage signing"** and pick your **Team** (your Apple ID
   / paid or free developer team).
3. Optionally change the bundle id — `com.example.ViolinPractice` is fine locally.
4. Ensure your device is **trusted**: Xcode → *Window → Devices and Simulators*
   shows the iPhone, and after enabling Developer Mode on the phone you must tap
   **Trust**.
5. Select your iPhone as the run destination and press **Run**.

If the phone shows nothing after a "successful" run, it is almost always the
signing/team step above (an unsigned binary can compile but cannot install) or the
device trust prompt. If you change the bundle id, you may need to re-select the
run destination.

The default `project.yml` uses `CODE_SIGN_STYLE: Automatic` with an empty
`DEVELOPMENT_TEAM`, so you **must** pick a team in Xcode (the team is per-developer
and is not committed).

---

## Hardware acceptance checklist (PLAN.md §8)

These steps require a real iPhone with a microphone and speaker (a simulator cannot
exercise the audio pipeline). The central experiment is **simultaneous speaker
metronome + microphone pitch detection**.

1. **Setup** — Install the app on an iPhone, grant microphone permission, and place
   the phone near your instrument. The tuner should show an idle state
   (`—` / `Listening…`) until a confident pitch is heard.
2. **Note recognition (the core experiment)** — Play a **sustained** note near the
   phone while the metronome is stopped, and while it is running (press **Start** so
   clicks are audible through the speaker):
   - Open **G3** (196 Hz)
   - **D4** (293.66 Hz)
   - **A4** (440 Hz)
   - **E5** (659.26 Hz)

   The correct note letter (G/D/A/E) should be shown, the needle should settle near
   0 cents when in tune, and it should move flat/sharp (left/right) as you bend the
   pitch.
3. **Needle stability** — On a sustained note the needle should be visually stable,
   not flickering; brief signal dropouts should hold the last reading for a moment
   before returning to `Listening…`.
4. **Click-rejection effectiveness** — With the metronome running and clicking
   through the speaker, a sustained violin note must **not** change note or jump
   noticeably on each click. This is the key acceptance test for the rejection
   window.
5. **BPM change while running** — Press **−**/**+** (or hold to repeat) while the
   metronome is running; the audible beat and the pendulum swing should track the
   new tempo smoothly without skipping or doubling beats.
6. **Pendulum synchronisation** — The visible pendulum should swing in time with the
   audible clicks, reaching its extreme at each beat.
7. **Background/foreground recovery** — Background the app (or lock the device),
   then return: audio and tuning should resume without the metronome or tuner
   drifting or crashing (best-effort for the POC).
8. **Accent** — Beat 1 of each 4/4 measure should sound distinctly accented
   (louder/brighter) than beats 2–4.

---

## Verification without hardware

The following pass in this environment (macOS, no iOS simulator runtime installed):

- `swift test` — 59 deterministic tests (music theory, YIN against synthetic sines,
  pitch smoothing, click rejection, metronome scheduling) all green.
- `xcodegen generate` — project generated cleanly.
- `xcodebuild … build` for `generic/platform=iOS` — app compiles.

Simulator **run** and the real-hardware checklist above are the final user steps and
cannot be exercised here.

---

## Architecture

Data flows are directional and thread-safe by construction. The one rule that bit
twice during bring-up: **realtime/background audio callbacks must be `nonisolated`,
`@Sendable`, and must never touch `@MainActor` state.**

```
mic ──installTap──▶ MicProcessor.process (realtime messenger queue)
                      │  copy PCM into a pre-allocated pool buffer (no alloc/lock)
                      ▼
                 serial DSP queue (com.example.violinpractice.pitch)
                      │  ClickRejection.skip? → RMS → YIN (PitchDetector)
                      │  → PitchSmoother → PitchMeasurement
                      ▼
                 Task { @MainActor } → engine.pitch  (SwiftUI observes)

engine.metronome (MetronomeState, @MainActor) ◀── setBPM/start/stop (UI buttons)
                                                      │
metronomeEngine (AVAudioSourceNode render block) ◀─────┘
   render() → sample-accurate click scheduling on the audio timeline
            → registers each click's host time with ClickRejectionBox
            → engine.pendulumPhase derived from last click host time
```

- **`ViolinPracticeCore`** — pure, mic-free, unit-tested (`Sources/`). Models +
  MusicTheory + YIN (`PitchDetector`) + smoothing (`PitchSmoother`) + click
  rejection (`ClickRejection`) + pure beat math (`MetronomeScheduler`). No
  AVFoundation, no UI.
- **`App/Audio/AudioEngine.swift`** — `@Observable @MainActor` seam. Owns the
  `AVAudioSession` + `AVAudioEngine` graph, the `MicProcessor`, and publishes
  `pitch`/`metronome`/`pendulumPhase`. Construct it **on the main actor**
  (`MainActor.run { AudioEngine() }` in the app entry), not as a stored `@State`
  default — a `@MainActor` init off the main thread traps at startup.
- **`App/Audio/MetronomeEngine.swift`** — `AVAudioSourceNode` render block doing
  sample-accurate click scheduling (never `Timer`/`DispatchSourceTimer`). Guarded
  by an unfair lock; allocation-free in the render path.
- **Shared clock** — `HostClock` (mach host time) is used for *both* click times
  and mic-frame times so `ClickRejection` compares like-for-like (input and output
  node sample clocks drift, so they are never mixed).
- **Views** (`App/Views/`) — read state through the `AudioEngine` seam only; zero
  DSP/audio logic.

### Concurrency boundaries (why they matter)

- Mic tap closure is `@Sendable` and captures only the `@unchecked Sendable`
  `MicProcessor` — it runs on AVFoundation's realtime messenger queue, *not* the
  main actor. Making it implicitly `@MainActor` (inheriting from `buildGraph()`)
  caused the startup `_dispatch_assert_queue_fail` crash.
- Background DSP publishes results via `Task { @MainActor in engine.pitch = … }` —
  never writes `@Observable` state directly from a background thread.
- `MainActor.assumeIsolated` was replaced with `Task { @MainActor }` — the former
  traps if the assumption is ever wrong.

---

## Debugging device crashes

To see why a device run crashed, pull the `.ips` crash logs off the phone and read
the faulting thread's backtrace:

```bash
brew install libimobiledevice   # one time
idevicecrashreport -k ./crashlogs
# then open crashlogs/.../ViolinPractice-*.ips
```

The key fields are `faultingThread`, `legacyInfo.threadTriggered.queue`, and the
`frames[].symbol` list. Symbolicated frames name the exact Swift closure or
framework that trapped.

Known trap (fixed): the mic-tap `installTap` closure inherits `@MainActor`
isolation from `AudioEngine.buildGraph()` but runs on AVFoundation's
`RealtimeMessenger` queue, trapping with `_dispatch_assert_queue_fail`. The tap
closure is marked `@Sendable` and captures only the `@unchecked Sendable`
`MicProcessor`, never `@MainActor` state. If you add audio callbacks, keep them
`nonisolated`/`@Sendable` and touch no main-actor state from realtime threads.
