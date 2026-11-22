import XCTest
@testable import ReceiptCore

private let draftID = "00000000-0000-4000-8000-000000000001"
// Server lib/security.ts SHA-256 -> unpadded base64url for a synthetic input:
// "fixture-only-key:draft:ios:2026-11-13:fixture-2". This is not a real credential.
private let draftToken = "j5pnC5j3YlB6-HFd9_hAyXdwcT3NmvIm1up_R8OktJU"
private let draftURL = URL(string: "https://ledger.xiaokai123.de5.net/confirm?id=\(draftID)&token=\(draftToken)")!

private func fixture(_ kind: String = "expense") throws -> ReceiptDraft {
    let category = kind == "refund" ? "退款" : kind == "income" ? "工资" : kind == "transfer" ? "转账" : "餐饮"
    let object: [String: Any] = [
        "id": draftID, "transactionType": kind, "amount": "23.00", "currency": "CNY",
        "category": category, "merchant": "示例商店", "product": "午餐", "platform": "微信",
        "paymentAccount": "微信零钱", "receiptAccount": "", "occurredAt": "2026-11-13T12:30",
        "budgetIncluded": true, "budgetMonth": "2026-11", "externalOrderReference": "",
        "originalTransactionId": "", "requiresManualReview": false,
        "refundMatch": ["candidates": [["id": "original-1", "occurredAt": "2026-11-12T12:30", "amount": "30.00", "remainingAmount": "25.00", "merchant": "示例商店", "product": "原订单商品", "paymentAccount": "微信零钱"]]]
    ]
    return try JSONDecoder().decode(ReceiptDraft.self, from: JSONSerialization.data(withJSONObject: object))
}

private actor MockLedger: LedgerServing {
    enum Outcome { case success, rejected, uncertain, gated }
    let draft: ReceiptDraft
    let outcome: Outcome
    var fetches = 0
    var saves = 0
    var cancels = 0
    var undoCalls = 0
    var uncertainUndo = false
    var payload: ConfirmationPayload?
    var fetchedReference: DraftReference?
    var gate: CheckedContinuation<Void, Never>?
    var started: CheckedContinuation<Void, Never>?
    init(kind: String = "expense", outcome: Outcome = .success) throws {
        draft = try fixture(kind); self.outcome = outcome
    }
    func fetch(_ reference: DraftReference, order: String?) async throws -> ReceiptDraft { fetches += 1; fetchedReference = reference; return draft }
    func confirm(_ payload: ConfirmationPayload) async throws {
        saves += 1; self.payload = payload
        switch outcome {
        case .success: break
        case .rejected: throw ReceiptError.rejected("信息不正确")
        case .uncertain: throw URLError(.timedOut)
        case .gated:
            await withCheckedContinuation { continuation in
                gate = continuation; started?.resume(); started = nil
            }
        }
    }
    func confirmWithUndo(_ payload: ConfirmationPayload) async throws -> UndoCapability? {
        try await confirm(payload)
        return UndoCapability(id: "fixture-undo", token: "fixture-token", expiresAt: Date().addingTimeInterval(30).timeIntervalSince1970 * 1000)
    }
    func makeUndoUncertain() { uncertainUndo = true }
    func undo(_ capability: UndoCapability) async throws -> DraftReference {
        undoCalls += 1
        if uncertainUndo { uncertainUndo = false; throw URLError(.timedOut) }
        return try DraftReference(url: URL(string: "https://ledger.xiaokai123.de5.net/confirm?id=00000000-0000-4000-8000-000000000002&token=\(draftToken)")!)
    }
    func undoCount() -> Int { undoCalls }
    func cancel(_ reference: DraftReference) async throws { cancels += 1 }
    func waitUntilSaving() async {
        if saves > 0 { return }
        await withCheckedContinuation { started = $0 }
    }
    func finish() { gate?.resume(); gate = nil }
    func counts() -> (Int, Int, Int) { (fetches, saves, cancels) }
}

private actor SaveDisplayProbe {
    private var shown = false
    func show() { shown = true }
    func wasShown() -> Bool { shown }
}

final class ReceiptCoreTests: XCTestCase {
    func testHydrationUpdatesOnlyThePendingSnippetOnceWithoutSaving() async throws {
        let mock = try MockLedger(), store = ReceiptStore(client: mock)
        let url = URL(string: draftURL.absoluteString.replacingOccurrences(of: "ledger.xiaokai", with: "ledger-sync.xiaokai"))!
        let id = "visible"
        await store.openScreenshot(id, preview: .init(text: ""), captured: Date())
        let revision = try await store.openScreenshotSnippet(id)
        let frame = try await store.screenshotSnippetFrame(id, revision: revision)
        XCTAssertTrue(frame.awaitingScreenshot)
        let early = await store.takeHydratedSnippetRefresh(id)
        XCTAssertFalse(early)
        try await store.bindScreenshot(id, to: url)
        let first = await store.takeHydratedSnippetRefresh(id)
        let second = await store.takeHydratedSnippetRefresh(id)
        let hydrated = try await store.screenshotSnippetFrame(id, revision: revision)
        XCTAssertTrue(first)
        XCTAssertFalse(second)
        XCTAssertFalse(hydrated.awaitingScreenshot)
        XCTAssertEqual(hydrated.draft.amount, "23.00")
        XCTAssertEqual(hydrated.draft.merchant, "示例商店")
        let calls = await mock.counts()
        XCTAssertEqual(calls.1,0)
    }

