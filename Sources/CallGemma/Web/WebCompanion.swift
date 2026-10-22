#if os(macOS)
import AppKit
import CoreImage.CIFilterBuiltins
import Foundation
import Darwin

@MainActor
final class WebCompanion {
    private struct Configuration: Codable {
        var host: String
        var port: UInt16
        var password: String
        var invite: String
        var session: String
        var localInvite: String?
        var localSession: String?
        var publicOrigin: String?
    }
    static let shared = WebCompanion()
    private var localServer: CompanionHTTP?
    private var localReady = false
    private let localPort: UInt16 = 8942
    private var server: CompanionHTTP?
    private var configuration: Configuration?
    private var panel: NSPanel?
    private var model: MessagingModel?
    private var controller: CallController?
    private var remoteCall: RemoteCallTransport?
    private var rtcCall: CompanionRTCCall?
    private var preparingRTC = false
    private var browserAssets: CompanionBrowserAssets?
    private var settingUp = false
    private var ready = false
    private var failure: String?
    private let root = AppQualificationEnvironment.root?.appending(path: "Companion")
        ?? URL.applicationSupportDirectory.appending(path: "Blessenger/Companion")

    func diagnostics() async -> [String: Any] {
        ["ready": ready, "localReady": localReady, "failure": failure ?? "",
         "network": await server?.diagnostics() ?? [:],
         "localNetwork": await localServer?.diagnostics() ?? [:]]
    }

