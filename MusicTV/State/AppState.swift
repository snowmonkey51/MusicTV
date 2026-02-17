import AppKit
import Foundation
import Observation

@Observable
final class AppState {
    // MARK: - Folder Selections
    var musicFolderURL: URL?
    var bumperFolderURL: URL?

    // MARK: - Opening Bumper
    var openingBumperURL: URL?
    private var activeOpeningBumperAccess: URL?

    // MARK: - Logo Overlay
    var logoURL: URL?
    var logoImage: NSImage?

    // Keep security-scoped access alive for the session
    private var activeMusicAccess: URL?
    private var activeBumperAccess: URL?
    private var activeLogoAccess: URL?

    // MARK: - Scanned Video Lists
    var musicVideos: [VideoItem] = []
    var bumperVideos: [VideoItem] = []

    // MARK: - Settings
    var settings: PlaybackSettings = PlaybackSettings() {
        didSet {
            buildPlaylist()
            saveSettings()
        }
    }

    // MARK: - Playlist (music + interleaved bumpers)
    var playlist: [VideoItem] = []
    var filteredMusicVideos: [VideoItem]?
    var selectedGenre: String = "All"

    var availableGenres: [String] {
        var genreSet = Set<String>()
        for item in musicVideos {
            for genre in item.genres {
                genreSet.insert(genre)
            }
        }
        return ["All"] + genreSet.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    // MARK: - Playback Tracking
    var currentIndex: Int = 0
    var isPlaying: Bool = false
    var isFullScreen: Bool = false
    var hasStarted: Bool = false
    var showPlaylist: Bool = false
    var currentFilter: VideoFilter = .none

    var currentItem: VideoItem? {
        guard hasStarted, playlist.indices.contains(currentIndex) else { return nil }
        return playlist[currentIndex]
    }

    // MARK: - UserDefaults Keys
    private enum Keys {
        static let musicBookmark = "musicFolderBookmark"
        static let bumperBookmark = "bumperFolderBookmark"
        static let bumperInterval = "bumperInterval"
        static let shuffleMusic = "shuffleMusic"
        static let shuffleBumpers = "shuffleBumpers"
        static let repeatPlaylist = "repeatPlaylist"
        static let logoBookmark = "logoImageBookmark"
        static let openingBumperBookmark = "openingBumperBookmark"
        static let videoFilter = "videoFilter"
        static let normalizeAudio = "normalizeAudio"
    }

    // MARK: - Init
    init() {
        loadSettings()
        loadFilter()
        restoreFolders()
        restoreLogo()
        restoreOpeningBumper()
    }

    func toggleFullScreen() {
        NSApp.keyWindow?.toggleFullScreen(nil)
    }

    // MARK: - Supported Formats
    private static let supportedExtensions: Set<String> = [
        "mp4", "mov", "m4v", "avi", "mkv", "ts", "webm"
    ]

    // MARK: - Folder Scanning

    /// Re-scans both music and bumper folders to pick up new/removed files.
    func refreshLibrary() {
        if let url = musicFolderURL {
            scanFolder(url: url, isBumper: false)
        }
        if let url = bumperFolderURL {
            scanFolder(url: url, isBumper: true)
        }
    }

    func scanFolder(url: URL, isBumper: Bool) {
        // Release previous security-scoped access
        if isBumper {
            activeBumperAccess?.stopAccessingSecurityScopedResource()
            activeBumperAccess = nil
        } else {
            activeMusicAccess?.stopAccessingSecurityScopedResource()
            activeMusicAccess = nil
        }

        // Start and keep security-scoped access alive for the session
        let accessing = url.startAccessingSecurityScopedResource()
        if accessing {
            if isBumper {
                activeBumperAccess = url
            } else {
                activeMusicAccess = url
            }
        }

        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return }

        var items: [VideoItem] = []
        for case let fileURL as URL in enumerator {
            if Self.supportedExtensions.contains(fileURL.pathExtension.lowercased()) {
                items.append(VideoItem(url: fileURL, isBumper: isBumper, rootURL: url))
            }
        }
        items.sort { $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending }

        if isBumper {
            bumperVideos = items
            bumperFolderURL = url
            saveBookmark(for: url, key: Keys.bumperBookmark)
        } else {
            musicVideos = items
            musicFolderURL = url
            saveBookmark(for: url, key: Keys.musicBookmark)
        }
        buildPlaylist()
    }

