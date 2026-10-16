import Foundation

/// Turns a finished task and what its capture saw into a record for the Mac.
enum RecordBuilder {
    static func record(task: URLSessionTask, capture: TaskCapture, error: Error?) -> KitRecord {
        let request = task.currentRequest ?? task.originalRequest
        let snapshot = capture.snapshot
        let metrics = autoreleasepool { taskMetrics(of: task) }
        let transaction = metrics?.transactionMetrics.last
        let limit = URLSessionCapture.settings.maxBodySize

        // The request's own headers, plus any URLSession added that the metrics' copy of the request shows.
        var headers = (request?.allHTTPHeaderFields ?? [:]).sorted { $0.key < $1.key }.map { KitHeader(name: $0.key, value: $0.value) }
        for (name, value) in (transaction?.request.allHTTPHeaderFields ?? [:]).sorted(by: { $0.key < $1.key })
        where !headers.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            headers.append(KitHeader(name: name, value: value))
        }

        var requestBody: Data?
        var requestBodySize: Int?
        var unavailable = false
        if let body = task.originalRequest?.httpBody ?? request?.httpBody {
            requestBodySize = body.count
            requestBody = body.count <= limit ? body : body.prefix(limit)
        } else if let upload = snapshot.upload {
            requestBodySize = upload.size
            requestBody = upload.data
        } else if request?.httpBodyStream != nil || task is URLSessionUploadTask {
            unavailable = true
        }

        let http = snapshot.response as? HTTPURLResponse
        let keptRequestBody = limit > 0 ? requestBody.flatMap { $0.isEmpty ? nil : $0 } : nil
        let started = [capture.startedAt, metrics?.transactionMetrics.first?.fetchStartDate].compactMap { $0 }.min() ?? capture.startedAt
        var record = KitRecord(
            seq: 0, startedAt: started, completedAt: transaction?.responseEndDate ?? Date(),
            method: request?.httpMethod ?? "GET", url: request?.url?.absoluteString ?? "",
            requestHeaders: headers,
            requestBody: keptRequestBody,
            requestBodySize: requestBodySize,
            requestBodyTruncated: (requestBodySize ?? 0) > (keptRequestBody?.count ?? 0) ? true : nil,
            requestBodyUnavailable: unavailable ? true : nil,
            statusCode: http?.statusCode,
            responseHeaders: http.map(responseHeaders),
            responseBody: snapshot.body.isEmpty ? nil : snapshot.body,
            responseBodySize: snapshot.response == nil ? nil : snapshot.bodySize,
            responseBodyTruncated: snapshot.bodySize > snapshot.body.count ? true : nil,
            error: error.map(describe))
        if let transaction {
            record.networkProtocol = transaction.networkProtocolName
            record.remoteAddress = transaction.remoteAddress
            record.remotePort = transaction.remotePort
            record.reusedConnection = transaction.isReusedConnection
            record.fromCache = transaction.resourceFetchType == .localCache ? true : nil
            record.timings = KitTimings(
                fetchStart: transaction.fetchStartDate, domainLookupStart: transaction.domainLookupStartDate,
                domainLookupEnd: transaction.domainLookupEndDate, connectStart: transaction.connectStartDate,
                connectEnd: transaction.connectEndDate, secureConnectionStart: transaction.secureConnectionStartDate,
                secureConnectionEnd: transaction.secureConnectionEndDate, requestStart: transaction.requestStartDate,
                requestEnd: transaction.requestEndDate, responseStart: transaction.responseStartDate,
                responseEnd: transaction.responseEndDate)
        }
        return record
    }

    static func responseHeaders(_ response: HTTPURLResponse) -> [KitHeader] {
        response.allHeaderFields.compactMap { key, value -> KitHeader? in
            guard let name = key as? String else { return nil }
            return KitHeader(name: name, value: "\(value)")
        }
        .sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    /// "The request timed out. (NSURLErrorDomain -1001)"
    static func describe(_ error: Error) -> String {
        let error = error as NSError
        return "\(error.localizedDescription) (\(error.domain) \(error.code))"
    }

    /// The task's timings without a delegate. URLSession only hands metrics to delegates, but the task keeps them;
    /// this private getter returns them as public URLSessionTaskMetrics. Nil when it isn't there.
    static func taskMetrics(of task: URLSessionTask) -> URLSessionTaskMetrics? {
        let selector = NSSelectorFromString("_incompleteTaskMetrics")
        guard task.responds(to: selector) else { return nil }
        return task.perform(selector)?.takeUnretainedValue() as? URLSessionTaskMetrics
    }
}
