import AVKit
import SwiftUI

/// UIHostingController subclass that prevents tvOS focus state from becoming
/// stale across overlay dismiss/present cycles. Without this, SwiftUI's TabView
/// retains internal focus references after the overlay is hidden, and the focus
/// engine deadlocks when AVKit tries to re-present the overlay.
class FocusResettingHostingController<Content: View>: UIHostingController<Content> {

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        // Direct focus to this controller's view so SwiftUI re-evaluates
        // from scratch rather than trying to restore stale references.
        return [self.view]
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        restoresFocusAfterTransition = false
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Force the focus engine to re-evaluate after the overlay appears.
        // Async dispatch ensures the view hierarchy is fully laid out.
        DispatchQueue.main.async { [weak self] in
            self?.setNeedsFocusUpdate()
            self?.updateFocusIfNeeded()
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        restoresFocusAfterTransition = false
    }
}

/// The root player view for the tvOS app. Wraps AVPlayerViewController and
/// uses Apple's built-in customization points for all UI:
///
///   - `customOverlayViewController` → tabbed overlay (swipe up)
///   - `transportBarCustomMenuItems` → Skip/Previous/Favorite buttons
///   - `customInfoViewControllers` → track info (swipe down)
///
/// All Siri Remote gestures are handled natively by AVPlayerViewController.
/// No custom gesture handlers, no SwiftUI overlays stealing focus.
struct TVVideoPlayerView: UIViewControllerRepresentable {
    let player: AVPlayer
    let appState: AppState
    let engine: PlaybackEngine

    func makeCoordinator() -> Coordinator {
        Coordinator(appState: appState, engine: engine)
    }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let vc = AVPlayerViewController()
        vc.allowsPictureInPicturePlayback = false
        // Prevent HDMI resolution switching when video resolution changes
        vc.appliesPreferredDisplayCriteriaAutomatically = false
        vc.player = player
        vc.showsPlaybackControls = true

        context.coordinator.playerVC = vc

        // --- Custom Overlay (swipe up) ---
        let overlayView = TVOverlayView(appState: appState, engine: engine)
        let overlayHosting = FocusResettingHostingController(rootView: overlayView)
        overlayHosting.view.backgroundColor = .clear
        overlayHosting.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        // Request generous height from AVKit's overlay container
        overlayHosting.preferredContentSize = CGSize(width: 1920, height: 700)
        vc.customOverlayViewController = overlayHosting
        context.coordinator.overlayHosting = overlayHosting

        // --- Transport Bar Custom Items ---
        installTransportBarItems(on: vc, context: context)

        // --- Track Info (swipe down) ---
        installTrackInfo(on: vc, context: context)

        // --- Start observing track changes to update metadata ---
        context.coordinator.startObservingTitle()

