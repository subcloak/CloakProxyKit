import CloakProxyKit
import Foundation

// Makes a few requests with CloakProxyKit running, so they show in Cloak Proxy.
//
//   swift run CloakProxyKitExample                                  finds Cloak Proxy over Bonjour
//   swift run CloakProxyKitExample --host 127.0.0.1 --port 9092     connects to this address instead
//
// Options:
//   --mac <name>       only connect to the Mac with this name
//   --fingerprint <hex> only connect to a Mac whose certificate fingerprint starts with this
//   --base <url>       where to send the requests (default https://httpbin.org)
//   --icon <file.png>  the icon to show in Cloak Proxy (a command-line tool has none)
//   --buffer <n>       keep at most n requests while the Mac is away
//   --late             make the requests first, then wait for the Mac (shows the buffer at work)
//   --wait <seconds>   how long to wait for the Mac to confirm everything (default 60)

let arguments = CommandLine.arguments
func value(_ flag: String) -> String? {
    guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

var options = CloakProxyKit.Options(appName: "CloakProxyKit Example")
options.host = value("--host")
options.macName = value("--mac")
options.macFingerprint = value("--fingerprint")
if let port = value("--port").flatMap(Int.init) { options.port = port }
if let limit = value("--buffer").flatMap(Int.init) { options.maxBufferedRequests = limit }
if let path = value("--icon") { options.appIcon = FileManager.default.contents(atPath: path) }
let base = URL(string: value("--base") ?? "https://httpbin.org")!
let wait = value("--wait").flatMap(Double.init) ?? 60

CloakProxyKit.start(options)
print("CloakProxyKit \(CloakProxyKit.version) started. Recording URLSession: \(CloakProxyKit.isCapturing)")

// Straight to the server, even when this Mac's proxy points at Cloak Proxy.
let configuration = URLSessionConfiguration.ephemeral
configuration.connectionProxyDictionary = ["HTTPEnable": false, "HTTPSEnable": false]
let session = URLSession(configuration: configuration)

func run(_ label: String, _ body: () async throws -> (Data, URLResponse)) async {
    do {
        let (data, response) = try await body()
        print("\(label): \((response as? HTTPURLResponse)?.statusCode ?? 0), \(data.count) bytes")
    } catch {
        print("\(label): failed (\(error.localizedDescription))")
    }
}

func makeRequests() async {
    await run("GET /get") { try await session.data(from: base.appendingPathComponent("get")) }
    var post = URLRequest(url: base.appendingPathComponent("post"))
    post.httpMethod = "POST"
    post.setValue("application/json", forHTTPHeaderField: "Content-Type")
    post.httpBody = Data(#"{"name":"Ada Park","email":"ada@example.com"}"#.utf8)
    await run("POST /post") { try await session.data(for: post) }
    var upload = URLRequest(url: base.appendingPathComponent("anything/upload"))
    upload.httpMethod = "PUT"
    upload.setValue("text/plain", forHTTPHeaderField: "Content-Type")
    await run("PUT /anything/upload") { try await session.upload(for: upload, from: Data("uploaded with uploadTask".utf8)) }
    await run("GET /status/404") { try await session.data(from: base.appendingPathComponent("status/404")) }
    // A completion-handler task, the older style.
    await run("GET /headers (completion handler)") {
        try await withCheckedThrowingContinuation { continuation in
            var request = URLRequest(url: base.appendingPathComponent("headers"))
            request.setValue("Bearer sk_test_example", forHTTPHeaderField: "Authorization")
            session.dataTask(with: request) { data, response, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: (data ?? Data(), response!)) }
            }.resume()
        }
    }
}

if arguments.contains("--late") {
    await makeRequests()
    print("Made the requests; waiting for Cloak Proxy…")
}

// Wait for the Mac to allow this app, unless the requests should wait in the buffer first.
let deadline = Date().addingTimeInterval(wait)
if !arguments.contains("--late") {
    var announced = false
    while Date() < deadline {
        if case .connected = CloakProxyKit.state { break }
        if case .waitingForApproval(let mac) = CloakProxyKit.state, !announced {
            print("Allow “CloakProxyKit Example” in Cloak Proxy on \(mac).")
            announced = true
        }
        try? await Task.sleep(nanoseconds: 100_000_000)
    }
    await makeRequests()
}

// Wait for the Mac to confirm every request.
try? await Task.sleep(nanoseconds: 300_000_000)
while Date() < deadline, CloakProxyKit.unsentCount > 0 {
    try? await Task.sleep(nanoseconds: 100_000_000)
}
print("State: \(CloakProxyKit.state). Unsent: \(CloakProxyKit.unsentCount)")
exit(CloakProxyKit.unsentCount == 0 ? 0 : 1)
