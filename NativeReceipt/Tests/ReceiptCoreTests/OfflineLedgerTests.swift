import XCTest
@testable import ReceiptCore

final class OfflineLedgerTests: XCTestCase {
    func testQueueSurvivesRelaunchAndAReceiptAppearsOnlyOnce() throws {
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:dir) }
        let file=OfflineLedgerFile(url:dir.appendingPathComponent("ledger.json"))
        var first=try file.load()
        let expense=StandaloneEntry(occurredAt:1793520000000,kind:"expense",cents:2300,category:"餐饮",included:true,budgetMonth:"2026-11")
        first.record(expense);try file.save(first)
        var reopened=try file.load()
        XCTAssertEqual(reopened.pending.map(\.id),[expense.id])
        let refund=StandaloneEntry(occurredAt:1798761600000,kind:"refund",cents:345,category:"退款",included:false,originalID:expense.id)
        let snapshot=LedgerSnapshot(ledgerID:"test-book",entries:[expense,refund],budgets:[.init(month:"2026-10",cents:10000)])
        try reopened.accept(snapshot,acknowledged:[])
        XCTAssertEqual(reopened.entries.count,2);XCTAssertEqual(reopened.pending.count,1)
        XCTAssertEqual(reopened.budget(in:"2026-11").used,1955)
        XCTAssertEqual(reopened.budget(in:"2026-11").limit,10000)
        XCTAssertThrowsError(try reopened.accept(.init(ledgerID:"other",entries:[],budgets:[]),acknowledged:[expense.id]))
        XCTAssertEqual(reopened.pending.count,1)
        try reopened.accept(snapshot,acknowledged:[expense.id]);try file.save(reopened)
        XCTAssertTrue(try file.load().pending.isEmpty)
        try Data("corrupt".utf8).write(to:file.url)
        XCTAssertThrowsError(try file.load())
    }
    func testExactInput(){
        XCTAssertEqual(OfflineLedger.amount("0.01"),1);XCTAssertEqual(OfflineLedger.amount("17.3"),1730)
        for v in ["0","-2","1.234","nan","1e2"]{XCTAssertNil(OfflineLedger.amount(v))}
    }
}
