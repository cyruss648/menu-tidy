import XCTest
@testable import MenuTidyCore

final class LocalizedMessageTests: XCTestCase {
    func testInterpolationUsesNumberedKeysAndCanBeReordered() {
        let message = LocalizedMessage("项目 \(3)/\(21)")
        XCTAssertEqual(message.sourceText, "项目 3/21")
        XCTAssertEqual(message.rendered { key in
            XCTAssertEqual(key, "项目 {0}/{1}")
            return "{1} items, {0} missing"
        }, "21 items, 3 missing")
    }

    func testNestedErrorsAndJoinedMessagesKeepTheirKeys() {
        let cause = MessageFailure("权限不足")
        let message = LocalizedMessage("恢复失败：\(cause.localizedMessage)") + LocalizedMessage("选择已保留。")
        let translations = ["恢复失败：{0}": "Recovery failed: {0}", "权限不足": "Access denied",
                            "选择已保留。": " Your choices are preserved."]
        XCTAssertEqual(message.rendered { translations[$0] ?? $0 },
                       "Recovery failed: Access denied Your choices are preserved.")
        XCTAssertEqual([message, "请重试"].joined(separator: "\n").rendered { translations[$0] ?? $0 },
                       "Recovery failed: Access denied Your choices are preserved.\n请重试")
    }

    func testExternalDataIsNeitherTranslatedNorReparsedAsTokens() {
        let name = "搜狗输入法 {1} %@ \"VPN\""
        let message = LocalizedMessage("正在打开「\(name)」：\(42)")
        let output = message.rendered { key in
            XCTAssertEqual(key, "正在打开「{0}」：{1}")
            return "Opening {0}: {1}"
        }
        XCTAssertEqual(output, "Opening 搜狗输入法 {1} %@ \"VPN\": 42")
    }

    func testExternalErrorDescriptionIsOpaque() {
        let error = NSError(domain: "external", code: 1,
                            userInfo: [NSLocalizedDescriptionKey: "第三方错误 {0}"])
        XCTAssertEqual(error.localizedMessage.rendered { _ in XCTFail("External data must not be translated"); return "" },
                       "第三方错误 {0}")
    }

    func testTheSameMessageCanBeRenderedInMultipleLanguages() {
        let message = LocalizedMessage("缺少 \(3) 个图像")
        XCTAssertEqual(message.rendered { _ in "{0} images missing" }, "3 images missing")
        XCTAssertEqual(message.sourceText, "缺少 3 个图像")
        XCTAssertEqual(message.rendered { _ in "Missing images: {0}" }, "Missing images: 3")
    }
}
