import SwiftUI

@main
struct WhiteNoiseApp: App {
    @State private var player = AudioPlayer()
    @State private var showSplash = true

    init() {
        AudioPlayer.configureSession()
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                ContentView(sounds: SoundLibrary.load())
                    .environment(player)

                if showSplash {
                    SplashScreenView {
                        dismissSplash()
                    }
                    .transition(.opacity)
                    .zIndex(1)
                }
            }
            .preferredColorScheme(.dark)
            .tint(Color("AccentColor"))
            .task {
                try? await Task.sleep(for: .seconds(1.2))
                dismissSplash()
            }
        }
    }

    private func dismissSplash() {
        guard showSplash else { return }
        withAnimation(.easeInOut(duration: 0.45)) {
            showSplash = false
        }
    }
}
