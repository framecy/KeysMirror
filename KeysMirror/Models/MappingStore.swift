import Foundation

extension Notification.Name {
    static let mappingStoreDidChange = Notification.Name("KeysMirror.MappingStoreDidChange")
}

@MainActor
final class MappingStore: ObservableObject {
    static let shared = MappingStore()

    @Published private(set) var profiles: [AppProfile] = [] {
        didSet { rebuildProfileIndex() }
    }

    /// `bundleIdentifier (lowercased) → AppProfile` 索引，`enabledProfile(bundleIdentifier:)` 走 O(1)。
    /// keyDown 热路径每次按键都会查一次，n 通常 < 50 时差距可忽略；这里更多是 hygiene。
    private var profileIndex: [String: AppProfile] = [:]

    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let fileURL: URL

    init(fileURL: URL? = nil) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
        self.fileURL = fileURL ?? Self.defaultFileURL()

        load() // Ensure data is loaded on init
    }

    func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            profiles = []
            return
        }

        do {
            let data = try Data(contentsOf: fileURL)
            profiles = try decoder.decode([AppProfile].self, from: data)
        } catch {
            // 损坏文件不能直接被 save() 覆盖，否则用户的所有配置会永久丢失。
            // 重命名为带时间戳的备份，便于后续手动找回，再以空配置启动。
            let timestamp = Int(Date().timeIntervalSince1970)
            let backupURL = fileURL
                .deletingLastPathComponent()
                .appendingPathComponent("mappings.json.bak.\(timestamp)")
            do {
                try FileManager.default.moveItem(at: fileURL, to: backupURL)
                NSLog("KeysMirror: mappings.json 解析失败，已备份为 \(backupURL.lastPathComponent)：\(error.localizedDescription)")
            } catch {
                NSLog("KeysMirror: mappings.json 解析失败且备份失败：\(error.localizedDescription)")
            }
            profiles = []
        }
    }

    /// 写盘防抖窗口。拖拽排序、连续调滑块这类操作会在几十毫秒内触发十几次 CRUD，
    /// 每次都同步原子写盘（编码整份配置 + 落盘 + rename）会卡在主线程上，表现为界面发涩。
    /// 300ms 内的连续改动合并成一次写。代价是极端情况下（进程被强杀）可能丢最后 300ms 的
    /// 编辑——所以退出、失焦、导出前都会 `flush()` 强制落盘。
    private static let saveDebounce: TimeInterval = 0.3
    private var pendingSave: DispatchWorkItem?

    /// 记录一次变更：**内存与 UI 立刻生效**，落盘延后合并。
    ///
    /// 通知必须同步发——菜单栏、overlay、拦截器都靠它刷新，延后会让界面比数据慢半拍。
    func save() {
        NotificationCenter.default.post(name: .mappingStoreDidChange, object: self)

        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingSave = nil
            self.writeToDisk()
        }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.saveDebounce, execute: work)
    }

    /// 立刻把挂起的改动落盘。退出前、导出前、App 失去焦点时调用。
    /// 没有挂起改动时是空操作，可以放心多调。
    func flush() {
        guard let pending = pendingSave else { return }
        pending.cancel()
        pendingSave = nil
        writeToDisk()
    }

    private func writeToDisk() {
        do {
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try encoder.encode(profiles)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("KeysMirror failed to save mappings: \(error.localizedDescription)")
        }
    }

    func enabledProfile(bundleIdentifier: String) -> AppProfile? {
        guard let profile = profileIndex[bundleIdentifier.lowercased()] else { return nil }
        return profile.isEnabled ? profile : nil
    }

    private func rebuildProfileIndex() {
        var index: [String: AppProfile] = [:]
        index.reserveCapacity(profiles.count)
        for profile in profiles {
            index[profile.bundleIdentifier.lowercased()] = profile
        }
        profileIndex = index
    }

    func addProfile(bundleIdentifier: String, appName: String) {
        guard !bundleIdentifier.isEmpty else { return }
        guard !profiles.contains(where: { $0.bundleIdentifier == bundleIdentifier }) else { return }

        profiles.append(AppProfile(bundleIdentifier: bundleIdentifier, appName: appName))
        save()
    }

    func updateProfile(_ profile: AppProfile) {
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        profiles[index] = profile
        save()
    }

    func deleteProfile(_ profile: AppProfile) {
        profiles.removeAll { $0.id == profile.id }
        save()
    }

    /// 撤销删除：把整个 profile（含映射与宏）原样放回原位置。
    /// 已存在同 id 时不重复插入；`index` 越界时追加到末尾。
    func restoreProfile(_ profile: AppProfile, at index: Int? = nil) {
        guard !profiles.contains(where: { $0.id == profile.id }) else { return }
        if let index, index >= 0, index <= profiles.count {
            profiles.insert(profile, at: index)
        } else {
            profiles.append(profile)
        }
        save()
    }

    func indexOfProfile(_ profile: AppProfile) -> Int? {
        profiles.firstIndex(where: { $0.id == profile.id })
    }

    func addMapping(_ mapping: KeyMapping, to profile: AppProfile) {
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        profiles[index].mappings.append(mapping)
        save()
    }

    func updateMapping(_ mapping: KeyMapping, in profile: AppProfile) {
        guard let profileIndex = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        guard let mappingIndex = profiles[profileIndex].mappings.firstIndex(where: { $0.id == mapping.id }) else { return }

        profiles[profileIndex].mappings[mappingIndex] = mapping
        save()
    }

    func deleteMapping(_ mapping: KeyMapping, from profile: AppProfile) {
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        profiles[index].mappings.removeAll { $0.id == mapping.id }
        save()
    }

    /// 撤销删除用：放回原来的位置（列表顺序不跳动）。越界或已存在时退化为 append。
    func insertMapping(_ mapping: KeyMapping, at index: Int, in profile: AppProfile) {
        guard let p = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        guard !profiles[p].mappings.contains(where: { $0.id == mapping.id }) else { return }
        let target = min(max(index, 0), profiles[p].mappings.count)
        profiles[p].mappings.insert(mapping, at: target)
        save()
    }

    func indexOfMapping(_ mapping: KeyMapping, in profile: AppProfile) -> Int? {
        profiles.first(where: { $0.id == profile.id })?.mappings.firstIndex(where: { $0.id == mapping.id })
    }

    // MARK: - Macros

    func addMacro(_ macro: MacroAction, to profile: AppProfile) {
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        profiles[index].macros.append(macro)
        save()
    }

    func updateMacro(_ macro: MacroAction, in profile: AppProfile) {
        guard let profileIndex = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        guard let macroIndex = profiles[profileIndex].macros.firstIndex(where: { $0.id == macro.id }) else { return }
        profiles[profileIndex].macros[macroIndex] = macro
        save()
    }

    func deleteMacro(_ macro: MacroAction, from profile: AppProfile) {
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        profiles[index].macros.removeAll { $0.id == macro.id }
        save()
    }

    /// 撤销删除用：放回原来的位置。
    func insertMacro(_ macro: MacroAction, at index: Int, in profile: AppProfile) {
        guard let p = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        guard !profiles[p].macros.contains(where: { $0.id == macro.id }) else { return }
        let target = min(max(index, 0), profiles[p].macros.count)
        profiles[p].macros.insert(macro, at: target)
        save()
    }

    func indexOfMacro(_ macro: MacroAction, in profile: AppProfile) -> Int? {
        profiles.first(where: { $0.id == profile.id })?.macros.firstIndex(where: { $0.id == macro.id })
    }

    // MARK: - Trigger conflicts

    /// 跨 mappings 与 macros 检查触发器冲突。一个 trigger 只能绑定到一条记录上，
    /// 否则 KeyInterceptor 在 dispatch 时会出现优先级歧义。
    func hasDuplicateTrigger(
        triggerType: TriggerType,
        keyCode: UInt16,
        modifiers: UInt64,
        mouseButtonNumber: Int?,
        in profile: AppProfile,
        excludingMappingId: UUID? = nil,
        excludingMacroId: UUID? = nil
    ) -> Bool {
        guard let stored = profiles.first(where: { $0.id == profile.id }) else { return false }

        let mappingHit = stored.mappings.contains { other in
            if let excludingMappingId, other.id == excludingMappingId { return false }
            return triggersMatch(
                lhsType: other.triggerType, lhsKey: other.keyCode, lhsMods: other.modifiers, lhsMouse: other.mouseButtonNumber,
                rhsType: triggerType, rhsKey: keyCode, rhsMods: modifiers, rhsMouse: mouseButtonNumber
            )
        }
        if mappingHit { return true }

        let macroHit = stored.macros.contains { other in
            if let excludingMacroId, other.id == excludingMacroId { return false }
            return triggersMatch(
                lhsType: other.triggerType, lhsKey: other.keyCode, lhsMods: other.modifiers, lhsMouse: other.mouseButtonNumber,
                rhsType: triggerType, rhsKey: keyCode, rhsMods: modifiers, rhsMouse: mouseButtonNumber
            )
        }
        return macroHit
    }

    /// 与 `hasDuplicateTrigger` 同一判定，但返回**占用者是谁**，
    /// 供「⌃⇧K 已被宏『连点』占用」这类指名道姓的提示与键位总览使用。
    func triggerOwner(
        triggerType: TriggerType,
        keyCode: UInt16,
        modifiers: UInt64,
        mouseButtonNumber: Int?,
        in profile: AppProfile,
        excludingMappingId: UUID? = nil,
        excludingMacroId: UUID? = nil
    ) -> TriggerOccupancy? {
        guard let stored = profiles.first(where: { $0.id == profile.id }) else { return nil }

        if let hit = stored.mappings.first(where: { other in
            if let excludingMappingId, other.id == excludingMappingId { return false }
            return triggersMatch(
                lhsType: other.triggerType, lhsKey: other.keyCode, lhsMods: other.modifiers, lhsMouse: other.mouseButtonNumber,
                rhsType: triggerType, rhsKey: keyCode, rhsMods: modifiers, rhsMouse: mouseButtonNumber
            )
        }) {
            return TriggerOccupancy(mapping: hit)
        }

        if let hit = stored.macros.first(where: { other in
            if let excludingMacroId, other.id == excludingMacroId { return false }
            return triggersMatch(
                lhsType: other.triggerType, lhsKey: other.keyCode, lhsMods: other.modifiers, lhsMouse: other.mouseButtonNumber,
                rhsType: triggerType, rhsKey: keyCode, rhsMods: modifiers, rhsMouse: mouseButtonNumber
            )
        }) {
            return TriggerOccupancy(macro: hit)
        }

        return nil
    }

    /// 旧 KeyMapping 重载：保持既有调用点不动。
    func hasDuplicateTrigger(_ candidate: KeyMapping, in profile: AppProfile, excludingId: UUID? = nil) -> Bool {
        return hasDuplicateTrigger(
            triggerType: candidate.triggerType,
            keyCode: candidate.keyCode,
            modifiers: candidate.modifiers,
            mouseButtonNumber: candidate.mouseButtonNumber,
            in: profile,
            excludingMappingId: excludingId ?? candidate.id
        )
    }

    private func triggersMatch(
        lhsType: TriggerType, lhsKey: UInt16, lhsMods: UInt64, lhsMouse: Int?,
        rhsType: TriggerType, rhsKey: UInt16, rhsMods: UInt64, rhsMouse: Int?
    ) -> Bool {
        guard lhsType == rhsType else { return false }
        switch lhsType {
        case .keyboard:
            return lhsKey == rhsKey && lhsMods == rhsMods
        case .mouseRight:
            return true
        case .mouseOther:
            return lhsMouse == rhsMouse
        }
    }

    // MARK: - 导入 / 导出

    /// 导出指定 profiles（带 schema 元信息）。caller 决定是单个还是全部。
    func exportData(for profiles: [AppProfile]) throws -> Data {
        let payload = ProfileExport(profiles: profiles)
        return try encoder.encode(payload)
    }

    /// 导入 JSON 数据；merge 模式下 bundleId 相同则覆盖，不同则新增；
    /// addAsNew 模式无脑追加（profile id 重新生成避免内存中冲突）。
    @discardableResult
    func importProfiles(from data: Data, mode: ImportMode) throws -> Int {
        let payload: ProfileExport
        do {
            payload = try decoder.decode(ProfileExport.self, from: data)
        } catch {
            // 兼容裸数组导出：尝试直接解码 [AppProfile]
            do {
                let bare = try decoder.decode([AppProfile].self, from: data)
                payload = ProfileExport(profiles: bare)
            } catch {
                throw ImportError.decodeFailed(underlying: error)
            }
        }

        guard payload.schemaVersion <= ProfileExport.currentSchemaVersion else {
            throw ImportError.unsupportedSchema(version: payload.schemaVersion)
        }

        var imported = 0
        for incoming in payload.profiles {
            switch mode {
            // ⚠️ 这里**只能**改 id，其余字段必须整份照搬 incoming。
            // 曾经的写法是逐个字段手工构造 AppProfile，结果每次给 AppProfile 加新字段
            // 都会在这里被静默漏掉、落回默认值——HUD 的四个设置（显示与否 / 贴哪个角 /
            // 形态 / 日志过滤）和每应用按压时长都这样丢过：导出再导入，这些设置全被清掉，
            // 而且没有任何报错。整份复制之后，以后再加字段也不会重蹈覆辙。
            case .merge:
                if let idx = profiles.firstIndex(where: { $0.bundleIdentifier.lowercased() == incoming.bundleIdentifier.lowercased() }) {
                    // 保留原 profile id（UI 的选中态、撤销记录都认这个 id），其余整份覆盖
                    var replaced = incoming
                    replaced.id = profiles[idx].id
                    profiles[idx] = replaced
                } else {
                    profiles.append(incoming)
                }
            case .addAsNew:
                // 重新生成 id，避免和内存里已有的 profile 撞 id
                var copy = incoming
                copy.id = UUID()
                profiles.append(copy)
            }
            imported += 1
        }
        save()
        // 导入是一次性的大改动，用户会立刻期待「已经存好了」；不等防抖窗口，直接落盘。
        flush()
        return imported
    }

    static func defaultFileURL() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport
            .appendingPathComponent("KeysMirror", isDirectory: true)
            .appendingPathComponent("mappings.json")
    }
}
