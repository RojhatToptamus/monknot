import Foundation
import Network

final class LoopbackHTTPTestServer {
    struct Response {
        let body: String
        let delay: TimeInterval

        init(body: String, delay: TimeInterval = 0) {
            self.body = body
            self.delay = delay
        }
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "MonknotTests.LoopbackHTTP")
    private let handler: (String) -> Response
    private let lock = NSLock()
    private var startContinuation: CheckedContinuation<URL, Error>?
    private var clientClosureCounts: [String: Int] = [:]
    private var connections: [ObjectIdentifier: NWConnection] = [:]

    init(handler: @escaping (String) -> Response) throws {
        self.handler = handler
        listener = try NWListener(using: .tcp, on: .any)
    }

    func start() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock {
                startContinuation = continuation
            }
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    guard let port = self.listener.port else {
                        self.finishStart(.failure(ServerError.missingPort))
                        return
                    }
                    self.finishStart(
                        .success(
                            URL(string: "http://127.0.0.1:\(port.rawValue)")!
                        )
                    )
                case let .failed(error):
                    self.finishStart(.failure(error))
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener.cancel()
        let active = lock.withLock {
            defer { connections.removeAll() }
            return Array(connections.values)
        }
        active.forEach { $0.cancel() }
    }

    func clientClosureCount(for path: String) -> Int {
        lock.withLock {
            clientClosureCounts[path, default: 0]
        }
    }

    private func finishStart(_ result: Result<URL, Error>) {
        let continuation = lock.withLock {
            defer { startContinuation = nil }
            return startContinuation
        }
        continuation?.resume(with: result)
    }

    private func accept(_ connection: NWConnection) {
        lock.withLock {
            connections[ObjectIdentifier(connection)] = connection
        }
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            switch state {
            case .ready:
                self.receiveRequest(on: connection, received: Data())
            case .cancelled, .failed:
                self.remove(connection)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func receiveRequest(
        on connection: NWConnection,
        received: Data
    ) {
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: 64 * 1_024
        ) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            guard error == nil, !isComplete else {
                self.remove(connection)
                connection.cancel()
                return
            }
            var requestData = received
            if let data {
                requestData.append(data)
            }
            guard let request = String(data: requestData, encoding: .utf8),
                  let lineEnd = request.range(of: "\r\n")
            else {
                self.receiveRequest(on: connection, received: requestData)
                return
            }
            let firstLine = String(request[..<lineEnd.lowerBound])
            let path = firstLine.split(separator: " ").dropFirst().first
                .map(String.init)
                ?? "/"
            let response = self.handler(path)
            if response.delay > 0 {
                self.observeClientClosure(on: connection, path: path)
            }
            self.queue.asyncAfter(deadline: .now() + response.delay) {
                self.send(response.body, on: connection, path: path)
            }
        }
    }

    private func observeClientClosure(
        on connection: NWConnection,
        path: String
    ) {
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: 1
        ) { [weak self] _, _, isComplete, error in
            guard let self else { return }
            if isComplete || error != nil {
                self.lock.withLock {
                    self.clientClosureCounts[path, default: 0] += 1
                }
            } else {
                self.observeClientClosure(on: connection, path: path)
            }
        }
    }

    private func send(
        _ body: String,
        on connection: NWConnection,
        path: String
    ) {
        let bodyData = Data(body.utf8)
        let headers = "HTTP/1.1 200 OK\r\n"
            + "Content-Type: application/json\r\n"
            + "Content-Length: \(bodyData.count)\r\n"
            + "Connection: close\r\n\r\n"
        connection.send(
            content: Data(headers.utf8) + bodyData,
            completion: .contentProcessed { [weak self] error in
                guard let self else {
                    connection.cancel()
                    return
                }
                if error != nil {
                    self.lock.withLock {
                        self.clientClosureCounts[path, default: 0] += 1
                    }
                }
                self.remove(connection)
                connection.cancel()
            }
        )
    }

    private func remove(_ connection: NWConnection) {
        _ = lock.withLock {
            connections.removeValue(forKey: ObjectIdentifier(connection))
        }
    }

    private enum ServerError: Error {
        case missingPort
    }
}

private extension NSLock {
    func withLock<T>(_ operation: () -> T) -> T {
        lock()
        defer { unlock() }
        return operation()
    }
}