    func testStaleSessionAndForegroundReviewDoNotReopenASnippet() async throws {
        let mock = try MockLedger(), store = ReceiptStore(client: mock)
        let url = URL(string: draftURL.absoluteString.replacingOccurrences(of: "ledger.xiaokai", with: "ledger-sync.xiaokai"))!
        await store.openScreenshot("first", preview: .init(text: ""), captured: Date())
        await store.openScreenshot("second", preview: .init(text: ""), captured: Date())
        let first = try await store.openScreenshotSnippet("first")
        _ = try await store.screenshotSnippetFrame("first", revision:first)
        _ = try await store.prepareScreenshotFeed("second")
        _ = try await store.screenshotSnippetFrame("first", revision:first)
        try await store.bindScreenshot("first", to:url)
        let stale = await store.takeHydratedSnippetRefresh("first")
        XCTAssertFalse(stale)
        let afterReady = try await store.openScreenshotSnippet("first")
        _ = try await store.screenshotSnippetFrame("first", revision:afterReady)
        let alreadyVisible = await store.takeHydratedSnippetRefresh("first")
        XCTAssertFalse(alreadyVisible)
    }

    func testLocalConfirmationNeedsMatchingIssuedDraftAndNeverDoubleWrites() async throws {
        let mock = try MockLedger(), store = ReceiptStore(client: mock)
        let id = try await store.open(draftURL)
        let mismatch = ScreenshotReceiptPreview(text: "商户：晴天面馆\n实付 11")
        try await store.confirm(id, matching: mismatch)
        let review = try await store.snapshot(id)
        let first = await mock.counts()
        XCTAssertEqual(first.1, 0)
        XCTAssertEqual(review.phase, .ready)
        XCTAssertFalse(review.message.isEmpty)
        try await store.edit(id, field: .merchant, value: "晴天面馆")
        let match = ScreenshotReceiptPreview(text: "商户：晴天面馆\n实付 23")
        try await store.confirm(id, matching: match)
        try await store.confirm(id, matching: match)
        let final = await mock.counts()
        let result = try await store.snapshot(id)
        XCTAssertEqual(final.1, 1)
        XCTAssertEqual(result.phase, .saved)
        XCTAssertTrue(result.canUndo)
    }

    func testOneEditablePaperKeepsChangesAndRequiresReviewWhenCloudFieldsChange() async throws {
        let mock = try MockLedger(), store = ReceiptStore(client: mock)
        let url = URL(string: draftURL.absoluteString.replacingOccurrences(of: "ledger.xiaokai", with: "ledger-sync.xiaokai"))!
        let job = "screenshot-test"
        let preview = ScreenshotReceiptPreview(text: "晴天面馆（东街店）\n番茄面 拼单价 ¥28\n实付 ¥13.80")
        await store.openScreenshot(job, preview: preview, captured: Date())
        let paper = try await store.snapshot(job)
        XCTAssertTrue(paper.awaitingScreenshot)
        XCTAssertEqual(paper.draft.amount, "13.80")
        try await store.edit(job, field: .amount, value: "15.25")
        try await store.edit(job, field: .merchant, value: "修改后的店名")
        try await store.edit(job, field: .note, value: "自己的备注")
        try await store.panel(job, .category)
        try await store.chooseInline(job, panel: .category, value: "购物")
        try await store.confirm(job, fromLocalPaper: true)
        let before = await mock.counts()
        XCTAssertEqual(before.1, 0)
        try await store.bindScreenshot(job, to: url)
        let bound = try await store.snapshot(job)
        XCTAssertEqual(bound.cardID, paper.cardID)
        XCTAssertFalse(bound.awaitingScreenshot)
        XCTAssertEqual(bound.draft.id, draftID)
        XCTAssertEqual(bound.draft.amount, "15.25")
        XCTAssertEqual(bound.draft.merchant, "修改后的店名")
        XCTAssertEqual(bound.note, "自己的备注")
        XCTAssertEqual(bound.draft.category, "购物")
        XCTAssertEqual(bound.draft.product, "午餐")
        try await store.confirm(job, fromLocalPaper: true)
        let staleTap = await mock.counts()
        XCTAssertEqual(staleTap.1, 0)
        try await store.confirm(job)
        try await store.confirm(job)
        let final = await mock.counts()
        XCTAssertEqual(final.1, 1)
        let saved = try await store.snapshot(job)
        XCTAssertTrue(saved.canUndo)
    }

    func testCancelledLocalPaperCannotBeRevivedOrBookedByAReadyResult() async throws {
        let mock = try MockLedger(), store = ReceiptStore(client: mock)
        let url = URL(string: draftURL.absoluteString.replacingOccurrences(of: "ledger.xiaokai", with: "ledger-sync.xiaokai"))!
        await store.openScreenshot("job", preview: ScreenshotReceiptPreview(text: ""), captured: Date())
        try await store.cancel("job")
        try await store.bindScreenshot("job", to: url)
        try await store.confirm("job")
        let snapshot = try await store.snapshot("job")
        let counts = await mock.counts()
        XCTAssertEqual(snapshot.phase, .cancelled)
        XCTAssertEqual(counts.1, 0)
    }

    func testExplicitContinueOpensExistingDraftWithoutReactivatingOldButtons() async throws {
        let mock = try MockLedger(), store = ReceiptStore(client: mock)
        let url = URL(string: draftURL.absoluteString.replacingOccurrences(of: "ledger.xiaokai", with: "ledger-sync.xiaokai"))!
        await store.openScreenshot("job", preview: .init(text: ""), captured: Date())
        try await store.cancel("job")
        try await store.bindScreenshot("job", to: url)
        let reopened = try await store.resumeClosedScreenshot("job") { url }
        let card = try XCTUnwrap(reopened)
        XCTAssertNotEqual(card, "job")
        let repeated = try await store.resumeClosedScreenshot("job") { url }
        XCTAssertEqual(repeated, card)
        let draft = try await store.snapshot(card)
        XCTAssertEqual(draft.phase, .ready)
        XCTAssertEqual(draft.draft.amount, "23.00")
        XCTAssertFalse(draft.awaitingScreenshot)
        try await store.confirm("job")
        let old = try await store.snapshot("job")
        XCTAssertTrue(old.closedLocalPreview)
        let count = await mock.counts()
        XCTAssertEqual(count.0, 1)
        XCTAssertEqual(count.1, 0)
        XCTAssertEqual(count.2, 0)
    }

