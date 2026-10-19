import Foundation
import Network

final class StaticHTTPServer {
    enum ServerError: Error {
        case missingResourceRoot
        case failedToStart(String)
    }

    private let rootURL: URL
    private let queue = DispatchQueue(label: "com.qimake.MikuDesktop.StaticHTTPServer")
    private var listener: NWListener?

    init(rootURL: URL) {
        self.rootURL = rootURL.standardizedFileURL.resolvingSymlinksInPath()
    }

    func start(completion: @escaping (Result<URL, Error>) -> Void) {
        guard FileManager.default.fileExists(atPath: rootURL.path) else {
            completion(.failure(ServerError.missingResourceRoot))
            return
        }

        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
            let listener = try NWListener(using: parameters)
            self.listener = listener
            var completed = false
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                guard let self else { return }
                switch state {
                case .ready:
                    guard !completed, let port = listener?.port else { return }
                    completed = true
                    completion(.success(URL(string: "http://127.0.0.1:\(port.rawValue)/companion/index.html")!))
                case .failed(let error):
                    guard !completed else { return }
                    completed = true
                    completion(.failure(ServerError.failedToStart(error.localizedDescription)))
                    self.stop()
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection)
            }
            listener.start(queue: queue)
        } catch {
            completion(.failure(error))
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveHeader(on: connection, buffer: Data())
    }

    private func receiveHeader(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8_192) { [weak self] data, _, isComplete, error in
            guard let self, error == nil else {
                connection.cancel()
                return
            }
            var accumulated = buffer
            if let data { accumulated.append(data) }
            if accumulated.count > 65_536 {
                self.send(status: "431 Request Header Fields Too Large", body: Data(), mime: "text/plain", headOnly: false, on: connection)
                return
            }
            if accumulated.range(of: Data("\r\n\r\n".utf8)) != nil {
                guard let request = String(data: accumulated, encoding: .utf8) else {
                    self.send(status: "400 Bad Request", body: Data(), mime: "text/plain", headOnly: false, on: connection)
                    return
                }
                self.respond(to: request, on: connection)
            } else if isComplete {
                self.send(status: "400 Bad Request", body: Data(), mime: "text/plain", headOnly: false, on: connection)
            } else {
                self.receiveHeader(on: connection, buffer: accumulated)
            }
        }
    }

    private func respond(to request: String, on connection: NWConnection) {
        let firstLine = request.split(separator: "\n", maxSplits: 1).first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else {
            send(status: "400 Bad Request", body: Data(), mime: "text/plain", headOnly: false, on: connection)
            return
        }

        let method = String(parts[0])
        guard method == "GET" || method == "HEAD" else {
            send(status: "405 Method Not Allowed", body: Data(), mime: "text/plain", headOnly: method == "HEAD", on: connection)
            return
        }

        guard let target = String(parts[1]).split(separator: "?", maxSplits: 1).first,
              let decoded = String(target).removingPercentEncoding,
              let fileURL = safeFileURL(for: decoded) else {
            send(status: "403 Forbidden", body: Data(), mime: "text/plain", headOnly: method == "HEAD", on: connection)
            return
        }

        guard let body = try? Data(contentsOf: fileURL, options: .mappedIfSafe) else {
            send(status: "404 Not Found", body: Data(), mime: "text/plain", headOnly: method == "HEAD", on: connection)
            return
        }
        send(status: "200 OK", body: body, mime: mimeType(for: fileURL), headOnly: method == "HEAD", on: connection)
    }

    private func safeFileURL(for requestPath: String) -> URL? {
        guard !requestPath.contains("\0") else { return nil }
        let relative = requestPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let components = relative.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.contains("..") else { return nil }

        let requested = components.reduce(rootURL) { url, component in
            url.appendingPathComponent(String(component), isDirectory: false)
        }.standardizedFileURL.resolvingSymlinksInPath()
        let rootPath = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
        guard requested.path == rootURL.path || requested.path.hasPrefix(rootPath) else { return nil }
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: requested.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return requested.appendingPathComponent("index.html")
        }
        return requested
    }

    private func send(status: String, body: Data, mime: String, headOnly: Bool, on connection: NWConnection) {
        let headers = [
            "HTTP/1.1 \(status)",
            "Content-Length: \(body.count)",
            "Content-Type: \(mime)",
            "Cache-Control: no-cache",
            "Connection: close",
            "X-Content-Type-Options: nosniff",
            "",
            ""
        ].joined(separator: "\r\n")
        var response = Data(headers.utf8)
        if !headOnly { response.append(body) }
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }

    private func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "html": return "text/html; charset=utf-8"
        case "js", "mjs": return "text/javascript; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "json": return "application/json; charset=utf-8"
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "svg": return "image/svg+xml"
        case "bmp": return "image/bmp"
        case "pmd": return "application/octet-stream"
        case "txt": return "text/plain; charset=utf-8"
        default: return "application/octet-stream"
        }
    }
}
