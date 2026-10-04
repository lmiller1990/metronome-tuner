import SwiftUI
import AVFoundation

@main
struct ViolinPracticeApp: App {
    /// Lazy so the @MainActor-isolated `AudioEngine` is constructed on the main
    /// actor. Instantiation as a stored `@State` default can run during
    /// non-main-actor scene setup and crash (dispatch assert).
    @State private var engine: AudioEngine?

    var body: some Scene {
        WindowGroup {
            if let engine {
                PracticeView(engine: engine)
                    .preferredColorScheme(.dark)
            } else {
                ProgressView()
                    .preferredColorScheme(.dark)
                    .task {
                        await startAudioIfPermitted()
                    }
            }
        }
    }

    /// Requests microphone access on first appear, builds the engine on the main
    /// actor, then starts it so the tuner runs continuously.
    private func startAudioIfPermitted() async {
        let granted = await AVAudioApplication.requestRecordPermission()
        guard granted else { return }
        let newEngine = await MainActor.run { AudioEngine() }
        engine = newEngine
        newEngine.start()
    }
}
