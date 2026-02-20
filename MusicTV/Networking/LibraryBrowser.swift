import Foundation
import Network
import Observation

/// A discovered MusicTV library on the local network.
struct DiscoveredLibrary: Identifiable, Hashable {
    let id: String
    let name: String
    let endpoint: NWEndpoint

    static func == (lhs: DiscoveredLibrary, rhs: DiscoveredLibrary) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

/// Discovers MusicTV libraries on the local network via Bonjour
/// and fetches their library metadata.
@Observable
@MainActor
final class LibraryBrowser {
    private(set) var discoveredLibraries: [DiscoveredLibrary] = []

    private var browser: NWBrowser?

    /// The service name used by our own server (so we can filter it out).
    var localServiceName: String?

    // MARK: - Browsing

    func startBrowsing() {
        guard browser == nil else { return }

        let browser = NWBrowser(for: .bonjour(type: "_musictv._tcp", domain: nil), using: .tcp)

        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor [weak self] in
                self?.updateDiscoveredLibraries(results)
            }
        }

        browser.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                print("[LibraryBrowser] Browsing for _musictv._tcp services")
            case .failed(let error):
                print("[LibraryBrowser] Browse failed: \(error) — will retry in 2s")
                // Browser failed (often due to local network permission not yet granted).
                // Cancel and retry after a short delay.
                Task { @MainActor [weak self] in
                    self?.browser?.cancel()
                    self?.browser = nil
                    try? await Task.sleep(for: .seconds(2))
                    self?.startBrowsing()
                }
            case .cancelled:
                break
            default:
                break
            }
        }

        browser.start(queue: .main)
        self.browser = browser
    }

    /// Restarts browsing — call this when the app becomes active so that
    /// a fresh browser picks up services after the user grants Local Network permission.
    func restartBrowsing() {
        print("[LibraryBrowser] Restarting browser")
        browser?.cancel()
        browser = nil
        startBrowsing()
    }

    func stopBrowsing() {
        browser?.cancel()
        browser = nil
        discoveredLibraries = []
    }

    private func updateDiscoveredLibraries(_ results: Set<NWBrowser.Result>) {
        discoveredLibraries = results.compactMap { result in
            guard case .service(let name, let type, _, _) = result.endpoint else { return nil }

            // Filter out our own service
            if let local = localServiceName, name == local { return nil }

            return DiscoveredLibrary(
                id: "\(name).\(type)",
                name: name,
                endpoint: result.endpoint
            )
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    // MARK: - Library Fetching

    /// Connects directly to the Bonjour service endpoint and performs an HTTP GET
    /// for /library.json entirely over the NWConnection. Uses the server-provided
    /// .local hostname for video streaming URLs so AVPlayer can resolve them via mDNS.
    func fetchLibrary(from library: DiscoveredLibrary) async throws -> (musicVideos: [VideoItem], bumperVideos: [VideoItem]) {
        print("[LibraryBrowser] Starting fetchLibrary for '\(library.name)'")

        // Try once, and if it times out, retry once (handles first-launch permission delays)
        let (data, resolvedHost, resolvedPort): (Data, String, UInt16)
        do {
            (data, resolvedHost, resolvedPort) = try await httpGetViaNWConnection(
                endpoint: library.endpoint,
                path: "/library.json"
            )
        } catch LibraryBrowserError.timeout {
            print("[LibraryBrowser] First attempt timed out, retrying once...")
            (data, resolvedHost, resolvedPort) = try await httpGetViaNWConnection(
                endpoint: library.endpoint,
                path: "/library.json"
            )
        }

        print("[LibraryBrowser] Received \(data.count) bytes from \(resolvedHost):\(resolvedPort)")

        // Decode the library JSON
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        do {
            let libraryResponse = try decoder.decode(LibraryResponse.self, from: data)
            print("[LibraryBrowser] Library '\(libraryResponse.name)': \(libraryResponse.musicVideos.count) music, \(libraryResponse.bumperVideos.count) bumpers")
            print("[LibraryBrowser] Server hostname: \(libraryResponse.hostname), port: \(libraryResponse.port)")

            // Use the .local hostname from the server for video URLs.
            // This allows AVPlayer to resolve the address via mDNS, which works
            // with macOS local network privacy (unlike raw IP addresses).
            let baseURLString = "http://\(libraryResponse.hostname):\(libraryResponse.port)"
            print("[LibraryBrowser] Base URL for videos: \(baseURLString)")

            let musicItems = libraryResponse.musicVideos.compactMap { transfer -> VideoItem? in
                guard let encoded = transfer.relativePath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
                      let videoURL = URL(string: "\(baseURLString)/video/\(encoded)") else {
                    print("[LibraryBrowser] Failed to encode path: \(transfer.relativePath)")
                    return nil
                }
                return VideoItem(
                    url: videoURL,
                    fileName: transfer.fileName,
                    isBumper: transfer.isBumper,
                    genres: transfer.genres,
                    dateAdded: transfer.dateAdded
                )
            }

            let bumperItems = libraryResponse.bumperVideos.compactMap { transfer -> VideoItem? in
                guard let encoded = transfer.relativePath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
                      let videoURL = URL(string: "\(baseURLString)/video/\(encoded)") else {
                    print("[LibraryBrowser] Failed to encode bumper path: \(transfer.relativePath)")
                    return nil
                }
                return VideoItem(
                    url: videoURL,
                    fileName: transfer.fileName,
                    isBumper: transfer.isBumper,
                    genres: transfer.genres,
                    dateAdded: transfer.dateAdded
                )
            }

            print("[LibraryBrowser] Created \(musicItems.count) music items, \(bumperItems.count) bumper items")
            return (musicItems, bumperItems)
        } catch {
            print("[LibraryBrowser] JSON decode error: \(error)")
            if let jsonString = String(data: data.prefix(500), encoding: .utf8) {
                print("[LibraryBrowser] Response preview: \(jsonString)")
            }
            throw error
        }
    }

    // MARK: - HTTP over NWConnection

    /// Performs a complete HTTP GET request over a single NWConnection to a Bonjour endpoint.
    /// Returns the response body data along with the resolved host and port.
    private nonisolated func httpGetViaNWConnection(
        endpoint: NWEndpoint,
        path: String
    ) async throws -> (data: Data, host: String, port: UInt16) {
        try await withCheckedThrowingContinuation { continuation in
            let queue = DispatchQueue(label: "com.musictv.http")
            let connection = NWConnection(to: endpoint, using: .tcp)
            let guard_ = ContinuationGuard()

            connection.stateUpdateHandler = { [guard_] state in
                print("[LibraryBrowser] NWConnection state: \(state)")
                switch state {
                case .ready:
                    // Extract host:port from the resolved connection
                    var hostString = "unknown"
                    var portValue: UInt16 = 0
                    if let remoteEndpoint = connection.currentPath?.remoteEndpoint,
                       case .hostPort(let host, let port) = remoteEndpoint {
                        switch host {
                        case .ipv4(let addr): hostString = "\(addr)"
                        case .ipv6(let addr): hostString = "\(addr)"
                        case .name(let name, _): hostString = name
                        @unknown default: hostString = "\(host)"
                        }
                        portValue = port.rawValue
                    }

                    print("[LibraryBrowser] Connected to \(hostString):\(portValue), sending HTTP GET \(path)")

                    // Send the HTTP request
                    let request = "GET \(path) HTTP/1.1\r\nHost: \(hostString)\r\nConnection: close\r\n\r\n"
                    connection.send(content: Data(request.utf8), isComplete: false, completion: .contentProcessed { sendError in
                        if let sendError {
                            guard guard_.claim() else { return }
                            print("[LibraryBrowser] Send error: \(sendError)")
                            connection.cancel()
                            continuation.resume(throwing: sendError)
                            return
                        }

                        // Read the entire response
                        self.readFullResponse(from: connection) { result in
                            guard guard_.claim() else { return }
                            connection.cancel()
                            switch result {
                            case .success(let bodyData):
                                continuation.resume(returning: (bodyData, hostString, portValue))
                            case .failure(let error):
                                continuation.resume(throwing: error)
                            }
                        }
                    })

                case .waiting(let error):
                    // Don't immediately cancel — the system may be prompting
                    // the user for local network permission. The 20-second
                    // timeout will catch genuinely stuck connections.
                    print("[LibraryBrowser] Connection waiting: \(error) — awaiting network permission")

                case .failed(let error):
                    print("[LibraryBrowser] Connection failed: \(error)")
                    guard guard_.claim() else { return }
                    connection.cancel()
                    continuation.resume(throwing: error)

                default:
                    break
                }
            }

            connection.start(queue: queue)

            // Timeout
            queue.asyncAfter(deadline: .now() + 20) { [guard_] in
                guard guard_.claim() else { return }
                print("[LibraryBrowser] Connection timed out after 20s")
                connection.cancel()
                continuation.resume(throwing: LibraryBrowserError.timeout)
            }
        }
    }

    /// Reads the full HTTP response by accumulating data until the connection closes.
    /// Parses out the HTTP body (skipping headers).
    private nonisolated func readFullResponse(
        from connection: NWConnection,
        accumulated: Data = Data(),
        completion: @escaping @Sendable (Result<Data, Error>) -> Void
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
            var buffer = accumulated
            if let data { buffer.append(data) }

            if isComplete || error != nil {
                // We have all the data — parse out the HTTP body
                if let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) {
                    let body = buffer[headerEnd.upperBound...]
                    let headerData = buffer[buffer.startIndex..<headerEnd.lowerBound]
                    if let headerString = String(data: headerData, encoding: .utf8) {
                        print("[LibraryBrowser] Response headers: \(headerString.prefix(200))")
                    }
                    completion(.success(Data(body)))
                } else if buffer.isEmpty {
                    completion(.failure(LibraryBrowserError.emptyResponse))
                } else {
                    // No headers found — treat entire buffer as body
                    completion(.success(buffer))
                }
                return
            }

            // Keep reading
            self.readFullResponse(from: connection, accumulated: buffer, completion: completion)
        }
    }
}

/// One-shot guard for continuation resumption.
private final class ContinuationGuard: @unchecked Sendable {
    private var claimed = false

    func claim() -> Bool {
        if claimed { return false }
        claimed = true
        return true
    }
}

enum LibraryBrowserError: LocalizedError {
    case invalidURL
    case resolutionFailed
    case timeout
    case localNetworkDenied
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid library URL"
        case .resolutionFailed: return "Could not resolve library address"
        case .timeout: return "Connection timed out"
        case .localNetworkDenied: return "Local network access denied. Please allow MusicTV in System Settings > Privacy & Security > Local Network."
        case .emptyResponse: return "Empty response from server"
        }
    }
}
