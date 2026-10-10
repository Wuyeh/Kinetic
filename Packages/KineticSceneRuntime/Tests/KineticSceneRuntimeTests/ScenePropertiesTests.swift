import Foundation
import XCTest
@testable import KineticSceneRuntime

final class ScenePropertiesTests: XCTestCase {
    private func schema() throws -> ScenePropertySchema {
        try ScenePropertySchema(data: Data(#"{"type":"scene","general":{"properties":{"enabled":{"type":"bool","text":"启用","value":true,"order":1},"speed":{"type":"slider","text":"速度","value":1,"min":0,"max":10,"condition":"enabled == true","order":2},"mode":{"type":"combo","text":"模式","value":1,"options":[{"label":"慢","value":1},{"label":"快","value":2}]},"tint":{"type":"color","text":"颜色","value":"1 0 0"},"caption":{"type":"textinput","value":"Hello"},"file":{"type":"file","value":"pixel.png"},"dir":{"type":"directory","value":"images"},"heading":{"type":"group","text":"组"}}}}"#.utf8))
    }
    func testAuthoredDefaultsOrderingAndVisibility() throws {
        let schema = try schema()
        XCTAssertEqual(schema.defaultValues["enabled"], .bool(true))
        XCTAssertEqual(schema.defaultValues["speed"], .number(1))
        XCTAssertEqual(schema.properties.first?.key, "enabled")
        XCTAssertTrue(schema.isVisible("speed", overrides: [:]))
        XCTAssertFalse(schema.isVisible("speed", overrides: ["enabled": .bool(false)]))
    }
    func testTypedValuesAndCanonicalCombo() throws {
        let values: [String: ScenePropertyValue] = ["enabled": .bool(false), "speed": .number(3.5),
            "mode": .string("2"), "tint": .string("0.2 0.5 1"), "caption": .string("世界"),
            "file": .string("images/pixel.png"), "dir": .string("images")]
        let result = try schema().validated(values)
        XCTAssertEqual(result["mode"], .number(2))
        XCTAssertEqual(result["speed"], .number(3.5))
        XCTAssertEqual(result["caption"], .string("世界"))
    }
    func testInvalidOrUndeclaredValuesAreRejected() throws {
        let schema = try schema()
        for values: [String: ScenePropertyValue] in [["speed": .number(-1)], ["speed": .number(.infinity)],
            ["speed": .number(.nan)], ["enabled": .string("yes")], ["mode": .number(9)],
            ["tint": .string("1 0")], ["tint": .string("2 0 0")], ["tint": .string("nan 0 0")],
            ["unknown": .bool(true)], ["heading": .string("executable")],
            ["caption": .string(String(repeating: "x", count: 4_097))]] {
            XCTAssertThrowsError(try schema.validated(values))
        }
    }
    func testFilePathsCannotEscapeScene() throws {
        for path in ["../outside", "/etc/passwd", "images/../../outside", "%2e%2e/outside"] {
            XCTAssertThrowsError(try schema().validated(["file": .string(path)]), path)
        }
        XCTAssertEqual(try schema().validated(["file": .string("")])["file"], .string(""))
    }
    func testMalformedAndOversizedManifestsRejected() throws {
        XCTAssertThrowsError(try ScenePropertySchema(data: Data("[]".utf8)))
        XCTAssertThrowsError(try ScenePropertySchema(data: Data(#"{"type":"web"}"#.utf8)))
        let properties = Dictionary(uniqueKeysWithValues: (0...256).map { ("p\($0)", ["type": "bool", "value": true] as [String: Any]) })
        let data = try JSONSerialization.data(withJSONObject: ["type": "scene", "general": ["properties": properties]])
        XCTAssertThrowsError(try ScenePropertySchema(data: data))
    }
    func testLocalizationAndPlainLabels() throws {
        let data = Data(#"{"type":"scene","general":{"localization":{"zh-Hans":{"name":"<b>速度</b>"}},"properties":{"speed":{"type":"slider","text":"name","value":1}}}}"#.utf8)
        let schema = try ScenePropertySchema(data: data)
        XCTAssertEqual(schema.properties.first?.title, "速度")
    }

    func testBatchVisibilityPreservesOrderConditionsAndPromotionalFiltering() throws {
        let data = Data(#"{"type":"scene","general":{"properties":{"enabled":{"type":"bool","value":true,"order":1},"group":{"type":"group","text":"Group","condition":"enabled.value","order":2},"speed":{"type":"slider","value":1,"min":0,"max":300,"step":0.001,"condition":"enabled.value","order":3},"hidden":{"type":"text","condition":"false","order":4},"promo":{"type":"text","text":"<a href='https://example.invalid'>Link</a>","order":5}}}}"#.utf8)
        let schema = try ScenePropertySchema(data: data)
        XCTAssertEqual(schema.visibleProperties(overrides: [:]).map(\.key), ["enabled", "group", "speed"])
        XCTAssertEqual(schema.visibleProperties(overrides: ["enabled": .bool(false)]).map(\.key), ["enabled"])
        XCTAssertFalse(schema.isVisible("missing", overrides: [:]))
        for overrides: [String: ScenePropertyValue] in [[:], ["enabled": .bool(false)], ["speed": .number(2)]] {
            XCTAssertEqual(schema.visibleProperties(overrides: overrides).map(\.key),
                           schema.properties.filter { schema.isVisible($0.key, overrides: overrides) }.map(\.key))
        }
    }

    func testManyConditionalPropertiesHaveOneBatchWithUnchangedDefaults() throws {
        var properties: [String: Any] = ["enabled": ["type": "bool", "value": true, "order": 0]]
        for index in 0..<200 {
            properties["p\(index)"] = ["type": "slider", "value": 45.726, "min": 0, "max": 300,
                                       "step": 0.001, "order": index + 1,
                                       "condition": "enabled.value && ([1, 2].includes(mode.value) || !hidden.value)"]
        }
        let data = try JSONSerialization.data(withJSONObject: ["type": "scene", "general": ["properties": properties]])
        let schema = try ScenePropertySchema(data: data)
        XCTAssertEqual(schema.visibleProperties(overrides: [:]).count, 201)
        XCTAssertEqual(schema.visibleProperties(overrides: ["enabled": .bool(false)]).count, 1)
        XCTAssertEqual(schema.defaultValues["p199"], .number(45.726))
    }
}
