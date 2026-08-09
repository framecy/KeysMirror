import XCTest
@testable import KeysMirror

@MainActor
final class MappingStoreTests: XCTestCase {
    func testStorePersistsProfilesAndMappings() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = directory.appendingPathComponent("mappings.json")
        let store = MappingStore(fileURL: fileURL)

        store.addProfile(bundleIdentifier: "com.apple.TextEdit", appName: "TextEdit")
        let profile = try XCTUnwrap(store.profiles.first)
        let mapping = KeyMapping(keyCode: 40, modifiers: 0, relativeX: 100, relativeY: 50, label: "Attack")
        store.addMapping(mapping, to: profile)
        store.flush()   // 写盘是防抖的，断言落盘内容前先强制落盘

        let reloadedStore = MappingStore(fileURL: fileURL)
        reloadedStore.load()

        let reloadedProfile = try XCTUnwrap(reloadedStore.profiles.first)
        XCTAssertEqual(reloadedProfile.bundleIdentifier, "com.apple.TextEdit")
        XCTAssertEqual(reloadedProfile.mappings.first?.label, "Attack")
        XCTAssertEqual(reloadedProfile.mappings.first?.relativeX, 100)
        XCTAssertEqual(reloadedProfile.mappings.first?.relativeY, 50)
    }

    func testCorruptMappingsFileIsBackedUpInsteadOfWiped() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("mappings.json")

        let garbage = Data("{ this is not valid json".utf8)
        try garbage.write(to: fileURL)

        let store = MappingStore(fileURL: fileURL)
        XCTAssertTrue(store.profiles.isEmpty)

        let backups = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix("mappings.json.bak.") }
        XCTAssertEqual(backups.count, 1, "解析失败的文件必须保留备份，不能被静默覆盖")

        // 原文件已被搬走，新写入不会污染备份
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testExportImportRoundTripMergesByBundleId() throws {
        let dir1 = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store1 = MappingStore(fileURL: dir1.appendingPathComponent("mappings.json"))
        store1.addProfile(bundleIdentifier: "com.acme.game", appName: "Game")
        let p1 = store1.profiles[0]
        store1.addMapping(KeyMapping(keyCode: 12, modifiers: 0, relativeX: 10, relativeY: 20, label: "Q"), to: p1)

        let exported = try store1.exportData(for: store1.profiles)

        let dir2 = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store2 = MappingStore(fileURL: dir2.appendingPathComponent("mappings.json"))
        // 预先放一个不同 bundleId 的配置
        store2.addProfile(bundleIdentifier: "com.other.app", appName: "Other")
        // 再放一个相同 bundleId 的旧配置（应被覆盖）
        store2.addProfile(bundleIdentifier: "com.acme.game", appName: "OldGame")

        let imported = try store2.importProfiles(from: exported, mode: .merge)
        XCTAssertEqual(imported, 1)
        XCTAssertEqual(store2.profiles.count, 2, "merge 应覆盖同 bundleId，不应新增")

        let merged = try XCTUnwrap(store2.profiles.first { $0.bundleIdentifier == "com.acme.game" })
        XCTAssertEqual(merged.appName, "Game")
        XCTAssertEqual(merged.mappings.first?.label, "Q")
    }

    func testImportAddAsNewAlwaysAppends() throws {
        let dir1 = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store1 = MappingStore(fileURL: dir1.appendingPathComponent("mappings.json"))
        store1.addProfile(bundleIdentifier: "com.acme.game", appName: "Game")
        let exported = try store1.exportData(for: store1.profiles)

        let dir2 = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store2 = MappingStore(fileURL: dir2.appendingPathComponent("mappings.json"))
        store2.addProfile(bundleIdentifier: "com.acme.game", appName: "Existing")

        let imported = try store2.importProfiles(from: exported, mode: .addAsNew)
        XCTAssertEqual(imported, 1)
        XCTAssertEqual(store2.profiles.count, 2, "addAsNew 即使 bundleId 冲突也应追加")
    }

    func testImportAcceptsBareProfileArrayForBackwardCompat() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = MappingStore(fileURL: dir.appendingPathComponent("mappings.json"))

        let bare = [AppProfile(bundleIdentifier: "com.legacy.app", appName: "Legacy")]
        let encoder = JSONEncoder()
        let data = try encoder.encode(bare)

        let imported = try store.importProfiles(from: data, mode: .merge)
        XCTAssertEqual(imported, 1)
        XCTAssertEqual(store.profiles.first?.bundleIdentifier, "com.legacy.app")
    }

    func testDuplicateTriggerIsDetected() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = directory.appendingPathComponent("mappings.json")
        let store = MappingStore(fileURL: fileURL)

        store.addProfile(bundleIdentifier: "com.apple.TextEdit", appName: "TextEdit")
        let profile = store.profiles[0]
        let existing = KeyMapping(keyCode: 12, modifiers: 0, relativeX: 10, relativeY: 10, label: "Q")
        store.addMapping(existing, to: profile)

        let dup = KeyMapping(keyCode: 12, modifiers: 0, relativeX: 99, relativeY: 99, label: "Other")
        XCTAssertTrue(store.hasDuplicateTrigger(dup, in: profile))

        // 不同修饰键不算重复
        let withMod = KeyMapping(keyCode: 12, modifiers: 0x100000, relativeX: 0, relativeY: 0, label: "Cmd+Q")
        XCTAssertFalse(store.hasDuplicateTrigger(withMod, in: profile))

        // 编辑自身不算重复
        XCTAssertFalse(store.hasDuplicateTrigger(existing, in: profile, excludingId: existing.id))
    }

    // MARK: - Macros

    func testMacroCRUDPersists() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = directory.appendingPathComponent("mappings.json")
        let store = MappingStore(fileURL: fileURL)

        store.addProfile(bundleIdentifier: "com.acme.game", appName: "Game")
        let profile = store.profiles[0]

        let macro = MacroAction(
            label: "日常",
            triggerType: .keyboard,
            keyCode: 122,
            repeatCount: 3,
            steps: [
                MacroStep(delaySeconds: 0, position: .inline(relativeX: 100, relativeY: 100, referenceWidth: 800, referenceHeight: 600)),
                MacroStep(delaySeconds: 2, position: .inline(relativeX: 200, relativeY: 200, referenceWidth: 800, referenceHeight: 600))
            ]
        )
        store.addMacro(macro, to: profile)
        store.flush()

        let reloaded = MappingStore(fileURL: fileURL)
        XCTAssertEqual(reloaded.profiles.first?.macros.count, 1)
        XCTAssertEqual(reloaded.profiles.first?.macros.first?.label, "日常")
        XCTAssertEqual(reloaded.profiles.first?.macros.first?.steps.count, 2)

        // update
        var updated = reloaded.profiles[0].macros[0]
        updated.label = "日常 v2"
        reloaded.updateMacro(updated, in: reloaded.profiles[0])
        reloaded.flush()

        let reloaded2 = MappingStore(fileURL: fileURL)
        XCTAssertEqual(reloaded2.profiles[0].macros.first?.label, "日常 v2")

        // delete
        reloaded2.deleteMacro(reloaded2.profiles[0].macros[0], from: reloaded2.profiles[0])
        reloaded2.flush()
        let reloaded3 = MappingStore(fileURL: fileURL)
        XCTAssertTrue(reloaded3.profiles[0].macros.isEmpty)
    }

    func testTriggerConflictAcrossMappingAndMacro() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = directory.appendingPathComponent("mappings.json")
        let store = MappingStore(fileURL: fileURL)

        store.addProfile(bundleIdentifier: "com.acme.game", appName: "Game")
        let profile = store.profiles[0]

        // 已有 mapping 占用 F1
        store.addMapping(KeyMapping(keyCode: 122, modifiers: 0, relativeX: 0, relativeY: 0, label: "Click"), to: profile)

        // 新建宏想用 F1 → 冲突
        XCTAssertTrue(store.hasDuplicateTrigger(
            triggerType: .keyboard, keyCode: 122, modifiers: 0, mouseButtonNumber: nil,
            in: profile
        ))

        // 不同 trigger 不冲突
        XCTAssertFalse(store.hasDuplicateTrigger(
            triggerType: .keyboard, keyCode: 123, modifiers: 0, mouseButtonNumber: nil,
            in: profile
        ))

        // 已有宏占用 F2，再来一条同 trigger 的宏：编辑自身不冲突，新增冲突
        let macro = MacroAction(label: "M", triggerType: .keyboard, keyCode: 120, steps: [
            MacroStep(position: .inline(relativeX: 0, relativeY: 0, referenceWidth: nil, referenceHeight: nil))
        ])
        store.addMacro(macro, to: profile)

        XCTAssertTrue(store.hasDuplicateTrigger(
            triggerType: .keyboard, keyCode: 120, modifiers: 0, mouseButtonNumber: nil,
            in: profile
        ))
        XCTAssertFalse(store.hasDuplicateTrigger(
            triggerType: .keyboard, keyCode: 120, modifiers: 0, mouseButtonNumber: nil,
            in: profile,
            excludingMacroId: macro.id
        ))
    }

    // MARK: - profileIndex (PR1.6 缓存)

    func testEnabledProfileIsCaseInsensitive() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = MappingStore(fileURL: dir.appendingPathComponent("mappings.json"))
        store.addProfile(bundleIdentifier: "com.Acme.App", appName: "App")

        XCTAssertNotNil(store.enabledProfile(bundleIdentifier: "com.acme.app"))
        XCTAssertNotNil(store.enabledProfile(bundleIdentifier: "COM.ACME.APP"))
        XCTAssertNotNil(store.enabledProfile(bundleIdentifier: "com.Acme.App"))
    }

    func testEnabledProfileReturnsNilForDisabledProfile() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = MappingStore(fileURL: dir.appendingPathComponent("mappings.json"))
        store.addProfile(bundleIdentifier: "com.acme.app", appName: "App")
        var p = store.profiles[0]
        p.isEnabled = false
        store.updateProfile(p)

        XCTAssertNil(store.enabledProfile(bundleIdentifier: "com.acme.app"),
                     "isEnabled=false 的 profile 不应被 enabledProfile 命中")
    }

    func testProfileIndexUpdatesAfterAddAndDelete() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = MappingStore(fileURL: dir.appendingPathComponent("mappings.json"))

        XCTAssertNil(store.enabledProfile(bundleIdentifier: "com.acme.app"))
        store.addProfile(bundleIdentifier: "com.acme.app", appName: "App")
        XCTAssertNotNil(store.enabledProfile(bundleIdentifier: "com.acme.app"))

        store.deleteProfile(store.profiles[0])
        XCTAssertNil(store.enabledProfile(bundleIdentifier: "com.acme.app"),
                     "删除 profile 后字典索引应同步移除")
    }

    func testProfileIndexUpdatesAfterUpdateProfile() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = MappingStore(fileURL: dir.appendingPathComponent("mappings.json"))
        store.addProfile(bundleIdentifier: "com.acme.app", appName: "Old")
        var p = store.profiles[0]
        p.appName = "New"
        store.updateProfile(p)

        XCTAssertEqual(store.enabledProfile(bundleIdentifier: "com.acme.app")?.appName, "New",
                       "update profile 后字典索引应反映最新值")
    }

    func testExportImportPreservesMacros() throws {
        let dir1 = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store1 = MappingStore(fileURL: dir1.appendingPathComponent("mappings.json"))
        store1.addProfile(bundleIdentifier: "com.acme.game", appName: "Game")
        let profile1 = store1.profiles[0]
        store1.addMacro(MacroAction(
            label: "测试宏",
            triggerType: .keyboard,
            keyCode: 12,
            repeatCount: 5,
            steps: [
                MacroStep(delaySeconds: 1.5, position: .inline(relativeX: 50, relativeY: 60, referenceWidth: 1024, referenceHeight: 768))
            ]
        ), to: profile1)

        let exported = try store1.exportData(for: store1.profiles)

        let dir2 = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store2 = MappingStore(fileURL: dir2.appendingPathComponent("mappings.json"))
        let imported = try store2.importProfiles(from: exported, mode: .merge)
        XCTAssertEqual(imported, 1)

        let restored = try XCTUnwrap(store2.profiles.first)
        XCTAssertEqual(restored.macros.count, 1)
        XCTAssertEqual(restored.macros.first?.label, "测试宏")
        XCTAssertEqual(restored.macros.first?.steps.first?.delaySeconds, 1.5)
    }

    // MARK: - 导入不丢字段

    /// 导入曾经会把 HUD 的四个设置和每应用按压时长静默重置成默认值——
    /// `importProfiles` 逐字段手工构造 AppProfile，每加一个新字段就漏一个。
    /// 用户感知是「导出再导入，我调好的 HUD 全没了」，而且没有任何报错。
    ///
    /// 这条用例把「整份复制、只改 id」的语义钉死：任何人以后再给 AppProfile 加字段，
    /// 只要在导入路径上退回手工构造，这里就会红。
    func testMergeImportPreservesEveryProfileField() throws {
        let dir1 = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let source = MappingStore(fileURL: dir1.appendingPathComponent("mappings.json"))
        source.addProfile(bundleIdentifier: "com.acme.game", appName: "Game")

        // 把所有「非默认值」都设上，默认值蒙混不过去
        var configured = source.profiles[0]
        configured.showHUD = false
        configured.hudCorner = .bottomLeading
        configured.hudMode = .compact
        configured.hudLogFilter = .all
        configured.clickDwellMs = 60
        configured.overlayOpacity = 0.9
        configured.showOverlay = false
        source.updateProfile(configured)

        let exported = try source.exportData(for: source.profiles)

        // 目标里已存在同 bundleId 的 profile → 走 merge 的「覆盖」分支
        let dir2 = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let target = MappingStore(fileURL: dir2.appendingPathComponent("mappings.json"))
        target.addProfile(bundleIdentifier: "com.acme.game", appName: "旧名字")
        let originalId = target.profiles[0].id

        _ = try target.importProfiles(from: exported, mode: .merge)

        let merged = try XCTUnwrap(target.profiles.first)
        XCTAssertEqual(merged.id, originalId, "merge 必须保留原 id，UI 选中态和撤销记录都认它")
        XCTAssertEqual(merged.appName, "Game")
        XCTAssertEqual(merged.showHUD, false)
        XCTAssertEqual(merged.hudCorner, .bottomLeading)
        XCTAssertEqual(merged.hudMode, .compact)
        XCTAssertEqual(merged.hudLogFilter, .all)
        XCTAssertEqual(merged.clickDwellMs, 60)
        XCTAssertEqual(merged.overlayOpacity, 0.9, accuracy: 0.0001)
        XCTAssertEqual(merged.showOverlay, false)
    }

    /// addAsNew 分支同样不能丢字段；它只该换一个新 id。
    func testAddAsNewImportPreservesEveryProfileFieldButRegeneratesId() throws {
        let dir1 = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let source = MappingStore(fileURL: dir1.appendingPathComponent("mappings.json"))
        source.addProfile(bundleIdentifier: "com.acme.game", appName: "Game")
        var configured = source.profiles[0]
        configured.hudMode = .hidden
        configured.clickDwellMs = 80
        configured.isEnabled = false
        source.updateProfile(configured)
        let sourceId = configured.id

        let exported = try source.exportData(for: source.profiles)

        let dir2 = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let target = MappingStore(fileURL: dir2.appendingPathComponent("mappings.json"))
        _ = try target.importProfiles(from: exported, mode: .addAsNew)

        let added = try XCTUnwrap(target.profiles.first)
        XCTAssertNotEqual(added.id, sourceId, "addAsNew 必须换新 id，避免和已有 profile 撞")
        XCTAssertEqual(added.hudMode, .hidden)
        XCTAssertEqual(added.clickDwellMs, 80)
        XCTAssertEqual(added.isEnabled, false)
    }

    // MARK: - 写盘防抖

    /// 连续 CRUD 只落盘一次：拖拽排序 / 连按开关会在几十毫秒内触发十几次 save()，
    /// 每次都同步编码整份配置 + 原子写盘会卡主线程，界面发涩。
    func testRapidEditsCoalesceIntoOneWrite() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = dir.appendingPathComponent("mappings.json")
        let store = MappingStore(fileURL: fileURL)

        for i in 0..<10 {
            store.addProfile(bundleIdentifier: "com.acme.app\(i)", appName: "App \(i)")
        }
        // 防抖窗口内还没落盘：文件此时应该压根不存在
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path),
                       "防抖窗口内不该发生写盘")

        store.flush()
        let onDisk = try JSONDecoder().decode([AppProfile].self, from: Data(contentsOf: fileURL))
        XCTAssertEqual(onDisk.count, 10, "flush 后必须一次性写入全部改动，不能只写最后一条")
    }

    /// UI 靠 mappingStoreDidChange 刷新（菜单栏、overlay、拦截器都订阅它）。
    /// 落盘可以延后，通知不行——延后会让界面比数据慢半拍。
    func testChangeNotificationIsPostedImmediatelyEvenThoughWriteIsDeferred() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = MappingStore(fileURL: dir.appendingPathComponent("mappings.json"))

        let notified = expectation(description: "变更通知同步送达")
        let token = NotificationCenter.default.addObserver(
            forName: .mappingStoreDidChange, object: store, queue: .main
        ) { _ in notified.fulfill() }
        defer { NotificationCenter.default.removeObserver(token) }

        store.addProfile(bundleIdentifier: "com.acme.app", appName: "App")
        wait(for: [notified], timeout: 0.1)
    }

    /// 没有挂起改动时 flush 是空操作，可以放心在退出 / 失焦路径上多调。
    func testFlushWithoutPendingChangesIsNoop() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = dir.appendingPathComponent("mappings.json")
        let store = MappingStore(fileURL: fileURL)

        store.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path),
                       "什么都没改就 flush，不该凭空创建配置文件")
    }

    /// 导入是一次性大改动，用户会立刻期待「存好了」——不等防抖窗口。
    func testImportFlushesImmediately() throws {
        let dir1 = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let source = MappingStore(fileURL: dir1.appendingPathComponent("mappings.json"))
        source.addProfile(bundleIdentifier: "com.acme.game", appName: "Game")
        let exported = try source.exportData(for: source.profiles)

        let dir2 = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = dir2.appendingPathComponent("mappings.json")
        let target = MappingStore(fileURL: fileURL)
        _ = try target.importProfiles(from: exported, mode: .merge)

        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path),
                      "导入后必须已经落盘，不能还挂在防抖窗口里")
    }

    // MARK: - 向前兼容（v1.7.1 新增字段）

    /// 旧 mappings.json / .playmap 没有 clickDwellMs 字段 → 必须解成 nil 并走全局默认，
    /// 不能因为多了个字段就让老用户的配置读不出来。
    func testLegacyProfileWithoutDwellDecodesToDefault() throws {
        let json = """
        [{"bundleIdentifier":"com.acme.game","appName":"Game","mappings":[],"isEnabled":true}]
        """.data(using: .utf8)!
        let profiles = try JSONDecoder().decode([AppProfile].self, from: json)
        let profile = try XCTUnwrap(profiles.first)
        XCTAssertNil(profile.clickDwellMs)
        XCTAssertNil(profile.clickDwellSeconds, "未设置时交给 ClickSimulator 用全局默认")
    }

    func testProfileDwellIsExposedInSeconds() {
        var profile = AppProfile(bundleIdentifier: "com.acme.game", appName: "Game")
        profile.clickDwellMs = 60
        XCTAssertEqual(try XCTUnwrap(profile.clickDwellSeconds), 0.06, accuracy: 0.0001)
    }

    /// 后台宏策略默认必须是「仅前台执行」。
    /// v1.7.0 的默认行为（后台也跑）会让 iOS-on-Mac 游戏窗口被系统切到前台，
    /// 这是系统限制、修不掉，只能默认关掉。旧 preferences.json 里没有这个字段时同样落到默认。
    func testBackgroundMacroPolicyDefaultsToFrontmostOnly() throws {
        XCTAssertEqual(Preferences().backgroundMacroPolicy, .frontmostOnly)

        let legacy = #"{"showInDock":false}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(Preferences.self, from: legacy)
        XCTAssertEqual(decoded.backgroundMacroPolicy, .frontmostOnly)
    }

    func testBackgroundMacroPolicyRoundTrips() throws {
        let prefs = Preferences(backgroundMacroPolicy: .allowActivation)
        let data = try JSONEncoder().encode(prefs)
        let decoded = try JSONDecoder().decode(Preferences.self, from: data)
        XCTAssertEqual(decoded.backgroundMacroPolicy, .allowActivation)
    }
}
