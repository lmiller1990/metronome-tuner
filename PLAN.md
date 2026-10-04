iOS Violin Tuner + Metronome — POC Requirements

1. Goal

Build an iOS proof-of-concept combining a real-time chromatic tuner and metronome into a single practice screen.

The defining feature is that both tools operate simultaneously. A violinist should be able to practise with an audible metronome while continuously seeing their intonation.

The POC should prioritise:

* Accurate, responsive pitch detection.
* Very stable metronome timing.
* Pitch detection that is not confused by the app’s own metronome clicks.
* A polished single-screen UI.
* Simple architecture that can evolve into a production app.

No accounts, cloud services, backend, AI, advertising, or analytics are required.

⸻

2. Platform and Technical Requirements

Platform

* Native iOS application.
* Swift.
* SwiftUI for UI.
* Target a recent iOS version rather than supporting legacy devices for the POC.
* Portrait orientation initially.
* iPhone only for the POC.

Use Apple’s native frameworks wherever practical.

Audio

Use:

* AVFoundation
* AVAudioEngine
* AVAudioSession

The audio system must support simultaneous microphone capture and metronome playback.

Configure the audio session appropriately for simultaneous recording/playback.

Audio processing must not occur on the main/UI thread.

Pitch Detection

Implement a real-time monophonic pitch detector.

Recommended initial algorithm: YIN.

The detector should output at minimum:

frequencyHz
nearestNote
centsFromNearestNote
confidence

For example:

frequency: 440.2 Hz
note: A4
cents: +0.8
confidence: 0.97

Reference tuning defaults to:

A4 = 440 Hz
12-tone equal temperament

The tuner is chromatic. Do not artificially restrict detection to violin strings.

Pitch processing should include:

* confidence thresholding;
* rejection of silence/very-low-level input;
* smoothing between successive measurements;
* rejection of obvious transient measurements;
* stable note selection near note boundaries.

The UI should feel stable rather than having the needle and note constantly flickering.

Metronome

The metronome must be driven by the audio system rather than SwiftUI timers.

Requirements:

* accurate beat scheduling;
* adjustable BPM;
* default 60 BPM;
* sensible POC range such as 30–240 BPM;
* 4/4 default;
* accented first beat;
* short percussive click;
* visual pendulum synchronised with audible beats.

Timing accuracy takes priority over perfectly synchronising SwiftUI animation frames.

Preventing the Metronome From Confusing the Tuner

This is an important POC requirement.

The app knows precisely when it generates a click. Pitch analysis should therefore downweight or reject microphone analysis frames immediately surrounding a metronome transient.

Initial strategy:

Metronome click generated
        ↓
~10–30 ms rejection/downweight window
        ↓
Resume normal pitch analysis

Combine this with YIN confidence/periodicity detection and temporal pitch smoothing.

Do not implement sophisticated acoustic echo cancellation for the initial POC unless testing demonstrates it is necessary.

A key acceptance test is playing sustained violin notes while the metronome is audible through the iPhone speaker.

⸻

3. Architecture

Keep the project deliberately small, but separate audio/DSP from presentation.

Suggested structure:

ViolinPractice/
│
├── App/
│   └── ViolinPracticeApp.swift
│
├── Audio/
│   ├── AudioEngine.swift
│   ├── PitchDetector.swift
│   ├── PitchSmoother.swift
│   └── MetronomeEngine.swift
│
├── Models/
│   ├── Pitch.swift
│   └── MetronomeState.swift
│
├── Views/
│   ├── PracticeView.swift
│   ├── TunerGauge.swift
│   ├── NoteDisplay.swift
│   ├── MetronomeControls.swift
│   └── PendulumView.swift
│
└── Utilities/
    └── MusicTheory.swift

Avoid putting DSP/audio logic directly inside SwiftUI views.

Prefer Apple’s observation/concurrency mechanisms and current Swift conventions. UI state updates must occur safely on the main actor.

The audio engine should expose state to the UI rather than the UI controlling low-level audio objects directly.

Dependencies

Prefer zero third-party dependencies for the POC.

Pitch detection is sufficiently contained that implementing YIN ourselves is preferable to introducing a large DSP library.

Use Swift Package Manager if an external dependency later becomes justified.

Testing

Unit-test the deterministic parts:

* Hz → musical note conversion.
* Frequency → cents calculation.
* BPM → beat duration.
* YIN against generated sine waves.
* Pitch smoothing.
* Click-rejection behaviour.

DSP components should be designed so recorded/generated audio can be passed into them without requiring a physical microphone.

⸻

4. Main UI

There is one main screen.

Use the approved dark mockup as the visual reference. We only want the left-hand phone UI, not the Settings screen.

