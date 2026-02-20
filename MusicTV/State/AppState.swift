#if canImport(AppKit)
import AppKit
#endif
import Foundation
import Observation

@Observable
final class AppState {
    // MARK: - Folder Selections (macOS only)
    #if os(macOS)
    var musicFolderURL: URL?
    var bumperFolderURL: URL?
    var musicFolderUnavailable: Bool = false
    var bumperFolderUnavailable: Bool = false

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
    #endif

    // MARK: - Scanned Video Lists
    var musicVideos: [VideoItem] = []
    var bumperVideos: [VideoItem] = []

    // MARK: - Library Sharing
    var isShareEnabled: Bool = false
    var connectedNetworkLibrary: DiscoveredLibrary? = nil
    var isLoadingNetworkLibrary: Bool = false
    #if os(macOS)
    let libraryServer = LibraryServer()
    #endif
    let libraryBrowser = LibraryBrowser()

    // MARK: - Settings
    var settings: PlaybackSettings = PlaybackSettings() {
        didSet {
            let playlistChanged =
                oldValue.shuffleMusic != settings.shuffleMusic ||
                oldValue.shuffleBumpers != settings.shuffleBumpers ||
                oldValue.bumperInterval != settings.bumperInterval ||
                oldValue.repeatPlaylist != settings.repeatPlaylist
            if playlistChanged {
                playlistRebuildToken += 1
                buildPlaylist()
            }
            saveSettings()
        }
    }

    // MARK: - Playlist (music + interleaved bumpers)
    var playlist: [VideoItem] = []
    var filteredMusicVideos: [VideoItem]?
    var selectedGenre: String = "All"

    var smartPlaylists: [String] {
        var list = ["All", "New"]
        if !favoritePaths.isEmpty {
            list.append("Favorites")
        }
        return list
    }

    var genreList: [String] {
        var genreSet = Set<String>()
        for item in musicVideos {
            for genre in item.genres {
                genreSet.insert(genre)
            }
        }
        return genreSet.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    var availableGenres: [String] {
        smartPlaylists + genreList
    }

    // MARK: - Favorites
    /// Stores relative paths (from music root) of favorited videos for persistence.
    var favoritePaths: Set<String> = []

    func isFavorite(_ item: VideoItem) -> Bool {
        #if os(macOS)
        guard let root = musicFolderURL else { return false }
        return favoritePaths.contains(relativePath(for: item, root: root))
        #else
        // On tvOS, use the URL string as the key since there's no local root folder
        return favoritePaths.contains(item.url.absoluteString)
        #endif
    }

    func toggleFavorite(_ item: VideoItem) {
        #if os(macOS)
        guard let root = musicFolderURL else { return }
        let path = relativePath(for: item, root: root)
        #else
        let path = item.url.absoluteString
        #endif
        if favoritePaths.contains(path) {
            favoritePaths.remove(path)
        } else {
            favoritePaths.insert(path)
        }
        saveFavorites()
        // If currently viewing favorites, rebuild
        if selectedGenre == "Favorites" {
            playlistRebuildToken += 1
            buildPlaylist()
        }
    }

    var favoriteVideos: [VideoItem] {
        #if os(macOS)
        guard let root = musicFolderURL else { return [] }
        return musicVideos.filter { favoritePaths.contains(relativePath(for: $0, root: root)) }
        #else
        return musicVideos.filter { favoritePaths.contains($0.url.absoluteString) }
        #endif
    }

    #if os(macOS)
    private func relativePath(for item: VideoItem, root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let filePath = item.url.standardizedFileURL.path
        if filePath.hasPrefix(rootPath) {
            return String(filePath.dropFirst(rootPath.count + 1))
        }
        return filePath
    }
    #endif

    // MARK: - Playback Tracking
    var currentIndex: Int = 0
    var isPlaying: Bool = false
    var isFullScreen: Bool = false
    var hasStarted: Bool = false
    var showPlaylist: Bool = false
    var currentFilter: VideoFilter = .none

    /// Incremented by genre/settings changes that rebuild the playlist mid-playback.
    /// Views compare against their own local copy to detect suppressed changes.
    var playlistRebuildToken: Int = 0

    var currentItem: VideoItem? {
        guard hasStarted, playlist.indices.contains(currentIndex) else { return nil }
        return playlist[currentIndex]
    }

    // MARK: - UserDefaults Keys
    private enum Keys {
        #if os(macOS)
        static let musicBookmark = "musicFolderBookmark"
        static let bumperBookmark = "bumperFolderBookmark"
        static let logoBookmark = "logoImageBookmark"
        static let openingBumperBookmark = "openingBumperBookmark"
        static let shareLibrary = "shareLibrary"
        #endif
        static let bumperInterval = "bumperInterval"
        static let shuffleMusic = "shuffleMusic"
        static let shuffleBumpers = "shuffleBumpers"
        static let repeatPlaylist = "repeatPlaylist"
        static let videoFilter = "videoFilter"
        static let normalizeAudio = "normalizeAudio"
        static let showTitleCards = "showTitleCards"
        static let selectedGenre = "selectedGenre"
    }

    // MARK: - Init
    init() {
        loadSettings()
        loadFilter()
        loadFavorites()
        #if os(macOS)
        restoreFolders()
        restoreLogo()
        restoreOpeningBumper()
        #endif
        restoreSelectedGenre()
        #if os(macOS)
        restoreShareSetting()
        #endif
        libraryBrowser.startBrowsing()
    }

    #if os(macOS)
    func toggleFullScreen() {
        NSApp.keyWindow?.toggleFullScreen(nil)
    }
    #endif

    // MARK: - Supported Formats
    private static let supportedExtensions: Set<String> = [
        "mp4", "mov", "m4v", "avi", "mkv", "ts", "webm"
    ]

    // MARK: - Folder Scanning (macOS only)
    #if os(macOS)
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

        // Check if the folder is reachable (handles network shares that aren't mounted)
        let reachable = FileManager.default.isReadableFile(atPath: url.path)
        if isBumper {
            bumperFolderUnavailable = !reachable
            bumperFolderURL = url
        } else {
            musicFolderUnavailable = !reachable
            musicFolderURL = url
        }

        guard reachable, let enumerator = FileManager.default.enumerator(
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
            saveBookmark(for: url, key: Keys.bumperBookmark)
        } else {
            musicVideos = items
            saveBookmark(for: url, key: Keys.musicBookmark)
        }
        buildPlaylist()
    }
    #endif