    func testContinueHonorsRemoteCancellationAndUnavailableDrafts() async throws {
        let mock = try MockLedger(), store = ReceiptStore(client: mock)
        let url = URL(string: draftURL.absoluteString.replacingOccurrences(of: "ledger.xiaokai", with: "ledger-sync.xiaokai"))!
        await store.openScreenshot("local", preview: .init(text: ""), captured: Date())
        try await store.cancel("local")
        do {
            _ = try await store.resumeClosedScreenshot("local") { throw URLError(.timedOut) }
            XCTFail("A failed lookup must leave the old card closed")
        } catch is URLError {}
        do {
            _ = try await store.resumeClosedScreenshot("local") { draftURL }
            XCTFail("The resumed draft must belong to the independent ledger")
        } catch is ReceiptError {}
        let local = try await store.snapshot("local")
        XCTAssertTrue(local.closedLocalPreview)
        await store.openScreenshot("bound", preview: .init(text: ""), captured: Date())
        try await store.bindScreenshot("bound", to: url)
        try await store.cancel("bound")
        let reopened = try await store.resumeClosedScreenshot("bound") { XCTFail("A server-cancelled draft must stay closed"); return url }
        XCTAssertNil(reopened)
        let bound = try await store.snapshot("bound")
        XCTAssertEqual(bound.phase, .cancelled)
        XCTAssertFalse(bound.closedLocalPreview)
        let count = await mock.counts()
        XCTAssertEqual(count.0, 1)
        XCTAssertEqual(count.1, 0)
        XCTAssertEqual(count.2, 1)
    }

    func testShortcutDraftsStayWithTheirIssuingLedger() async throws {
        let independent = URL(string: draftURL.absoluteString.replacingOccurrences(of: "ledger.xiaokai", with: "ledger-sync.xiaokai"))!
        let old = try DraftReference(url: draftURL)
        let fresh = try DraftReference(url: independent)
        XCTAssertEqual(old.service, .original)
        XCTAssertEqual(fresh.service, .independent)
        XCTAssertEqual(fresh.service.api.host, independent.host)
        XCTAssertEqual(fresh.service.confirmation.host, independent.host)
        XCTAssertNotEqual(old, fresh)
        XCTAssertThrowsError(try DraftReference(url: URL(string: independent.absoluteString.replacingOccurrences(of: "ledger-sync.", with: "unrelated."))!))
        let store = ReceiptStore(client: try MockLedger())
        let originalCard = try await store.open(draftURL)
        let freshCard = try await store.open(independent)
        XCTAssertNotEqual(originalCard, freshCard)
        let reopened = try await store.open(independent)
        XCTAssertEqual(freshCard, reopened)
    }

