import XCTest
@testable import ReceiptCore

private actor PendingReceipt {
    var calls = 0
    var continuation: CheckedContinuation<String, Never>?
    func load() async -> String {
        calls += 1
        return await withCheckedContinuation { continuation = $0 }
    }
    func finish() { continuation?.resume(returning: "same-card"); continuation = nil }
}

final class ScreenshotReceiptPreviewTests: XCTestCase {
    func testMarketplaceReviewsEachFieldWithoutAnAmountAndProtectsOrderStatus() {
        let partial = ScreenshotReceiptPreview(text: """
            拼多多 订单详情
            收货地址
            已隐藏
            纸舟日用官方旗舰店 进店
            云纹抽纸 3包 拼单价 ¥32.90
            商品总额 ¥32.90
            平台优惠 ¥10.00
            更多推荐
            星舟便利店
            实付 ¥3.50
            """)
        XCTAssertEqual(partial.platform, "拼多多")
        XCTAssertNil(partial.amount)
        XCTAssertEqual(partial.merchant, "纸舟日用官方旗舰店")
        XCTAssertEqual(partial.product, "云纹抽纸 3包")
        XCTAssertEqual(partial.category, "购物")
        XCTAssertFalse(partial.canConfirm)
        let complete = ScreenshotReceiptPreview(text: """
            拼多多
            订单详情
            纸舟日用官方旗舰店
            云纹抽纸 拼单价 ¥32.90
            共1件商品，实付款（含运费¥0.00） ¥22.90
            付款方式 微信支付
            """)
        XCTAssertEqual(complete.amount, "22.90")
        XCTAssertEqual(complete.merchant, "纸舟日用官方旗舰店")
        XCTAssertEqual(complete.platform, "拼多多")
        XCTAssertNil(complete.account)
        let pending = ScreenshotReceiptPreview(text: "拼多多\n待扣款\n纸舟日用官方旗舰店\n商品名称 云纹抽纸\n实付 ¥22.90")
        XCTAssertNil(pending.amount)
        XCTAssertEqual(pending.product, "云纹抽纸")
        XCTAssertFalse(pending.canConfirm)
    }

    func testWalletDetailShowsSignedHeadlineMerchantAccountAndTime() {
        let wechat = ScreenshotReceiptPreview(text: """
            微信支付
            账单详情
            -18.60
            当前状态 支付成功
            商品说明 青茶一杯
            商户全称 星舟茶饮
            付款方式 零钱
            支付时间 2026-11-22 15:20:38
            交易单号
            12345678901234567890
            """)
        XCTAssertEqual(wechat.amount, "18.60")
        XCTAssertEqual(wechat.transactionType, .expense)
        XCTAssertEqual(wechat.platform, "微信支付")
        XCTAssertEqual(wechat.merchant, "星舟茶饮")
        XCTAssertEqual(wechat.product, "青茶一杯")
        XCTAssertEqual(wechat.category, "餐饮")
        XCTAssertEqual(wechat.account, "微信零钱")
        XCTAssertEqual(wechat.occurredAt, "2026-11-22T15:20")

        let alipay = ScreenshotReceiptPreview(text: "支付宝\n账单详情\n星舟超市\n¥32.50\n支付成功\n商品说明 生活日用品\n付款方式 余额宝\n订单号 1234567890123")
        XCTAssertEqual(alipay.amount, "32.50")
        XCTAssertEqual(alipay.merchant, "星舟超市")
        XCTAssertEqual(alipay.account, "余额宝")
        XCTAssertEqual(alipay.platform, "支付宝")
        XCTAssertEqual(alipay.category, "购物")
        let union = ScreenshotReceiptPreview(text: "云闪付\n账单详情\n交易金额 18.20\n交易方向 支出\n商户名称 城南地铁\n付款方式 招商银行储蓄卡")
        XCTAssertEqual(union.platform, "云闪付")
        XCTAssertEqual(union.amount, "18.20")
        XCTAssertEqual(union.category, "交通")
        XCTAssertEqual(union.account, "银行卡")
    }