    // MARK: - Playlist Building
    func buildPlaylist() {
        var result: [VideoItem] = []

        // Apply genre filter, then any additional search/artist filter on top
        var baseVideos = musicVideos
        if selectedGenre != "All" {
            baseVideos = baseVideos.filter { $0.genres.contains(selectedGenre) }
        }
        let sourceVideos = filteredMusicVideos ?? baseVideos
        let musicList = settings.shuffleMusic ? sourceVideos.shuffled() : sourceVideos
        let bumperList = settings.shuffleBumpers ? bumperVideos.shuffled() : bumperVideos
        var bumperIndex = 0
        var lastBumperID: UUID?
        let interval = max(1, settings.bumperInterval)

        for (i, video) in musicList.enumerated() {
            result.append(video)
            if !bumperList.isEmpty && (i + 1) % interval == 0 {
                var candidate = bumperList[bumperIndex % bumperList.count]
                if bumperList.count > 1 && candidate.id == lastBumperID {
                    bumperIndex += 1
                    candidate = bumperList[bumperIndex % bumperList.count]
                }
                result.append(candidate)
                lastBumperID = candidate.id
                bumperIndex += 1
            }
        }
        playlist = result

        if currentIndex >= playlist.count {
            currentIndex = 0
        }
    }

    // MARK: - Genre Filtering

    /// Sets the active genre and rebuilds the playlist.
    func setGenre(_ genre: String) {
        selectedGenre = genre
        filteredMusicVideos = nil
        buildPlaylist()
    }

    // MARK: - Filtered Playback

    /// Sets a filtered subset of music videos and rebuilds the playlist.
    func playFilteredVideos(_ videos: [VideoItem]) {
        filteredMusicVideos = videos
        buildPlaylist()
        currentIndex = 0
        hasStarted = true
    }

    /// Clears any active filter and restores the full playlist.
    func clearFilter() {
        guard filteredMusicVideos != nil else { return }
        filteredMusicVideos = nil
        buildPlaylist()
    }

    // MARK: - Bookmark Persistence

    private func saveBookmark(for url: URL, key: String) {
        do {
            let bookmark = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(bookmark, forKey: key)
        } catch {
            print("Failed to save bookmark for \(key): \(error)")
        }
    }

    private func resolveBookmark(key: String) -> URL? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        do {
            var isStale = false
            let url = try URL(
                resolvingBookmarkData: data,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            if isStale {
                saveBookmark(for: url, key: key)
            }
            return url
        } catch {
            print("Failed to resolve bookmark for \(key): \(error)")
            return nil
        }
    }

    private func restoreFolders() {
        if let musicURL = resolveBookmark(key: Keys.musicBookmark) {
            scanFolder(url: musicURL, isBumper: false)
        }
        if let bumperURL = resolveBookmark(key: Keys.bumperBookmark) {
            scanFolder(url: bumperURL, isBumper: true)
        }
    }

    // MARK: - Logo Management

    func setLogo(url: URL) {
        activeLogoAccess?.stopAccessingSecurityScopedResource()
        activeLogoAccess = nil

        let accessing = url.startAccessingSecurityScopedResource()
        logoURL = url
        logoImage = NSImage(contentsOf: url)
        if accessing {
            activeLogoAccess = url
        }
        saveBookmark(for: url, key: Keys.logoBookmark)

        // Cache the image data to app support for reliable restore
        if let image = logoImage {
            cacheLogoImage(image)
        }
    }

    func removeLogo() {
        activeLogoAccess?.stopAccessingSecurityScopedResource()
        activeLogoAccess = nil
        logoURL = nil
        logoImage = nil
        UserDefaults.standard.removeObject(forKey: Keys.logoBookmark)
        // Remove cached file
        try? FileManager.default.removeItem(at: logoCacheURL)
    }

