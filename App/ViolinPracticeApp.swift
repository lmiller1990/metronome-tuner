import SwiftUI
import AVFoundation
import UIKit

@main
struct ViolinPracticeApp: App {
    /// Lazy so the @MainActor-isolated `AudioEngine` is constructed on the main
    /// actor (see `startAudioIfPermitted()`).
    @State private var engine: AudioEngine?
    @State private var microphoneDenied = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            Group {
                if let engine {
                    PracticeView(engine: engine)
                } else if microphoneDenied {
                    MicrophonePermissionView()
                } else {
                    ProgressView()
                        .preferredColorScheme(.dark)
                        .task { await startAudioIfPermitted() }
                }
            }
            .preferredColorScheme(.dark)
            .onChange(of: scenePhase) { _, phase in
                // Returning from Settings (or another app) is the only way a denied
                // permission can become granted, so re-check on every activation.
                guard phase == .active else { return }
                Task { await startAudioIfPermitted() }
            }
        }
    }

    /// Requests microphone access, then builds the engine on the main actor and
    /// starts it so the tuner runs continuously. On denial the UI switches to an
    /// actionable message instead of spinning forever.
    @MainActor
    private func startAudioIfPermitted() async {
        guard engine == nil else { return }
        let granted = await AVAudioApplication.requestRecordPermission()
        guard granted else {
            microphoneDenied = true
            return
        }
        let newEngine = AudioEngine()
        engine = newEngine
        microphoneDenied = false
        newEngine.start()
    }
}

/// Shown when microphone access is denied, with a direct link to Settings.
@MainActor
private struct MicrophonePermissionView: View {
    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "mic.slash.fill")
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.6))
            Text("Microphone Access Needed")
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
            Text("Violin Practice listens through the microphone to tune your instrument. "
                 + "Turn on microphone access in Settings to use the tuner and metronome together.")
                .font(.system(size: 15, weight: .medium, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.6))
                .multilineTextAlignment(.center)
            Button {
                guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                UIApplication.shared.open(url)
            } label: {
                Text("Open Settings")
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 14)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.green)
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.ignoresSafeArea())
    }
}
