import Foundation
import Combine
import os.log

@MainActor
final class AppLogger: ObservableObject {
    static let shared = AppLogger()

    @Published var logs: [String] = []
    private let maxLogs = 200

    private let osLog = OSLog(subsystem: "com.keysmirror.KeysMirror", category: "app")

    // DateFormatter 创建较贵，每次 log 都新建会成为热点；改为复用一个实例。
    // 仅在 main actor 上调用，无并发。
    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    private let logFileURL: URL
    private var logFileHandle: FileHandle?
    // 文件 I/O 串行队列，避免在主线程（含 CGEventTap 回调）阻塞。
    private let writeQueue = DispatchQueue(label: "com.keysmirror.AppLogger.write", qos: .utility)

    private init() {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("KeysMirror", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("keysmirror.log")
        logFileURL = url

        // 启动时把上一会话的日志归档为 .log.1（保留一份历史，便于排查崩溃）
        let archive = dir.appendingPathComponent("keysmirror.log.1")
        if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: archive)
            try? FileManager.default.moveItem(at: url, to: archive)
        }

        FileManager.default.createFile(atPath: url.path, contents: nil)
        logFileHandle = try? FileHandle(forWritingTo: url)
    }

    func log(_ message: String, type: String = "INFO") {
        let timestamp = Self.timestampFormatter.string(from: Date())
        let entry = "[\(timestamp)] [\(type)] \(message)"

        // os_log — Console.app / log stream 可见
        os_log("%{public}@", log: osLog, type: .default, entry)

        // 异步追加写文件 — 不阻塞主线程，即便写入卡顿也不影响 event tap 回调延迟
        if let data = (entry + "\n").data(using: .utf8), let handle = logFileHandle {
            writeQueue.async {
                handle.seekToEndOfFile()
                handle.write(data)
            }
        }

        // 内存缓冲供 UI
        logs.insert(entry, at: 0)
        if logs.count > maxLogs { logs.removeLast() }
    }

    func clear() {
        logs = []
        let handle = logFileHandle
        writeQueue.async {
            handle?.truncateFile(atOffset: 0)
            handle?.seek(toFileOffset: 0)
        }
    }

    /// 导出当前内存中的日志为 UTF-8 字符串，按时间正序（最早在前）排列，便于排查问题。
    /// 内存缓冲是 200 行的 ring buffer；如需完整历史请直接读取 `logFileURL`。
    func exportSnapshot() -> Data {
        let header = "KeysMirror 日志快照\n生成时间: \(Self.timestampFormatter.string(from: Date()))\n日志文件: \(logFileURL.path)\n────────────────────────────\n"
        // logs 内部是新→旧，导出时倒序为旧→新
        let body = logs.reversed().joined(separator: "\n")
        return (header + body + "\n").data(using: .utf8) ?? Data()
    }

    /// 当前持久化日志文件 URL，便于「在 Finder 中显示」操作。
    var currentLogFileURL: URL { logFileURL }
}
