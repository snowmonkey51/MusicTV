import Foundation

struct VideoItem: Identifiable, Hashable {
    let id: UUID
    let url: URL
    let fileName: String
    let isBumper: Bool

    init(url: URL, isBumper: Bool = false) {
        self.id = UUID()
        self.url = url
        self.fileName = url.deletingPathExtension().lastPathComponent
        self.isBumper = isBumper
    }
}
