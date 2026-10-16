// The CloakProxyKit wire protocol, version 1.
//
// This file is shared word for word by the SDK (SDK/CloakProxyKit/Sources/CloakProxyKit/KitWire.swift) and the Mac
// app (Sources/CloakCore/SDK/KitWire.swift). Edit both together; cloak-selftest fails when they differ.
//
// An app connects to the Mac over TLS and sends length-prefixed JSON messages: a 4-byte big-endian length, then that
// many bytes of JSON (`KitMessage`). Dates are seconds since 1970 as doubles, and bodies are base64.
//
//   app → Mac   hello      who the app and device are, and the token the Mac gave it last time
//   Mac → app   status     pending (waiting for the person at the Mac), allowed (with a token), or blocked
//   app → Mac   icon       the app icon as a PNG, only when the Mac asked for it (needIcon)
//   app → Mac   records    finished requests, numbered by seq within this launch (session)
//   Mac → app   ack        every record up to this seq arrived; the app drops them from its buffer

import Foundation

enum KitWire {
    static let version = 1
    /// Bonjour service type the Mac advertises while it accepts apps.
    static let serviceType = "_cloakproxy-sdk._tcp"
    static let defaultPort = 9092
    /// The largest message either side sends or accepts.
    static let maxMessageBytes = 16 << 20
    /// The largest icon the Mac keeps.
    static let maxIconBytes = 512 << 10
    /// Records per `records` message, and their rough size, so a message stays well under `maxMessageBytes`.
    static let maxRecordsPerMessage = 50
    static let maxBatchBytes = 4 << 20

    struct TooLarge: Error {}

    /// A message as it goes on the wire: its length, then the JSON.
    static func frame(_ payload: Data) -> Data {
        var length = UInt32(payload.count).bigEndian
        var framed = Data(bytes: &length, count: 4)
        framed.append(payload)
        return framed
    }

    /// Takes every complete message off the front of `buffer`, leaving a partial one in place.
    static func unframe(_ buffer: inout Data) throws -> [Data] {
        var messages: [Data] = []
        var offset = buffer.startIndex
        while buffer.endIndex - offset >= 4 {
            let length = buffer[offset..<(offset + 4)].reduce(0) { ($0 << 8) | Int($1) }
            guard length <= maxMessageBytes else { throw TooLarge() }
            guard buffer.endIndex - offset - 4 >= length else { break }
            messages.append(Data(buffer[(offset + 4)..<(offset + 4 + length)]))
            offset += 4 + length
        }
        if offset != buffer.startIndex { buffer = Data(buffer[offset...]) }
        return messages
    }

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.dataEncodingStrategy = .base64
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        decoder.dataDecodingStrategy = .base64
        return decoder
    }

    static func encode(_ message: KitMessage) throws -> Data {
        frame(try encoder().encode(message))
    }
}

/// One message. `type` says which of the optional fields is set.
struct KitMessage: Codable, Sendable {
    var type: String
    var hello: KitHello?
    var status: KitStatus?
    /// `icon`: the app icon, a square PNG.
    var icon: Data?
    var records: [KitRecord]?
    /// `ack`: the highest record seq the Mac has.
    var ack: Int?

    static func hello(_ hello: KitHello) -> KitMessage { KitMessage(type: "hello", hello: hello) }
    static func status(_ status: KitStatus) -> KitMessage { KitMessage(type: "status", status: status) }
    static func icon(_ png: Data) -> KitMessage { KitMessage(type: "icon", icon: png) }
    static func records(_ records: [KitRecord]) -> KitMessage { KitMessage(type: "records", records: records) }
    static func ack(_ seq: Int) -> KitMessage { KitMessage(type: "ack", ack: seq) }
}

struct KitHello: Codable, Sendable, Equatable {
    var protocolVersion: Int
    var sdkVersion: String
    /// Random for each launch of the app; record seqs count up within it.
    var session: String
    /// The token this Mac gave the app when it was allowed, if the app has one.
    var token: String?
    var app: KitApp
    var device: KitDevice
}

struct KitApp: Codable, Sendable, Equatable {
    /// The name shown under the icon (CFBundleDisplayName, else CFBundleName).
    var name: String
    var bundleID: String
    /// CFBundleShortVersionString and CFBundleVersion.
    var version: String?
    var build: String?
    /// Lowercase hex SHA-256 of the icon PNG, so the Mac asks for it only when it doesn't have it.
    var iconHash: String?
}

struct KitDevice: Codable, Sendable, Equatable {
    /// Stable for this app on this device (identifierForVendor on iOS).
    var id: String
    /// The device's name. Since iOS 16 that's generic ("iPhone") unless the app has the entitlement.
    var name: String
    /// The hardware model, "iPhone16,1" or "Mac15,3".
    var model: String?
    /// "iPhone", "iPad", "Mac", "Apple TV", "Apple Vision Pro".
    var kind: String
    /// "iOS", "iPadOS", "macOS", "tvOS", "visionOS".
    var system: String
    var systemVersion: String
    var isSimulator: Bool
}

struct KitStatus: Codable, Sendable, Equatable {
    /// "pending", "allowed" or "blocked".
    var state: String
    var macName: String
    /// Sent when the Mac allows the app; the app sends it in later hellos.
    var token: String?
    /// The Mac has no icon with the hello's `iconHash` yet.
    var needIcon: Bool?
    var message: String?
}

struct KitHeader: Codable, Sendable, Equatable {
    var name: String
    var value: String
}

/// One finished request, as the app's URLSession saw it.
struct KitRecord: Codable, Sendable, Equatable {
    var seq: Int
    var startedAt: Date
    var completedAt: Date?
    var method: String
    var url: String
    var requestHeaders: [KitHeader]
    var requestBody: Data?
    /// The body's full size, when only its start was kept.
    var requestBodySize: Int?
    var requestBodyTruncated: Bool?
    /// The request had a body the SDK couldn't read (a stream, or a file upload).
    var requestBodyUnavailable: Bool?
    var statusCode: Int?
    var responseHeaders: [KitHeader]?
    /// As the app received it: already decompressed, even when Content-Encoding says gzip or br.
    var responseBody: Data?
    var responseBodySize: Int?
    var responseBodyTruncated: Bool?
    /// Set when the request failed: "The request timed out. (NSURLErrorDomain -1001)".
    var error: String?
    /// ALPN protocol from the task metrics: "http/1.1", "h2", "h3".
    var networkProtocol: String?
    var remoteAddress: String?
    var remotePort: Int?
    var reusedConnection: Bool?
    var fromCache: Bool?
    var timings: KitTimings?
}

/// Points in time from URLSessionTaskMetrics (the last transaction). Missing ones didn't happen (a reused
/// connection has no DNS, connect or TLS).
struct KitTimings: Codable, Sendable, Equatable {
    var fetchStart: Date?
    var domainLookupStart: Date?
    var domainLookupEnd: Date?
    var connectStart: Date?
    var connectEnd: Date?
    var secureConnectionStart: Date?
    var secureConnectionEnd: Date?
    var requestStart: Date?
    var requestEnd: Date?
    var responseStart: Date?
    var responseEnd: Date?
}