    func start(model: MessagingModel, controller: CallController) {
        guard server == nil else { return }
        self.model = model; self.controller = controller
        let configURL = root.appending(path: "configuration.json")
        guard FileManager.default.fileExists(atPath: configURL.path) else { return }
        do {
            var config = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: configURL))
            guard config.port > 0, config.invite.count >= 64, config.session.count >= 64,
                  !config.host.isEmpty, config.host.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == ".") }) else {
                throw GemmaError(message: "Invalid companion configuration.")
            }
            if config.localInvite == nil || config.localSession == nil {
                config.localInvite = (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "")
                config.localSession = (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "")
                try JSONEncoder().encode(config).write(to: configURL, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
            }
            configuration = config
            if let resources = Bundle.main.resourceURL {
                browserAssets = try CompanionBrowserAssets(root: resources.appending(path: "Browser"))
            }
            localServer = try CompanionHTTP(port: localPort) { [weak self] request in
                await self?.handle(request, local: true) ?? .json(["error": "Host unavailable"], status: 503)
            }
            localServer?.start { [weak self] error in
                Task { @MainActor in self?.localReady = error == nil; if let error { self?.failure = error } }
            }
            server = try CompanionHTTP(identity: Data(contentsOf: root.appending(path: "server.p12")),
                password: config.password, port: config.port) { [weak self] request in
                    await self?.handle(request) ?? .json(["error": "Host unavailable"], status: 503)
                }
            server?.start { [weak self] error in
                Task { @MainActor in self?.ready = error == nil; self?.failure = error }
            }
        } catch { failure = error.localizedDescription }
    }

    func showPairing() {
        guard !settingUp else { return }
        if configuration == nil, failure == nil, let model, let controller {
            settingUp = true
            Task {
                do {
                    let root = self.root
                    try await Task.detached { try CompanionSetup.create(at: root) }.value
                    start(model: model, controller: controller)
                    for _ in 0..<50 {
                        if ready || localReady || failure != nil { break }
                        try await Task.sleep(for: .milliseconds(100))
                    }
                    settingUp = false; showPairing()
                } catch { settingUp = false; failure = error.localizedDescription; showPairing() }
            }
            return
        }

        guard let url = pairingURL() else {
            let alert = NSAlert()
            alert.messageText = "Companion unavailable"
            alert.informativeText = failure ?? "The local listener is not ready."
            alert.runModal(); return
        }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(url.utf8)
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
              let cg = CIContext().createCGImage(output, from: output.extent) else { return }
        let image = NSImageView(frame: NSRect(x: 20, y: 55, width: 300, height: 300))
        image.image = NSImage(cgImage: cg, size: NSSize(width: 300, height: 300))
        image.imageScaling = .scaleProportionallyUpOrDown
        let button = NSButton(title: "Copy", target: self, action: #selector(copyAddress))
        button.frame = NSRect(x: 125, y: 12, width: 90, height: 32)
        button.toolTip = "Copy the private pairing link"
        self.panel?.close()
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 375),
                            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.title = "Blessenger"
        panel.contentView?.addSubview(image); panel.contentView?.addSubview(button)
        panel.center(); panel.makeKeyAndOrderFront(nil); self.panel = panel
    }
    private func pairingURL() -> String? {
        guard let config = configuration else { return nil }
        if let origin = config.publicOrigin {
            // A configured gateway must never silently fall back to HTTP or
            // disclose the TLS pairing credential to a malformed URL.
            guard ready, var url = URLComponents(string: origin),
                  url.scheme == "https", let host = url.host, !host.isEmpty,
                  url.user == nil, url.password == nil,
                  url.query == nil, url.fragment == nil,
                  url.path.isEmpty || url.path == "/" else { return nil }
            url.path = "/"; url.fragment = config.invite
            return url.string
        }
        guard localReady, let invite = config.localInvite else { return nil }
        let host = Self.localAddresses().first ?? config.host
        return "http://\(host):\(localPort)/#\(invite)"
    }
    @objc private func copyAddress() {
        guard let url = pairingURL() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
    }
    /// Prefer Wi-Fi/Ethernet numeric addresses, as in Sing's proven LAN QR flow.
    /// Host admission is refreshed on each request after interface changes.
    private static func localAddresses() -> [String] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return [] }
        defer { freeifaddrs(list) }
        var pointer = list, candidates: [(String, String)] = []
        while let item = pointer {
            defer { pointer = item.pointee.ifa_next }
            guard let address = item.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET),
                  item.pointee.ifa_flags & UInt32(IFF_UP) != 0 else { continue }
            let name = String(cString: item.pointee.ifa_name)
            guard name.hasPrefix("en") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &host,
                           socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                candidates.append((name, String(cString: host)))
            }
        }
        return candidates.sorted { $0.0 < $1.0 }.map(\.1)
    }

    private func admit(_ text: String, attachments: [MessageAttachment], thread: UUID,
                       model: MessagingModel, controller: CallController) async -> CompanionResponse {
        let admitted = AsyncStream<Bool>.makeStream()
        Task { @MainActor in
            let success = await model.send(text, threadID: thread, mentions: [], attachments: attachments, controller: controller,
                onAdmitted: { admitted.continuation.yield(true); admitted.continuation.finish() })
            if !success { admitted.continuation.yield(false); admitted.continuation.finish() }
        }
        for await success in admitted.stream { return .json(["accepted": success], status: success ? 202 : 500) }
        return .json(["error": "Message was not admitted"], status: 500)
    }

    private func handle(_ request: CompanionRequest, local: Bool = false) async -> CompanionResponse {
        guard let config = configuration, let model, let controller else { return .json(["error": "Unavailable"], status: 503) }
        let authority = request.headers["host"]?.lowercased() ?? ""
        let allowed = local ? ([config.host] + Self.localAddresses()).map { "\($0):\(localPort)".lowercased() }
                            : ["\(config.host):\(config.port)".lowercased()]
        guard allowed.contains(authority) else { return .json(["error": "Unknown host"], status: 403) }
        if request.method != "GET" {
            guard request.headers["origin"] == (local ? "http://" : "https://") + authority else {
                return .json(["error": "Origin rejected"], status: 403)
            }
        }
        // Never send the HTTPS credential over the plaintext LAN connection.
        guard let invite = local ? config.localInvite : config.invite,
              let session = local ? config.localSession : config.session else {
            return .json(["error": "Pairing unavailable"], status: 503)
        }
        let cookieName = local ? "blessenger_lan" : "blessenger"
        if local && (request.path.hasPrefix("/api/rtc/") || request.path.hasPrefix("/api/call") || request.path == "/api/note") {
            return .json(["error": "Browser microphone access requires trusted HTTPS."], status: 403)
        }
        if request.path == "/api/pair", request.method == "POST" {
            guard let object = try? JSONSerialization.jsonObject(with: request.body) as? [String: String], object["invite"] == invite else {
                return .json(["error": "Pairing link is invalid"], status: 401)
            }
            var response = CompanionResponse.json(["paired": true])
            response.headers["Set-Cookie"] = "\(cookieName)=\(session); Path=/; HttpOnly; \(local ? "" : "Secure; ")SameSite=Strict; Max-Age=31536000"
            return response
        }
        let resources = ["/": ("companion", "html", "text/html; charset=utf-8"),
            "/app.js": ("companion", "js", "text/javascript"),
            "/style.css": ("companion", "css", "text/css"),
            "/manifest.webmanifest": ("companion", "webmanifest", "application/manifest+json"),
            "/sw.js": ("companion-sw", "js", "text/javascript"),
            "/recorder.js": ("companion-recorder", "js", "text/javascript"),
            "/call-audio.js": ("companion-call-audio", "js", "text/javascript"),
            "/rtc.js": ("companion-rtc", "js", "text/javascript"),
            "/runtime.js": ("companion-runtime", "js", "text/javascript"),
            "/speech-check.html": ("speech-check", "html", "text/html"),
            "/speech-check.js": ("speech-check", "js", "text/javascript"),
            "/icon.png": ("companion-icon", "png", "image/png")]
        if request.method == "GET", let (name, ext, type) = resources[request.path],
           let url = BlessengerResources.bundle.url(forResource: name, withExtension: ext), let data = try? Data(contentsOf: url) {
            return CompanionResponse(type: type, body: data)
        }
        let cookies = (request.headers["cookie"] ?? "").split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
        guard cookies.contains(cookieName + "=" + session) else { return .json(["error": "Scan the Mac’s pairing code"], status: 401) }
        do {
            if request.method == "GET", request.path == "/api/network" {
                return .json(await diagnostics())
            }
            if request.method == "GET", request.path == "/api/runtime", let browserAssets {
                return .json(["base": browserAssets.basePath, "revision": browserAssets.manifest.revision])
            }
            if request.method == "GET", request.path.hasPrefix("/runtime/"), let browserAssets {
                return try await Task.detached {
                    try browserAssets.response(path: request.path) ?? .json(["error": "Runtime asset unavailable"], status: 404)
                }.value
            }
            if request.method == "GET", request.path == "/api/state" {
                await model.load()
                let visible = model.state.threads.filter { $0.deleted != true }
                let ids = Set(visible.map(\.id))
                return .json(["contacts": model.state.contacts.map { ["id": $0.id.uuidString, "name": $0.name, "avatar": "/avatar/" + $0.id.uuidString] },
                    "threads": visible.map { ["id": $0.id.uuidString, "title": $0.title, "participants": $0.participants.map(\.uuidString)] as [String: Any] },
                    "messages": model.state.messages.filter { ids.contains($0.thread) && $0.deleted != true }.map { message in
                        ["id": message.id.uuidString, "thread": message.thread.uuidString, "sender": message.sender?.uuidString ?? "", "text": message.text,
                         "reactions": Array(message.reactions), "attachments": message.attachments.map { ["id": $0.id.uuidString, "name": $0.name, "kind": $0.kind.rawValue, "url": "/attachment/" + $0.id.uuidString] }] as [String: Any]
                    }, "generating": model.generating.map(\.uuidString), "ready": controller.ready, "inCall": controller.inCall])
            }
            if request.method == "GET", request.path.hasPrefix("/avatar/"),
               let id = UUID(uuidString: String(request.path.dropFirst(8))), let contact = model.state.contacts.first(where: { $0.id == id }),
               contact.avatar.hasPrefix("portrait:"), let index = Int(contact.avatar.dropFirst(9)), (0..<14).contains(index),
               let image = BlessengerResources.bundle.image(forResource: "contact-portrait-\(index)"),
               let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) {
                return CompanionResponse(type: "image/png", body: png)
            }
            if request.method == "GET", request.path.hasPrefix("/attachment/"),
               let id = UUID(uuidString: String(request.path.dropFirst(12))),
               let attachment = model.state.messages.filter({ $0.deleted != true }).flatMap(\.attachments).first(where: { $0.id == id }) {
                let data = try await Task.detached { try Data(contentsOf: attachment.url) }.value
                return CompanionResponse(type: attachment.kind == .audio ? "audio/" + (attachment.url.pathExtension == "wav" ? "wav" : "mp4") : "application/octet-stream", body: data)
            }
            if request.method == "POST", request.path == "/api/note" {
                guard let raw = request.headers["x-blessenger-thread"], let id = UUID(uuidString: raw),
                      model.state.threads.contains(where: { $0.id == id && $0.deleted != true }),
                      request.headers["content-type"] == "audio/wav", request.body.count <= 2_000_000 else {
                    throw GemmaError(message: "Invalid voice note.")
                }
                let attachment = try await Task.detached {
                    let temporary = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".wav")
                    try request.body.write(to: temporary, options: .atomic)
                    defer { try? FileManager.default.removeItem(at: temporary) }
                    let duration = try VoiceSample.duration(of: temporary)
                    guard duration <= 60 else { throw GemmaError(message: "Voice notes are limited to one minute.") }
                    return try await AttachmentLibrary().importFile(temporary)
                }.value
                return await admit("", attachments: [attachment], thread: id, model: model, controller: controller)
            }
            guard request.method == "POST", let object = try JSONSerialization.jsonObject(with: request.body) as? [String: Any] else {
                return .json(["error": "Not found"], status: 404)
            }
            switch request.path {
            case "/api/rtc/start":
                guard !preparingRTC, rtcCall == nil || rtcCall?.closed == true,
                      !controller.inCall, !controller.busy else { throw GemmaError(message: "Audio is busy.") }
                preparingRTC = true
                defer { preparingRTC = false }
                let credentials = try await CloudflareTURN.generate()
                guard !controller.inCall, !controller.busy else { throw GemmaError(message: "Audio is busy.") }
                let ice = try JSONEncoder().encode(credentials.iceServers)
                let connection = try CompanionRTCCall(iceServers: ice,
                    echoCancellation: object["echoCancellation"] as? Bool == true) { [weak self] in
                        guard let self, let rtc = self.rtcCall, rtc.admitted, self.remoteCall === rtc.transport else { return }
                        if controller.inCall { controller.toggleCall() }
                    }
                rtcCall = connection
                return .json(["id": connection.id.uuidString, "iceServers": try JSONSerialization.jsonObject(with: ice)])
            case "/api/rtc/offer", "/api/rtc/candidates", "/api/rtc/end", "/api/rtc/report":
                guard let rtc = rtcCall, object["id"] as? String == rtc.id.uuidString else {
                    throw GemmaError(message: "Connection expired.")
                }
                if request.path == "/api/rtc/report" {
                    guard let detail = object["detail"] as? String, let cause = object["cause"] as? Int else {
                        throw GemmaError(message: "Invalid peer diagnostic.")
                    }
                    try rtc.recordBrowserFailure(detail: detail, cause: cause)
                    return .json(["recorded": true])
                }
                if request.path == "/api/rtc/end" {
                    rtc.close()
                    if rtc.admitted { await controller.waitForCallTeardown() }
                    return .json(["closed": true])
                }
                if request.path == "/api/rtc/offer" {
                    guard let offer = object["sdp"] as? String else { throw GemmaError(message: "Missing offer.") }
                    do { return .json(["sdp": try await rtc.answer(offer)]) }
                    catch { rtc.close(); throw error }
                }
                guard let cursor = object["cursor"] as? Int, let candidates = object["candidates"] as? [Any] else {
                    throw GemmaError(message: "Invalid candidates.")
                }
                do { return .json(try rtc.signal(cursor: cursor, candidates: candidates)) }
                catch { rtc.close(); throw error }
            case "/api/ice":
                let credentials = try await CloudflareTURN.generate()
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                return CompanionResponse(type: "application/json", body: try encoder.encode(credentials))
            case "/api/call":
                guard remoteCall == nil || remoteCall?.closed == true,
                      let raw = object["thread"] as? String, let id = UUID(uuidString: raw),
                      let thread = model.state.threads.first(where: { $0.id == id && $0.deleted != true }) else {
                    throw GemmaError(message: "Conversation unavailable.")
                }
                let rtc: CompanionRTCCall?
                if let id = object["rtc"] as? String {
                    guard let connection = rtcCall, !connection.closed, connection.id.uuidString == id else {
                        throw GemmaError(message: "Connection expired.")
                    }
                    rtc = connection
                } else {
                    guard rtcCall == nil || rtcCall?.closed == true else { throw GemmaError(message: "Audio is busy.") }
                    rtc = nil
                }
                let transport = rtc?.transport ?? RemoteCallTransport(echoCancellation: object["echoCancellation"] as? Bool == true)
                let participants = thread.participants.compactMap { id in model.state.contacts.first { $0.id == id } }
                guard participants.count == thread.participants.count else { throw GemmaError(message: "Contact unavailable.") }
                remoteCall = transport
                do {
                    try rtc?.start()
                    try await controller.dialRemote(participants: participants, transport: transport, memoryStore: model.store)
                    rtc?.didDial()
                    if rtc?.closed == true {
                        if controller.inCall { controller.toggleCall() }
                        throw GemmaError(message: "Connection closed during call setup.")
                    }
                } catch { rtc?.close(); transport.close(); throw error }
                return .json(["id": transport.id.uuidString, "epoch": transport.epoch.uuidString])
            case "/api/call/audio":
                guard let transport = remoteCall, object["id"] as? String == transport.id.uuidString else {
                    throw GemmaError(message: "Call expired.")
                }
                if transport.closed || !controller.inCall {
                    transport.close()
                    return .json(["closed": true, "error": controller.notice ?? ""])
                }
                guard let sequence = object["sequence"] as? Int, let samples = object["samples"] as? [Float],
                      let acknowledged = object["acknowledged"] as? [Int], acknowledged.count <= 8,
                      let rawEpoch = object["epoch"] as? String, let epoch = UUID(uuidString: rawEpoch) else {
                    throw GemmaError(message: "Invalid audio packet.")
                }
                return .json(try await transport.exchange(sequence: sequence, samples: samples, acknowledged: acknowledged, epoch: epoch))
            case "/api/call/end":
                guard let transport = remoteCall, object["id"] as? String == transport.id.uuidString else {
                    throw GemmaError(message: "Call expired.")
                }
                if !transport.closed, controller.inCall { controller.toggleCall() }
                transport.close()
                if rtcCall?.transport === transport { rtcCall?.close() }
                await controller.waitForCallTeardown()
                return .json(["closed": true])
            case "/api/chats":
                guard let raw = object["contacts"] as? [String], !raw.isEmpty, raw.count <= 14 else { throw GemmaError(message: "Choose a contact.") }
                let ids = raw.compactMap(UUID.init(uuidString:))
                guard ids.count == raw.count, ids.allSatisfy({ id in model.state.contacts.contains { $0.id == id } }),
                      let id = await model.createChat(contacts: ids) else { throw GemmaError(message: "Could not create conversation.") }
                return .json(["id": id.uuidString])
            case "/api/send":
                guard let raw = object["thread"] as? String, let id = UUID(uuidString: raw),
                      model.state.threads.contains(where: { $0.id == id && $0.deleted != true }),
                      let text = object["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      text.utf8.count <= 65_536 else { throw GemmaError(message: "Invalid message.") }
                return await admit(text, attachments: [], thread: id, model: model, controller: controller)
            case "/api/rename":
                guard let raw = object["thread"] as? String, let id = UUID(uuidString: raw),
                      var thread = model.state.threads.first(where: { $0.id == id && $0.deleted != true }),
                      let title = object["title"] as? String, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      title.count <= 120 else { throw GemmaError(message: "Invalid conversation name.") }
                thread.title = title; await model.updateThread(thread)
                return .json(["updated": true])
            case "/api/react":
                guard let raw = object["message"] as? String, let id = UUID(uuidString: raw),
                      let message = model.state.messages.first(where: { $0.id == id && $0.deleted != true }),
                      let emoji = object["emoji"] as? String, emoji.count == 1, emoji.utf8.count <= 32 else {
                    throw GemmaError(message: "Invalid reaction.")
                }
                await model.react(message, emoji: emoji)
                return .json(["updated": true])
            default: return .json(["error": "Not found"], status: 404)
            }
        } catch { return .json(["error": error.localizedDescription], status: 400) }
    }
}
#endif
