import XCTest
@testable import ReceiptCore

final class PinyinEngineTests: XCTestCase {
    func testBundledDictionarySupportsChineseWordsAndUmlaut() {
        let engine = PinyinEngine.shared
        XCTAssertGreaterThan(engine.entryCount, 100_000, "The actual bundled dictionary must be present")
        for (pinyin, text) in [("wancan", "晚餐"), ("tingchefei", "停车费"), ("zhongguo", "中国"), ("nv", "女"), ("lve", "略"), ("xi'an", "西安"), ("zhifubao", "支付宝")] {
            let candidates = engine.candidates(pinyin)
            XCTAssertTrue(candidates.contains { $0.text == text && $0.consumed == pinyin.count }, pinyin)
            XCTAssertEqual(Set(candidates.map(\.id)).count, candidates.count)
        }
        XCTAssertEqual(engine.candidates("wancan").first?.text, "晚餐")
        XCTAssertTrue(engine.candidates("a/../../secret").isEmpty)
        XCTAssertTrue(engine.candidates(String(repeating: "a", count: 49)).isEmpty)
        XCTAssertTrue(engine.candidates("").isEmpty)
    }

    func testSeparatorDisambiguatesAndPrefixLeavesRemainingComposition() {
        let engine = PinyinEngine(tsv: "xi an\t西安\t100\nxian\t先\t200\nwan\t晚\t100\nwan can\t晚餐\t300\n")
        XCTAssertEqual(engine.candidates("xian").first?.text, "先")
        XCTAssertEqual(engine.candidates("xi'an").first?.text, "西安")
        XCTAssertFalse(engine.candidates("xi'an").contains { $0.text == "先" })
        XCTAssertTrue(engine.candidates("wancan").contains { $0.text == "晚" && $0.consumed == 3 })
        XCTAssertTrue(engine.candidates("wan'can").contains { $0.text == "晚" && $0.consumed == 4 })
    }

    func testTearPoseHasContinuousTensionRipAndFallWithNoEarlyFade() {
        let initial = ReceiptTearPose(progress: 0)
        XCTAssertEqual(initial.y, 0); XCTAssertEqual(initial.rotation, 0); XCTAssertEqual(initial.opacity, 1)
        XCTAssertEqual(ReceiptTearPose(progress: 0.175).rip, 0)
        XCTAssertEqual(ReceiptTearPose(progress: 0.425).rip, 1, accuracy: 0.00001)
        XCTAssertEqual(ReceiptTearPose(progress: 0.7).opacity, 1)
        XCTAssertEqual(ReceiptTearPose(progress: 1).opacity, 0)
        var previous = initial
        for step in 1...800 {
            let pose = ReceiptTearPose(progress: Double(step) / 800)
            XCTAssertGreaterThanOrEqual(pose.y, previous.y)
            XCTAssertLessThan(abs(pose.y - previous.y), 1)
            XCTAssertLessThan(abs(pose.rotation - previous.rotation), 0.1)
            previous = pose
        }
    }
}
