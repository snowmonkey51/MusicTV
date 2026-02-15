import AVFoundation
import Observation

@Observable
final class PlaybackEngine {
    let player: AVPlayer = AVPlayer()

    var currentTime: Double = 0
    var duration: Double = 0
    var volume: Float = 1.0 {
        didSet { player.volume = volume }
    }

    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private weak var appState: AppState?

    func attach(to appState: AppState) {
        self.appState = appState
        player.volume = volume
    }

    func playItem(_ item: VideoItem) {
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }

        currentTime = 0
        duration = 0

        let playerItem = AVPlayerItem(url: item.url)
        player.replaceCurrentItem(with: playerItem)

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: playerItem,
            queue: .main
        ) { [weak self] _ in
            self?.advanceToNext()
        }

        if let timeObserver {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            guard let self else { return }
            self.currentTime = time.seconds
            let dur = playerItem.duration.seconds
            self.duration = dur.isFinite ? dur : 0
        }

        player.play()
        appState?.isPlaying = true
    }

    func advanceToNext() {
        guard let appState else { return }
        let nextIndex = appState.currentIndex + 1
        if nextIndex < appState.playlist.count {
            appState.currentIndex = nextIndex
            if let item = appState.currentItem {
                playItem(item)
            }
        } else if appState.settings.repeatPlaylist && !appState.playlist.isEmpty {
            appState.currentIndex = 0
            if let item = appState.currentItem {
                playItem(item)
            }
        } else {
            player.pause()
            appState.isPlaying = false
        }
    }

    func togglePlayPause() {
        guard let appState, appState.hasStarted else { return }
        if appState.isPlaying {
            player.pause()
        } else {
            player.play()
        }
        appState.isPlaying.toggle()
    }

    func skip() {
        advanceToNext()
    }

    func skipBack() {
        guard let appState else { return }
        let prevIndex = appState.currentIndex - 1
        if prevIndex >= 0 {
            appState.currentIndex = prevIndex
            if let item = appState.currentItem {
                playItem(item)
            }
        }
    }

    func seek(to fraction: Double) {
        guard duration > 0 else { return }
        let target = CMTime(seconds: fraction * duration, preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func teardown() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        appState?.isPlaying = false
    }
}
