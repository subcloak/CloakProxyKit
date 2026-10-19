import Foundation
import Network
import XCTest
@testable import CloakProxyKit

final class CloakProxyKitTests: XCTestCase {
    /// Records finished tasks the way the engine does, without a Mac.
    final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var records: [KitRecord] = []

        func add(_ record: KitRecord) { lock.lock(); records.append(record); lock.unlock() }
        var all: [KitRecord] { lock.lock(); defer { lock.unlock() }; return records }

        func waitFor(_ count: Int, timeout: TimeInterval = 10) -> [KitRecord] {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline, all.count < count { Thread.sleep(forTimeInterval: 0.02) }
            return all
        }
    }

    func testCapturesURLSessionTrafficWithoutChangingIt() async throws {
        guard CloakProxyKit.isRecordingCompiledIn else {
            throw XCTSkip("Release builds don't contain the recording code; testReleaseBuildsContainNoRecording covers them.")
        }
        let server = try TestHTTPServer()
        defer { server.stop() }
        XCTAssertTrue(URLSessionCapture.install(), "the hooks install on this OS")
        let collector = Collector()
        URLSessionCapture.settings = .init(enabled: true, maxBodySize: 64, ignoredHosts: ["ignored.example.com"])
        URLSessionCapture.onFinish = { task, capture, error in
            collector.add(RecordBuilder.record(task: task, capture: capture, error: error))
        }
        defer {
            URLSessionCapture.settings.enabled = false
            URLSessionCapture.onFinish = nil
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = ["HTTPEnable": false, "HTTPSEnable": false]
        let session = URLSession(configuration: configuration)
        let base = URL(string: "http://127.0.0.1:\(server.port)")!

        // async/await data task: the app gets exactly what the server sent.
        let (data, response) = try await session.data(from: base.appendingPathComponent("json"))
        XCTAssertEqual(String(decoding: data, as: UTF8.self), #"{"hello":"world"}"#)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)

        // A POST with a body over the 64-byte cap.
        var post = URLRequest(url: base.appendingPathComponent("echo"))
        post.httpMethod = "POST"
        post.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let big = Data(repeating: UInt8(ascii: "a"), count: 100)
        post.httpBody = big
        let (echoed, _) = try await session.data(for: post)
        XCTAssertEqual(echoed, big, "the app still gets the whole body")

        // An upload from Data, and a completion-handler task with a 404.
        var put = URLRequest(url: base.appendingPathComponent("echo"))
        put.httpMethod = "PUT"
        _ = try await session.upload(for: put, from: Data("uploaded".utf8))
        let done = expectation(description: "completion handler")
        session.dataTask(with: base.appendingPathComponent("missing")) { _, response, _ in
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 404)
            done.fulfill()
        }.resume()
        await fulfillment(of: [done], timeout: 10)

        // A connection that fails.
        _ = try? await session.data(from: URL(string: "http://127.0.0.1:1/refused")!)

        let records = collector.waitFor(5)
        XCTAssertEqual(records.count, 5)
        let byPath = Dictionary(records.map { (URL(string: $0.url)?.path ?? "", $0) }, uniquingKeysWith: { $1 })

        let get = try XCTUnwrap(byPath["/json"])
        XCTAssertEqual(get.method, "GET")
        XCTAssertEqual(get.statusCode, 200)
        XCTAssertEqual(get.responseBody.map { String(decoding: $0, as: UTF8.self) }, #"{"hello":"world"}"#)
        XCTAssertEqual(get.responseHeaders?.first { $0.name.lowercased() == "content-type" }?.value, "application/json")
        XCTAssertNotNil(get.timings?.requestStart, "timings come from the task's metrics")
        XCTAssertEqual(get.networkProtocol, "http/1.1")
        XCTAssertLessThanOrEqual(get.startedAt, get.completedAt ?? .distantPast)

        let echo = try XCTUnwrap(records.first { $0.method == "POST" })
        XCTAssertEqual(echo.requestBody?.count, 64, "request body capped")
        XCTAssertEqual(echo.requestBodySize, 100)
        XCTAssertEqual(echo.requestBodyTruncated, true)
        XCTAssertEqual(echo.responseBody?.count, 64, "response body capped")
        XCTAssertEqual(echo.responseBodySize, 100)
        XCTAssertEqual(echo.responseBodyTruncated, true)
        XCTAssertTrue(echo.requestHeaders.contains { $0.name == "Content-Type" && $0.value == "application/json" })

        let upload = try XCTUnwrap(records.first { $0.method == "PUT" })
        XCTAssertEqual(upload.requestBody.map { String(decoding: $0, as: UTF8.self) }, "uploaded", "upload(for:from:) bodies are kept")

        XCTAssertEqual(byPath["/missing"]?.statusCode, 404)
        let failed = try XCTUnwrap(byPath["/refused"])
        XCTAssertNil(failed.statusCode)
        XCTAssertNotNil(failed.error)

        // Ignored hosts and turning capture off.
        URLSessionCapture.settings.enabled = false
        _ = try await session.data(from: base.appendingPathComponent("json"))
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(collector.all.count, 5, "nothing recorded while off")
    }

    /// The private-API hooks exist only with DEBUG. `swift test` covers the Debug side; scripts/check-release.sh runs
    /// these tests in Release too and checks the compiled library holds none of the private names.
    func testReleaseBuildsContainNoRecording() async throws {
        let task = URLSession.shared.dataTask(with: URL(string: "http://127.0.0.1:9/")!)
        #if DEBUG
        XCTAssertTrue(CloakProxyKit.isRecordingCompiledIn)
        XCTAssertTrue(URLSessionCapture.install())
        #else
        XCTAssertFalse(CloakProxyKit.isRecordingCompiledIn)
        XCTAssertFalse(URLSessionCapture.install(), "no hooks in a Release build")
        XCTAssertNil(RecordBuilder.taskMetrics(of: task), "no private metrics getter in a Release build")
        CloakProxyKit.start(CloakProxyKit.Options(host: "127.0.0.1", port: 9, enabledInReleaseBuilds: true))
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(CloakProxyKit.state, .stopped, "start() does nothing, even when asked to run in Release")
        XCTAssertFalse(CloakProxyKit.isCapturing)
        #endif
        task.cancel()
    }

    func testBufferIsBoundedAndAcknowledged() {
        var buffer = RecordBuffer(maxCount: 3, maxBytes: 1 << 20)
        for seq in 1...5 { buffer.append(Self.record(seq)) }
        XCTAssertEqual(buffer.records.map(\.seq), [3, 4, 5], "oldest dropped first")
        XCTAssertEqual(buffer.dropped, 2)
        XCTAssertEqual(buffer.batch(after: 0, maxCount: 2).map(\.seq), [3, 4])
        buffer.acknowledge(through: 4)
        XCTAssertEqual(buffer.records.map(\.seq), [5])

        var small = RecordBuffer(maxCount: 100, maxBytes: 2_000)
        for seq in 1...10 { small.append(Self.record(seq, body: 600)) }
        XCTAssertLessThanOrEqual(small.bytes, 2_000)
        XCTAssertEqual(small.records.last?.seq, 10)
        small.append(Self.record(11, body: 5_000))
        XCTAssertEqual(small.records.map(\.seq), [11], "a record larger than the limit is still kept, alone")
    }

    func testWireFraming() throws {
        let message = KitMessage.records([Self.record(7)])
        var stream = try KitWire.encode(message) + KitWire.encode(.ack(7))
        let partial = stream.suffix(3)
        stream.removeLast(3)
        var buffer = stream
        let first = try KitWire.unframe(&buffer)
        XCTAssertEqual(first.count, 1, "the second message isn't complete yet")
        buffer.append(partial)
        let second = try KitWire.unframe(&buffer)
        XCTAssertEqual(second.count, 1)
        XCTAssertTrue(buffer.isEmpty)
        let decoded = try KitWire.decoder().decode(KitMessage.self, from: first[0])
        XCTAssertEqual(decoded.records?.first, Self.record(7))
        XCTAssertEqual(try KitWire.decoder().decode(KitMessage.self, from: second[0]).ack, 7)

        var huge = Data([0x7F, 0xFF, 0xFF, 0xFF])
        XCTAssertThrowsError(try KitWire.unframe(&huge))
    }

    func testHostPatterns() {
        XCTAssertTrue(URLSessionCapture.host("api.example.com", matches: "example.com"))
        XCTAssertTrue(URLSessionCapture.host("example.com", matches: "example.com"))
        XCTAssertFalse(URLSessionCapture.host("example.com", matches: "*.example.com"))
        XCTAssertFalse(URLSessionCapture.host("badexample.com", matches: "example.com"))
    }

    static func record(_ seq: Int, body: Int = 0) -> KitRecord {
        KitRecord(seq: seq, startedAt: Date(timeIntervalSince1970: 1_700_000_000), completedAt: Date(timeIntervalSince1970: 1_700_000_000.25),
                  method: "GET", url: "https://api.example.com/items/\(seq)", requestHeaders: [KitHeader(name: "Accept", value: "*/*")],
                  responseBody: body > 0 ? Data(count: body) : nil)
    }
}

/// HTTP/1.1 on 127.0.0.1 and a random port: /json, /echo (returns the body), anything else 404.
final class TestHTTPServer: @unchecked Sendable {
    let listener: NWListener
    let queue = DispatchQueue(label: "test-http")
    private(set) var port: UInt16 = 0

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        listener.newConnectionHandler = { [queue] connection in
            connection.start(queue: queue)
            Self.serve(connection, buffer: Data())
        }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 5)
        port = listener.port?.rawValue ?? 0
    }

    func stop() { listener.cancel() }

    private static func serve(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, error in
            var buffer = buffer
            if let data { buffer.append(data) }
            guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if error == nil && !isComplete { serve(connection, buffer: buffer) } else { connection.cancel() }
                return
            }
            let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
            let length = head.split(separator: "\r\n").first { $0.lowercased().hasPrefix("content-length:") }
                .flatMap { Int($0.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) } ?? 0
            let body = buffer[end.upperBound...]
            guard body.count >= length else {
                serve(connection, buffer: buffer)
                return
            }
            let path = head.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            let (status, type, content): (String, String, Data)
            switch path {
            case "/json": (status, type, content) = ("200 OK", "application/json", Data(#"{"hello":"world"}"#.utf8))
            case "/echo": (status, type, content) = ("200 OK", "application/octet-stream", Data(body.prefix(length)))
            default: (status, type, content) = ("404 Not Found", "text/plain", Data("not found".utf8))
            }
            var response = Data("HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(content.count)\r\nConnection: close\r\n\r\n".utf8)
            response.append(content)
            connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}
