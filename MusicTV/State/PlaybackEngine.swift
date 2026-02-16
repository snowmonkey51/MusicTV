import AVFoundation
import CoreImage
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
    private var statusObservation: NSKeyValueObservation?
    private weak var appState: AppState?
    private let ciContext = CIContext()
    private(set) var playingOpeningBumper: Bool = false

    func attach(to appState: AppState) {
        self.appState = appState
        player.volume = volume
    }

    func playItem(_ item: VideoItem) {
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        statusObservation?.invalidate()
        statusObservation = nil

        currentTime = 0
        duration = 0

        let playerItem = AVPlayerItem(url: item.url)
        applyFilter(to: playerItem, filter: appState?.currentFilter ?? .none)
        applyAudioNormalization(to: playerItem, enabled: appState?.settings.normalizeAudio ?? false)
        player.replaceCurrentItem(with: playerItem)

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: playerItem,
            queue: .main
        ) { [weak self] _ in
            self?.advanceToNext()
        }

        // Watch for load failures (e.g. sandbox can't read the file) and skip ahead
        statusObservation = playerItem.observe(\.status, options: [.new]) { [weak self] item, _ in
            if item.status == .failed {
                DispatchQueue.main.async {
                    self?.advanceToNext()
                }
            }
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

    /// Starts playback, playing the opening bumper first if one is set.
    func startPlayback() {
        guard let appState else { return }
        if let bumperURL = appState.openingBumperURL {
            playingOpeningBumper = true
            let bumperItem = VideoItem(url: bumperURL, isBumper: true)
            playItem(bumperItem)
        } else {
            playingOpeningBumper = false
            if let item = appState.currentItem {
                playItem(item)
            }
        }
    }

    func advanceToNext() {
        guard let appState else { return }

        // If the opening bumper just finished, start the real playlist
        if playingOpeningBumper {
            playingOpeningBumper = false
            if let item = appState.currentItem {
                playItem(item)
            }
            return
        }

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
        // If skipping during opening bumper, go straight to playlist
        if playingOpeningBumper {
            playingOpeningBumper = false
            guard let appState, let item = appState.currentItem else { return }
            playItem(item)
            return
        }
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

    // MARK: - Video Filters

    /// Applies a VideoFilter to a given AVPlayerItem via AVVideoComposition.
    private func applyFilter(to playerItem: AVPlayerItem, filter: VideoFilter) {
        guard filter != .none else {
            playerItem.videoComposition = nil
            return
        }

        playerItem.videoComposition = buildComposition(for: playerItem, filter: filter)
    }

    /// Changes the filter on the currently playing item without restarting playback.
    func changeFilter(_ filter: VideoFilter) {
        guard let playerItem = player.currentItem else { return }

        let wasPlaying = appState?.isPlaying ?? false

        // Pause to avoid rendering pipeline conflicts during composition swap
        player.pause()

        if filter == .none {
            playerItem.videoComposition = nil
        } else {
            playerItem.videoComposition = buildComposition(for: playerItem, filter: filter)
        }

        // Seek to current position to flush the pipeline, then resume
        let current = player.currentTime()
        player.seek(to: current, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            if wasPlaying {
                self?.player.play()
            }
        }
    }

    /// Builds the appropriate AVVideoComposition for a filter.
    private func buildComposition(for playerItem: AVPlayerItem, filter: VideoFilter) -> AVVideoComposition? {
        if filter.usesCustomKernel {
            return buildCustomKernelComposition(for: playerItem, filter: filter)
        } else {
            return buildCIFilterChainComposition(for: playerItem, filter: filter)
        }
    }

    /// Standard CIFilter chain composition (static filters, no time dependence).
    private func buildCIFilterChainComposition(for playerItem: AVPlayerItem, filter: VideoFilter) -> AVVideoComposition? {
        let filterChain = filter.buildFilterChain()
        guard !filterChain.isEmpty else { return nil }

        return AVMutableVideoComposition(
            asset: playerItem.asset,
            applyingCIFiltersWithHandler: { request in
                var output = request.sourceImage.clampedToExtent()
                for ciFilter in filterChain {
                    ciFilter.setValue(output, forKey: kCIInputImageKey)
                    if let result = ciFilter.outputImage {
                        output = result
                    }
                }
                let time = CMTimeGetSeconds(request.compositionTime)
                output = Self.applyGrain(to: output, extent: request.sourceImage.extent, time: time)
                let cropped = output.cropped(to: request.sourceImage.extent)
                request.finish(with: cropped, context: nil)
            }
        )
    }

    /// Custom composition (time-animated effects).
    private func buildCustomKernelComposition(for playerItem: AVPlayerItem, filter: VideoFilter) -> AVVideoComposition? {
        switch filter {
        case .scanlines:
            return AVMutableVideoComposition(
                asset: playerItem.asset,
                applyingCIFiltersWithHandler: { request in
                    let seconds = CMTimeGetSeconds(request.compositionTime)
                    let source = request.sourceImage.clampedToExtent()
                    var filtered = ScanlinesKernel.apply(to: source, time: seconds)
                    filtered = Self.applyGrain(to: filtered, extent: request.sourceImage.extent, time: seconds)
                    let cropped = filtered.cropped(to: request.sourceImage.extent)
                    request.finish(with: cropped, context: nil)
                }
            )
        default:
            return nil
        }
    }

    // MARK: - Audio Normalization

    /// Applies audio normalization to a player item via AVAudioMix.
    private func applyAudioNormalization(to playerItem: AVPlayerItem, enabled: Bool) {
        guard enabled else {
            playerItem.audioMix = nil
            return
        }

        let asset = playerItem.asset
        guard let audioTrack = asset.tracks(withMediaType: .audio).first else { return }

        let params = AVMutableAudioMixInputParameters(track: audioTrack)
        params.audioTimePitchAlgorithm = .timeDomain
        params.setVolume(1.0, at: .zero)

        let audioMix = AVMutableAudioMix()
        audioMix.inputParameters = [params]
        playerItem.audioMix = audioMix
    }

    /// Toggles audio normalization on the currently playing item without restarting.
    func changeAudioNormalization(_ enabled: Bool) {
        guard let playerItem = player.currentItem else { return }
        applyAudioNormalization(to: playerItem, enabled: enabled)
    }

    // MARK: - Film Grain

    /// Adds animated film grain noise over the image using CIRandomGenerator.
    /// The noise pattern is shifted each frame based on `time` so the grain moves.
    private static func applyGrain(to image: CIImage, extent: CGRect, time: Double) -> CIImage {
        guard let noise = CIFilter(name: "CIRandomGenerator")?.outputImage else {
            return image
        }

        // Shift the noise pattern each frame so the grain animates
        let offsetX = CGFloat(time * 1000).truncatingRemainder(dividingBy: 500)
        let offsetY = CGFloat(time * 743).truncatingRemainder(dividingBy: 500)
        let shiftedNoise = noise.transformed(by: CGAffineTransform(translationX: offsetX, y: offsetY))

        // Desaturate the noise to greyscale and reduce intensity
        guard let greyNoise = CIFilter(name: "CIColorMatrix") else { return image }
        let grainIntensity: CGFloat = 0.08
        greyNoise.setValue(shiftedNoise, forKey: kCIInputImageKey)
        greyNoise.setValue(CIVector(x: 0, y: 0, z: 0, w: 0), forKey: "inputRVector")
        greyNoise.setValue(CIVector(x: 0, y: 0, z: 0, w: 0), forKey: "inputGVector")
        greyNoise.setValue(CIVector(x: 0, y: 0, z: 0, w: 0), forKey: "inputBVector")
        greyNoise.setValue(CIVector(x: 0, y: 0, z: 0, w: grainIntensity), forKey: "inputAVector")
        greyNoise.setValue(CIVector(x: grainIntensity, y: grainIntensity, z: grainIntensity, w: 0), forKey: "inputBiasVector")

        guard var grainImage = greyNoise.outputImage else { return image }
        grainImage = grainImage.cropped(to: extent)

        // Composite grain over the filtered image using screen blend
        guard let blend = CIFilter(name: "CIScreenBlendMode") else { return image }
        blend.setValue(grainImage, forKey: kCIInputImageKey)
        blend.setValue(image, forKey: kCIInputBackgroundImageKey)

        return blend.outputImage?.cropped(to: extent) ?? image
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
        statusObservation?.invalidate()
        statusObservation = nil
        appState?.isPlaying = false
    }
}
