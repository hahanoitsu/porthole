import Foundation

public enum LogLevel: Int, Comparable, Sendable {
    case debug = 0, info, warning, error

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool { lhs.rawValue < rhs.rawValue }

    var tag: String {
        switch self {
        case .debug: return "DEBUG"
        case .info: return "INFO "
        case .warning: return "WARN "
        case .error: return "ERROR"
        }
    }
}

/// Writes timestamped lines to stderr and, once `openFile` is called, to a log file.
public final class Log: @unchecked Sendable {
    public static let shared = Log()

    public var level: LogLevel = .info
    public private(set) var fileURL: URL?

    private let queue = DispatchQueue(label: "porthole.log")
    private var handle: FileHandle?
    private let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    /// Starts a fresh log at `url`. Earlier runs' logs are kept next to it as
    /// "porthole-<start time>.log", the newest `keeping` of them.
    public func openFile(_ url: URL, keeping: Int = 10) {
        queue.sync {
            let fileManager = FileManager.default
            let directory = url.deletingLastPathComponent()
            try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let base = url.deletingPathExtension().lastPathComponent
            let stamp = DateFormatter()
            stamp.dateFormat = "yyyyMMdd-HHmmss"

            // Archive the last run's log (and the single "previous" log older versions kept).
            for old in [url, directory.appendingPathComponent("\(base).previous.log")] where fileManager.fileExists(atPath: old.path) {
                let started = (try? fileManager.attributesOfItem(atPath: old.path)[.creationDate] as? Date) ?? Date()
                let archived = directory.appendingPathComponent("\(base)-\(stamp.string(from: started)).log")
                if fileManager.fileExists(atPath: archived.path) {
                    try? fileManager.removeItem(at: old)
                } else {
                    try? fileManager.moveItem(at: old, to: archived)
                }
            }
            let archives = ((try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? [])
                .filter { $0.hasPrefix("\(base)-") && $0.hasSuffix(".log") }
                .sorted(by: >)
            for name in archives.dropFirst(keeping) {
                try? fileManager.removeItem(at: directory.appendingPathComponent(name))
            }

            fileManager.createFile(atPath: url.path, contents: nil)
            handle = try? FileHandle(forWritingTo: url)
            fileURL = url
        }
    }

    public func write(_ level: LogLevel, _ message: String) {
        guard level >= self.level else { return }
        let date = Date()
        queue.async {
            let line = "\(self.formatter.string(from: date)) [\(level.tag)] \(message)\n"
            let data = Data(line.utf8)
            FileHandle.standardError.write(data)
            self.handle?.write(data)
        }
    }
}

public func logDebug(_ message: @autoclosure () -> String) {
    if Log.shared.level <= .debug { Log.shared.write(.debug, message()) }
}

public func logInfo(_ message: @autoclosure () -> String) {
    Log.shared.write(.info, message())
}

public func logWarning(_ message: @autoclosure () -> String) {
    Log.shared.write(.warning, message())
}

public func logError(_ message: @autoclosure () -> String) {
    Log.shared.write(.error, message())
}
