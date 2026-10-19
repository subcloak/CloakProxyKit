import Foundation
import ObjectiveC

/// Watches the app's URLSession tasks from the inside, without changing them.
///
/// URLSession hands every request of an in-process session to a connection object
/// (`__NSCFURLLocalSessionConnection`) that tells the task about the response, each piece of the body and the end.
/// We wrap those three calls, plus `resume` (for the start time) and the upload-from-data call (for upload bodies).
/// Each wrapper copies what it needs and then calls the original, so the app's delegates, completion handlers,
/// cookies, caching and authentication behave exactly as before. This is the approach Proxyman's Atlantis takes.
///
/// The connection class and its methods are private. Each hook is installed only when the method exists with the
/// expected signature; anything missing is skipped (and `isCapturing` reports it), never forced. Background sessions
/// run in another process and are never seen; WebSocket tasks are skipped.
///
/// The hooks are compiled only with the DEBUG flag, so a Release or App Store build of an app that links this package
/// contains none of the private names or calls: `install()` returns false there (`CloakProxyKit.isRecordingCompiledIn`).
enum URLSessionCapture {
    struct Settings {
        var enabled = false
        var maxBodySize = 1 << 20
        var ignoredHosts: [String] = []
    }

    private static let lock = NSLock()
    private static var _settings = Settings()
    private static var _onFinish: ((URLSessionTask, TaskCapture, Error?) -> Void)?
    private static var installed: Bool?

    static var settings: Settings {
        get { lock.lock(); defer { lock.unlock() }; return _settings }
        set { lock.lock(); _settings = newValue; lock.unlock() }
    }

