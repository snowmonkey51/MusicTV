import AVFoundation
#if os(tvOS) || os(iOS)
import AVKit
#endif
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
    private var rateObservation: NSKeyValueObservation?
    private weak var appState: AppState?
    private let ciContext = CIContext()
    private(set) var playingOpeningBumper: Bool = false

    /// Cached per-file normalization gain values so each file is analyzed once.
    private var loudnessCache: [URL: Float] = [:]

    func attach(to appState: AppState) {
        self.appState = appState
        player.volume = volume
        // Local files don't need stall-prevention buffering — disabling this
        // prevents AVPlayer from pausing playback due to false buffer warnings.
        player.automaticallyWaitsToMinimizeStalling = false
        setupTimeObserver()

        #if os(tvOS)
        // On tvOS, AVPlayerViewController owns play/pause via the Siri Remote.
        // Observe the player's rate so appState.isPlaying stays in sync.
        rateObservation = player.observe(\.rate, options: [.new]) { [weak self] player, _ in
            DispatchQueue.main.async {
                self?.appState?.isPlaying = player.rate > 0
            }
        }
        #endif
    }

    /// Set up the periodic time observer once — it reads from player.currentItem
    /// so it automatically tracks whichever item is loaded.
    private func setupTimeObserver() {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            guard let self else { return }
            self.currentTime = time.seconds
            if let currentItem = self.player.currentItem {
                let dur = currentItem.duration.seconds
                self.duration = dur.isFinite ? dur : 0
            }
        }
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

        // Stamp metadata BEFORE replaceCurrentItem so AVKit never sees the
        // item without the correct title — eliminates the old-title flash.
        // macOS uses its own custom title display and doesn't use externalMetadata.
        #if os(tvOS) || os(iOS)
        playerItem.externalMetadata = buildExternalMetadata(for: item.isBumper ? nil : item)
        #endif

        // Enable stall-prevention buffering for network streams
        let isNetwork = item.url.scheme == "http" || item.url.scheme == "https"
        player.automaticallyWaitsToMinimizeStalling = isNetwork
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
                print("[PlaybackEngine] Item failed to load: \(item.error?.localizedDescription ?? "unknown error")")
                if let urlAsset = item.asset as? AVURLAsset {
                    print("[PlaybackEngine] Failed URL: \(urlAsset.url)")
                }
                DispatchQueue.main.async {
                    self?.advanceToNext()
                }
            }
        }

        player.play()
        appState?.isPlaying = true
        // Track what is actually loaded into AVPlayer so currentItem and the
        // transport bar title stay correct even if the playlist is rebuilt
        // mid-song (e.g. genre switch, shuffle change).
        appState?.nowPlayingURL = item.url
        appState?.nowPlayingItem = item.isBumper ? nil : item

        // Record in AppState's play history for history-aware shuffle rebuilds.
        if !item.isBumper {
            appState?.recordPlayed(item.url)
        }
    }

    func startPlayback() {
        guard let appState else { return }
        #if os(macOS)
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
        #else
        playingOpeningBumper = false
        if let item = appState.currentItem {
            playItem(item)
        }
        #endif
    }

    func advanceToNext() {
        guard let appState else { return }

        // If the opening bumper just finished, start the real playlist
        if playingOpeningBumper {
            playingOpeningBumper = false
            appState.nowPlayingURL = nil
            if let item = appState.currentItem {
                playItem(item)
            }
            return
        }

        // Resolve the true current index from nowPlayingURL so that genre/settings
        // rebuilds that moved currentIndex to 0 don't cause a skip to restart the
        // same song. Clear nowPlayingURL first so currentItem uses currentIndex.
        //
        // Check currentIndex first rather than blindly calling firstIndex. With
        // only 7 bumpers cycling through thousands of songs, the same bumper URL
        // appears at positions 5, 47, 89, … — firstIndex always returns 5, causing
        // the playhead to jump back ~42 positions and replay the same songs.
        if let url = appState.nowPlayingURL {
            let playlist = appState.playlist
            let alreadyCorrect = playlist.indices.contains(appState.currentIndex)
                && playlist[appState.currentIndex].url == url
            if !alreadyCorrect,
               let trueIndex = playlist.firstIndex(where: { $0.url == url }) {
                appState.currentIndex = trueIndex
            }
        }
        appState.nowPlayingURL = nil

        let nextIndex = appState.currentIndex + 1
        if nextIndex < appState.playlist.count {
            appState.currentIndex = nextIndex
            if let item = appState.currentItem {
                playItem(item)
            }
        } else if appState.settings.repeatPlaylist && !appState.playlist.isEmpty {
            // Re-shuffle on wrap. buildPlaylist() clears the play history (default
            // preserveHistory: false) and creates a fresh shuffle of all songs.
            if appState.settings.shuffleMusic {
                appState.buildPlaylist()
            }
            appState.currentIndex = 0
            // Play the first item directly — avoid currentItem's nowPlayingURL
            // indirection since we just cleared nowPlayingURL above.
            if let first = appState.playlist.first {
                playItem(first)
            }
        } else {
            player.pause()
            appState.isPlaying = false
            appState.nowPlayingURL = nil
            appState.nowPlayingItem = nil
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
        // Resolve true current index from nowPlayingURL before stepping back.
        // Same duplicate-bumper-URL guard as advanceToNext(): check currentIndex
        // first to avoid firstIndex jumping back to the earliest occurrence.
        if let url = appState.nowPlayingURL {
            let playlist = appState.playlist
            let alreadyCorrect = playlist.indices.contains(appState.currentIndex)
                && playlist[appState.currentIndex].url == url
            if !alreadyCorrect,
               let trueIndex = playlist.firstIndex(where: { $0.url == url }) {
                appState.currentIndex = trueIndex
            }
        }
        appState.nowPlayingURL = nil

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
    /// Loads video tracks asynchronously first — some assets (especially network
    /// streams) haven't resolved their tracks at item-creation time, and building
    /// a composition before tracks are available produces a zero-size composition
    /// that silently drops all video while audio continues.
    private func applyFilter(to playerItem: AVPlayerItem, filter: VideoFilter) {
        guard filter != .none else {
            playerItem.videoComposition = nil
            return
        }

        let asset = playerItem.asset
        Task {
            do {
                let tracks = try await asset.loadTracks(withMediaType: .video)
                guard !tracks.isEmpty else {
                    // No video track — nothing to compose, leave videoComposition nil.
                    print("[PlaybackEngine] No video tracks found, skipping composition.")
                    return
                }
                // Build the composition outside MainActor.run since buildComposition is now async
                let composition = await self.buildComposition(for: playerItem, filter: filter)
                await MainActor.run {
                    // Only apply if this item is still the current one
                    guard self.player.currentItem === playerItem else { return }
                    playerItem.videoComposition = composition
                }
            } catch {
                print("[PlaybackEngine] Failed to load video tracks: \(error)")
            }
        }
    }

    /// Changes the filter on the currently playing item by replacing it entirely
    /// to avoid AVFoundation rendering pipeline freezes from hot-swapping compositions.
    func changeFilter(_ filter: VideoFilter) {
        guard let oldItem = player.currentItem,
              let asset = oldItem.asset as? AVURLAsset else { return }

        let wasPlaying = appState?.isPlaying ?? false
        let position = player.currentTime()

        // Tear down old observers
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        statusObservation?.invalidate()
        statusObservation = nil

        // Build a fresh player item at the same URL
        let newItem = AVPlayerItem(url: asset.url)
        applyFilter(to: newItem, filter: filter)
        applyAudioNormalization(to: newItem, enabled: appState?.settings.normalizeAudio ?? false)
        player.replaceCurrentItem(with: newItem)

        // Re-attach end-of-track and failure observers
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: newItem,
            queue: .main
        ) { [weak self] _ in
            self?.advanceToNext()
        }

        statusObservation = newItem.observe(\.status, options: [.new]) { [weak self] item, _ in
            if item.status == .failed {
                DispatchQueue.main.async {
                    self?.advanceToNext()
                }
            }
        }

        // Seek back to where we were and resume
        player.seek(to: position, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            if wasPlaying {
                self?.player.play()
            }
        }
    }

    /// Builds the appropriate AVVideoComposition for a filter.
    private func buildComposition(for playerItem: AVPlayerItem, filter: VideoFilter) async -> AVVideoComposition? {
        if filter.usesCustomKernel {
            return await buildCustomKernelComposition(for: playerItem, filter: filter)
        } else {
            return await buildCIFilterChainComposition(for: playerItem, filter: filter)
        }
    }

    /// Standard CIFilter chain composition (static filters, no time dependence).
    private func buildCIFilterChainComposition(for playerItem: AVPlayerItem, filter: VideoFilter) async -> AVVideoComposition? {
        let filterSpec = filter  // capture the filter enum, not CIFilter instances
        let context = ciContext

        if #available(tvOS 26, iOS 26, macOS 26, *) {
            return try? await AVVideoComposition(applyingFiltersTo: playerItem.asset) { params in
                // Build fresh CIFilter instances per frame to avoid thread-safety issues
                let filterChain = filterSpec.buildFilterChain()
                guard !filterChain.isEmpty else {
                    return AVCIImageFilteringResult(resultImage: params.sourceImage, ciContext: context)
                }

                var output = params.sourceImage.clampedToExtent()
                for ciFilter in filterChain {
                    ciFilter.setValue(output, forKey: kCIInputImageKey)
                    if let result = ciFilter.outputImage {
                        output = result
                    }
                }
                let time = CMTimeGetSeconds(params.compositionTime)
                output = Self.applyGrain(to: output, extent: params.sourceImage.extent, time: time)
                let cropped = output.cropped(to: params.sourceImage.extent)
                return AVCIImageFilteringResult(resultImage: cropped, ciContext: context)
            }
        } else {
            return await withCheckedContinuation { continuation in
                AVMutableVideoComposition.videoComposition(
                    with: playerItem.asset,
                    applyingCIFiltersWithHandler: { request in
                        // Build fresh CIFilter instances per frame to avoid thread-safety issues
                        let filterChain = filterSpec.buildFilterChain()
                        guard !filterChain.isEmpty else {
                            request.finish(with: request.sourceImage, context: context)
                            return
                        }

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
                        request.finish(with: cropped, context: context)
                    },
                    completionHandler: { composition, _ in
                        continuation.resume(returning: composition)
                    }
                )
            }
        }
    }

    /// Custom composition (time-animated effects).
    private func buildCustomKernelComposition(for playerItem: AVPlayerItem, filter: VideoFilter) async -> AVVideoComposition? {
        let context = ciContext

        switch filter {
        case .crt:
            if #available(tvOS 26, iOS 26, macOS 26, *) {
                return try? await AVVideoComposition(applyingFiltersTo: playerItem.asset) { params in
                    let seconds = CMTimeGetSeconds(params.compositionTime)
                    let source = params.sourceImage.clampedToExtent()
                    var filtered = CRTKernel.apply(to: source, time: seconds)
                    filtered = Self.applyGrain(to: filtered, extent: params.sourceImage.extent, time: seconds)
                    let cropped = filtered.cropped(to: params.sourceImage.extent)
                    return AVCIImageFilteringResult(resultImage: cropped, ciContext: context)
                }
            } else {
                return await withCheckedContinuation { continuation in
                    AVMutableVideoComposition.videoComposition(
                        with: playerItem.asset,
                        applyingCIFiltersWithHandler: { request in
                            let seconds = CMTimeGetSeconds(request.compositionTime)
                            let source = request.sourceImage.clampedToExtent()
                            var filtered = CRTKernel.apply(to: source, time: seconds)
                            filtered = Self.applyGrain(to: filtered, extent: request.sourceImage.extent, time: seconds)
                            let cropped = filtered.cropped(to: request.sourceImage.extent)
                            request.finish(with: cropped, context: context)
                        },
                        completionHandler: { composition, _ in
                            continuation.resume(returning: composition)
                        }
                    )
                }
            }
        default:
            return nil
        }
    }

    // MARK: - Audio Normalization

    /// Target RMS level. ~-20 dBFS gives comfortable loudness without clipping.
    private let normTargetRMS: Float = 0.1

    /// Applies audio normalization to a player item via AVAudioMix.
    ///
    /// If a cached gain is available for this file it is applied immediately.
    /// Otherwise volume stays at 1.0 and a background analysis task computes
    /// the gain and updates the mix once done.
    private func applyAudioNormalization(to playerItem: AVPlayerItem, enabled: Bool) {
        guard enabled else {
            playerItem.audioMix = nil
            return
        }

        let asset = playerItem.asset
        let fileURL = (asset as? AVURLAsset)?.url
        let cachedGain = fileURL.flatMap { loudnessCache[$0] }

        Task { [weak self] in
            guard let self else { return }
            // loadTracks(withMediaType:) replaces the deprecated synchronous tracks(withMediaType:)
            guard let tracks = try? await asset.loadTracks(withMediaType: .audio),
                  let audioTrack = tracks.first else { return }

            await MainActor.run {
                // Apply the cached gain immediately (or 1.0 while analysis is pending).
                self.setNormalizationGain(cachedGain ?? 1.0, on: playerItem, track: audioTrack)
            }

            guard cachedGain == nil, let fileURL else { return }

            let gain = await self.analyzeRMSGain(asset: asset, url: fileURL)
            await MainActor.run {
                self.loudnessCache[fileURL] = gain
                // Update the mix only if this item is still loaded in the player.
                guard self.player.currentItem === playerItem else { return }
                self.setNormalizationGain(gain, on: playerItem, track: audioTrack)
            }
        }
    }

    private func setNormalizationGain(_ gain: Float, on playerItem: AVPlayerItem, track: AVAssetTrack) {
        let params = AVMutableAudioMixInputParameters(track: track)
        params.setVolume(gain, at: .zero)
        let mix = AVMutableAudioMix()
        mix.inputParameters = [params]
        playerItem.audioMix = mix
    }

    /// Reads up to 90 seconds of audio samples from the asset and returns a
    /// gain factor that would bring the RMS to `normTargetRMS`.
    /// Returns 1.0 on any error so playback is unaffected.
    private func analyzeRMSGain(asset: AVAsset, url: URL) async -> Float {
        guard let tracks = try? await asset.loadTracks(withMediaType: .audio),
              let audioTrack = tracks.first else { return 1.0 }

        let outputSettings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsNonInterleaved: false,
            AVNumberOfChannelsKey: 1,
            AVSampleRateKey: 44100.0
        ]

        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            return 1.0
        }

        // Skip the first 10 seconds (often a quiet intro) then analyze up to
        // 3 minutes for a more representative loudness sample.
        reader.timeRange = CMTimeRange(
            start: CMTime(seconds: 10, preferredTimescale: 44100),
            duration: CMTime(seconds: 170, preferredTimescale: 44100)
        )

        let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: outputSettings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return 1.0 }
        reader.add(output)
        guard reader.startReading() else { return 1.0 }

        var sumSquares: Double = 0
        var sampleCount: Int = 0

        while reader.status == .reading {
            autoreleasepool {
                guard let sampleBuffer = output.copyNextSampleBuffer() else { return }
                guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }

                var totalLength = 0
                var dataPointer: UnsafeMutablePointer<Int8>?
                guard CMBlockBufferGetDataPointer(
                    blockBuffer, atOffset: 0,
                    lengthAtOffsetOut: nil,
                    totalLengthOut: &totalLength,
                    dataPointerOut: &dataPointer
                ) == noErr, let ptr = dataPointer else { return }

                let floatCount = totalLength / MemoryLayout<Float>.size
                ptr.withMemoryRebound(to: Float.self, capacity: floatCount) { samples in
                    for i in 0 ..< floatCount {
                        let s = samples[i]
                        sumSquares += Double(s) * Double(s)
                    }
                }
                sampleCount += floatCount
            }
        }
        reader.cancelReading()

        guard sampleCount > 0 else { return 1.0 }
        let rms = Float(sqrt(sumSquares / Double(sampleCount)))
        guard rms > 0.0001 else { return 1.0 }  // avoid huge gain on near-silent files

        // Cap the upward gain at +18 dB to catch very quiet recordings while
        // still preventing runaway amplification of near-silent content.
        return min(normTargetRMS / rms, 8.0)
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
        rateObservation?.invalidate()
        rateObservation = nil
        appState?.isPlaying = false
        appState?.nowPlayingURL = nil
        appState?.nowPlayingItem = nil
    }
}