    func testBankSeparatesAmountsDirectionBalanceAndUnsettledRefund() {
        for bank in ["中国工商银行","中国建设银行","中国农业银行","中国银行","招商银行","交通银行"] {
            let receipt = ScreenshotReceiptPreview(text: "\(bank)\n交易明细\n交易金额 ￥12.80\n交易后余额 9,987.20\n借贷标志 借方\n对方户名 城南地铁\n交易摘要 乘车扣费")
            XCTAssertEqual(receipt.platform, bank)
            XCTAssertEqual(receipt.amount, "12.80")
            XCTAssertEqual(receipt.transactionType, .expense)
            XCTAssertEqual(receipt.merchant, "城南地铁")
            XCTAssertEqual(receipt.product, "乘车扣费")
            XCTAssertEqual(receipt.category, "交通")
        }
        let income = ScreenshotReceiptPreview(text: "招商银行\n交易详情\n贷方发生额 ￥3,200.00\n账户余额 25,000.00\n对方户名 星舟公司\n交易摘要 工资入账")
        XCTAssertEqual(income.amount, "3200.00")
        XCTAssertEqual(income.transactionType, .income)
        XCTAssertEqual(income.category, "工资")
        for text in ["招商银行\n账户余额 ¥1200\n可用余额 ¥1000", "招商银行\n交易金额 19.90\n收支方向 未知\n账户余额 900",
                     "微信支付\n交易成功\n退款处理中\n实付 12.00","微信支付\n本月支出\n-25.00\n支付成功",
                     "招商银行\n交易金额 12.80\n交易金额 23.50\n借方\n账户余额 700.00"] {
            XCTAssertNil(ScreenshotReceiptPreview(text: text).amount, text)
        }
        let refund = ScreenshotReceiptPreview(text: "支付宝\n退款成功\n退款金额 ¥8.00\n原订单实付 ¥60.00\n商户名称 星舟超市")
        XCTAssertEqual(refund.transactionType, .refund)
        XCTAssertEqual(refund.amount, "8.00")
        XCTAssertEqual(refund.category, "退款")
        XCTAssertFalse(refund.canConfirm)
    }

    func testMarketplaceAndDeliveryBrandsDoNotComeFromTheirPaymentMethod() {
        for brand in ["京东","淘宝","天猫","抖音商城","美团","饿了么","淘宝闪购","唯品会","快手小店","拼好饭"] {
            let receipt = ScreenshotReceiptPreview(text: "\(brand)\n订单详情\n店铺名称 星舟便利店\n商品名称 纸巾\n实付 12.34\n付款方式\n支付宝")
            XCTAssertEqual(receipt.platform, brand)
            XCTAssertEqual(receipt.amount, "12.34")
            XCTAssertEqual(receipt.product, "纸巾")
            XCTAssertEqual(receipt.merchant, "星舟便利店")
        }
        XCTAssertNil(ScreenshotReceiptPreview(text: "晴天面馆（东街店）\n炒面 拼单价 ¥9.90\n实付 ¥8.90").platform)
        let partial = ScreenshotReceiptPreview(text: "拼多多\n商品名称 抽纸\n优惠 ¥5")
        let combined = ScreenshotReceiptPreview(spatialText: "拼多多\n纸舟日用官方旗舰店\n实付款（含运费¥0.00） ¥22.90", fallback: partial)
        XCTAssertEqual(combined.amount, "22.90")
        XCTAssertEqual(combined.product, "抽纸")
        XCTAssertEqual(combined.merchant, "纸舟日用官方旗舰店")
    }

    func testPaidTotalBeatsItemPriceAndRecommendations() {
        let text = """
        服务保障中
        晴天面馆（东街店）
        招牌面 拼单价 ¥19.90
        ×1
        实付
        ¥12.34 >
        配送地址
        更多推荐
        山茶咖啡（南街店）
        实付 ¥35.00
        """
        let preview = ScreenshotReceiptPreview(text: text)
        XCTAssertEqual(preview.amount, "12.34")
        XCTAssertEqual(preview.merchant, "晴天面馆(东街店)")
        XCTAssertEqual(preview.category, "餐饮")
        XCTAssertTrue(preview.canConfirm)
    }

