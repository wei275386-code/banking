#if os(macOS)
import Foundation
import AppKit

/// Opt-in local diagnostics. Only operation names and durations are written.
@MainActor enum ReviewLatency {
    private static let output: URL? = {
        if let path = ProcessInfo.processInfo.environment["BANKING_LATENCY_LOG"] { return URL(fileURLWithPath: path) }
        guard let url = Bundle.main.url(forResource: "latency-profile", withExtension: "json"),
              let bytes = try? Data(contentsOf: url),
              let settings = try? JSONDecoder().decode([String: String].self, from: bytes),
              let path = settings["path"] else { return nil }
        return URL(fileURLWithPath: path)
    }()
    private static var starts = [String: UInt64]()
    private static let writer = DispatchQueue(label: "banking.latency-log", qos: .utility)
    static func begin(_ name: String) {
        guard output != nil else { return }
        starts[name] = DispatchTime.now().uptimeNanoseconds
    }
    static func finish(_ name: String) {
        guard output != nil, let start = starts.removeValue(forKey: name) else { return }
        record(name + ".swiftui-update", milliseconds: Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        // Run after this SwiftUI update has handed work back to the main queue.
        DispatchQueue.main.async {
            let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            record(name, milliseconds: ms)
        }
    }
    static func record(_ name: String, milliseconds: Double) {
        guard let output else { return }
        let active = NSApplication.shared.isActive
        writer.async {
            let payload: [String: Any] = ["operation": name, "ms": milliseconds, "appActive": active,
                                          "measurement": "operation wall time; swiftui-update stops at update callback; unsuffixed UI events stop after next main queue turn"]
            guard var bytes = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else { return }
            bytes.append(10)
            if !FileManager.default.fileExists(atPath: output.path) { FileManager.default.createFile(atPath: output.path, contents: nil) }
            guard let handle = try? FileHandle(forWritingTo: output) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd(); try? handle.write(contentsOf: bytes)
        }
    }

}
#else
import Foundation
@MainActor enum ReviewLatency {
    static func begin(_ name: String) {}
    static func finish(_ name: String) {}
    static func record(_ name: String, milliseconds: Double) {}
}
#endif
