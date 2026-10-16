import Foundation

/// Finished requests waiting to reach the Mac, oldest first. Bounded by count and by size: while the Mac is away the
/// oldest records are dropped to make room. Records leave when the Mac acknowledges them, so ones sent on a
/// connection that then dropped are sent again on the next.
struct RecordBuffer {
    var maxCount: Int
    var maxBytes: Int
    private(set) var records: [KitRecord] = []
    private(set) var bytes = 0
    /// Records dropped to stay within the limits, since start.
    private(set) var dropped = 0

    init(maxCount: Int, maxBytes: Int) {
        self.maxCount = max(maxCount, 1)
        self.maxBytes = max(maxBytes, 1)
    }

    var isEmpty: Bool { records.isEmpty }

    mutating func append(_ record: KitRecord) {
        records.append(record)
        bytes += Self.size(of: record)
        // Always keep the newest record, even when it alone is over the size limit.
        while records.count > maxCount || (bytes > maxBytes && records.count > 1) {
            bytes -= Self.size(of: records.removeFirst())
            dropped += 1
        }
    }

    /// The Mac has every record up to `seq`.
    mutating func acknowledge(through seq: Int) {
        let count = records.prefix { $0.seq <= seq }.count
        guard count > 0 else { return }
        for record in records.prefix(count) { bytes -= Self.size(of: record) }
        records.removeFirst(count)
    }

    /// The next records to send after `seq`, within one message's limits (at least one).
    func batch(after seq: Int, maxCount: Int = KitWire.maxRecordsPerMessage, maxBytes: Int = KitWire.maxBatchBytes) -> [KitRecord] {
        var batch: [KitRecord] = []
        var size = 0
        for record in records where record.seq > seq {
            let recordSize = Self.size(of: record)
            if !batch.isEmpty && (batch.count >= maxCount || size + recordSize > maxBytes) { break }
            batch.append(record)
            size += recordSize
        }
        return batch
    }

    mutating func removeAll() {
        records.removeAll()
        bytes = 0
    }

    /// Roughly what a record costs in memory and on the wire.
    static func size(of record: KitRecord) -> Int {
        let headers = (record.requestHeaders + (record.responseHeaders ?? [])).reduce(0) { $0 + $1.name.utf8.count + $1.value.utf8.count + 8 }
        return 256 + record.url.utf8.count + headers + (record.requestBody?.count ?? 0) + (record.responseBody?.count ?? 0)
    }
}
