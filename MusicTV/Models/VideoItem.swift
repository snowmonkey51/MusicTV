import Foundation

struct VideoItem: Identifiable, Hashable {
    let id: UUID
    let url: URL
    let fileName: String
    let isBumper: Bool
    let genres: [String]

    init(url: URL, isBumper: Bool = false, rootURL: URL? = nil) {
        self.id = UUID()
        self.url = url
        self.fileName = url.deletingPathExtension().lastPathComponent
        self.isBumper = isBumper

        // Extract genre path components between root folder and the file
        if let root = rootURL {
            let rootComponents = root.standardizedFileURL.pathComponents
            let fileComponents = url.standardizedFileURL.deletingLastPathComponent().pathComponents
            self.genres = Array(fileComponents.dropFirst(rootComponents.count))
        } else {
            self.genres = []
        }
    }
}
