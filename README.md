# CloakProxyKit

Shows your iOS or macOS app's network requests in [Cloak Proxy](https://subcloak.com/apps/cloak-proxy/) on your Mac,
with no proxy settings and no certificate to install. Add it to the debug build of your own app, call
`CloakProxyKit.start()`, and every URLSession request the app makes appears in Cloak Proxy under the app's name and
icon, with headers, bodies and timings. It works for apps that pin their certificates, because it records requests
inside the app instead of intercepting them.

- iOS 15 and later, macOS 12 and later
- Swift Package Manager, no dependencies
- Cloak Proxy 0.3.0 or later on the Mac

## Install

**Xcode:** choose **File › Add Package Dependencies…**, enter `https://github.com/subcloak/CloakProxyKit`, and add
the **CloakProxyKit** library to your app target.

**Package.swift:**

```swift
dependencies: [
    .package(url: "https://github.com/subcloak/CloakProxyKit", from: "0.3.0"),
],
targets: [
    .target(name: "MyApp", dependencies: [.product(name: "CloakProxyKit", package: "CloakProxyKit")]),
]
```

### Info.plist (iOS)

iOS asks before an app uses the local network, and only lets it browse Bonjour services it lists. Add both keys to
the app's Info.plist (a debug-only Info.plist is fine):

```xml
<key>NSLocalNetworkUsageDescription</key>
<string>Sends this app's network requests to Cloak Proxy on your Mac while debugging.</string>
<key>NSBonjourServices</key>
<array>
    <string>_cloakproxy-sdk._tcp</string>
</array>
```

The first time the app starts the SDK, iOS asks to allow local network access. Allow it.

macOS apps in the App Sandbox need the **Outgoing Connections (Client)** capability
(`com.apple.security.network.client`).

## Quick start

1. On the Mac, open Cloak Proxy's **Settings › In-app SDK** and turn on
   **Accept traffic from apps using CloakProxyKit**.
2. Start the SDK as early as you can, for example in your `App` initializer or
   `application(_:didFinishLaunchingWithOptions:)`:

   ```swift
   #if DEBUG
   import CloakProxyKit
   #endif

   @main
   struct WeatherApp: App {
       init() {
           #if DEBUG
           CloakProxyKit.start()
           #endif
       }
       // …
   }
   ```

3. Run the app. Cloak Proxy asks, for example, **Allow “Weather” on iPhone at 192.168.1.23 to send traffic?**
   Click **Allow**. The answer is remembered for this app on this device.

The app's requests now appear in Cloak Proxy: under **Devices** (the device, then the app with its icon) for a
phone or another Mac, or under **Apps** for an app in the iOS Simulator or a Mac app on the same Mac. They carry an
**SDK** tag, and search, Trace Value, Insights, Privacy Map, exports and the MCP server see them like any other
request.

Cloak Proxy only observes this traffic. Rules, breakpoints and other debugging tools don't apply to it.

## Options

```swift
var options = CloakProxyKit.Options()
options.macName = "Ada's MacBook Pro"   // only connect to this Mac
options.maxBodySize = 256 * 1024        // keep at most 256 KB of each body
options.ignoredHosts = ["analytics.example.com"]
CloakProxyKit.start(options)
```

| Option | Default | What it does |
|---|---|---|
| `macName` | any | Connect only to the Mac with this name (its Bonjour name, as in **System Settings › General › Sharing**). |
| `macFingerprint` | none | Connect only to a Mac whose certificate fingerprint starts with this (at least 16 hex digits). **Settings › In-app SDK** shows it. |
| `host`, `port` | Bonjour, `9092` | Skip Bonjour and connect to this address and port, for networks where Bonjour doesn't work. |
| `maxBodySize` | 1 MB | The most of each request and response body kept. `0` sends no bodies. At most 4 MB. |
| `maxBufferedRequests` | 500 | Finished requests kept while the Mac is away or hasn't allowed the app yet. The oldest go first. |
| `maxBufferedBytes` | 16 MB | The same buffer's size limit. |
| `ignoredHosts` | none | Requests to these hosts aren't recorded. `example.com` covers its subdomains; `*.example.com` only the subdomains. |
| `appName` | the bundle's display name | The name shown in Cloak Proxy. |
| `appIcon` | the app icon | A square PNG to show instead. Command-line tools have no icon of their own. |
| `enabledInReleaseBuilds` | `false` | Also run in builds without the `DEBUG` flag. |

