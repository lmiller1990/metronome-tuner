import SwiftUI
import AVFoundation

@main
struct ViolinPracticeApp: App {
    /// Single shared audio engine owned by the app, passed to `PracticeView`.
    @State private var engine = AudioEngine()

    var body: some Scene {
        WindowGroup {
            PracticeView(engine: engine)
                .preferredColorScheme(.dark)
                .task {
                    await startAudioIfPermitted()
                }
        }
    }

    /// Requests microphone access on first appear, then starts the audio engine on success.
    private func startAudioIfPermitted() async {
        let granted = await AVAudioApplication.requestRecordPermission()
        guard granted else { return }
        engine.start()
    }
}
