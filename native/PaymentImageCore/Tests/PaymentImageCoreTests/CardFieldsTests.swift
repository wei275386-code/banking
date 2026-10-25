import XCTest
@testable import PaymentImageCore

final class CardFieldsTests: XCTestCase {
    func line(_ text: String, x: Double = 0.8, y: Double = 0.8) -> TextLine {
        TextLine(text: text, visionBox: TextBox(x: x, y: y, width: 0.15, height: 0.05))
    }

    func testMoneyKeepsOneCentDifferenceAndRejectsSubCent() {
        XCTAssertEqual(CardFields.exactCents("13.1"), 1310)
        XCTAssertEqual(CardFields.exactCents("13.11"), 1311)
        XCTAssertNil(CardFields.exactCents("13.111"))
        XCTAssertNil(CardFields.exactCents("13."))
        XCTAssertNil(CardFields.exactCents("+13.1"))
        XCTAssertNil(CardFields.exactCents("13.١"))
        XCTAssertNil(CardFields.exactCents("999999999999999999999999"))
    }

    func testProductImagePriceDoesNotCompeteWithOrderAmount() {
        let result = CardFields.parse([line("¥9.90", x: 0.1), line("¥13.11", y: 0.5),
                                       line("已完成"), line("下单: 2026-09-06 11:19", x: 0.1, y: 0.3)])
        XCTAssertEqual(result.amountCents, 1311)
        XCTAssertEqual(result.orderedMinute, "2026-09-06 11:19")
        XCTAssertTrue(result.reviewReasons.isEmpty)
    }

    func testCompetingAmountsStayUnknownRatherThanTakingFirst() {
        let result = CardFields.parse([line("¥13.11"), line("¥13.10")])
        XCTAssertNil(result.amountCents)
        XCTAssertTrue(result.reviewReasons.contains("金额存在多个候选"))
    }

    func testCouponExpiryDoesNotBecomeOrderDate() {
        let result = CardFields.parse([line("¥24.7", y: 0.4), line("支付成功"),
                                       line("有效期至: 2026-09-30", x: 0.1)])
        XCTAssertNil(result.orderedMinute)
        XCTAssertEqual(result.status, "支付成功")
    }

    func testInvalidCalendarDateIsNotAccepted() {
        let result = CardFields.parse([line("¥1"), line("已完成"),
                                       line("下单: 2026-02-30 11:19", x: 0.1)])
        XCTAssertNil(result.orderedMinute)
        XCTAssertTrue(result.reviewReasons.contains("下单日期或时间无效"))
    }

    func testUnknownStateAndImageTextAreNotAcceptedAsOrderState() {
        let result = CardFields.parse([line("待使用"), line("已完成", x: 0.1), line("¥1")])
        XCTAssertNil(result.status)
        XCTAssertTrue(result.reviewReasons.contains("状态缺失或未知"))
    }

    func testMergedMerchantStatusRequiresActualRightSideCharacterBoxes() {
        let header = "商户已完成"
        let region = TextBox(x: 0.8, y: 0.8, width: 0.04, height: 0.06)
        let chars = header.map { TextCharacter(text: String($0), visionBox: region) }
        let merged = TextLine(text: header, visionBox: TextBox(x: 0.1, y: 0.8, width: 0.85, height: 0.06), characters: chars)
        XCTAssertEqual(CardFields.parse([merged]).status, "已完成")
        let missingGeometry = TextLine(text: header, visionBox: merged.visionBox)
        XCTAssertNil(CardFields.parse([missingGeometry]).status)
        let leftChars = header.map { TextCharacter(text: String($0), visionBox: TextBox(x: 0.1, y: 0.8, width: 0.04, height: 0.06)) }
        XCTAssertNil(CardFields.parse([TextLine(text: header, visionBox: merged.visionBox, characters: leftChars)]).status)
    }
}