Also available: `CloakProxyKit.stop()`, `CloakProxyKit.state` (`searching`, `connecting`, `waitingForApproval`,
`connected`, `blocked`), `CloakProxyKit.unsentCount` and `CloakProxyKit.isCapturing`.

## How it works

- **Recording.** URLSession hands every request of an in-process session to an internal connection object. The SDK
  wraps the three calls that object makes on the task (response received, body data received, finished), plus
  `resume` for the start time and the upload-from-data call for upload bodies. Each wrapper copies what it needs and
  then calls the original, so delegates, completion handlers, async/await, cookies, caching and authentication behave
  exactly as before. This is the approach Proxyman's Atlantis takes. Timings come from the task's own metrics.
- **Finding the Mac.** Cloak Proxy advertises `_cloakproxy-sdk._tcp` over Bonjour while the setting is on. Bonjour
  also works over a USB cable when the Mac and the device see each other on the cable's network interface.
- **Sending.** The SDK connects over TLS (1.2 or later) and checks the Mac's certificate by its SHA-256 fingerprint,
  which must match the one the Mac advertises (or `macFingerprint`). It sends length-prefixed JSON (`KitWire.swift`).
  Requests are sent once finished, in batches, and kept until the Mac acknowledges them, so nothing is lost when the
  connection drops and nothing is delivered twice.
- **Approval.** The first time an app connects from a device, Cloak Proxy asks whether to allow it. An allowed app gets
  a token (kept in the app's user defaults, per Mac) that it sends from then on. An app without a valid token is asked
  about again. **Settings › In-app SDK** lists allowed and blocked apps; **Remove** forgets one.

## Safety

- In builds without `DEBUG`, `start()` does nothing unless you set `enabledInReleaseBuilds`. Better still, keep the
  call inside `#if DEBUG` as above. The code that reads URLSession's internals is still linked into a Release build
  that includes the package; leave the package out of App Store builds if you can.
- Nothing throws, blocks the app or changes a request. Recording work is a copy and a lock; sending happens on the
  SDK's own queue. If the Mac isn't there, requests wait in the bounded buffer and the oldest are dropped.
- Anyone on your network can see the Bonjour advertisement, and something pretending to be Cloak Proxy could accept
  the traffic. Use `macName` or `macFingerprint` on shared networks, and only use the SDK in debug builds.

## Limits

- **URLSession only.** Requests made with `URLSession` (and libraries built on it, such as Alamofire) are recorded.
  WKWebView, AVPlayer streaming, `Network.framework` connections and other networking stacks are not.
- **Background sessions** run in a system process, so their tasks aren't seen.
- **WebSocket tasks** are skipped.
- **Upload bodies** passed as `Data` and set on the request are recorded. Bodies from a file (`upload(for:fromFile:)`)
  or a stream (`httpBodyStream`) aren't; the request is marked as truncated.
- **Redirects** show as one request with the final URL and response.
- **Response bodies** are recorded as the app received them: already decompressed, even when `Content-Encoding` says
  `gzip` or `br`.
- The recording relies on URLSession internals that have been stable for years. If a future OS changes them, the SDK
  records nothing (`isCapturing` is `false`) rather than misbehaving.
- iOS drops connections when the app is in the background. The SDK reconnects when it comes back and sends what was
  buffered.

## Try it

`swift run CloakProxyKitExample` (in this folder) makes a few requests to `httpbin.org` with the SDK running. Pass
`--host 127.0.0.1 --port 9092` to skip Bonjour, `--base <url>` to use another server, and `--icon <file.png>` to give
it an icon.

`swift test` runs the package's tests on macOS. To build for iOS:

```bash
xcodebuild -scheme CloakProxyKit -destination 'generic/platform=iOS' build
```

## License

MIT. See [LICENSE](LICENSE).