// MARK: - Metadata helper

#if os(tvOS) || os(iOS)
/// Builds the `externalMetadata` array for an AVPlayerItem.
///
/// Setting this BEFORE `replaceCurrentItem(with:)` ensures AVKit never sees the
/// item without correct title metadata, eliminating the brief flash of the
/// previous song's title when a new track starts.
///
/// Not used on macOS — the Mac app renders title information through its own UI.
func buildExternalMetadata(for item: VideoItem?) -> [AVMetadataItem] {
    // Always clear the embedded creation date so AVKit doesn't render a year.
    let dateMeta = AVMutableMetadataItem()
    dateMeta.identifier = .commonIdentifierCreationDate
    dateMeta.value = "" as NSString
    dateMeta.extendedLanguageTag = "und"

    guard let item, !item.isBumper else {
        return [dateMeta]
    }

    let parsed = TitleCleaner.parse(item.fileName)
    let yearPattern = #"\s*[\(\[]\d{4}[\)\]]\s*"#
    let cleanTitle = parsed.title
        .replacingOccurrences(of: yearPattern, with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespaces)
    let cleanArtist = parsed.artist?
        .replacingOccurrences(of: yearPattern, with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespaces)
    let displayTitle = cleanArtist.map { "\($0) - \(cleanTitle)" } ?? cleanTitle

    let titleMeta = AVMutableMetadataItem()
    titleMeta.identifier = .commonIdentifierTitle
    titleMeta.value = displayTitle as NSString
    titleMeta.extendedLanguageTag = "und"

    return [titleMeta, dateMeta]
}
#endif
