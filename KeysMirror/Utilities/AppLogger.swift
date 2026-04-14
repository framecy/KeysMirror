import Foundation
import Combine

@MainActor
final class AppLogger: ObservableObject {
    static let shared = AppLogger()
    
    @Published var logs: [String] = []
    private let maxLogs = 100
    
    private init() {}
    
    func log(_ message: String, type: String = "INFO") {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        let timestamp = formatter.string(from: Date())
        let entry = "[\(timestamp)] [\(type)] \(message)"
        
        // Print to system console
        NSLog("KeysMirror: \(entry)")
        
        // Keep in memory for UI
        logs.insert(entry, at: 0)
        if logs.count > maxLogs {
            logs.removeLast()
        }
    }
    
    func clear() {
        logs = []
    }
}
