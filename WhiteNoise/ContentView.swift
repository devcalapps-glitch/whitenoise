import SwiftUI

struct ContentView: View {
    let sounds: [Sound]
    @Environment(AudioPlayer.self) private var player
    @State private var showingAbout = false

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 14)]

    var body: some View {
        NavigationStack {
            ScrollView {
                if sounds.isEmpty {
                    ContentUnavailableView(
                        "No Sounds Available",
                        systemImage: "speaker.slash",
                        description: Text("Try closing and reopening the app.")
                    )
                    .padding(.top, 80)
                } else {
                    TimerPicker()
                        .padding(.horizontal)
                        .padding(.top, 4)
                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(sounds) { sound in
                            SoundTile(
                                sound: sound,
                                isActive: player.currentSound == sound,
                                isPlaying: player.currentSound == sound && player.isPlaying
                            ) {
                                player.toggle(sound)
                            }
                        }
                    }
                    .padding()
                }
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Sleep Sounds")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingAbout = true
                    } label: {
                        Image(systemName: "info.circle")
                            .foregroundStyle(Theme.dimText.opacity(0.7))
                    }
                    .accessibilityLabel("About Sleep Sounds")
                }
            }
            .sheet(isPresented: $showingAbout) {
                AboutView()
            }
            .task {
                player.restoreLastSound(from: sounds)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                NowPlayingBar()
                    .padding(.top, 8)
                    .background {
                        Theme.background
                            .ignoresSafeArea(edges: .bottom)
                            .overlay(alignment: .top) {
                                LinearGradient(colors: [Theme.background.opacity(0), Theme.background], startPoint: .top, endPoint: .bottom)
                                    .frame(height: 24)
                                    .offset(y: -24)
                            }
                    }
            }
        }
    }
}

private struct TimerPicker: View {
    @Environment(AudioPlayer.self) private var player

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Sleep timer", systemImage: "moon.zzz.fill")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Theme.dimText.opacity(0.7))
            HStack(spacing: 8) {
                chip("Off", hours: nil)
                ForEach(AudioPlayer.timerOptions, id: \.self) { hours in
                    chip("\(hours)h", hours: hours)
                }
            }
        }
    }

    private func chip(_ title: String, hours: Int?) -> some View {
        let isSelected = player.timerHours == hours
        return Button {
            player.setTimer(hours: hours)
        } label: {
            Text(title)
                .font(.subheadline.weight(.medium))
                .frame(maxWidth: .infinity, minHeight: 36)
                .foregroundStyle(isSelected ? Theme.background : Theme.dimText)
                .background(
                    Capsule().fill(isSelected ? Color.accentColor : Theme.tile)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(hours.map { "\($0) hours" } ?? "Timer off")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct SoundTile: View {
    let sound: Sound
    let isActive: Bool
    let isPlaying: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 12) {
                Image(systemName: sound.symbol)
                    .font(.system(size: 34))
                    .symbolEffect(.pulse, isActive: isPlaying)
                    .frame(height: 40)
                Text(sound.name)
                    .font(.subheadline.weight(.medium))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
            .foregroundStyle(isActive ? Color.accentColor : Theme.dimText)
            .frame(maxWidth: .infinity, minHeight: 130)
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(isActive ? Theme.tileActive : Theme.tile)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(isActive ? Color.accentColor.opacity(0.5) : .clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(sound.name)
        .accessibilityValue(isPlaying ? "Playing" : "Paused")
    }
}

private struct NowPlayingBar: View {
    @Environment(AudioPlayer.self) private var player

    var body: some View {
        @Bindable var player = player
        VStack(spacing: 14) {
            HStack {
                if let sound = player.currentSound {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(sound.name)
                            .font(.headline)
                            .foregroundStyle(Theme.dimText)
                            .lineLimit(1)
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text(Self.status(for: player, at: context.date))
                                .monospacedDigit()
                        }
                        .font(.caption)
                        .foregroundStyle(Theme.dimText.opacity(0.6))
                    }
                    Spacer()
                    Button {
                        player.togglePlayback()
                    } label: {
                        Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 44))
                            .foregroundStyle(Color.accentColor)
                    }
                    .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Select a sound")
                            .font(.headline)
                            .foregroundStyle(Theme.dimText.opacity(0.7))
                        Text("Tap any sound above to start")
                            .font(.caption)
                            .foregroundStyle(Theme.dimText.opacity(0.45))
                    }
                    Spacer()
                }
            }
            .frame(minHeight: 52)
            HStack(spacing: 10) {
                Image(systemName: "speaker.fill")
                Slider(value: $player.volume, in: 0...1)
                    .accessibilityLabel("Volume")
                Image(systemName: "speaker.wave.3.fill")
            }
            .font(.footnote)
            .foregroundStyle(Theme.dimText.opacity(0.7))
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .padding(.horizontal)
        .padding(.bottom, 4)
    }

    private static func status(for player: AudioPlayer, at date: Date) -> String {
        let seconds = Int(player.elapsed(at: date))
        if !player.isPlaying, seconds == 0 { return "Ready to play" }
        let elapsed = Duration.seconds(seconds)
            .formatted(.time(pattern: .hourMinuteSecond))
        var text = player.isPlaying ? "Playing for \(elapsed)" : "Paused at \(elapsed)"
        if let end = player.timerEndDate {
            text += " · Stops in \(remaining(until: end, from: date))"
        }
        return text
    }

    private static func remaining(until end: Date, from now: Date) -> String {
        let minutes = max(0, Int(ceil(end.timeIntervalSince(now) / 60)))
        return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }
}

enum Theme {
    static let background = Color(red: 0.04, green: 0.05, blue: 0.09)
    static let tile = Color.white.opacity(0.05)
    static let tileActive = Color.white.opacity(0.10)
    static let dimText = Color(white: 0.78)
}

#Preview {
    ContentView(sounds: [])
        .environment(AudioPlayer())
        .preferredColorScheme(.dark)
}
