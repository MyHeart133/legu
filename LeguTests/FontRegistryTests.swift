import UIKit
import XCTest
@testable import Legu

/// 字体可用性检测与回退
final class FontRegistryTests: XCTestCase {

    func testSystemResolvesToNilName() {
        let r = FontRegistry.shared.resolve("system")
        XCTAssertNil(r.postScriptName)
        XCTAssertFalse(r.displayName.isEmpty)
    }

    func testBuiltinStylesAllResolve() {
        for opt in FontRegistry.builtinOptions {
            let r = FontRegistry.shared.resolve(opt.id)
            XCTAssertFalse(r.displayName.isEmpty, "\(opt.id) 显示名不能为空")
            if let name = r.postScriptName {
                XCTAssertNotNil(UIFont(name: name, size: 12), "\(opt.id) 解析出的字体必须真实存在: \(name)")
            }
        }
    }

    func testBoldVariantStillResolves() {
        for opt in FontRegistry.builtinOptions {
            let r = FontRegistry.shared.resolve(opt.id, bold: true)
            if let name = r.postScriptName {
                XCTAssertNotNil(UIFont(name: name, size: 12), "\(opt.id) 加粗变体必须真实存在: \(name)")
            }
        }
    }

    func testCustomGarbageFallsBack() {
        let r = FontRegistry.shared.resolve("custom:NotARealFont-12345")
        XCTAssertTrue(r.isFallback)
    }

    func testUnknownStyleFallsBack() {
        let r = FontRegistry.shared.resolve("nonexistent-style")
        XCTAssertTrue(r.isFallback)
    }

    func testBuiltinOptionListComplete() {
        let ids = FontRegistry.builtinOptions.map { $0.id }
        XCTAssertEqual(ids, ["system", "songti", "heiti", "kaiti", "fangsong", "yuanti"])
    }
}
