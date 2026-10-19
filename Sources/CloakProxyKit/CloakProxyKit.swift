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
/// changes its requests.
///
/// The recording code reads URLSession's private internals, so it's compiled only with the DEBUG flag (Xcode's Debug
/// configuration, `swift build` without `-c release`). In Release and App Store builds the package contains none of it
/// and `start()` does nothing; `isRecordingCompiledIn` says which kind of build this is.
public enum CloakProxyKit {
    /// The SDK's version, sent to the Mac.
    public static let version = "0.4.0"

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
        /// No longer has any effect: since 0.4.0 the recording code is compiled only with DEBUG, so Release builds
        /// can't record whatever this says.
        @available(*, deprecated, message: "Release builds of CloakProxyKit no longer contain the recording code, so this has no effect.")
        public var enabledInReleaseBuilds: Bool {
            get { releaseBuildsRequested }
            set { releaseBuildsRequested = newValue }
        }
        private var releaseBuildsRequested = false

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
            self.releaseBuildsRequested = enabledInReleaseBuilds
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

    /// Whether this build contains the recording code: true only when the package was compiled with DEBUG. In a
    /// Release or App Store build it's false, and the build has no code that reads URLSession's internals.
    public static let isRecordingCompiledIn: Bool = {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }()

    /// Starts recording URLSession traffic and sending it to Cloak Proxy. Calling it again restarts with new options.
    /// Does nothing in builds without DEBUG (`isRecordingCompiledIn`).
    public static func start(_ options: Options = Options()) {
        #if DEBUG
        KitEngine.shared.start(options)
        #endif
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