    func testBoundedCharacterGroupsKeepBufferedEditsOnTheSameCard() async throws {
        let client = try MockLedger()
        let store = ReceiptStore(client: client)
        let id = try await store.open(draftURL)
        try await store.textAction(id, operation: "open", value: "note")
        try await store.textAction(id, operation: "phrase", value: "测试")
        var allKeys = Set<String>()
        for _ in 0..<4 {
            try await store.textAction(id, operation: "characters")
            let s = try await store.snapshot(id)
            XCTAssertEqual(s.cardID, id); XCTAssertEqual(s.textInput, "测试"); XCTAssertEqual(s.note, "")
            let keys = ReceiptTextKeyboard.keys(page: s.characterPage, order: false)
            XCTAssertLessThanOrEqual(keys.count, 12); allKeys.formUnion(keys)
        }
        XCTAssertEqual(allKeys, Set(Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ- ").map(String.init)))
        try await store.textAction(id, operation: "characters")
        var s = try await store.snapshot(id)
        XCTAssertEqual(s.characterPage, 0); XCTAssertEqual(s.textInput, "测试")
        try await store.textAction(id, operation: "done")
        s = try await store.snapshot(id)
        XCTAssertEqual(s.note, "测试"); XCTAssertEqual(s.panel, .summary); XCTAssertNil(s.inlineEditor)
        try await store.textAction(id, operation: "open", value: "order")
        allKeys = []
        for _ in 0..<4 {
            s = try await store.snapshot(id)
            allKeys.formUnion(ReceiptTextKeyboard.keys(page: s.characterPage, order: true))
            try await store.textAction(id, operation: "characters")
        }
        XCTAssertEqual(allKeys, Set(Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ- ").map(String.init)))
        let counts = await client.counts()
        XCTAssertEqual(counts.1, 0); XCTAssertEqual(counts.2, 0)
    }
    func testExpandedOptionsEditSameReceiptWithoutWritesUntilConfirm() async throws {
        let client = try MockLedger(); let store = ReceiptStore(client: client)
        let id = try await store.open(draftURL)
        try await store.chooseInline(id, panel: .category, value: "购物")
        try await store.chooseInline(id, panel: .account, value: "银行卡")
        try await store.setNote(id, value: "工作报销")
        try await store.adjustDate(id, component: "day", offset: -1)
        try await store.adjustDate(id, component: "budget", offset: 1)
        var s = try await store.snapshot(id)
        XCTAssertEqual(s.cardID, id); XCTAssertEqual(s.panel, .summary)
        XCTAssertEqual(s.draft.occurredAt, "2026-11-12T12:30")
        var counts = await client.counts(); XCTAssertEqual(counts.1, 0)
        try await store.confirm(id)
        s = try await store.snapshot(id); XCTAssertEqual(s.phase, .saved)
        let payload = await client.payload
        XCTAssertEqual(payload?.category, "购物"); XCTAssertEqual(payload?.paymentAccount, "银行卡")
        XCTAssertEqual(payload?.userRemark, "工作报销"); XCTAssertEqual(payload?.budgetMonth, "2026-12")
        counts = await client.counts(); XCTAssertEqual(counts.1, 1)
    }

    func testProgressiveEditorsCollapseWithoutDiscardingAnotherPendingEdit() async throws {
        let client = try MockLedger(); let store = ReceiptStore(client: client)
        let id = try await store.open(draftURL)
        try await store.panel(id, .category)
        try await store.panel(id, .account)
        var s = try await store.snapshot(id)
        XCTAssertEqual(s.panel, .account); XCTAssertNil(s.inlineEditor)
        try await store.chooseInline(id, panel: .account, value: "银行卡")
        s = try await store.snapshot(id)
        XCTAssertEqual(s.panel, .summary); XCTAssertEqual(s.draft.account, "银行卡")
        try await store.panel(id, .category)
        try await store.textAction(id, operation: "open", value: "note")
        try await store.textAction(id, operation: "phrase", value: "工作报销")
        try await store.panel(id, .amount)
        s = try await store.snapshot(id)
        XCTAssertEqual(s.panel, .summary); XCTAssertEqual(s.inlineEditor, "note")
        XCTAssertEqual(s.textInput, "工作报销"); XCTAssertFalse(s.message.isEmpty)
        try await store.textAction(id, operation: "open", value: "merchant")
        s = try await store.snapshot(id); XCTAssertEqual(s.inlineEditor, "note")
        try await store.textAction(id, operation: "done")
        s = try await store.snapshot(id); XCTAssertNil(s.inlineEditor); XCTAssertEqual(s.note, "工作报销")
        try await store.panel(id, .amount)
        try await store.amountKey(id, key: "8")
        try await store.textAction(id, operation: "open", value: "date")
        s = try await store.snapshot(id)
        XCTAssertEqual(s.panel, .amount); XCTAssertNil(s.inlineEditor); XCTAssertEqual(s.amountInput, "8")
        try await store.amountKey(id, key: "done")
        try await store.textAction(id, operation: "open", value: "budgetMonth")
        try await store.adjustDate(id, component: "budget", offset: 1)
        try await store.textAction(id, operation: "cancel")
        s = try await store.snapshot(id)
        XCTAssertEqual(s.cardID, id); XCTAssertEqual(s.panel, .summary); XCTAssertNil(s.inlineEditor)
        XCTAssertEqual(s.draft.amount, "8.00"); XCTAssertEqual(s.draft.budgetMonth, "2026-12")
        let counts = await client.counts(); XCTAssertEqual(counts.1, 0)
    }

    func testInlineTextBuffersCommitDiscardAndBlockPrematureConfirmation() async throws {
        let client = try MockLedger(); let store = ReceiptStore(client: client)
        let id = try await store.open(draftURL)
        try await store.setNote(id, value: "日常开销")
        try await store.textAction(id, operation: "open", value: "note")
        try await store.textAction(id, operation: "clear")
        try await store.textAction(id, operation: "phrase", value: "工作报销")
        try await store.textAction(id, operation: "key", value: "1")
        try await store.confirm(id)
        var counts = await client.counts(); XCTAssertEqual(counts.1, 0)
        var s = try await store.snapshot(id)
        XCTAssertEqual(s.note, "日常开销"); XCTAssertEqual(s.textInput, "工作报销1")
        try await store.textAction(id, operation: "cancel")
        s = try await store.snapshot(id); XCTAssertEqual(s.note, "日常开销"); XCTAssertNil(s.inlineEditor)
        try await store.textAction(id, operation: "open", value: "note")
        try await store.textAction(id, operation: "clear")
        try await store.textAction(id, operation: "phrase", value: "与人分摊")
        try await store.textAction(id, operation: "done")
        s = try await store.snapshot(id); XCTAssertEqual(s.note, "与人分摊"); XCTAssertNil(s.inlineEditor)
        try await store.confirm(id)
        counts = await client.counts(); XCTAssertEqual(counts.1, 1)
    }

    func testInlineDateAdjustmentsHandleLeapMonthAndMidnight() async throws {
        let store = ReceiptStore(client: try MockLedger()); let id = try await store.demo()
        try await store.edit(id, field: .date, value: "2024-01-31T23:59")
        try await store.adjustDate(id, component: "month", offset: 1)
        var s = try await store.snapshot(id); XCTAssertEqual(s.draft.occurredAt, "2024-02-29T23:59")
        try await store.adjustDate(id, component: "minute", offset: 1)
        s = try await store.snapshot(id); XCTAssertEqual(s.draft.occurredAt, "2024-03-01T00:00")
        try await store.adjustDate(id, component: "year", offset: 1)
        s = try await store.snapshot(id); XCTAssertEqual(s.draft.occurredAt, "2025-03-01T00:00")
    }

    func testRefundOrderInputStaysInlineAndNeverAutoSelectsOrSaves() async throws {
        let client = try MockLedger(kind: "refund"); let store = ReceiptStore(client: client)
        let id = try await store.open(draftURL)
        try await store.textAction(id, operation: "open", value: "order")
        try await store.textAction(id, operation: "key", value: "1")
        try await store.textAction(id, operation: "done")
        var s = try await store.snapshot(id); XCTAssertEqual(s.inlineEditor, "order"); XCTAssertFalse(s.message.isEmpty)
        for key in ["2", "3", "4"] { try await store.textAction(id, operation: "key", value: key) }
        try await store.textAction(id, operation: "done")
        s = try await store.snapshot(id); XCTAssertNil(s.inlineEditor); XCTAssertEqual(s.cardID, id)
        XCTAssertEqual(s.panel, .refunds, "Lookup candidates must remain visible for explicit selection")
        XCTAssertTrue(s.draft.originalTransactionId.isEmpty)
        let counts = await client.counts(); XCTAssertEqual(counts.0, 2); XCTAssertEqual(counts.1, 0)
    }

    func testServerBase64URLCapabilityReachesFetchAndConfirmationUnchanged() async throws {
        let client = try MockLedger(); let store = ReceiptStore(client: client)
        let id = try await store.open(draftURL)
        let fetched = await client.fetchedReference
        XCTAssertEqual(fetched?.id, draftID); XCTAssertEqual(fetched?.token, draftToken)
        var counts = await client.counts(); XCTAssertEqual(counts.0, 1); XCTAssertEqual(counts.1, 0)
        try await store.confirm(id)
        let payload = await client.payload
        XCTAssertEqual(payload?.token, draftToken)
        counts = await client.counts(); XCTAssertEqual(counts.1, 1)
    }

    func testCapabilitySupportsServerEncodingAndHexWithoutRelaxingURLBoundary() throws {
        for host in ["ledger.xiaokai123.de5.net", "suishou-ledger-0726.qq2301796536.chatgpt.site"] {
            for token in [draftToken, String(repeating: "a", count: 64)] {
                var c = URLComponents(string: "https://\(host)/confirm")!
                c.queryItems = [URLQueryItem(name: "id", value: draftID), URLQueryItem(name: "token", value: token)]
                XCTAssertEqual(try DraftReference(url: c.url!).token, token)
            }
        }
    }

    func testMissingTruncatedAndMalformedCapabilitiesFailBeforeNetworkAccess() async throws {
        let client = try MockLedger(); let store = ReceiptStore(client: client)
        for token in ["", String(draftToken.dropLast()), draftToken + "x", draftToken + "=",
                      draftToken + "\n", " " + draftToken, String(repeating: "g", count: 64),
                      draftToken.replacingOccurrences(of: "-", with: "+"),
                      draftToken.replacingOccurrences(of: "_", with: "/")] {
            var c = URLComponents(string: "https://ledger.xiaokai123.de5.net/confirm")!
            c.queryItems = [URLQueryItem(name: "id", value: draftID), URLQueryItem(name: "token", value: token)]
            do { _ = try await store.open(c.url!); XCTFail("Malformed capability must not reach the API") } catch { }
        }
        let counts = await client.counts()
        XCTAssertEqual(counts.0, 0); XCTAssertEqual(counts.1, 0); XCTAssertEqual(counts.2, 0)
    }

    func testInlineAmountKeysStayOnCardAndOnlyCommitOnDone() async throws {
        let client = try MockLedger(); let store = ReceiptStore(client: client)
        let id = try await store.open(draftURL)
        try await store.panel(id, .amount)
        for key in ["4", "9", ".", "9"] { try await store.amountKey(id, key: key) }
        var s = try await store.snapshot(id)
        XCTAssertEqual(s.cardID, id); XCTAssertEqual(s.panel, .amount)
        XCTAssertEqual(s.amountInput, "49.9"); XCTAssertEqual(s.draft.amount, "23.00")
        try await store.confirm(id)
        var counts = await client.counts(); XCTAssertEqual(counts.1, 0)
        try await store.amountKey(id, key: "done")
        s = try await store.snapshot(id)
        XCTAssertEqual(s.panel, .summary); XCTAssertEqual(s.draft.amount, "49.90")
        try await store.amountKey(id, key: "8") // stale button from the previous snapshot
        s = try await store.snapshot(id); XCTAssertEqual(s.draft.amount, "49.90")
        try await store.confirm(id)
        let payload = await client.payload; XCTAssertEqual(payload?.amount, "49.90")
        counts = await client.counts(); XCTAssertEqual(counts.1, 1)
    }

    func testInlineAmountCancelPrecisionAndInvalidZero() async throws {
        let client = try MockLedger(); let store = ReceiptStore(client: client)
        let id = try await store.open(draftURL)
        try await store.panel(id, .amount)
        for key in [".", "0", "1", "9"] { try await store.amountKey(id, key: key) }
        var s = try await store.snapshot(id); XCTAssertEqual(s.amountInput, "0.01")
        try await store.amountKey(id, key: "cancel")
        s = try await store.snapshot(id); XCTAssertEqual(s.draft.amount, "23.00"); XCTAssertEqual(s.panel, .summary)
        try await store.panel(id, .amount)
        try await store.amountKey(id, key: "clear")
        try await store.amountKey(id, key: "done")
        s = try await store.snapshot(id); XCTAssertEqual(s.panel, .amount); XCTAssertFalse(s.message.isEmpty)
        for key in ["1", "2", ".", "done"] { try await store.amountKey(id, key: key) }
        s = try await store.snapshot(id); XCTAssertEqual(s.draft.amount, "12.00")
        let counts = await client.counts(); XCTAssertEqual(counts.1, 0)
    }

    func testInlineAmountBackspaceAndMagnitudeLimit() async throws {
        let store = ReceiptStore(client: try MockLedger()); let id = try await store.demo()
        try await store.panel(id, .amount)
        for key in ["backspace", "backspace", "backspace"] { try await store.amountKey(id, key: key) }
        var s = try await store.snapshot(id); XCTAssertEqual(s.amountInput, "23")
        try await store.amountKey(id, key: "clear")
        for _ in 0..<13 { try await store.amountKey(id, key: "9") }
        s = try await store.snapshot(id); XCTAssertEqual(s.amountInput, "999999999999")
        do { try await store.amountKey(id, key: "1e9"); XCTFail("reject malformed key") } catch { }
        for key in [".", "5", "done"] { try await store.amountKey(id, key: key) }
        s = try await store.snapshot(id); XCTAssertEqual(s.draft.amount, "999999999999.50")
    }

    func testPrintingIsCosmeticMonotonicAndPreservesEdits() async throws {
        let client = try MockLedger(); let store = ReceiptStore(client: client)
        let id = try await store.open(draftURL)
        try await store.edit(id, field: .amount, value: "48.50")
        let maybeGeneration = try await store.beginMotion(id, .printing)
        let generation = try XCTUnwrap(maybeGeneration)
        let duplicate = try await store.beginMotion(id, .printing); XCTAssertNil(duplicate)
        try await store.confirm(id)
        try await store.advanceMotion(id, generation: generation, progress: 0.5)
        let backwards = try await store.advanceMotion(id, generation: generation, progress: 0.2); XCTAssertFalse(backwards)
        let stale = try await store.advanceMotion(id, generation: "old", progress: 1); XCTAssertFalse(stale)
        var s = try await store.snapshot(id); XCTAssertEqual(s.paperProgress, 0.5); XCTAssertTrue(s.locked)
        try await store.advanceMotion(id, generation: generation, progress: 1)
        s = try await store.snapshot(id); XCTAssertEqual(s.motion, .idle); XCTAssertFalse(s.locked)
        XCTAssertEqual(s.draft.amount, "48.50")
        let counts = await client.counts(); XCTAssertEqual(counts.1, 0)
    }

    func testTearingRequiresAcknowledgedSaveAndCannotRepeatWrite() async throws {
        for outcome in [MockLedger.Outcome.success, .rejected, .uncertain] {
            let client = try MockLedger(outcome: outcome); let store = ReceiptStore(client: client)
            let id = try await store.open(draftURL)
            let premature = try await store.beginMotion(id, .tearing); XCTAssertNil(premature)
            try await store.confirm(id)
            let generation = try await store.beginMotion(id, .tearing)
            if outcome == .success {
                let token = try XCTUnwrap(generation)
                try await store.advanceMotion(id, generation: token, progress: 1, completing: false)
                let lastPose = try await store.snapshot(id)
                XCTAssertEqual(lastPose.motion, .tearing, "Do not replace the sheet before its final interpolation/audio interval ends")
                try await store.advanceMotion(id, generation: token, progress: 1)
                let repeatTear = try await store.beginMotion(id, .tearing); XCTAssertNil(repeatTear)
                try await store.confirm(id)
            } else { XCTAssertNil(generation) }
            let counts = await client.counts(); XCTAssertEqual(counts.1, 1)
        }
    }

    func testInterruptedPrintExpiresWithoutTrappingEditor() async throws {
        let store = ReceiptStore(client: try MockLedger()); let id = try await store.demo()
        _ = try await store.beginMotion(id, .printing)
        try await Task.sleep(for: .milliseconds(5100))
        let s = try await store.snapshot(id)
        XCTAssertEqual(s.motion, .idle); XCTAssertEqual(s.paperProgress, 1); XCTAssertFalse(s.locked)
        try await store.panel(id, .amount)
        try await store.amountKey(id, key: "7")
        let edited = try await store.snapshot(id); XCTAssertEqual(edited.amountInput, "7")
    }

    func testCapabilityValidationRejectsUntrustedDestinationsAndDuplicateParameters() throws {
        XCTAssertEqual(try DraftReference(url: draftURL).id, draftID)
        let valid = draftURL.absoluteString
        for url in [valid.replacingOccurrences(of: "https:", with: "http:"),
                    valid.replacingOccurrences(of: "ledger.xiaokai123.de5.net", with: "attacker.example"),
                    valid.replacingOccurrences(of: "/confirm", with: "/ledger"),
                    valid + "&id=" + draftID, valid + "&token=bad", valid + "#fragment",
                    valid.replacingOccurrences(of: "https://", with: "https://user:password@") ] {
            XCTAssertThrowsError(try DraftReference(url: URL(string: url)!))
        }
    }

    func testAmountAndDateValidation() {
        for amount in ["23", "23.00", "0.01"] { XCTAssertTrue(ReceiptDraft.validAmount(amount)) }
        for amount in ["0", "-1", "1.001", "1e2", "NaN", "1,000", ""] { XCTAssertFalse(ReceiptDraft.validAmount(amount)) }
        XCTAssertTrue(ReceiptDraft.validDate("2026-11-13T12:30"))
        XCTAssertFalse(ReceiptDraft.validDate("2026-02-30T12:30"))
        XCTAssertFalse(ReceiptDraft.validMonth("2026-13"))
    }

    func testSnapshotReadsAndChoicesNeverSave() async throws {
        let client = try MockLedger(); let store = ReceiptStore(client: client)
        let id = try await store.open(draftURL)
        for _ in 0..<4 { _ = try await store.snapshot(id) }
        try await store.panel(id, .category)
        try await store.choose(id, value: "购物")
        let snapshot = try await store.snapshot(id)
        XCTAssertEqual(snapshot.draft.category, "购物")
        XCTAssertEqual(snapshot.draft.transactionType, .expense)
        let counts = await client.counts()
        XCTAssertEqual(counts.0, 1); XCTAssertEqual(counts.1, 0)
    }

    func testDemoDoesNotCallAnyAPI() async throws {
        let client = try MockLedger(); let store = ReceiptStore(client: client)
        let id = try await store.demo()
        try await store.edit(id, field: .amount, value: "24.50")
        try await store.confirm(id)
        let snapshot = try await store.snapshot(id)
        XCTAssertTrue(snapshot.isDemo); XCTAssertEqual(snapshot.phase, .saved)
        let counts = await client.counts()
        XCTAssertEqual(counts.0 + counts.1 + counts.2, 0)
    }

    func testConcurrentConfirmationWritesOnceAndLocksEdits() async throws {
        let client = try MockLedger(outcome: .gated); let store = ReceiptStore(client: client)
        let id = try await store.open(draftURL)
        let display = SaveDisplayProbe()
        let first = Task { try await store.confirm(id, onSaving: { await display.show() }) }
        await client.waitUntilSaving()
        let displayed = await display.wasShown()
        XCTAssertTrue(displayed, "Notify the snippet of saving before waiting for the API result")
        try await store.confirm(id)
        do { try await store.edit(id, field: .amount, value: "99"); XCTFail("must reject edits during save") }
        catch { }
        let pending = try await store.snapshot(id)
        XCTAssertEqual(pending.phase, .saving)
        let counts = await client.counts(); XCTAssertEqual(counts.1, 1)
        await client.finish(); try await first.value
        let saved = try await store.snapshot(id); XCTAssertEqual(saved.phase, .saved)
    }

    func testUncertainSaveDoesNotAnimateSuccessOrRetry() async throws {
        let client = try MockLedger(outcome: .uncertain); let store = ReceiptStore(client: client)
        let id = try await store.open(draftURL)
        try await store.confirm(id)
        try await store.confirm(id)
        let s = try await store.snapshot(id)
        XCTAssertEqual(s.phase, .uncertain); XCTAssertTrue(s.locked)
        let counts = await client.counts(); XCTAssertEqual(counts.1, 1)
    }

    func testRejectedSaveKeepsPaperEditable() async throws {
        let client = try MockLedger(outcome: .rejected); let store = ReceiptStore(client: client)
        let id = try await store.open(draftURL)
        try await store.confirm(id)
        try await store.edit(id, field: .amount, value: "10.00")
        let s = try await store.snapshot(id)
        XCTAssertEqual(s.phase, .ready); XCTAssertEqual(s.draft.amount, "10.00")
    }

    func testRefundRequiresExplicitMatchingOrderAndChecksBalance() async throws {
        let client = try MockLedger(kind: "refund"); let store = ReceiptStore(client: client)
        let id = try await store.open(draftURL)
        try await store.confirm(id)
        var counts = await client.counts(); XCTAssertEqual(counts.1, 0)
        try await store.panel(id, .refunds)
        try await store.choose(id, value: "original-1")
        try await store.edit(id, field: .amount, value: "26.00")
        try await store.confirm(id)
        counts = await client.counts(); XCTAssertEqual(counts.1, 0)
        try await store.edit(id, field: .amount, value: "20.00")
        try await store.confirm(id)
        let payload = await client.payload
        XCTAssertEqual(payload?.originalTransactionId, "original-1")
        XCTAssertEqual(payload?.transactionType, .refund)
        XCTAssertEqual(payload?.budgetIncluded, false)
    }

    func testUnknownTypeCannotOpenCard() async throws {
        let client = try MockLedger(kind: "unknown"); let store = ReceiptStore(client: client)
        do { _ = try await store.open(draftURL); XCTFail("must not default unknown type to expense") }
        catch { }
        let counts = await client.counts(); XCTAssertEqual(counts.1, 0)
    }

    func testIncomeAndTransferAccountsAndNotesSurvivePayload() async throws {
        for kind in ["income", "transfer"] {
            let client = try MockLedger(kind: kind); let store = ReceiptStore(client: client)
            let id = try await store.open(draftURL)
            try await store.edit(id, field: .destination, value: "银行卡")
            try await store.edit(id, field: .note, value: "个人备注")
            try await store.confirm(id)
            let payload = await client.payload
            XCTAssertEqual(payload?.receiptAccount, "银行卡")
            XCTAssertEqual(payload?.userRemark, "个人备注")
            XCTAssertEqual(payload?.transactionType.rawValue, kind)
            XCTAssertEqual(payload?.budgetIncluded, false)
        }
    }

    func testReopeningPreservesEditsAndCancellationNeverSaves() async throws {
        let client = try MockLedger(); let store = ReceiptStore(client: client)
        let id = try await store.open(draftURL)
        try await store.edit(id, field: .amount, value: "15.00")
        let again = try await store.open(draftURL); XCTAssertEqual(again, id)
        let s = try await store.snapshot(again); XCTAssertEqual(s.draft.amount, "15.00")
        try await store.cancel(id)
        try await store.confirm(id)
        let counts = await client.counts(); XCTAssertEqual(counts.1, 0); XCTAssertEqual(counts.2, 1)
    }
}

extension ReceiptCoreTests {
    func testChineseTypingStaysBufferedAndNeverWritesBeforeConfirmation() async throws {
        let client = try MockLedger(); let store = ReceiptStore(client: client)
        let id = try await store.open(draftURL)
        try await store.textAction(id, operation: "open", value: "note")
        var s = try await store.snapshot(id)
        let session = s.textSession
        for key in "wancan" { try await store.keyboardAction(id, session: session, operation: "key", value: String(key)) }
        s = try await store.snapshot(id)
        XCTAssertEqual(s.pinyinInput, "wancan"); XCTAssertEqual(s.note, "")
        try await store.textAction(id, operation: "done")
        s = try await store.snapshot(id); XCTAssertEqual(s.inlineEditor, "note")
        try await store.confirm(id)
        try await store.choosePinyin(id, session: session, composition: "wancan", text: "晚餐", consumed: 6)
        s = try await store.snapshot(id)
        XCTAssertEqual(s.textInput, "晚餐"); XCTAssertEqual(s.note, ""); XCTAssertEqual(s.pinyinInput, "")
        try await store.textAction(id, operation: "done")
        s = try await store.snapshot(id)
        XCTAssertEqual(s.note, "晚餐"); XCTAssertEqual(s.cardID, id); XCTAssertNil(s.inlineEditor)
        let counts = await client.counts(); XCTAssertEqual(counts.1, 0)
    }

    func testPinyinModesPagesBackspaceAndStaleChoices() async throws {
        let store = ReceiptStore(client: try MockLedger()); let id = try await store.demo()
        try await store.textAction(id, operation: "open", value: "note")
        var s = try await store.snapshot(id); let session = s.textSession
        for key in "wancan" { try await store.keyboardAction(id, session: session, operation: "key", value: String(key)) }
        try await store.keyboardAction(id, session: session, operation: "mode", value: "english")
        s = try await store.snapshot(id); XCTAssertEqual(s.keyboardMode, .pinyin); XCTAssertEqual(s.pinyinInput, "wancan")
        try await store.choosePinyin(id, session: session, composition: "wancan", text: "伪造", consumed: 6)
        try await store.choosePinyin(id, session: session, composition: "wan", text: "晚餐", consumed: 3)
        s = try await store.snapshot(id); XCTAssertEqual(s.textInput, "")
        try await store.keyboardAction(id, session: session, operation: "page", value: "1")
        s = try await store.snapshot(id); XCTAssertEqual(s.candidatePage, 1)
        try await store.choosePinyin(id, session: session, composition: "wancan", text: "晚", consumed: 3)
        s = try await store.snapshot(id); XCTAssertEqual(s.textInput, "晚"); XCTAssertEqual(s.pinyinInput, "can")
        try await store.keyboardAction(id, session: session, operation: "backspace")
        s = try await store.snapshot(id); XCTAssertEqual(s.pinyinInput, "ca"); XCTAssertEqual(s.textInput, "晚")
        try await store.keyboardAction(id, session: session, operation: "clearComposition")
        try await store.keyboardAction(id, session: session, operation: "mode", value: "english")
        for key in "ABC" { try await store.keyboardAction(id, session: session, operation: "key", value: String(key)) }
        try await store.keyboardAction(id, session: session, operation: "space")
        try await store.keyboardAction(id, session: session, operation: "mode", value: "numbers")
        try await store.keyboardAction(id, session: session, operation: "key", value: "2")
        s = try await store.snapshot(id); XCTAssertEqual(s.textInput, "晚ABC 2")
        try await store.textAction(id, operation: "cancel")
        try await store.textAction(id, operation: "open", value: "note")
        try await store.keyboardAction(id, session: session, operation: "key", value: "x")
        s = try await store.snapshot(id)
        XCTAssertNotEqual(s.textSession, session); XCTAssertEqual(s.textInput, ""); XCTAssertEqual(s.pinyinInput, ""); XCTAssertEqual(s.note, "")
    }

    func testPinyinCandidateCannotConsumeInputBeyondTextLimit() async throws {
        let store = ReceiptStore(client: try MockLedger()); let id = try await store.demo()
        try await store.edit(id, field: .note, value: String(repeating: "字", count: 300))
        try await store.textAction(id, operation: "open", value: "note")
        var s = try await store.snapshot(id)
        for key in "wan" { try await store.keyboardAction(id, session: s.textSession, operation: "key", value: String(key)) }
        try await store.choosePinyin(id, session: s.textSession, composition: "wan", text: "晚", consumed: 3)
        s = try await store.snapshot(id)
        XCTAssertEqual(s.textInput.count, 300); XCTAssertEqual(s.pinyinInput, "wan"); XCTAssertFalse(s.message.isEmpty)
    }

    func testSuccessIsDeferredUntilTearCompletesAndDuplicateConfirmNeverWrites() async throws {
        let client = try MockLedger(); let store = ReceiptStore(client: client)
        let id = try await store.open(draftURL)
        try await store.confirm(id, prepareTear: true)
        var s = try await store.snapshot(id)
        XCTAssertEqual(s.phase, .saved); XCTAssertFalse(s.showsCompletion); XCTAssertTrue(s.locked)
        let motion = try await store.beginMotion(id, .tearing)
        let generation = try XCTUnwrap(motion)
        try await store.advanceMotion(id, generation: generation, progress: 1, completing: false)
        s = try await store.snapshot(id); XCTAssertFalse(s.showsCompletion)
        try await store.confirm(id, prepareTear: true)
        try await store.advanceMotion(id, generation: generation, progress: 1)
        s = try await store.snapshot(id); XCTAssertTrue(s.showsCompletion); XCTAssertFalse(s.completionPending)
        try await store.confirm(id, prepareTear: true)
        s = try await store.snapshot(id); XCTAssertTrue(s.showsCompletion)
        let counts = await client.counts(); XCTAssertEqual(counts.1, 1)
    }
}

extension ReceiptCoreTests {
    func testUndoRestoresSameCardWithNewCapabilityAndAllowsOneExplicitResave() async throws {
        let client = try MockLedger(); let store = ReceiptStore(client: client)
        let id = try await store.open(draftURL)
        try await store.edit(id, field: .note, value: "保留备注")
        try await store.confirm(id)
        var s = try await store.snapshot(id); XCTAssertTrue(s.canUndo)
        let firstTear = try await store.beginMotion(id, .tearing)
        try await store.advanceMotion(id, generation: XCTUnwrap(firstTear), progress: 1)
        try await store.undo(id)
        s = try await store.snapshot(id)
        XCTAssertEqual(s.cardID, id); XCTAssertEqual(s.phase, .ready); XCTAssertEqual(s.note, "保留备注")
        XCTAssertEqual(s.draft.id, "00000000-0000-4000-8000-000000000002"); XCTAssertTrue(s.undoRestored)
        try await store.undo(id)
        let undoCount = await client.undoCount(); XCTAssertEqual(undoCount, 1)
        try await store.confirm(id)
        let counts = await client.counts(); XCTAssertEqual(counts.1, 2)
        let nextTear = try await store.beginMotion(id, .tearing); XCTAssertNotNil(nextTear)
    }
    func testUncertainUndoCannotSaveAgainUntilIdempotentResultIsConfirmed() async throws {
        let client = try MockLedger(); let store = ReceiptStore(client: client)
        let id = try await store.open(draftURL); try await store.confirm(id)
        await client.makeUndoUncertain(); try await store.undo(id)
        var s = try await store.snapshot(id); XCTAssertEqual(s.phase, .undoUncertain); XCTAssertTrue(s.canUndo)
        try await store.confirm(id)
        let counts = await client.counts(); XCTAssertEqual(counts.1, 1)
        try await store.undo(id)
        s = try await store.snapshot(id); XCTAssertEqual(s.phase, .ready)
    }
    func testLocalRemindersAreBoundedSortedAndNeverContainInvalidPastItems() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var items: [[String: Any]] = (0..<70).map { i in ["id": "fixture-\(i)", "title": "会员", "amount": "19.00", "dueDate": "2028-01-01", "remindAt": now.addingTimeInterval(Double(1000-i)).timeIntervalSince1970*1000] }
        items.append(["id":"past","title":"过去","amount":"1.00","dueDate":"2028-01-01","remindAt":0])
        items.append(items[0])
        let data = try JSONSerialization.data(withJSONObject: items)
        let schedule = try ReceiptReminder.schedule(data: data, now: now)
        XCTAssertEqual(schedule.count, 60); XCTAssertEqual(Set(schedule.map(\.id)).count, 60)
        XCTAssertEqual(schedule.first?.id, "fixture-69"); XCTAssertTrue(schedule.allSatisfy { $0.identifier.hasPrefix("ledger.recurring.") })
    }
}
