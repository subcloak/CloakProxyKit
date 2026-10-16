import CryptoKit
import Foundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
import SystemConfiguration
#endif

/// Who is sending: the app (with its icon) and the device. Collected once, on the main thread.
struct AppInfo {
    var app: KitApp
    var device: KitDevice
    var iconPNG: Data?

    /// Icons are sent at this size, square.
    static let iconPixels = 128

    static func collect(options: CloakProxyKit.Options) -> AppInfo {
        let bundle = Bundle.main
        let info = bundle.infoDictionary ?? [:]
        let process = ProcessInfo.processInfo.processName
        let named = [options.appName, info["CFBundleDisplayName"] as? String, info["CFBundleName"] as? String, process]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty } ?? "App"
        let icon = options.appIcon ?? iconPNG()
        let app = KitApp(name: named, bundleID: bundle.bundleIdentifier ?? "process.\(process)",
                         version: info["CFBundleShortVersionString"] as? String, build: info["CFBundleVersion"] as? String,
                         iconHash: icon.map(hash))
        return AppInfo(app: app, device: device(), iconPNG: icon)
    }

    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// The hardware model: "iPhone16,1", "Mac15,3".
    static func hardwareModel() -> String? {
        #if os(macOS)
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &bytes, &size, nil, 0) == 0 else { return nil }
        return String(cString: bytes)
        #else
        var system = utsname()
        uname(&system)
        let model = withUnsafeBytes(of: &system.machine) { raw in String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self) }
        return model.isEmpty ? nil : model
        #endif
    }

    /// A random id kept in the app's defaults, where the system offers nothing better.
    static func storedID() -> String {
        let key = "CloakProxyKit.deviceID"
        if let id = UserDefaults.standard.string(forKey: key) { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: key)
        return id
    }

    #if canImport(UIKit)
    static func device() -> KitDevice {
        let device = UIDevice.current
        let environment = ProcessInfo.processInfo.environment
        let kind: String
        switch device.userInterfaceIdiom {
        case .pad: kind = "iPad"
        case .tv: kind = "Apple TV"
        case .mac: kind = "Mac"
        default:
            if #available(iOS 17.0, tvOS 17.0, *), device.userInterfaceIdiom == .vision { kind = "Apple Vision Pro" } else { kind = device.model }
        }
        #if targetEnvironment(simulator)
        let simulator = true
        let name = environment["SIMULATOR_DEVICE_NAME"] ?? device.name
        let model = environment["SIMULATOR_MODEL_IDENTIFIER"] ?? hardwareModel()
        #else
        let simulator = false
        let name = device.name
        let model = hardwareModel()
        #endif
        return KitDevice(id: device.identifierForVendor?.uuidString ?? storedID(), name: name, model: model, kind: kind,
                         system: device.systemName, systemVersion: device.systemVersion, isSimulator: simulator)
    }

    /// The primary app icon from the bundle (CFBundleIcons), with rounded corners, as a PNG.
    static func iconPNG() -> Data? {
        let info = Bundle.main.infoDictionary ?? [:]
        let icons = (info["CFBundleIcons"] as? [String: Any])?["CFBundlePrimaryIcon"] as? [String: Any]
        let candidates = ((icons?["CFBundleIconFiles"] as? [String]) ?? []).reversed() + [icons?["CFBundleIconName"] as? String].compactMap { $0 }
        guard let image = candidates.lazy.compactMap({ UIImage(named: $0) }).first else { return nil }
        let size = CGSize(width: iconPixels, height: iconPixels)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        return UIGraphicsImageRenderer(size: size, format: format).pngData { _ in
            let rect = CGRect(origin: .zero, size: size)
            UIBezierPath(roundedRect: rect, cornerRadius: size.width * 0.2237).addClip()
            image.draw(in: rect)
        }
    }
    #elseif canImport(AppKit)
    static func device() -> KitDevice {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let name = (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? "Mac"
        return KitDevice(id: storedID(), name: name, model: hardwareModel(), kind: "Mac", system: "macOS",
                         systemVersion: "\(version.majorVersion).\(version.minorVersion)" + (version.patchVersion > 0 ? ".\(version.patchVersion)" : ""),
                         isSimulator: false)
    }

    /// The app's Finder icon. Command-line tools have none (pass `Options.appIcon`).
    static func iconPNG() -> Data? {
        let path = Bundle.main.bundlePath
        guard path.hasSuffix(".app") else { return nil }
        let image = NSWorkspace.shared.icon(forFile: path)
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: iconPixels, pixelsHigh: iconPixels, bitsPerSample: 8,
                                            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                            bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        image.draw(in: NSRect(x: 0, y: 0, width: iconPixels, height: iconPixels), from: .zero, operation: .copy, fraction: 1)
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.representation(using: .png, properties: [:])
    }
    #else
    static func device() -> KitDevice {
        KitDevice(id: storedID(), name: "Device", model: hardwareModel(), kind: "Device", system: "Unknown", systemVersion: "", isSimulator: false)
    }

    static func iconPNG() -> Data? { nil }
    #endif
}
