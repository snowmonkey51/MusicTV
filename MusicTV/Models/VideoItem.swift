import Foundation

struct VideoItem: Identifiable, Hashable {
    let id: UUID
    let url: URL
    let fileName: String
    let isBumper: Bool
    let genres: [String]
    let dateAdded: Date

    /// Creates a VideoItem from a local file URL.
    init(url: URL, isBumper: Bool = false, rootURL: URL? = nil) {
        self.id = UUID()
        self.url = url
        self.fileName = url.deletingPathExtension().lastPathComponent
        self.isBumper = isBumper

        // Use file creation date as "date added"
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let created = attrs[.creationDate] as? Date {
            self.dateAdded = created
        } else {
            self.dateAdded = .distantPast
        }

        // Extract genre path components between root folder and the file
        if let root = rootURL {
            let rootComponents = root.standardizedFileURL.pathComponents
            let fileComponents = url.standardizedFileURL.deletingLastPathComponent().pathComponents
            self.genres = Array(fileComponents.dropFirst(rootComponents.count))
        } else {
            self.genres = []
        }
    }

    /// Creates a VideoItem from network metadata (no file system access needed).
    init(url: URL, fileName: String, isBumper: Bool, genres: [String], dateAdded: Date) {
        self.id = UUID()
        self.url = url
        self.fileName = fileName
        self.isBumper = isBumper
        self.genres = genres
        self.dateAdded = dateAdded
    }
}

// MARK: - Network Transfer

/// JSON-serialisable representation of a video for network sharing.
struct VideoItemTransfer: Codable {
    let fileName: String
    let relativePath: String
    let genres: [String]
    let dateAdded: Date
    let isBumper: Bool
}

/// Top-level response from a shared library's `/library.json` endpoint.
struct LibraryResponse: Codable {
    let name: String
    let hostname: String
    let port: UInt16
    let musicVideos: [VideoItemTransfer]
    let bumperVideos: [VideoItemTransfer]
}
