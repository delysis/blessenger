#if os(macOS)
import Foundation
import Security

/// Only the Mac reads the long-lived TURN key. Paired clients receive expiring
/// ICE credentials, never the provider token or a Cloudflare account API key.
enum CloudflareTURN {
    static let keychainService = "Blessenger.CloudflareTURN.AppOwned"
    private static let legacyKeychainService = "Blessenger.CloudflareTURN"
    static let keychainAccount = "credentials"
    struct Key: Codable, Sendable {
        let id: String
        let token: String
    }
    struct Server: Codable, Sendable {
        let urls: [String]
        let username: String?
        let credential: String?
    }
    struct Credentials: Codable, Sendable {
        let iceServers: [Server]
        let expiresAt: Date?
        let turnConfigured: Bool
    }
    private struct ProviderResponse: Decodable { let iceServers: [Server] }
    static let stun = Server(urls: ["stun:stun.cloudflare.com:3478"], username: nil, credential: nil)

    static func loadKey() throws -> Key? {
        let started = ContinuousClock.now
        defer { NSLog("Blessenger TURN Keychain read: %@", String(describing: started.duration(to: .now))) }
        if let data = try readKey(service: keychainService) { return try validatedKey(data) }
        guard let data = try readKey(service: legacyKeychainService) else { return nil }
        let key = try validatedKey(data)
        // The CLI-imported item belongs to apple-tool:, causing an authorization
        // dialog on every signed app launch. Create from this signed process so
        // Keychain assigns its normal app identity. Preserve the original item.
        let attributes: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService, kSecAttrAccount as String: keychainAccount,
            kSecAttrLabel as String: "Blessenger TURN", kSecValueData as String: data]
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess || status == errSecDuplicateItem else {
            throw GemmaError(message: "Could not save Blessenger’s TURN credential in Keychain.")
        }
        // A racing launch may have saved a different key; use the stored value.
        guard let saved = try readKey(service: keychainService) else {
            throw GemmaError(message: "Could not read Blessenger’s saved TURN credential.")
        }
        NSLog("Blessenger TURN app-owned Keychain item ready")
        return status == errSecSuccess ? key : try validatedKey(saved)
    }

    private static func readKey(service: String) throws -> Data? {
        var result: CFTypeRef?
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw GemmaError(message: "Cloudflare TURN credentials are unavailable in Keychain.")
        }
        return data
    }

    private static func validatedKey(_ data: Data) throws -> Key {
        let key = try JSONDecoder().decode(Key.self, from: data)
        guard !key.id.isEmpty, key.id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }),
              !key.token.isEmpty, !key.token.contains(where: { $0.isWhitespace }) else {
            throw GemmaError(message: "Invalid Cloudflare TURN configuration.")
        }
        return key
    }

    private static let cache = CloudflareTURNCredentialCache(load: loadKey, issue: issue)

    static func generate() async throws -> Credentials {
        try await cache.generate()
    }

    static func issue(_ key: Key) async throws -> Credentials {
        let started = ContinuousClock.now
        defer { NSLog("Blessenger TURN provider issuance: %@", String(describing: started.duration(to: .now))) }
        let ttl = 3600
        let issuedAt = Date()
        let url = URL(string: "https://rtc.live.cloudflare.com/v1/turn/keys/\(key.id)/credentials/generate-ice-servers")!
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("Bearer " + key.token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["ttl": ttl])
        let configuration = URLSessionConfiguration.ephemeral
        // The request timeout is an inactivity timeout, not a total deadline.
        // Bound the entire provider transfer below the companion's 20 s request
        // deadline so a slow provider can produce an error response instead of
        // letting the local HTTPS connection expire without a response.
        configuration.timeoutIntervalForResource = 15
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 201 else {
            // Do not forward provider bodies: they may contain credential details.
            throw GemmaError(message: "Cloudflare could not issue TURN credentials.")
        }
        return try decode(data, expiresAt: issuedAt.addingTimeInterval(TimeInterval(ttl)))
    }

    static func decode(_ data: Data, expiresAt: Date) throws -> Credentials {
        guard data.count <= 65_536 else { throw GemmaError(message: "Invalid Cloudflare TURN response.") }
        let response = try JSONDecoder().decode(ProviderResponse.self, from: data)
        var servers = [stun]
        for server in response.iceServers {
            let urls = server.urls.filter { value in
                guard let schemeEnd = value.firstIndex(of: ":") else { return false }
                let scheme = String(value[..<schemeEnd])
                guard scheme == "turn" || scheme == "turns",
                      let components = URLComponents(string: scheme + "://" + value[value.index(after: schemeEnd)...]),
                      components.host == "turn.cloudflare.com", components.user == nil, components.password == nil,
                      components.path.isEmpty, components.fragment == nil,
                      let port = components.port, [3478, 443, 80, 5349].contains(port) else { return false }
                return components.query == "transport=udp" || components.query == "transport=tcp"
            }
            guard !urls.isEmpty else { continue }
            guard let username = server.username, !username.isEmpty,
                  let credential = server.credential, !credential.isEmpty else {
                throw GemmaError(message: "Cloudflare returned incomplete TURN credentials.")
            }
            servers.append(Server(urls: urls, username: username, credential: credential))
        }
        guard servers.count > 1 else { throw GemmaError(message: "Cloudflare returned no usable TURN servers.") }
        return Credentials(iceServers: servers, expiresAt: expiresAt, turnConfigured: true)
    }
}

/// Read Keychain once after successful access. Reuse short-lived credentials
/// until one minute before expiry, and coalesce simultaneous refresh requests.
actor CloudflareTURNCredentialCache {
    typealias Key = CloudflareTURN.Key
    typealias Credentials = CloudflareTURN.Credentials
    private let load: @Sendable () throws -> Key?
    private let issue: @Sendable (Key) async throws -> Credentials
    private let now: @Sendable () -> Date
    private var key: Key?
    private var cached: Credentials?
    private var inFlight: Task<Credentials, Error>?

    init(load: @escaping @Sendable () throws -> Key?,
         issue: @escaping @Sendable (Key) async throws -> Credentials,
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.load = load; self.issue = issue; self.now = now
    }

    func generate() async throws -> Credentials {
        if let cached, let expiry = cached.expiresAt, expiry.timeIntervalSince(now()) > 60 {
            return cached
        }
        if let inFlight { return try await inFlight.value }
        let task = Task { () throws -> Credentials in
            if key == nil { key = try load() }
            guard let key else {
                return Credentials(iceServers: [CloudflareTURN.stun], expiresAt: nil, turnConfigured: false)
            }
            return try await issue(key)
        }
        inFlight = task
        defer { inFlight = nil }
        let value = try await task.value
        cached = value
        return value
    }
}
#endif