    /// Called on URLSession's own queue when a captured task ends. Keep it quick.
    static var onFinish: ((URLSessionTask, TaskCapture, Error?) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _onFinish }
        set { lock.lock(); _onFinish = newValue; lock.unlock() }
    }

    /// Installs the hooks once. False when this OS doesn't have the methods they need (nothing is captured then).
    @discardableResult
    static func install() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if let installed { return installed }
        let result = installHooks()
        installed = result
        return result
    }

    // MARK: Tasks

    private static let captureKey = UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1)
    private static let uploadKey = UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1)

    static func capture(of task: URLSessionTask) -> TaskCapture? {
        objc_getAssociatedObject(task, captureKey) as? TaskCapture
    }

    /// The task's capture, started now if the task is one we record (http or https, not ignored, not a WebSocket).
    static func startCapture(of task: URLSessionTask) -> TaskCapture? {
        if let existing = capture(of: task) { return existing }
        let settings = self.settings
        guard settings.enabled, !(task is URLSessionWebSocketTask),
              let url = (task.originalRequest ?? task.currentRequest)?.url,
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        let host = url.host?.lowercased() ?? ""
        if settings.ignoredHosts.contains(where: { Self.host(host, matches: $0) }) { return nil }
        let capture = TaskCapture(maxBodySize: settings.maxBodySize)
        if let upload = objc_getAssociatedObject(task, uploadKey) as? UploadBody { capture.setUpload(upload) }
        objc_setAssociatedObject(task, captureKey, capture, .OBJC_ASSOCIATION_RETAIN)
        return capture
    }

    /// "example.com" matches it and its subdomains; "*.example.com" only subdomains.
    static func host(_ host: String, matches pattern: String) -> Bool {
        let pattern = pattern.lowercased().trimmingCharacters(in: .whitespaces)
        guard !pattern.isEmpty else { return false }
        if pattern.hasPrefix("*.") { return host.hasSuffix(String(pattern.dropFirst(1))) }
        return host == pattern || host.hasSuffix("." + pattern)
    }

    // MARK: Hooks

    #if DEBUG

    private final class Original {
        let imp: IMP
        let selector: Selector
        init(_ imp: IMP, _ selector: Selector) {
            self.imp = imp
            self.selector = selector
        }
    }

    /// Replaces `name` on `cls` with `make(original)` when it exists there with this type encoding (ignoring the
    /// frame offsets, which differ by architecture).
    private static func hook(_ cls: AnyClass, _ name: String, encoding: String, _ make: (Original) -> Any) -> Bool {
        let selector = NSSelectorFromString(name)
        guard let method = class_getInstanceMethod(cls, selector), let types = method_getTypeEncoding(method),
              String(cString: types).filter({ !$0.isNumber }) == encoding else { return false }
        let original = Original(method_getImplementation(method), selector)
        method_setImplementation(method, imp_implementationWithBlock(make(original)))
        return true
    }

    private static func installHooks() -> Bool {
        guard let connection = NSClassFromString("__NSCFURLLocalSessionConnection"),
              let taskIvar = class_getInstanceVariable(connection, "_task") else { return false }
        func task(of connection: AnyObject) -> URLSessionTask? {
            object_getIvar(connection, taskIvar) as? URLSessionTask
        }

        let response = hook(connection, "_didReceiveResponse:sniff:", encoding: "v@:@B") { original in
            typealias Function = @convention(c) (AnyObject, Selector, AnyObject?, Bool) -> Void
            let call = unsafeBitCast(original.imp, to: Function.self)
            let block: @convention(block) (AnyObject, AnyObject?, Bool) -> Void = { connection, response, sniff in
                if let task = task(of: connection), let response = response as? URLResponse {
                    startCapture(of: task)?.received(response)
                }
                call(connection, original.selector, response, sniff)
            }
            return block
        }
        let data = hook(connection, "_didReceiveData:", encoding: "v@:@") { original in
            typealias Function = @convention(c) (AnyObject, Selector, AnyObject?) -> Void
            let call = unsafeBitCast(original.imp, to: Function.self)
            let block: @convention(block) (AnyObject, AnyObject?) -> Void = { connection, data in
                // dispatch_data_t is an NSData on Apple platforms.
                if let task = task(of: connection), let data = data as? NSData { capture(of: task)?.received(data) }
                call(connection, original.selector, data)
            }
            return block
        }
        let finish = hook(connection, "_didFinishWithError:", encoding: "v@:@") { original in
            typealias Function = @convention(c) (AnyObject, Selector, AnyObject?) -> Void
            let call = unsafeBitCast(original.imp, to: Function.self)
            let block: @convention(block) (AnyObject, AnyObject?) -> Void = { connection, error in
                if let task = task(of: connection), let capture = startCapture(of: task), capture.finish() {
                    onFinish?(task, capture, error as? Error)
                }
                call(connection, original.selector, error)
            }
            return block
        }
        guard response, data, finish else { return false }

        // The start time. Optional: without it a request starts when its connection does.
        _ = hook(URLSessionTask.self, "resume", encoding: "v@:") { original in
            typealias Function = @convention(c) (AnyObject, Selector) -> Void
            let call = unsafeBitCast(original.imp, to: Function.self)
            let block: @convention(block) (AnyObject) -> Void = { task in
                if let task = task as? URLSessionTask { _ = startCapture(of: task) }
                call(task, original.selector)
            }
            return block
        }

        // Upload bodies passed as Data aren't on the request. Every uploadTask(with:from:) variant, async ones
        // included, goes through this method; remember the start of the data on the task it returns.
        _ = hook(URLSession.self, "_uploadTaskWithRequest:fromData:delegate:completionHandler:", encoding: "@@:@@@@?") { original in
            typealias Function = @convention(c) (AnyObject, Selector, AnyObject?, AnyObject?, AnyObject?, AnyObject?) -> Unmanaged<AnyObject>?
            let call = unsafeBitCast(original.imp, to: Function.self)
            let block: @convention(block) (AnyObject, AnyObject?, AnyObject?, AnyObject?, AnyObject?) -> Unmanaged<AnyObject>? = { session, request, body, delegate, handler in
                let result = call(session, original.selector, request, body, delegate, handler)
                if settings.enabled, let task = result?.takeUnretainedValue() as? URLSessionTask, let body = body as? NSData {
                    let limit = settings.maxBodySize
                    let kept = body.length <= limit ? Data(referencing: body) : body.subdata(with: NSRange(location: 0, length: limit))
                    objc_setAssociatedObject(task, uploadKey, UploadBody(data: kept, size: body.length), .OBJC_ASSOCIATION_RETAIN)
                }
                return result
            }
            return block
        }
        return true
    }
    #else
    /// Release builds have no hooks: the code that reads URLSession's internals is compiled only with DEBUG.
    private static func installHooks() -> Bool { false }
    #endif
}

final class UploadBody {
    let data: Data
    let size: Int

    init(data: Data, size: Int) {
        self.data = data
        self.size = size
    }
}

/// What one task has done so far. Written on URLSession's queue for that task, read once it finishes.
final class TaskCapture {
    let startedAt = Date()
    private let lock = NSLock()
    private let maxBodySize: Int
    private(set) var response: URLResponse?
    private(set) var body = Data()
    private(set) var bodySize = 0
    private(set) var upload: UploadBody?
    private var finished = false

    init(maxBodySize: Int) {
        self.maxBodySize = maxBodySize
    }

    func received(_ response: URLResponse) {
        lock.lock()
        defer { lock.unlock() }
        // A second response (after an informational one, or a retry) replaces the first, along with its body.
        self.response = response
        body = Data()
        bodySize = 0
    }

    func received(_ data: NSData) {
        lock.lock()
        defer { lock.unlock() }
        bodySize += data.length
        let room = maxBodySize - body.count
        guard room > 0 else { return }
        if data.length <= room {
            body.append(Data(referencing: data))
        } else {
            body.append(data.subdata(with: NSRange(location: 0, length: room)))
        }
    }

    func setUpload(_ upload: UploadBody) {
        lock.lock()
        self.upload = upload
        lock.unlock()
    }

    /// True the first time only.
    func finish() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return false }
        finished = true
        return true
    }

    var snapshot: (response: URLResponse?, body: Data, bodySize: Int, upload: UploadBody?) {
        lock.lock()
        defer { lock.unlock() }
        return (response, body, bodySize, upload)
    }
}