    func testDistantPaidColumnAndAfterSalesMenuUseTheCorrectVisualRow() {
        let boxes = [
            ReceiptTextBox(text: "¥ 13.80 ›", left: 0.82, top: 0.523, height: 0.022),
            ReceiptTextBox(text: "拼单价 ¥24.00", left: 0.77, top: 0.422, height: 0.020),
            ReceiptTextBox(text: "晴天面馆（东街店）", left: 0.03, top: 0.35, height: 0.020),
            ReceiptTextBox(text: "招牌番茄面", left: 0.21, top: 0.424, height: 0.019),
            ReceiptTextBox(text: "实 付", left: 0.03, top: 0.526, height: 0.018),
            ReceiptTextBox(text: "申请退款", left: 0.22, top: 0.22, height: 0.020),
            ReceiptTextBox(text: "更多推荐", left: 0.03, top: 0.78, height: 0.020),
            ReceiptTextBox(text: "实付 ¥8", left: 0.60, top: 0.84, height: 0.020)
        ]
        let flat = ScreenshotReceiptPreview(text: "实付\n配送地址\n拼单价 ¥24.00\n¥13.80")
        XCTAssertNil(flat.amount)
        let result = ScreenshotReceiptPreview(spatialText: ReceiptTextBox.rows(boxes), fallback: flat)
        XCTAssertEqual(result.amount, "13.80")
        XCTAssertEqual(result.merchant, "晴天面馆(东街店)")
        XCTAssertEqual(result.product, "招牌番茄面")
        XCTAssertEqual(result.category, "餐饮")
        XCTAssertNil(ScreenshotReceiptPreview(spatialText: "实付 13.80", fallback: .init(text: "退款成功\n实付 13.80")).amount)
        XCTAssertNil(ScreenshotReceiptPreview(spatialText: "实付 13.80", fallback: .init(text: "实付 83.80")).amount)
    }

    func testNoInventedTotalsOrPaymentForAmbiguousTransactions() {
        for text in ["拼单价 ¥35.90\n优惠 ¥5", "实付 19.99\n退款成功", "待支付\n实付 19",
                     "实付 8\n实付款 9", "实际支付 USD 48", "实付 ¥12.345", "实付 0", "实付 9\n港币"] {
            XCTAssertNil(ScreenshotReceiptPreview(text: text).amount, text)
        }
        let unknown = ScreenshotReceiptPreview(text: "配送地址\n示例路11单元（假店）\n实付 ¥20")
        XCTAssertEqual(unknown.amount, "20.00")
        XCTAssertNil(unknown.merchant)
        XCTAssertFalse(unknown.canConfirm)
    }

    func testFirstPaperDoesNotWaitAndReopenReusesTheWorker() async throws {
        let gate = PendingReceipt(), session = ScreenshotReviewSession()
        let preview = ScreenshotReceiptPreview(text: "商户：晴天面馆\n实付 28")
        await session.begin("a", preview: preview) { await gate.load() }
        let initial = await session.state("a")
        XCTAssertEqual(initial?.preview.amount, "28.00")
        XCTAssertNil(initial?.card)
        await session.begin("a", preview: preview) { XCTFail("Unexpected duplicate worker"); return "other" }
        let waiting = try await session.review("a", waiting: .milliseconds(50))
        XCTAssertNil(waiting.card)
        let calls = await gate.calls
        XCTAssertEqual(calls, 1)
        await gate.finish()
        let complete = try await session.review("a")
        XCTAssertEqual(complete.card, "same-card")
        XCTAssertEqual(complete.preview, initial?.preview)
        XCTAssertTrue(complete.message.isEmpty)
    }

    func testFailedReadCanResumeWithoutChangingPreview() async throws {
        actor Flaky {
            var first = true
            func resolve() throws -> String {
                if first { first = false; throw ReceiptError.message("登录已过期") }
                return "restored-card"
            }
        }
        let loader = Flaky(), session = ScreenshotReviewSession()
        let preview = ScreenshotReceiptPreview(text: "实付款：¥10.80")
        await session.begin("b", preview: preview) { try await loader.resolve() }
        for _ in 0..<100 {
            if await session.state("b")?.message == "登录已过期" { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let failed = await session.state("b")
        XCTAssertEqual(failed?.message, "登录已过期")
        let restored = try await session.review("b")
        XCTAssertEqual(restored.card, "restored-card")
        XCTAssertEqual(restored.preview.amount, "10.80")
    }
}
