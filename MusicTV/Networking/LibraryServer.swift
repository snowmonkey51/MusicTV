import Foundation
import Network
import Observation

/// Serves the local MusicTV library over HTTP and advertises via Bonjour.
///
/// Endpoints:
///   GET /library.json     – JSON metadata for all videos
///   GET /video/<path>     – streams a video file (supports Range requests)
@Observable
@MainActor
final class LibraryServer {
    private(set) var isRunning: Bool = false
    private(set) var port: UInt16 = 0

    private var listener: NWListener?
    private weak var appState: AppState?

    // MARK: - Lifecycle

    func start(appState: AppState) {
        guard !isRunning else { return }
        self.appState = appState

        do {
            let params = NWParameters.tcp
            let listener = try NWListener(using: params)

            let hostName = Host.current().localizedName ?? "MusicTV"
            listener.service = NWListener.Service(
                name: hostName,
                type: "_musictv._tcp"
            )

            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor [weak self] in
                    self?.handleStateUpdate(state)
                }
            }

            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor [weak self] in
                    self?.handleConnection(connection)
                }
            }

            listener.start(queue: .main)
            self.listener = listener
        } catch {
            print("[LibraryServer] Failed to create listener: \(error)")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
        port = 0
    }

    // MARK: - State

    private func handleStateUpdate(_ state: NWListener.State) {
        switch state {
        case .ready:
            if let p = listener?.port?.rawValue {
                port = p
            }
            isRunning = true
            print("[LibraryServer] Listening on port \(port)")
        case .failed(let error):
            print("[LibraryServer] Listener failed: \(error)")
            stop()
        case .cancelled:
            isRunning = false
        default:
            break
        }
    }

    // MARK: - Connection Handling

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: .main)
        receiveRequest(on: connection, accumulated: Data())
    }

    private func receiveRequest(on connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, isComplete, error in
            Task { @MainActor [weak self] in
                guard let self else { return }

                var buffer = accumulated
                if let data { buffer.append(data) }

                // Check if we have the full HTTP headers
                if let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) {
                    let headerData = buffer[buffer.startIndex..<headerEnd.lowerBound]
                    if let headerString = String(data: headerData, encoding: .utf8) {
                        self.dispatch(request: headerString, on: connection)
                    } else {
                        self.sendError(status: "400 Bad Request", on: connection)
                    }
                } else if buffer.count > 16384 {
                    // Headers too large
                    self.sendError(status: "413 Payload Too Large", on: connection)
                } else if isComplete || error != nil {
                    self.sendError(status: "400 Bad Request", on: connection)
                } else {
                    // Keep reading
                    self.receiveRequest(on: connection, accumulated: buffer)
                }
            }
        }
    }

    // MARK: - Request Dispatch

    private func dispatch(request: String, on connection: NWConnection) {
        let lines = request.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            sendError(status: "400 Bad Request", on: connection)
            return
        }

        let parts = requestLine.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2, parts[0] == "GET" else {
            sendError(status: "405 Method Not Allowed", on: connection)
            return
        }

        let rawPath = String(parts[1])

        // Parse headers for Range support
        var rangeHeader: String?
        for line in lines.dropFirst() {
            if line.lowercased().hasPrefix("range:") {
                rangeHeader = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            }
        }

        print("[LibraryServer] \(parts[0]) \(rawPath) range=\(rangeHeader ?? "none")")

        if rawPath == "/library.json" {
            sendLibraryJSON(on: connection)
        } else if rawPath.hasPrefix("/video/") {
            let encodedPath = String(rawPath.dropFirst("/video/".count))
            if let decodedPath = encodedPath.removingPercentEncoding {
                sendVideoFile(relativePath: decodedPath, rangeHeader: rangeHeader, on: connection)
            } else {
                print("[LibraryServer] Failed to decode path: \(encodedPath)")
                sendError(status: "400 Bad Request", on: connection)
            }
        } else {
            sendError(status: "404 Not Found", on: connection)
        }
    }

    // MARK: - /library.json

    private func sendLibraryJSON(on connection: NWConnection) {
        guard let appState else {
            sendError(status: "503 Service Unavailable", on: connection)
            return
        }

        let hostName = Host.current().localizedName ?? "MusicTV"

        let musicTransfers = appState.musicVideos.map { item -> VideoItemTransfer in
            let relative = relativePath(for: item, root: appState.musicFolderURL)
            return VideoItemTransfer(
                fileName: item.fileName,
                relativePath: relative,
                genres: item.genres,
                dateAdded: item.dateAdded,
                isBumper: false
            )
        }

        let bumperTransfers = appState.bumperVideos.map { item -> VideoItemTransfer in
            let relative = relativePath(for: item, root: appState.bumperFolderURL)
            return VideoItemTransfer(
                fileName: item.fileName,
                relativePath: relative,
                genres: item.genres,
                dateAdded: item.dateAdded,
                isBumper: true
            )
        }

        // Use the real mDNS hostname (e.g. "Aarons-MacBook-Pro.local") for video URLs.
        // ProcessInfo.hostName returns the actual Bonjour hostname that mDNS can resolve,
        // unlike Host.current().localizedName which is the display name (e.g. "Aaron's MacBook Pro").
        let localHostname = ProcessInfo.processInfo.hostName
        print("[LibraryServer] Serving library with hostname: \(localHostname), port: \(self.port)")

        let response = LibraryResponse(
            name: hostName,
            hostname: localHostname,
            port: self.port,
            musicVideos: musicTransfers,
            bumperVideos: bumperTransfers
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        guard let jsonData = try? encoder.encode(response) else {
            sendError(status: "500 Internal Server Error", on: connection)
            return
        }

        sendResponse(
            status: "200 OK",
            headers: [
                "Content-Type": "application/json",
                "Content-Length": "\(jsonData.count)"
            ],
            body: jsonData,
            on: connection
        )
    }

    private func relativePath(for item: VideoItem, root: URL?) -> String {
        guard let root else { return item.url.lastPathComponent }
        let rootPath = root.standardizedFileURL.path
        let filePath = item.url.standardizedFileURL.path
        if filePath.hasPrefix(rootPath) {
            var rel = String(filePath.dropFirst(rootPath.count))
            if rel.hasPrefix("/") { rel = String(rel.dropFirst()) }
            return rel
        }
        return item.url.lastPathComponent
    }

    // MARK: - /video/<path>

    private func sendVideoFile(relativePath: String, rangeHeader: String?, on connection: NWConnection) {
        guard let appState else {
            sendError(status: "503 Service Unavailable", on: connection)
            return
        }

        // Try to resolve against music folder first, then bumper folder
        var resolvedURL: URL?
        if let musicRoot = appState.musicFolderURL {
            let candidate = musicRoot.appendingPathComponent(relativePath)
            if isSafePath(candidate, within: musicRoot) && FileManager.default.fileExists(atPath: candidate.path) {
                resolvedURL = candidate
            }
        }
        if resolvedURL == nil, let bumperRoot = appState.bumperFolderURL {
            let candidate = bumperRoot.appendingPathComponent(relativePath)
            if isSafePath(candidate, within: bumperRoot) && FileManager.default.fileExists(atPath: candidate.path) {
                resolvedURL = candidate
            }
        }

        guard let fileURL = resolvedURL else {
            print("[LibraryServer] 404 — file not found: \(relativePath)")
            sendError(status: "404 Not Found", on: connection)
            return
        }

        guard let fileHandle = try? FileHandle(forReadingFrom: fileURL),
              let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let fileSize = attrs[.size] as? UInt64 else {
            print("[LibraryServer] 500 — can't read file: \(fileURL.path)")
            sendError(status: "500 Internal Server Error", on: connection)
            return
        }

        let contentType = mimeType(for: fileURL.pathExtension)

        // Parse Range header (e.g. "bytes=0-1", "bytes=1024-", "bytes=0-65535")
        if let range = rangeHeader, range.hasPrefix("bytes=") {
            let rangeSpec = String(range.dropFirst("bytes=".count))
            // Split on "-" but keep empty parts (e.g., "0-" splits to ["0", ""])
            let dashIndex = rangeSpec.firstIndex(of: "-") ?? rangeSpec.endIndex
            let startStr = String(rangeSpec[rangeSpec.startIndex..<dashIndex])
            let endStr = dashIndex < rangeSpec.endIndex ? String(rangeSpec[rangeSpec.index(after: dashIndex)...]) : ""

            let start = UInt64(startStr) ?? 0
            let end: UInt64
            if let e = UInt64(endStr), !endStr.isEmpty {
                end = min(e, fileSize - 1)
            } else {
                end = fileSize - 1
            }

            let length = end - start + 1
            fileHandle.seek(toFileOffset: start)

            print("[LibraryServer] 206 \(fileURL.lastPathComponent) bytes=\(start)-\(end)/\(fileSize) (\(length) bytes)")

            let headers: [String: String] = [
                "Content-Type": contentType,
                "Content-Length": "\(length)",
                "Content-Range": "bytes \(start)-\(end)/\(fileSize)",
                "Accept-Ranges": "bytes"
            ]

            sendResponseHeader(status: "206 Partial Content", headers: headers, on: connection)
            streamFileChunks(fileHandle: fileHandle, remaining: length, on: connection)
        } else {
            // Full file — but still tell AVPlayer we accept ranges
            print("[LibraryServer] 200 \(fileURL.lastPathComponent) full file (\(fileSize) bytes)")

            let headers: [String: String] = [
                "Content-Type": contentType,
                "Content-Length": "\(fileSize)",
                "Accept-Ranges": "bytes"
            ]

            sendResponseHeader(status: "200 OK", headers: headers, on: connection)
            streamFileChunks(fileHandle: fileHandle, remaining: fileSize, on: connection)
        }
    }

    /// Path traversal prevention.
    private func isSafePath(_ resolved: URL, within root: URL) -> Bool {
        let resolvedPath = resolved.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        return resolvedPath.hasPrefix(rootPath)
    }

    // MARK: - File Streaming

    private let chunkSize: Int = 512 * 1024  // 512 KB

    private func streamFileChunks(fileHandle: FileHandle, remaining: UInt64, on connection: NWConnection) {
        guard remaining > 0 else {
            fileHandle.closeFile()
            connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in
                connection.cancel()
            })
            return
        }

        let readSize = min(UInt64(chunkSize), remaining)
        let data = fileHandle.readData(ofLength: Int(readSize))

        guard !data.isEmpty else {
            fileHandle.closeFile()
            connection.cancel()
            return
        }

        let newRemaining = remaining - UInt64(data.count)
        let isLast = newRemaining == 0

        connection.send(content: data, isComplete: isLast, completion: .contentProcessed { [weak self] error in
            if let error {
                print("[LibraryServer] Send error: \(error)")
                fileHandle.closeFile()
                connection.cancel()
                return
            }
            if isLast {
                fileHandle.closeFile()
                connection.cancel()
            } else {
                Task { @MainActor [weak self] in
                    self?.streamFileChunks(fileHandle: fileHandle, remaining: newRemaining, on: connection)
                }
            }
        })
    }

    // MARK: - HTTP Response Helpers

    private func sendResponse(status: String, headers: [String: String], body: Data?, on connection: NWConnection) {
        var response = "HTTP/1.1 \(status)\r\n"
        for (key, value) in headers {
            response += "\(key): \(value)\r\n"
        }
        response += "Connection: close\r\n"
        response += "\r\n"

        var responseData = Data(response.utf8)
        if let body { responseData.append(body) }

        connection.send(content: responseData, isComplete: true, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func sendResponseHeader(status: String, headers: [String: String], on connection: NWConnection) {
        var response = "HTTP/1.1 \(status)\r\n"
        for (key, value) in headers {
            response += "\(key): \(value)\r\n"
        }
        response += "Connection: close\r\n"
        response += "\r\n"

        connection.send(content: Data(response.utf8), isComplete: false, completion: .contentProcessed { error in
            if let error {
                print("[LibraryServer] Header send error: \(error)")
                connection.cancel()
            }
        })
    }

    private func sendError(status: String, on connection: NWConnection) {
        sendResponse(status: status, headers: ["Content-Length": "0"], body: nil, on: connection)
    }

    // MARK: - MIME Types

    private func mimeType(for ext: String) -> String {
        switch ext.lowercased() {
        case "mp4", "m4v": return "video/mp4"
        case "mov": return "video/quicktime"
        case "avi": return "video/x-msvideo"
        case "mkv": return "video/x-matroska"
        case "ts": return "video/mp2t"
        case "webm": return "video/webm"
        default: return "application/octet-stream"
        }
    }
}