    // MARK: - Playlist Building
    func buildPlaylist() {
        var result: [VideoItem] = []

        // Apply genre filter, then any additional search/artist filter on top
        var baseVideos = musicVideos
        if selectedGenre == "New" {
            baseVideos = Array(musicVideos.sorted { $0.dateAdded > $1.dateAdded }.prefix(50))
        } else if selectedGenre == "Favorites" {
            baseVideos = favoriteVideos
        } else if selectedGenre != "All" {
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
        // Preserve the currently playing video across rebuilds.
        let currentURL = currentItem?.url
        if let url = currentURL,
           let newIndex = result.firstIndex(where: { $0.url == url }) {
            currentIndex = newIndex
        } else if currentIndex >= result.count {
            currentIndex = 0
        }
        playlist = result
    }

    // MARK: - Genre Filtering

    /// Sets the active genre and rebuilds the playlist.
    func setGenre(_ genre: String) {
        selectedGenre = genre
        filteredMusicVideos = nil
        playlistRebuildToken += 1
        buildPlaylist()
        UserDefaults.standard.set(genre, forKey: Keys.selectedGenre)
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

    // MARK: - Bookmark Persistence (macOS only)
    #if os(macOS)
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

    func rescanFolders() {
        if let url = musicFolderURL {
            scanFolder(url: url, isBumper: false)
        }
        if let url = bumperFolderURL {
            scanFolder(url: url, isBumper: true)
        }
    }
    #endif

    // MARK: - Logo Management (macOS only)
    #if os(macOS)
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
    #endif

    // MARK: - Opening Bumper Management (macOS only)
    #if os(macOS)
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
    #endif

    // MARK: - Library Sharing

    #if os(macOS)
    func setShareEnabled(_ enabled: Bool) {
        isShareEnabled = enabled
        if enabled {
            libraryServer.start(appState: self)
            libraryBrowser.localServiceName = Host.current().localizedName ?? "MusicTV"
        } else {
            libraryServer.stop()
            libraryBrowser.localServiceName = nil
        }
        UserDefaults.standard.set(enabled, forKey: Keys.shareLibrary)
    }

    private func restoreShareSetting() {
        if UserDefaults.standard.bool(forKey: Keys.shareLibrary) {
            setShareEnabled(true)
        }
    }
    #endif

    func connectToNetworkLibrary(_ library: DiscoveredLibrary) {
        guard connectedNetworkLibrary?.id != library.id else { return }
        isLoadingNetworkLibrary = true
        connectedNetworkLibrary = library
        print("[AppState] Connecting to network library: \(library.name)")

        Task {
            do {
                let result = try await libraryBrowser.fetchLibrary(from: library)
                print("[AppState] Received \(result.musicVideos.count) music, \(result.bumperVideos.count) bumpers")
                musicVideos = result.musicVideos
                bumperVideos = result.bumperVideos
                playlistRebuildToken += 1
                buildPlaylist()
                print("[AppState] Playlist rebuilt with \(playlist.count) items")
            } catch {
                print("[AppState] Failed to connect to network library: \(error)")
                connectedNetworkLibrary = nil
            }
            isLoadingNetworkLibrary = false
            print("[AppState] Loading complete, isLoading=\(isLoadingNetworkLibrary)")
        }
    }

    func disconnectFromNetworkLibrary() {
        connectedNetworkLibrary = nil
        #if os(macOS)
        rescanFolders()
        #else
        musicVideos = []
        bumperVideos = []
        hasStarted = false
        isPlaying = false
        buildPlaylist()
        #endif
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
        defaults.set(settings.showTitleCards, forKey: Keys.showTitleCards)
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
        if defaults.object(forKey: Keys.showTitleCards) != nil {
            loaded.showTitleCards = defaults.bool(forKey: Keys.showTitleCards)
        }
        settings = loaded
    }

    private func loadFilter() {
        if let raw = UserDefaults.standard.string(forKey: Keys.videoFilter),
           let filter = VideoFilter(rawValue: raw) {
            currentFilter = filter
        }
    }

    private func restoreSelectedGenre() {
        guard let saved = UserDefaults.standard.string(forKey: Keys.selectedGenre),
              availableGenres.contains(saved) else { return }
        selectedGenre = saved
        buildPlaylist()
    }

    // MARK: - Favorites Persistence

    private var favoritesCacheURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = appSupport.appendingPathComponent(Bundle.main.bundleIdentifier ?? "MusicTV")
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        return appDir.appendingPathComponent("favorites.json")
    }

    private func saveFavorites() {
        let sorted = favoritePaths.sorted()
        guard let data = try? JSONEncoder().encode(sorted) else { return }
        try? data.write(to: favoritesCacheURL, options: .atomic)
    }

    private func loadFavorites() {
        guard let data = try? Data(contentsOf: favoritesCacheURL),
              let paths = try? JSONDecoder().decode([String].self, from: data) else { return }
        favoritePaths = Set(paths)
    }
}
