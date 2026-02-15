import AppKit
import Foundation
import Observation

@Observable
final class AppState {
    // MARK: - Folder Selections
    var musicFolderURL: URL?
    var bumperFolderURL: URL?

    // Keep security-scoped access alive for the session
    private var activeMusicAccess: URL?
    private var activeBumperAccess: URL?

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

    // MARK: - Playback Tracking
    var currentIndex: Int = 0
    var isPlaying: Bool = false
    var isFullScreen: Bool = false
    var hasStarted: Bool = false
    var showPlaylist: Bool = false

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
    }

    // MARK: - Init
    init() {
        loadSettings()
        restoreFolders()
    }

    func toggleFullScreen() {
        NSApp.keyWindow?.toggleFullScreen(nil)
    }

    // MARK: - Supported Formats
    private static let supportedExtensions: Set<String> = [
        "mp4", "mov", "m4v", "avi", "mkv", "ts", "webm"
    ]

    // MARK: - Folder Scanning
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
                items.append(VideoItem(url: fileURL, isBumper: isBumper))
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
        let musicList = settings.shuffleMusic ? musicVideos.shuffled() : musicVideos
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

    // MARK: - Settings Persistence

    private func saveSettings() {
        let defaults = UserDefaults.standard
        defaults.set(settings.bumperInterval, forKey: Keys.bumperInterval)
        defaults.set(settings.shuffleMusic, forKey: Keys.shuffleMusic)
        defaults.set(settings.shuffleBumpers, forKey: Keys.shuffleBumpers)
        defaults.set(settings.repeatPlaylist, forKey: Keys.repeatPlaylist)
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
        settings = loaded
    }
}