        return vc
    }

    func updateUIViewController(_ vc: AVPlayerViewController, context: Context) {
        if vc.player !== player {
            vc.player = player
        }

        // IMPORTANT: Do NOT modify AVPlayerViewController properties here.
        //
        // This method fires on EVERY @Observable state change (playback position,
        // timer ticks, settings toggles, etc.). Reassigning transportBarCustomMenuItems,
        // customOverlayViewController rootView, or any other AVKit property during
        // user interaction destabilizes the focus/responder chain and causes the
        // Siri Remote to become unresponsive.
        //
        // All SwiftUI views inside hosting controllers observe AppState and
        // PlaybackEngine directly via @Observable. Transport bar actions read
        // current state at tap time through the coordinator. Track title metadata
        // is updated via withObservationTracking in the coordinator.
    }

    // MARK: - Transport Bar Custom Menu Items

    private func installTransportBarItems(on vc: AVPlayerViewController, context: Context) {
        let coordinator = context.coordinator

        let previousAction = UIAction(
            title: "Previous",
            image: UIImage(systemName: "backward.fill")
        ) { _ in
            coordinator.engine.skipBack()
        }

        let skipAction = UIAction(
            title: "Skip",
            image: UIImage(systemName: "forward.fill")
        ) { _ in
            coordinator.engine.skip()
        }

        let favoriteAction = UIAction(
            title: "Favorite",
            image: UIImage(systemName: "star")
        ) { _ in
            if let item = coordinator.appState.currentItem {
                coordinator.appState.toggleFavorite(item)
            }
        }

        vc.transportBarCustomMenuItems = [previousAction, skipAction, favoriteAction]
    }

    // MARK: - Track Info (customInfoViewControllers)

    private func installTrackInfo(on vc: AVPlayerViewController, context: Context) {
        let infoView = TVTrackInfoView(appState: appState, engine: engine)
        let infoHosting = UIHostingController(rootView: infoView)
        infoHosting.title = "Track Info"
        infoHosting.preferredContentSize = CGSize(width: 0, height: 300)
        infoHosting.view.backgroundColor = .clear

        vc.customInfoViewControllers = [infoHosting]
    }

    // MARK: - Coordinator

    class Coordinator {
        var playerVC: AVPlayerViewController?
        var overlayHosting: FocusResettingHostingController<TVOverlayView>?
        let appState: AppState
        let engine: PlaybackEngine

        init(appState: AppState, engine: PlaybackEngine) {
            self.appState = appState
            self.engine = engine
        }

        /// Observes appState.currentItem and sets externalMetadata on the
        /// current AVPlayerItem so AVKit shows the title natively in the
        /// transport bar (appears/disappears with the progress bar).
        func startObservingTitle() {
            updateMetadata()
        }

        private func updateMetadata() {
            withObservationTracking {
                let item = self.appState.currentItem
                let bumper = self.engine.playingOpeningBumper

                guard let playerItem = self.playerVC?.player?.currentItem else { return }

                if let item, !item.isBumper, !bumper {
                    let parsed = TitleCleaner.parse(item.fileName)

                    // Strip any remaining year in parens/brackets from both parts
                    let yearPattern = #"\s*[\(\[]\d{4}[\)\]]\s*"#
                    let cleanedTitle = parsed.title.replacingOccurrences(
                        of: yearPattern, with: " ", options: .regularExpression
                    ).trimmingCharacters(in: .whitespaces)
                    let cleanedArtist = parsed.artist?.replacingOccurrences(
                        of: yearPattern, with: " ", options: .regularExpression
                    ).trimmingCharacters(in: .whitespaces)

                    // Combine artist and title into one string for the title view.
                    // AVKit only displays .commonIdentifierTitle in the transport
                    // bar area; the artist identifier is used elsewhere (e.g. Info tab).
                    let displayTitle: String
                    if let artist = cleanedArtist, !artist.isEmpty {
                        displayTitle = "\(artist) - \(cleanedTitle)"
                    } else {
                        displayTitle = cleanedTitle
                    }

                    // extendedLanguageTag = "und" is required per WWDC16 Session 506
                    // or AVKit will not display the metadata.
                    let titleMeta = AVMutableMetadataItem()
                    titleMeta.identifier = .commonIdentifierTitle
                    titleMeta.value = displayTitle as NSString
                    titleMeta.extendedLanguageTag = "und"

                    // Override any embedded creation date so AVKit doesn't
                    // show the year above the title in the transport bar.
                    let dateMeta = AVMutableMetadataItem()
                    dateMeta.identifier = .commonIdentifierCreationDate
                    dateMeta.value = "" as NSString
                    dateMeta.extendedLanguageTag = "und"

                    playerItem.externalMetadata = [titleMeta, dateMeta]
                } else {
                    // Still override creation date on bumpers so the year
                    // from the file's embedded metadata doesn't appear.
                    let dateMeta = AVMutableMetadataItem()
                    dateMeta.identifier = .commonIdentifierCreationDate
                    dateMeta.value = "" as NSString
                    dateMeta.extendedLanguageTag = "und"
                    playerItem.externalMetadata = [dateMeta]
                }
            } onChange: { [weak self] in
                DispatchQueue.main.async {
                    self?.updateMetadata()
                }
            }
        }
    }
}
