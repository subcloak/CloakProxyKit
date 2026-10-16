import Foundation
import Network
import os

/// Records finished requests, finds Cloak Proxy over Bonjour and sends them. Everything but `start`, `stop` and the
/// capture callback runs on `queue`.
final class KitEngine: @unchecked Sendable {
    static let shared = KitEngine()

    let queue = DispatchQueue(label: "com.subcloak.cloakproxykit", qos: .utility)
    private let log = Logger(subsystem: "com.subcloak.cloakproxykit", category: "CloakProxyKit")
    private let lock = NSLock()
    private var _state: CloakProxyKit.State = .stopped
    private var _isCapturing = false

    var state: CloakProxyKit.State {
        lock.lock()
        defer { lock.unlock() }
        return _state
    }

    var isCapturing: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isCapturing
    }

    var unsentCount: Int { queue.sync { buffer.records.count } }

    // MARK: Owned by `queue`

    private var options = CloakProxyKit.Options()
    private var running = false
    private var info: AppInfo?
    /// Random per launch; with `nextSeq` it lets the Mac skip records it already has after a reconnect.
    private let session = UUID().uuidString
    private var nextSeq = 1
    private var buffer = RecordBuffer(maxCount: 500, maxBytes: 16 << 20)
    private var browser: NWBrowser?
    private var services: [NWBrowser.Result] = []
    private var link: KitLink?
    private var allowed = false
    /// The last seq of the batch waiting for its ack.
    private var inFlight: Int?
    private var retryDelay: TimeInterval = 0.5
    /// Bumped to cancel a scheduled retry.
    private var retryToken = 0
    private var retryPending = false
    private var reportedDrops = 0
    private var observingForeground = false

    // MARK: Start and stop

    func start(_ requested: CloakProxyKit.Options) {
        var options = requested
        options.maxBodySize = min(max(options.maxBodySize, 0), 4 << 20)
        options.maxBufferedRequests = max(options.maxBufferedRequests, 1)
        options.maxBufferedBytes = max(options.maxBufferedBytes, 64 << 10)
        let capturing = URLSessionCapture.install()
        lock.lock()
        _isCapturing = capturing
        lock.unlock()
        if !capturing { log.error("CloakProxyKit can't record URLSession on this OS version. Nothing will be sent.") }
        URLSessionCapture.settings = .init(enabled: capturing, maxBodySize: options.maxBodySize, ignoredHosts: options.ignoredHosts)
        URLSessionCapture.onFinish = { [weak self] task, capture, error in self?.finished(task, capture, error) }
        // UIKit wants the main thread for the device and the icon.
        let begin = { [self] in
            let info = AppInfo.collect(options: options)
            queue.async { self.begin(options, info) }
        }
        if Thread.isMainThread { begin() } else { DispatchQueue.main.async(execute: begin) }
    }

    func stop() {
        URLSessionCapture.settings.enabled = false
        queue.async { [self] in
            running = false
            tearDown()
            buffer.removeAll()
            setState(.stopped)
        }
    }

    private func begin(_ options: CloakProxyKit.Options, _ info: AppInfo) {
        tearDown()
        self.options = options
        self.info = info
        running = true
        buffer.maxCount = options.maxBufferedRequests
        buffer.maxBytes = options.maxBufferedBytes
        retryDelay = 0.5
        setState(.searching)
        observeForeground()
        if options.host == nil { startBrowser() }
        connectNext()
    }

    private func tearDown() {
        retryToken += 1
        retryPending = false
        browser?.cancel()
        browser = nil
        services = []
        link?.close()
        link = nil
        allowed = false
        inFlight = nil
    }

    private func setState(_ state: CloakProxyKit.State) {
        lock.lock()
        let changed = _state != state
        _state = state
        lock.unlock()
        guard changed else { return }
        switch state {
        case .waitingForApproval(let mac): log.notice("Waiting for you to allow this app in Cloak Proxy on \(mac, privacy: .public)")
        case .connected(let mac): log.notice("Sending requests to Cloak Proxy on \(mac, privacy: .public)")
        case .blocked(let mac): log.notice("Cloak Proxy on \(mac, privacy: .public) blocked this app. Unblock it in Settings › In-app SDK.")
        default: break
        }
    }

    /// iOS drops connections in the background; try again as soon as the app is back.
    private func observeForeground() {
        guard !observingForeground else { return }
        observingForeground = true
        for name in ["UIApplicationWillEnterForegroundNotification", "NSApplicationDidBecomeActiveNotification"] {
            NotificationCenter.default.addObserver(forName: Notification.Name(name), object: nil, queue: nil) { [weak self] _ in
                guard let self else { return }
                queue.async { self.reconnectNow() }
            }
        }
    }

    private func reconnectNow() {
        guard running, link == nil else { return }
        retryToken += 1
        retryPending = false
        retryDelay = 0.5
        connectNext()
    }

    // MARK: Records

    private func finished(_ task: URLSessionTask, _ capture: TaskCapture, _ error: Error?) {
        queue.async { [self] in
            guard running else { return }
            var record = RecordBuilder.record(task: task, capture: capture, error: error)
            record.seq = nextSeq
            nextSeq += 1
            buffer.append(record)
            if buffer.dropped > reportedDrops, !allowed {
                reportedDrops = buffer.dropped
                if reportedDrops == 1 || reportedDrops % 100 == 0 {
                    log.info("The Mac isn't connected; dropped \(self.reportedDrops) older requests to stay within the buffer")
                }
            }
            pump()
        }
    }

    /// Sends the next batch when the Mac has allowed us and the previous batch was acknowledged.
    private func pump() {
        guard allowed, let link, inFlight == nil else { return }
        let batch = buffer.batch(after: 0)
        guard let seq = batch.last?.seq else { return }
        inFlight = seq
        link.send(.records(batch))
        // No ack for a long time: the connection is probably dead without having said so.
        queue.asyncAfter(deadline: .now() + 30) { [weak self, weak link] in
            guard let self, let link, link === self.link, inFlight == seq else { return }
            drop(link, reason: "no answer from the Mac")
        }
    }

    // MARK: Finding the Mac

    private func startBrowser() {
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: KitWire.serviceType, domain: nil), using: NWParameters())
        browser.browseResultsChangedHandler = { [weak self, weak browser] results, _ in
            guard let self, let browser, browser === self.browser else { return }
            services = Array(results)
            if link == nil, !retryPending { connectNext() }
        }
        browser.stateUpdateHandler = { [weak self, weak browser] state in
            guard let self, let browser, browser === self.browser else { return }
            switch state {
            case .failed(let error):
                log.error("Bonjour browsing failed: \(String(describing: error), privacy: .public). Check NSBonjourServices in Info.plist.")
                browser.cancel()
                self.browser = nil
                // Try browsing again later; the network may come back.
                let token = retryToken
                queue.asyncAfter(deadline: .now() + 15) { [weak self] in
                    guard let self, running, token == retryToken, self.browser == nil, options.host == nil else { return }
                    startBrowser()
                }
            case .waiting(let error):
                log.info("Bonjour browsing is waiting: \(String(describing: error), privacy: .public)")
            default:
                break
            }
        }
        self.browser = browser
        browser.start(queue: queue)
    }

    private struct Candidate {
        var endpoint: NWEndpoint
        var name: String
        /// The start of the Mac's certificate fingerprint, from its TXT record.
        var fingerprint: String?
    }

    /// Where to connect: the configured host, else the best Mac found over Bonjour (one that allowed this app before
    /// first, then by name).
    private func candidates() -> [Candidate] {
        if let host = options.host {
            guard let port = NWEndpoint.Port(rawValue: UInt16(clamping: options.port)) else { return [] }
            return [Candidate(endpoint: .hostPort(host: NWEndpoint.Host(host), port: port), name: host, fingerprint: nil)]
        }
        let remembered = Array(Pairings.all.keys)
        var found: [Candidate] = []
        for result in services {
            guard case .service(let serviceName, _, _, _) = result.endpoint else { continue }
            var txtName: String?, fingerprint: String?, version: String?
            if case .bonjour(let txt) = result.metadata {
                txtName = txt["name"]
                fingerprint = txt["fp"]?.lowercased()
                version = txt["pv"]
            }
            if let version, Int(version) != KitWire.version { continue }
            let name = txtName ?? serviceName
            if let wanted = options.macName, wanted.caseInsensitiveCompare(name) != .orderedSame,
               wanted.caseInsensitiveCompare(serviceName) != .orderedSame { continue }
            if let wanted = options.macFingerprint?.lowercased(), let fingerprint,
               !(wanted.hasPrefix(fingerprint) || fingerprint.hasPrefix(wanted)) { continue }
            found.append(Candidate(endpoint: result.endpoint, name: name, fingerprint: fingerprint))
        }
        func known(_ candidate: Candidate) -> Bool {
            guard let fingerprint = candidate.fingerprint, !fingerprint.isEmpty else { return false }
            return remembered.contains { $0.hasPrefix(fingerprint) }
        }
        return found.sorted { (known($0) ? 0 : 1, $0.name) < (known($1) ? 0 : 1, $1.name) }
    }

    private func connectNext() {
        guard running, link == nil, let info else { return }
        guard let candidate = candidates().first else {
            setState(.searching)
            // With a fixed host, keep retrying; with Bonjour, the browser calls back when a Mac appears.
            if options.host != nil { scheduleRetry() }
            return
        }
        setState(.connecting)
        let expected = options.macFingerprint?.lowercased() ?? candidate.fingerprint
        let link = KitLink(endpoint: candidate.endpoint, expectedFingerprint: expected, queue: queue)
        self.link = link
        allowed = false
        inFlight = nil
        link.onReady = { [weak self, weak link] in
            guard let self, let link, link === self.link else { return }
            let token = link.fingerprint.flatMap { Pairings.all[$0] }
            link.send(.hello(KitHello(protocolVersion: KitWire.version, sdkVersion: CloakProxyKit.version, session: session,
                                      token: token, app: info.app, device: info.device)))
        }
        link.onMessage = { [weak self, weak link] message in
            guard let self, let link, link === self.link else { return }
            handle(message, from: link, candidate: candidate)
        }
        link.onClose = { [weak self, weak link] reason in
            guard let self, let link, link === self.link else { return }
            closed(link, reason: reason)
        }
        link.start()
    }

    private func handle(_ message: KitMessage, from link: KitLink, candidate: Candidate) {
        switch message.type {
        case "status":
            guard let status = message.status else { return }
            let mac = status.macName.isEmpty ? candidate.name : status.macName
            switch status.state {
            case "allowed":
                if let token = status.token, let fingerprint = link.fingerprint { Pairings.save(token, for: fingerprint) }
                allowed = true
                retryDelay = 0.5
                setState(.connected(mac: mac))
                if status.needIcon == true, let icon = info?.iconPNG, icon.count <= KitWire.maxIconBytes { link.send(.icon(icon)) }
                pump()
            case "blocked":
                allowed = false
                setState(.blocked(mac: mac))
                link.onClose = nil
                link.close()
                self.link = nil
                // Ask again now and then, in case it's unblocked on the Mac.
                scheduleRetry(after: 60)
            default:
                setState(.waitingForApproval(mac: mac))
            }
        case "ack":
            guard let seq = message.ack else { return }
            buffer.acknowledge(through: seq)
            if let inFlight, seq >= inFlight { self.inFlight = nil }
            pump()
        default:
            break
        }
    }

    private func drop(_ link: KitLink, reason: String) {
        link.onClose = nil
        link.close()
        closed(link, reason: reason)
    }

    private func closed(_ link: KitLink, reason: String) {
        guard link === self.link else { return }
        self.link = nil
        allowed = false
        inFlight = nil
        log.info("Disconnected from Cloak Proxy: \(reason, privacy: .public)")
        guard running else { return }
        setState(.searching)
        scheduleRetry()
    }

    private func scheduleRetry(after fixed: TimeInterval? = nil) {
        guard running else { return }
        retryToken += 1
        let token = retryToken
        retryPending = true
        let delay = fixed ?? retryDelay * Double.random(in: 0.8...1.2)
        if fixed == nil { retryDelay = min(retryDelay * 2, 15) }
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, token == retryToken else { return }
            retryPending = false
            connectNext()
        }
    }
}