    private func restoreLogo() {
        // First try the bookmark (original file)
        if let url = resolveBookmark(key: Keys.logoBookmark) {
            let accessing = url.startAccessingSecurityScopedResource()
            let image = NSImage(contentsOf: url)
            if let image {
                logoURL = url
                logoImage = image
                if accessing {
                    activeLogoAccess = url
                }
                return
            }
            if accessing {
                url.stopAccessingSecurityScopedResource()
            }
        }
        // Fallback: load from cached copy
        if let image = NSImage(contentsOf: logoCacheURL) {
            logoImage = image
        }
    }

    private var logoCacheURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = appSupport.appendingPathComponent(Bundle.main.bundleIdentifier ?? "MusicTV")
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        return appDir.appendingPathComponent("cachedLogo.png")
    }

    private func cacheLogoImage(_ image: NSImage) {
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else { return }
        try? pngData.write(to: logoCacheURL, options: .atomic)
    }

    // MARK: - Opening Bumper Management

    /// Cache URL inside App Support — always readable without security scope.
    private var bumperCacheURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = appSupport.appendingPathComponent(Bundle.main.bundleIdentifier ?? "MusicTV")
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        return appDir.appendingPathComponent("cachedOpeningBumper.mov")
    }

    func setOpeningBumper(url: URL) {
        activeOpeningBumperAccess?.stopAccessingSecurityScopedResource()
        activeOpeningBumperAccess = nil

        let accessing = url.startAccessingSecurityScopedResource()
        if accessing {
            activeOpeningBumperAccess = url
        }

        // Copy the video into App Support so it's always accessible on relaunch
        let dest = bumperCacheURL
        try? FileManager.default.removeItem(at: dest)
        do {
            try FileManager.default.copyItem(at: url, to: dest)
            openingBumperURL = dest
        } catch {
            // If copy fails, use the original URL for this session
            openingBumperURL = url
        }

        // Store a flag so we know a bumper was set
        UserDefaults.standard.set(true, forKey: Keys.openingBumperBookmark)
    }

    func removeOpeningBumper() {
        activeOpeningBumperAccess?.stopAccessingSecurityScopedResource()
        activeOpeningBumperAccess = nil
        openingBumperURL = nil
        UserDefaults.standard.removeObject(forKey: Keys.openingBumperBookmark)
        try? FileManager.default.removeItem(at: bumperCacheURL)
    }

    private func restoreOpeningBumper() {
        // Check if a bumper was previously set
        guard UserDefaults.standard.bool(forKey: Keys.openingBumperBookmark) else { return }

        // Load from the cached copy in App Support
        let cached = bumperCacheURL
        if FileManager.default.fileExists(atPath: cached.path) {
            openingBumperURL = cached
        }
    }

    // MARK: - Settings Persistence

    func saveFilter() {
        UserDefaults.standard.set(currentFilter.rawValue, forKey: Keys.videoFilter)
    }

    private func saveSettings() {
        let defaults = UserDefaults.standard
        defaults.set(settings.bumperInterval, forKey: Keys.bumperInterval)
        defaults.set(settings.shuffleMusic, forKey: Keys.shuffleMusic)
        defaults.set(settings.shuffleBumpers, forKey: Keys.shuffleBumpers)
        defaults.set(settings.repeatPlaylist, forKey: Keys.repeatPlaylist)
        defaults.set(settings.normalizeAudio, forKey: Keys.normalizeAudio)
    }

    private func loadSettings() {
        let defaults = UserDefaults.standard
        var loaded = PlaybackSettings()
        if defaults.object(forKey: Keys.bumperInterval) != nil {
            loaded.bumperInterval = defaults.integer(forKey: Keys.bumperInterval)
        }
        loaded.shuffleMusic = defaults.bool(forKey: Keys.shuffleMusic)
        loaded.shuffleBumpers = defaults.bool(forKey: Keys.shuffleBumpers)
        if defaults.object(forKey: Keys.repeatPlaylist) != nil {
            loaded.repeatPlaylist = defaults.bool(forKey: Keys.repeatPlaylist)
        }
        loaded.normalizeAudio = defaults.bool(forKey: Keys.normalizeAudio)
        settings = loaded
    }

    private func loadFilter() {
        if let raw = UserDefaults.standard.string(forKey: Keys.videoFilter),
           let filter = VideoFilter(rawValue: raw) {
            currentFilter = filter
        }
    }
}
