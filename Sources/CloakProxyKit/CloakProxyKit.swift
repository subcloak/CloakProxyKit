import Foundation

/// Shows this app's URLSession traffic in Cloak Proxy on your Mac, with no proxy settings or certificate.
///
/// ```swift
/// #if DEBUG
/// import CloakProxyKit
/// #endif
///
/// // At launch:
/// #if DEBUG
/// CloakProxyKit.start()
/// #endif
/// ```
///
/// The app finds Cloak Proxy over Bonjour on the local network and waits for you to allow it on the Mac. Until then,
/// and whenever the Mac is away, finished requests wait in a bounded buffer. Nothing here throws, blocks the app or
/// changes its requests. In Release builds `start()` does nothing unless `Options.enabledInReleaseBuilds` is set.
public enum CloakProxyKit {
    /// The SDK's version, sent to the Mac.
    public static let version = "0.3.0"

    public struct Options {
        /// Connect only to the Mac with this name (its Bonjour name, usually the Mac's name in Sharing settings).
        public var macName: String?
        /// Connect only to a Mac whose Cloak Proxy certificate fingerprint starts with this (lowercase hex, at
        /// least 16 characters). Settings › In-app SDK on the Mac shows it.
        public var macFingerprint: String?
        /// Skip Bonjour and connect to this address and port, for networks where Bonjour doesn't work.
        public var host: String?
        public var port: Int
        /// The most of each request and response body kept, in bytes. 0 sends no bodies. At most 4 MB.
        public var maxBodySize: Int
        /// While the Mac is away (or hasn't allowed the app yet), keep at most this many finished requests…
        public var maxBufferedRequests: Int
        /// …and at most about this many bytes of them. The oldest go first.
        public var maxBufferedBytes: Int
        /// Requests to these hosts aren't recorded ("example.com" covers its subdomains too).
        public var ignoredHosts: [String]
        /// The name shown in Cloak Proxy, instead of the bundle's display name.
        public var appName: String?
        /// A square PNG to show instead of the app icon. Command-line tools have no icon of their own.
        public var appIcon: Data?
        /// Run in builds without the DEBUG flag too. Off: Release builds send nothing.
        public var enabledInReleaseBuilds: Bool

        public init(macName: String? = nil, macFingerprint: String? = nil, host: String? = nil, port: Int = 9092,
                    maxBodySize: Int = 1 << 20, maxBufferedRequests: Int = 500, maxBufferedBytes: Int = 16 << 20,
                    ignoredHosts: [String] = [], appName: String? = nil, appIcon: Data? = nil, enabledInReleaseBuilds: Bool = false) {
            self.macName = macName
            self.macFingerprint = macFingerprint
            self.host = host
            self.port = port
            self.maxBodySize = maxBodySize
            self.maxBufferedRequests = maxBufferedRequests
            self.maxBufferedBytes = maxBufferedBytes
            self.ignoredHosts = ignoredHosts
            self.appName = appName
            self.appIcon = appIcon
            self.enabledInReleaseBuilds = enabledInReleaseBuilds
        }
    }

    public enum State: Equatable, Sendable {
        case stopped
        /// Looking for Cloak Proxy over Bonjour, or waiting to retry.
        case searching
        case connecting
        /// Connected; someone at the Mac has to allow this app.
        case waitingForApproval(mac: String)
        case connected(mac: String)
        /// The Mac said no. It's asked again in a minute, in case that changes in Settings.
        case blocked(mac: String)
    }

    /// Starts recording URLSession traffic and sending it to Cloak Proxy. Calling it again restarts with new options.
    public static func start(_ options: Options = Options()) {
        #if !DEBUG
        guard options.enabledInReleaseBuilds else { return }
        #endif
        KitEngine.shared.start(options)
    }

    /// Stops recording and disconnects. Requests not yet sent are dropped.
    public static func stop() {
        KitEngine.shared.stop()
    }

    public static var state: State { KitEngine.shared.state }

    /// Finished requests waiting to reach the Mac (or for it to confirm them).
    public static var unsentCount: Int { KitEngine.shared.unsentCount }

    /// False when this OS's URLSession lacks the methods recording relies on; nothing is recorded then.
    public static var isCapturing: Bool { KitEngine.shared.isCapturing }
}
