import Foundation

/// 导出文件外层包装：带元信息便于后续 schema 演进与排错。
struct ProfileExport: Codable {
    /// schema 版本号；解码时不强制 == currentVersion，仅用于诊断
    let schemaVersion: Int
    let exportedAt: Date
    let appVersion: String
    let profiles: [AppProfile]

    /// v2: AppProfile 新增 `macros` 字段（v1.5）。v1 文件向前兼容——AppProfile.init(from:)
    /// 缺字段时回退到 `macros == []`，所以可以直接读旧文件。
    static let currentSchemaVersion: Int = 2

    init(profiles: [AppProfile]) {
        self.schemaVersion = Self.currentSchemaVersion
        self.exportedAt = Date()
        self.appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        self.profiles = profiles
    }
}

/// 导入合并策略
enum ImportMode {
    /// 按 bundleIdentifier 合并：相同 bundleId 的现有配置被传入版本覆盖；不存在则新增
    case merge
    /// 不论是否冲突一律新建（id 重新生成，避免 ObservableObject 内 id 冲突）
    case addAsNew
}

enum ImportError: LocalizedError {
    case decodeFailed(underlying: Error)
    case unsupportedSchema(version: Int)

    var errorDescription: String? {
        switch self {
        case .decodeFailed(let underlying):
            return "导入文件解析失败：\(underlying.localizedDescription)"
        case .unsupportedSchema(let v):
            return "不支持的 schema 版本：\(v)（当前支持 \(ProfileExport.currentSchemaVersion)）"
        }
    }
}