The overall appearance is a modern, restrained, dark iOS interface with the tuner occupying approximately the upper half and the metronome the lower half.

Top Bar

Black/dark background.

At the top:

☰        Tuner | Metronome        ⚙

For the POC, the menu and settings controls may be non-functional or omitted if necessary.

The segmented control shown in the concept should not switch off either system. Tuner and metronome remain visible and functional simultaneously. It may therefore be removed if it implies mutually exclusive modes.

Below it:

A4 = 440 Hz                         Violin

Because instrument selection is unnecessary for the POC, remove the Violin selector.

Retain:

A4 = 440 Hz

as a small secondary control/label.

⸻

5. Tuner UI

The tuner occupies roughly the upper 45–50% of the usable screen.

Its dominant element is a large semicircular speedometer-style pitch gauge.

Conceptually:

 FLAT                 IN TUNE                 SHARP
 -50¢                    0                     +50¢
    \  | | | | | | | | | | | | | | | | |  /
                  ↑

Range:

-50 cents ───────── 0 ───────── +50 cents

The centre represents perfect tuning.

The needle:

* points left when flat;
* points vertically upward at 0 cents;
* points right when sharp;
* moves smoothly rather than jumping between measurements.

Colour treatment:

* neutral/dim markings across most of the gauge;
* green around the centre/in-tune region;
* warm/orange/red indication toward significantly flat/sharp extremes.

Do not rely solely on colour to communicate tuning direction.

Under the gauge, display the detected note prominently:

A

Below:

440.2 Hz
+2 cents

The note should be the visually dominant tuner value.

The cents value should clearly indicate:

-12 cents
0 cents
+7 cents

Define an initial “in tune” tolerance around approximately ±5 cents, primarily as a visual state rather than forcing the needle to zero.

Do not require users to select which violin string they are playing.

⸻

6. Metronome UI

The lower half contains the metronome.

At the top of this section:

          Adagio
   −        60        +
            BPM

BPM is large and prominent.

Minus and plus controls change tempo.

For the POC, tapping changes BPM by 1. Holding the control may repeatedly increment/decrement if straightforward to implement.

Below this is a large physical-metronome-inspired pendulum.

It should resemble the approved concept:

             |
             |
             ●
             |
          /     \
        /         \
      /             \

The arm swings visibly left/right on each beat.

The visual motion must derive from the metronome’s timing state; it must not be an unrelated looping SwiftUI animation.

Show subtle tick markings around the pendulum travel.

A small 4/4 control appears to the left.

A metronome sound/volume control may appear to the right.

At the bottom is a large primary button:

        ▶ Start

When running:

        ■ Stop

Starting the metronome should not start/stop tuner microphone analysis. The tuner should operate continuously once microphone permission is granted and the practice screen is active.

⸻

7. Interaction Behaviour

On first launch:

1. Request microphone permission with a concise explanation.
2. Start tuner analysis when permission is available.
3. Display an idle tuner state until a sufficiently confident pitch is detected.
4. Metronome remains stopped at 60 BPM.
5. User presses Start to begin the metronome.

When no reliable note exists, avoid showing random notes. Prefer something such as:

—
Listening…

When a note becomes stable, animate the gauge toward the detected cents offset.

If the signal disappears, briefly retain the previous measurement to prevent flashing, then return to the listening state.

⸻

8. POC Acceptance Criteria

The POC is successful if:

* A real violin played near the iPhone produces the correct note.
* Open G3, D4, A4 and E5 are reliably recognised.
* The gauge accurately shows flat/sharp deviation.
* Sustained notes produce a visually stable needle.
* The metronome maintains consistent timing.
* The visual pendulum corresponds to the audible beat.
* BPM can be changed while running.
* The tuner continues operating while the metronome is running.
* Metronome speaker clicks do not produce false note changes or materially destabilise an actual sustained violin pitch.
* Audio remains functional after normal interruptions such as backgrounding/foregrounding where practical for the POC.
* The UI closely matches the approved left-hand mockup.

The most important technical experiment is simultaneous speaker metronome + microphone pitch detection on real iPhone hardware. That should be proven early rather than polishing the UI first.

⸻

9. Explicitly Out of Scope

For the first POC, do not build:

* accounts/login;
* backend;
* cloud storage;
* subscriptions;
* practice history;
* recording;
* sheet music;
* AI analysis;
* instrument profiles;
* alternate temperaments;
* Apple Watch support;
* iPad-specific UI;
* complex settings;
* social features;
* advanced acoustic echo cancellation.

The POC should answer one question well:

Can we make an excellent single-screen iPhone practice tool where a musician can see intonation continuously while practising against an accurate audible and visual metronome?
