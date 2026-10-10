import SwiftUI

@main
struct WhiteNoiseApp: App {
    @State private var player = AudioPlayer()

    init() {
        AudioPlayer.configureSession()
    }

    var body: some Scene {
        WindowGroup {
            ContentView(sounds: SoundLibrary.load())
                .environment(player)
                .preferredColorScheme(.dark)
        }
    }
}