/// The tokens Macs gave this app when they allowed it, by the Mac's certificate fingerprint.
enum Pairings {
    private static let key = "CloakProxyKit.tokens"

    static var all: [String: String] {
        UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
    }

    static func save(_ token: String, for fingerprint: String) {
        var tokens = all
        tokens[fingerprint] = token
        UserDefaults.standard.set(tokens, forKey: key)
    }
}

/// One TLS connection to a Mac, speaking length-prefixed JSON.
final class KitLink {
    let connection: NWConnection
    private let queue: DispatchQueue
    private let expectedFingerprint: String?
    /// The Mac's certificate fingerprint (lowercase hex SHA-256 of its DER), once TLS has checked it.
    var fingerprint: String? { seen.value }
    private let seen: Seen
    var onReady: (() -> Void)?
    var onMessage: ((KitMessage) -> Void)?
    var onClose: ((String) -> Void)?
    private var received = Data()
    private var isClosed = false
    private var isReady = false

    init(endpoint: NWEndpoint, expectedFingerprint: String?, queue: DispatchQueue) {
        self.queue = queue
        self.expectedFingerprint = expectedFingerprint
        let seen = Seen()
        self.seen = seen
        let tls = NWProtocolTLS.Options()
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 10
        tcp.keepaliveInterval = 5
        tcp.keepaliveCount = 3
        tcp.connectionTimeout = 10
        // The Mac's certificate is self-signed: check it by fingerprint instead of against the system's roots.
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        let expected = expectedFingerprint
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, trust, complete in
            let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
            guard let chain = SecTrustCopyCertificateChain(secTrust) as? [SecCertificate], let leaf = chain.first else {
                complete(false)
                return
            }
            let fingerprint = AppInfo.hash(SecCertificateCopyData(leaf) as Data)
            seen.value = fingerprint
            complete(expected.map { fingerprint.hasPrefix($0) } ?? true)
        }, queue)
        let parameters = NWParameters(tls: tls, tcp: tcp)
        parameters.preferNoProxies = true
        connection = NWConnection(to: endpoint, using: parameters)
    }

    /// Written by the TLS verify block, on the same queue as everything else.
    private final class Seen {
        var value: String?
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                isReady = true
                onReady?()
                receive()
            case .waiting(let error), .failed(let error):
                fail(String(describing: error))
            case .cancelled:
                fail("closed")
            default:
                break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let self, !isReady else { return }
            fail("timed out")
        }
    }

    func send(_ message: KitMessage) {
        guard !isClosed, let data = try? KitWire.encode(message) else { return }
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            if let error { self?.fail(String(describing: error)) }
        })
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        connection.stateUpdateHandler = nil
        connection.cancel()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            guard let self, !isClosed else { return }
            if let data, !data.isEmpty {
                received.append(data)
                do {
                    for payload in try KitWire.unframe(&received) {
                        guard let message = try? KitWire.decoder().decode(KitMessage.self, from: payload) else { continue }
                        onMessage?(message)
                        if isClosed { return }
                    }
                } catch {
                    fail("the Mac sent a message that's too large")
                    return
                }
            }
            if let error {
                fail(String(describing: error))
            } else if isComplete {
                fail("the Mac closed the connection")
            } else {
                receive()
            }
        }
    }

    private func fail(_ reason: String) {
        guard !isClosed else { return }
        close()
        onClose?(reason)
    }
}
