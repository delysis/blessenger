#if os(macOS)
import Foundation
import Network
import Security

struct CompanionRequest: Sendable {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data
}
struct CompanionResponse: Sendable {
    var status = 200
    var type = "application/json"
    var headers: [String: String] = [:]
    var body = Data()
    static func json(_ value: Any, status: Int = 200) -> Self {
        Self(status: status, body: (try? JSONSerialization.data(withJSONObject: value)) ?? Data("{}".utf8))
    }
}

/// One bounded HTTP request per connection. No arbitrary file routes or debug commands.
final class CompanionHTTP: @unchecked Sendable {
    private let listener: NWListener
    private var connections: [UUID: NWConnection] = [:]
    private var deadlines: [ObjectIdentifier: UUID] = [:]
    private var counters: [String: Int] = [:]
    private let queue = DispatchQueue(label: "blessenger.companion.network")
    private let handler: @Sendable (CompanionRequest) async -> CompanionResponse
    init(identity: Data? = nil, password: String = "", port: UInt16,
         handler: @escaping @Sendable (CompanionRequest) async -> CompanionResponse) throws {
        let parameters: NWParameters
        if let identity {
        var imported: CFArray?
        // The encrypted identity already has app-owned persistence. Reimporting
        // it into the login keychain binds TLS signing to a previous executable's
        // access control and can stall handshakes after a rebuild.
        guard SecPKCS12Import(identity as CFData, [kSecImportExportPassphrase as String: password,
                                                  kSecImportToMemoryOnly as String: true] as CFDictionary, &imported) == errSecSuccess,
              let entries = imported as? [[String: Any]], let raw = entries.first?[kSecImportItemIdentity as String],
              CFGetTypeID(raw as CFTypeRef) == SecIdentityGetTypeID() else {
            throw GemmaError(message: "The companion TLS identity could not be loaded.")
        }
        let identity = raw as! SecIdentity
        guard let secured = sec_identity_create(identity) else { throw GemmaError(message: "Invalid TLS identity.") }
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, secured)
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        parameters = NWParameters(tls: tls)
        } else {
            parameters = .tcp
        }
        parameters.includePeerToPeer = true
        listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
        listener.service = NWListener.Service(name: identity == nil ? "Blessenger Local" : "Blessenger", type: "_blessenger._tcp")
        self.handler = handler
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            guard self.connections.count < 32 else { connection.cancel(); return }
            let id = UUID()
            self.connections[id] = connection
            self.counters["accepted", default: 0] += 1
            connection.stateUpdateHandler = { [weak self, weak connection] state in
                if case .ready = state { self?.counters["ready", default: 0] += 1 }
                if case .failed = state { self?.counters["failed", default: 0] += 1 }
                if case .cancelled = state {
                    self?.connections.removeValue(forKey: id)
                    if let connection { self?.deadlines.removeValue(forKey: ObjectIdentifier(connection)) }
                }
            }
            connection.start(queue: self.queue)
            self.receive(connection, accumulated: Data())
            self.refreshDeadline(connection)
        }
    }
    func start(onState: @escaping @Sendable (String?) -> Void) {
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: onState(nil)
            case .waiting(let error): onState(error.localizedDescription)
            case .failed(let error): onState(error.localizedDescription)
            default: break
            }
        }
        listener.start(queue: queue)
    }
    func stop() { listener.cancel() }
    // Only aggregate counts leave the network queue. No endpoints, headers,
    // cookies, pairing secrets, or request bodies are exposed by diagnostics.
    func diagnostics() async -> [String: Int] {
        await withCheckedContinuation { continuation in
            queue.async {
                var result = self.counters
                result["active"] = self.connections.count
                continuation.resume(returning: result)
            }
        }
    }
    private func receive(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, ended, error in
            guard let self else { return }
            var bytes = accumulated
            if let data { bytes.append(data) }
            guard bytes.count <= 16_800_000 else { self.send(connection, .json(["error": "Request too large"], status: 413)); return }
            guard let end = bytes.range(of: Data("\r\n\r\n".utf8)) else {
                if bytes.count > 16_384 || ended || error != nil { connection.cancel() }
                else { self.receive(connection, accumulated: bytes) }
                return
            }
            let lines = String(decoding: bytes[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
            let first = (lines.first ?? "").split(separator: " ")
            guard end.lowerBound <= 16_384, first.count == 3, first[2] == "HTTP/1.1",
                  first[1].hasPrefix("/"), !first[1].hasPrefix("//"),
                  let url = URLComponents(string: String(first[1])) else { connection.cancel(); return }
            var headers: [String: String] = [:]
            for line in lines.dropFirst() {
                guard let colon = line.firstIndex(of: ":") else { connection.cancel(); return }
                let name = line[..<colon].lowercased()
                guard headers[name] == nil else { connection.cancel(); return }
                headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            guard headers["transfer-encoding"] == nil,
                  let size = Int(headers["content-length"] ?? "0"), (0...16_777_216).contains(size) else {
                self.send(connection, .json(["error": "Invalid request length"], status: 400)); return
            }
            guard bytes.count - end.upperBound >= size else {
                if ended || error != nil { connection.cancel() } else { self.receive(connection, accumulated: bytes) }
                return
            }
            let request = CompanionRequest(method: String(first[0]), path: url.path, headers: headers,
                body: bytes.subdata(in: end.upperBound..<(end.upperBound + size)))
            self.counters["requests", default: 0] += 1
            Task { self.send(connection, await self.handler(request)) }
        }
    }
    private func send(_ connection: NWConnection, _ response: CompanionResponse) {
        queue.async { self.sendOnQueue(connection, response) }
    }
    private func refreshDeadline(_ connection: NWConnection) {
        let key = ObjectIdentifier(connection), token = UUID()
        deadlines[key] = token
        queue.asyncAfter(deadline: .now() + 20) { [weak self, weak connection] in
            guard let self, let connection, self.deadlines[key] == token else { return }
            self.counters["timedOut", default: 0] += 1
            connection.cancel()
        }
    }
    private func sendOnQueue(_ connection: NWConnection, _ response: CompanionResponse) {
        guard deadlines[ObjectIdentifier(connection)] != nil else { return }
        counters["responses", default: 0] += 1
        refreshDeadline(connection)
        var head = "HTTP/1.1 \(response.status) Response\r\nContent-Type: \(response.type)\r\nContent-Length: \(response.body.count)\r\nConnection: close\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nReferrer-Policy: no-referrer\r\n"
        head += "Content-Security-Policy: default-src 'self'; img-src 'self' blob:; media-src 'self' blob:; style-src 'self'; script-src 'self' 'wasm-unsafe-eval'; worker-src 'self'; connect-src 'self'; frame-ancestors 'none'\r\n"
        head += "Permissions-Policy: microphone=(self), camera=()\r\n"
        for (name, value) in response.headers { head += "\(name): \(value)\r\n" }
        connection.send(content: Data((head + "\r\n").utf8), completion: .contentProcessed { error in
            if error != nil { connection.cancel(); return }
            self.sendBody(connection, response.body, offset: 0)
        })
    }
    private func sendBody(_ connection: NWConnection, _ body: Data, offset: Int) {
        guard deadlines[ObjectIdentifier(connection)] != nil else { return }
        refreshDeadline(connection)
        // A model download must not duplicate its entire mapped file in RAM or
        // enqueue it all into Network.framework. Keep one bounded write in flight.
        let end = min(offset + 65_536, body.count)
        let final = end == body.count
        connection.send(content: body.subdata(in: offset..<end),
                        contentContext: final ? .finalMessage : .defaultMessage, isComplete: true,
                        completion: .contentProcessed { error in
            if error != nil { connection.cancel(); return }
            if final {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { _, _, _, _ in connection.cancel() }
            } else { self.sendBody(connection, body, offset: end) }
        })
    }
}
#endif
