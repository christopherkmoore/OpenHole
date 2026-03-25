import Foundation
import os

final class AppLogger: @unchecked Sendable {
    static let shared = AppLogger()

    private let osLog = os.Logger(subsystem: "com.openhole.ai", category: "general")
    private let fileURL: URL
    private let queue = DispatchQueue(label: "com.openhole.ai.logger")

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        fileURL = docs.appendingPathComponent("openhole.log")

        // Trim log if over 500KB
        if let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
           let size = attrs[.size] as? Int, size > 500_000 {
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    func debug(_ message: String, file: String = #fileID, function: String = #function) {
        log(.debug, message, file: file, function: function)
    }

    func info(_ message: String, file: String = #fileID, function: String = #function) {
        log(.info, message, file: file, function: function)
    }

    func error(_ message: String, file: String = #fileID, function: String = #function) {
        log(.error, message, file: file, function: function)
    }

    private func log(_ level: OSLogType, _ message: String, file: String, function: String) {
        let tag = file.split(separator: "/").last.map(String.init) ?? file
        let prefix = "[\(tag):\(function)]"

        switch level {
        case .debug: osLog.debug("\(prefix) \(message)")
        case .info:  osLog.info("\(prefix) \(message)")
        case .error: osLog.error("\(prefix) \(message)")
        default:     osLog.log("\(prefix) \(message)")
        }

        queue.async { [fileURL] in
            let timestamp = ISO8601DateFormatter().string(from: Date())
            let line = "\(timestamp) \(prefix) \(message)\n"
            if let data = line.data(using: .utf8) {
                if FileManager.default.fileExists(atPath: fileURL.path) {
                    if let handle = try? FileHandle(forWritingTo: fileURL) {
                        handle.seekToEndOfFile()
                        handle.write(data)
                        handle.closeFile()
                    }
                } else {
                    try? data.write(to: fileURL)
                }
            }
        }
    }

    var logFileURL: URL { fileURL }
}

let holeLog = AppLogger.shared
