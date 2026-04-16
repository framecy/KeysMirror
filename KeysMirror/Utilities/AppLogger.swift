import Foundation
import Combine
import os.log

@MainActor
final class AppLogger: ObservableObject {
    static let shared = AppLogger()

    @Published var logs: [String] = []
    private let maxLogs = 200

    private let osLog = OSLog(subsystem: "com.keysmirror.KeysMirror", category: "app")

    // 计算一次，缓存为实例变量（避免 stored-property closure 的初始化时序问题）
    private let logFileURL: URL
    private var logFileHandle: FileHandle?

    private init() {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("KeysMirror", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("keysmirror.log")
        logFileURL = url

        // 每次启动截断旧内容
        try? "".write(to: url, atomically: false, encoding: .utf8)
        logFileHandle = try? FileHandle(forWritingTo: url)
    }

    func log(_ message: String, type: String = "INFO") {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        let timestamp = formatter.string(from: Date())
        let entry = "[\(timestamp)] [\(type)] \(message)"

        // os_log — Console.app / log stream 可见
        os_log("%{public}@", log: osLog, type: .default, entry)

        // 追加写文件 — 可 tail -f 实时查看
        if let data = (entry + "\n").data(using: .utf8) {
            logFileHandle?.seekToEndOfFile()
            logFileHandle?.write(data)
        }

        // 内存缓冲供 UI
        logs.insert(entry, at: 0)
        if logs.count > maxLogs { logs.removeLast() }
    }

    func clear() {
        logs = []
        logFileHandle?.truncateFile(atOffset: 0)
        logFileHandle?.seek(toFileOffset: 0)
    }
}
