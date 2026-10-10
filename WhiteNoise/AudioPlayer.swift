import AVFoundation
import Observation

@MainActor
@Observable
final class AudioPlayer {
    private(set) var currentSound: Sound?
    private(set) var isPlaying = false

    var volume: Float = 0.8 {
        didSet { player.volume = volume }
    }

    static let timerOptions = [2, 4, 6, 8, 10]
    static let fadeOutDuration: TimeInterval = 30

    /// Selected sleep timer in hours; `nil` plays until paused.
    private(set) var timerHours: Int?
    /// When the running timer will stop playback; `nil` while nothing is counting down.
    private(set) var timerEndDate: Date?

    /// Listening time for the current sound from earlier stretches, excluding the one in progress.
    private(set) var playedBefore: TimeInterval = 0
    /// Start of the stretch currently playing; `nil` while paused.
    private(set) var playingSince: Date?

    func elapsed(at date: Date) -> TimeInterval {
        playedBefore + (playingSince.map { date.timeIntervalSince($0) } ?? 0)
    }

    @ObservationIgnored private let player = AVQueuePlayer()
    @ObservationIgnored private var looper: AVPlayerLooper?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var timerTask: Task<Void, Never>?

    init() {
        player.volume = volume
        player.automaticallyWaitsToMinimizeStalling = false
        observeSession()
    }

    static func configureSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
        } catch {
            print("Audio session setup failed: \(error)")
        }
    }

    func toggle(_ sound: Sound) {
        if currentSound == sound {
            isPlaying ? pause() : resume()
        } else {
            play(sound)
        }
    }

    func togglePlayback() {
        guard currentSound != nil else { return }
        isPlaying ? pause() : resume()
    }

    func play(_ sound: Sound) {
        looper?.disableLooping()
        player.removeAllItems()
        let item = AVPlayerItem(url: sound.url)
        looper = AVPlayerLooper(player: player, templateItem: item)
        currentSound = sound
        playedBefore = 0
        playingSince = nil
        resume()
    }

    func resume() {
        try? AVAudioSession.sharedInstance().setActive(true)
        player.volume = volume
        player.play()
        isPlaying = true
        if playingSince == nil { playingSince = Date() }
        if timerTask == nil { startTimer() }
    }

    func pause() {
        player.pause()
        isPlaying = false
        stopClock()
        cancelTimer()
    }

    private func stopClock() {
        playedBefore = elapsed(at: Date())
        playingSince = nil
    }

    func setTimer(hours: Int?) {
        timerHours = hours
        cancelTimer()
        if isPlaying { startTimer() }
    }

    private func startTimer() {
        guard let hours = timerHours else { return }
        let end = Date().addingTimeInterval(TimeInterval(hours) * 3600)
        timerEndDate = end
        timerTask = Task { [weak self] in
            let fadeStart = end.addingTimeInterval(-Self.fadeOutDuration)
            do {
                try await Task.sleep(for: .seconds(max(0, fadeStart.timeIntervalSinceNow)))
            } catch {
                return
            }
            await self?.fadeOutAndStop()
        }
    }

    private func cancelTimer() {
        timerTask?.cancel()
        timerTask = nil
        timerEndDate = nil
    }

    private func fadeOutAndStop() async {
        let steps = 60
        for step in 1...steps {
            player.volume = volume * Float(steps - step) / Float(steps)
            do {
                try await Task.sleep(for: .seconds(Self.fadeOutDuration / Double(steps)))
            } catch {
                player.volume = volume
                return
            }
        }
        pause()
        player.volume = volume
    }

    private func observeSession() {
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()

        observers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: session, queue: .main
        ) { [weak self] note in
            let info = note.userInfo
            let type = (info?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init)
            let options = (info?[AVAudioSessionInterruptionOptionKey] as? UInt).map(AVAudioSession.InterruptionOptions.init)
            MainActor.assumeIsolated {
                self?.handleInterruption(type: type, options: options)
            }
        })

        observers.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: session, queue: .main
        ) { [weak self] note in
            let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt)
                .flatMap(AVAudioSession.RouteChangeReason.init)
            MainActor.assumeIsolated {
                if reason == .oldDeviceUnavailable { self?.pause() }
            }
        })
    }

    private var wasPlayingBeforeInterruption = false

    private func handleInterruption(type: AVAudioSession.InterruptionType?, options: AVAudioSession.InterruptionOptions?) {
        switch type {
        case .began:
            wasPlayingBeforeInterruption = isPlaying
            isPlaying = false
            stopClock()
        case .ended:
            if wasPlayingBeforeInterruption, options?.contains(.shouldResume) == true {
                resume()
            }
            wasPlayingBeforeInterruption = false
        default:
            break
        }
    }
}
