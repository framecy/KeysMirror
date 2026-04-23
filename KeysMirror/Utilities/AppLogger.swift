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
    /// init 后只读，writeQueue 上访问也安全。FileHandle 本身做了原子串行写。
    private nonisolated(unsafe) var logFileHandle: FileHandle?
    // 文件 I/O 串行队列，避免在主线程（含 CGEventTap 回调）阻塞。
    private let writeQueue = DispatchQueue(label: "com.keysmirror.AppLogger.write", qos: .utility)

    // 批量写盘缓冲区。INFO/TRACE/ACTION 级别累积，定时或满阈值后一次写盘；
    // ERROR/WARN 立即触发 flush，保证崩溃前能落盘。
    // 仅在 writeQueue 上访问 — 用 nonisolated(unsafe) 绕开 @MainActor 隔离，
    // 由 writeQueue 串行性自身保证线程安全。
    private nonisolated(unsafe) var pendingBuffer: [Data] = []
    private nonisolated(unsafe) var pendingByteCount: Int = 0
    private nonisolated(unsafe) var flushScheduled: Bool = false
    nonisolated private static let flushInterval: DispatchTimeInterval = .milliseconds(250)
    nonisolated private static let flushByteThreshold: Int = 16 * 1024
    nonisolated private static let immediateFlushTypes: Set<String> = ["ERROR", "WARN"]

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

        // 文件 I/O 走 writeQueue，批量合并写盘
        if let data = (entry + "\n").data(using: .utf8) {
            let isImmediate = Self.immediateFlushTypes.contains(type)
            writeQueue.async { [weak self] in
                self?.appendPending(data: data, immediate: isImmediate)
            }
        }

        // 内存缓冲供 UI
        logs.insert(entry, at: 0)
        if logs.count > maxLogs { logs.removeLast() }
    }

    /// writeQueue 内：将 entry 追加到 pending buffer，按需触发 flush。
    /// 触发条件：(1) immediate（ERROR/WARN）；(2) 累积 ≥16KB；(3) 250ms 定时器到期。
    private nonisolated func appendPending(data: Data, immediate: Bool) {
        pendingBuffer.append(data)
        pendingByteCount += data.count

        if immediate || pendingByteCount >= Self.flushByteThreshold {
            flushPending()
            return
        }

        guard !flushScheduled else { return }
        flushScheduled = true
        writeQueue.asyncAfter(deadline: .now() + Self.flushInterval) { [weak self] in
            self?.flushPending()
        }
    }

    /// writeQueue 内：将所有 pending 写入文件句柄并清空。
    private nonisolated func flushPending() {
        flushScheduled = false
        guard !pendingBuffer.isEmpty, let handle = logFileHandle else {
            pendingBuffer.removeAll()
            pendingByteCount = 0
            return
        }
        var combined = Data()
        combined.reserveCapacity(pendingByteCount)
        for chunk in pendingBuffer {
            combined.append(chunk)
        }
        pendingBuffer.removeAll(keepingCapacity: true)
        pendingByteCount = 0
        handle.seekToEndOfFile()
        handle.write(combined)
    }

    func clear() {
        logs = []
        let handle = logFileHandle
        writeQueue.async {
            self.pendingBuffer.removeAll()
            self.pendingByteCount = 0
            handle?.truncateFile(atOffset: 0)
            handle?.seek(toFileOffset: 0)
        }
    }

    /// 退出前同步 flush 一次，避免最后几条 log 丢盘（applicationWillTerminate 调用）。
    nonisolated func flushSync() {
        writeQueue.sync {
            self.flushPending()
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
