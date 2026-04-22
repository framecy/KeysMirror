import XCTest
@testable import KeysMirror

final class MacroActionTests: XCTestCase {
    func testCodableRoundTripWithMixedSteps() throws {
        let mappingId = UUID()
        let macro = MacroAction(
            label: "日常",
            triggerType: .keyboard,
            keyCode: 122, // F1
            modifiers: 0,
            blockInput: true,
            isEnabled: true,
            repeatCount: 3,
            steps: [
                MacroStep(delaySeconds: 0, position: .mapping(mappingId)),
                MacroStep(delaySeconds: 2.5, position: .inline(relativeX: 100, relativeY: 200, referenceWidth: 800, referenceHeight: 600)),
                MacroStep(delaySeconds: 60, position: .inline(relativeX: 50, relativeY: 50, referenceWidth: nil, referenceHeight: nil))
            ]
        )

        let data = try JSONEncoder().encode(macro)
        let decoded = try JSONDecoder().decode(MacroAction.self, from: data)

        XCTAssertEqual(decoded, macro)
        XCTAssertEqual(decoded.steps.count, 3)
        if case .mapping(let id) = decoded.steps[0].position {
            XCTAssertEqual(id, mappingId)
        } else {
            XCTFail("第一步应解码为 .mapping case")
        }
        if case .inline(let x, let y, let w, let h) = decoded.steps[1].position {
            XCTAssertEqual(x, 100)
            XCTAssertEqual(y, 200)
            XCTAssertEqual(w, 800)
            XCTAssertEqual(h, 600)
        } else {
            XCTFail("第二步应解码为 .inline case")
        }
        if case .inline(_, _, let w, let h) = decoded.steps[2].position {
            XCTAssertNil(w)
            XCTAssertNil(h)
        } else {
            XCTFail("第三步应解码为 .inline case 且无参考尺寸")
        }
    }

    func testRepeatCountZeroIsInfiniteSummary() {
        let macro = MacroAction(label: "无限", repeatCount: 0, steps: [
            MacroStep(position: .inline(relativeX: 0, relativeY: 0, referenceWidth: nil, referenceHeight: nil))
        ])
        XCTAssertTrue(macro.stepSummary.contains("无限"))
    }

    func testRepeatCountOneShowsSingle() {
        let macro = MacroAction(label: "单次", repeatCount: 1, steps: [
            MacroStep(position: .inline(relativeX: 0, relativeY: 0, referenceWidth: nil, referenceHeight: nil)),
            MacroStep(position: .inline(relativeX: 1, relativeY: 1, referenceWidth: nil, referenceHeight: nil))
        ])
        XCTAssertEqual(macro.stepSummary, "2 步 × 单次")
    }

    func testLegacyAppProfileWithoutMacrosFieldDecodesAsEmpty() throws {
        // v1.4 及以下的 AppProfile JSON 没有 macros 字段
        let legacyJSON = """
        {
            "id": "00000000-0000-0000-0000-000000000001",
            "bundleIdentifier": "com.acme.game",
            "appName": "Game",
            "mappings": [],
            "isEnabled": true,
            "overlayOpacity": 0.5,
            "showOverlay": true
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(AppProfile.self, from: legacyJSON)
        XCTAssertEqual(decoded.bundleIdentifier, "com.acme.game")
        XCTAssertTrue(decoded.macros.isEmpty, "缺 macros 字段必须解码为空数组而非报错")
    }

    func testLegacyMacroJsonWithoutOptionalFieldsDecodes() throws {
        // 模拟未来某个字段被删除的情况：当前最小集合也应能解码
        let minimalJSON = """
        {
            "id": "11111111-1111-1111-1111-111111111111",
            "label": "minimal",
            "triggerType": "keyboard",
            "keyCode": 12,
            "modifiers": 0,
            "blockInput": true,
            "isEnabled": true,
            "repeatCount": 1,
            "steps": []
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(MacroAction.self, from: minimalJSON)
        XCTAssertEqual(decoded.label, "minimal")
        XCTAssertNil(decoded.mouseButtonNumber)
        XCTAssertEqual(decoded.steps.count, 0)
    }
}
