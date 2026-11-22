import Foundation

/// Local, read-only extraction. Each field keeps its own evidence, so a missing amount
/// cannot erase a clearly printed shop, product or payment account.
public struct ScreenshotReceiptPreview: Equatable, Sendable {
    public private(set) var amount: String?
    public private(set) var merchant: String?
    public private(set) var category: String?
    public private(set) var product: String?
    public private(set) var platform: String?
    public private(set) var account: String?
    public private(set) var occurredAt: String?
    public private(set) var transactionType: TransactionKind = .unknown
    public private(set) var paidOnOneLine = false
    private var blockedAmount = false

    private struct Money: Equatable {
        let value: String
        let sign: Int
        let line: Int
        let inline: Bool
    }
    private static let price = try! NSRegularExpression(pattern: #"^[:：]?(?:\((?:人民币|元)\))?(?:人民币|CNY|RMB)?([+\-−]?)[¥￥]?([+\-−]?)((?:[0-9]{1,3}(?:,[0-9]{3})+|[0-9]{1,9})(?:\.[0-9]{1,2})?)(?:元|人民币)?[›>〉»❯]?$"#, options: .caseInsensitive)
    private static let deliveryNote = try! NSRegularExpression(pattern: #"\((?:含运费(?:[:：]?[¥￥]?\d+(?:\.\d{1,2})?元?)?|免运费|包邮|运费[¥￥]?\d+(?:\.\d{1,2})?元?)\)|(?:免运费|包邮)$"#)
    private static let leadingCount = try! NSRegularExpression(pattern: #"^共[0-9]{1,3}件(?:商品)?[,，·]?"#)
    private static let datePattern = try! NSRegularExpression(pattern: #"^(?:支付时间|付款时间|交易时间|入账时间|到账时间|交易日期)[:：]?([0-9]{4})[-年/.]([0-9]{1,2})[-月/.]([0-9]{1,2})(?:日)?(?:T|\s+)([0-9]{1,2}):([0-9]{2})(?::[0-9]{2})?$"#)
    private static let paid = ["订单实付金额","订单实付款","订单实付","合计实付款","合计实付","实付金额","实际支付金额","实付款","实际付款","实际支付","实付","付款金额","支付金额"]
    private static let blocked = ["待支付","待付款","等待付款","未付款","尚未支付","支付失败","付款失败","交易关闭","交易取消","尚未扣款","待扣款","支付剩余","退款处理中","退款申请中","退款中","退款失败","交易冲正","冲正交易"]
    private static let harmless = ["申请退款","退款/售后","退款售后","退款规则","退款说明","极速退款","退款保障","查看退款规则","查看退款说明"]
    private static let nonCNY = try! NSRegularExpression(pattern: #"USD|HKD|US\$|HK\$|美元|港元|港币|日元|JPY|EUR|欧元|英镑|GBP|澳元|新币|新加坡元|SGD|外币"#, options: .caseInsensitive)

    public init(text: String) {
        let page = ScreenshotBillLayout(text)
        platform = page.platform
        let body = page.compact.map { line in Self.harmless.reduce(line) { $0.replacingOccurrences(of: $1, with: "") } }.joined(separator: "\n")
        let summary = ["本月总支出","本月总收入","本月支出","本月收入","本月汇总","收支统计","账单列表","月度账单"].contains(where: body.contains)
        let blocked = Self.blocked.contains(where: body.contains) || body.contains("未扣款") || summary || ScreenshotBillLayout.matches(Self.nonCNY, body)
        let hasRefund = body.contains("退款") || body.contains("退回")
        let transfer = ["转账","转入","转出","本人互转","账户互转"].contains(where: body.contains)
        let salary = body.contains("工资") || body.contains("薪资")
        let completed = ["支付成功","付款成功","交易成功","扣款成功","已支付","已付款","已扣款"].contains(where: body.contains)
        let outgoing = ["支出","借方","消费","付款成功","支付成功","已付款","已支付","扣款成功"].contains(where: body.contains)
        let incoming = ["收入","贷方","已收款","收款成功","已到账","入账成功","工资入账","薪资入账"].contains(where: body.contains)
        var candidate: Money?
        let header = page.family == .bank || page.family == .wallet ? Self.header(in: page, unsigned: page.family == .wallet && (outgoing != incoming)) : nil
        if blocked {
            blockedAmount = true
        } else if hasRefund {
            if ["退款成功","已退款","退款到账","已退回"].contains(where: body.contains) {
                candidate = Self.labeled(["退款金额","已退金额","退回金额","实际退款"], in: page)
            }
            transactionType = candidate == nil ? .unknown : .refund
            blockedAmount = candidate == nil
        } else if transfer {
            if ["本人账户互转","本人互转","账户互转"].contains(where: body.contains),
               ["转账成功","交易成功","已到账"].contains(where: body.contains) {
                candidate = Self.labeled(["转账金额","转出金额","转入金额"], in: page)
            }
            transactionType = candidate == nil ? .unknown : .transfer
            blockedAmount = candidate == nil
        } else {
            // Conflicting explicit totals indicate multiple transactions or a disputed amount.
            let explicitTotals = Self.amounts(Self.paid, in: page)
            if Set(explicitTotals.map(\.value)).count > 1 {
                blockedAmount = true
            } else if let ordinary = explicitTotals.first {
                if ordinary.sign <= 0 { candidate = ordinary; transactionType = .expense }
                else { blockedAmount = true }
            } else if page.family == .bank || page.family == .wallet {
                let debitRows = Self.amounts(["支出金额","借方发生额","借方金额","扣款金额","消费金额"], in: page)
                let creditRows = Self.amounts(["收入金额","贷方发生额","贷方金额","入账金额","到账金额","收款金额"], in: page)
                let genericRows = Self.amounts(["交易金额","交易发生额","人民币金额"], in: page)
                let debit = debitRows.first, credit = creditRows.first, generic = genericRows.first
                let primary = debit ?? credit ?? generic ?? header
                let relevant = debitRows + creditRows + genericRows + [header].compactMap { $0 }
                if Set(relevant.map(\.value)).count > 1 { blockedAmount = true }
                else if let primary {
                    let isDebit = debit != nil || primary.sign < 0 || outgoing
                    let isCredit = credit != nil || primary.sign > 0 || incoming || salary
                    if isDebit != isCredit {
                        candidate = primary
                        transactionType = isDebit ? .expense : .income
                    } else { blockedAmount = true }
                }
            } else if page.family == .order && completed && !["优惠","折扣","立减","待付","尾款"].contains(where: body.contains) {
                candidate = Self.labeled(["订单合计","合计"], in: page)
                if candidate != nil { transactionType = .expense }
            }
        }

        let shop = page.merchant(near: header?.line)
        merchant = shop?.name
        product = page.product(after: shop?.index)
        if transactionType == .unknown && !blockedAmount && page.family == .order && (shop != nil || product != nil) {
            transactionType = .expense
        }
        amount = candidate?.value
        paidOnOneLine = candidate?.inline ?? false
        if !blockedAmount || transactionType != .unknown { category = page.category(merchant: merchant, product: product, type: transactionType) }
        account = page.account()
        occurredAt = Self.transactionDate(page)
    }

    public init(spatialText: String, fallback: Self) {
        let spatial = Self(text: spatialText)
        self = spatial
        let identityAgrees = spatial.merchant == nil || fallback.merchant == nil || Self.normalized(spatial.merchant!) == Self.normalized(fallback.merchant!)
        merchant = spatial.merchant ?? fallback.merchant
        if identityAgrees {
            product = spatial.product ?? fallback.product
            category = spatial.category ?? fallback.category
        }
        platform = spatial.platform ?? fallback.platform
        account = spatial.account ?? fallback.account
        occurredAt = spatial.occurredAt ?? fallback.occurredAt
        let conflictingRole = spatial.transactionType != .unknown && fallback.transactionType != .unknown && spatial.transactionType != fallback.transactionType
        if spatial.blockedAmount || fallback.blockedAmount || conflictingRole ||
            (spatial.amount != nil && fallback.amount != nil && spatial.amount != fallback.amount && fallback.paidOnOneLine) {
            amount = nil; paidOnOneLine = false; transactionType = .unknown; blockedAmount = true; category = nil
        } else if spatial.amount == nil {
            amount = fallback.amount
            paidOnOneLine = fallback.paidOnOneLine
            if fallback.transactionType != .unknown { transactionType = fallback.transactionType }
        }
    }

    public var canConfirm: Bool { transactionType == .expense && amount != nil && merchant != nil && category != nil && !blockedAmount }
    public func matches(_ draft: ReceiptDraft) -> Bool {
        guard canConfirm, let amount, let merchant, draft.transactionType == .expense, draft.currency.uppercased() == "CNY",
              !draft.requiresManualReview, draft.category == category, Decimal(string: amount) == Decimal(string: draft.amount) else { return false }
        return Self.normalized(merchant) == Self.normalized(draft.merchant)
    }

    private static func normalized(_ value: String) -> String {
        ScreenshotBillLayout.squeeze(value.folding(options: .widthInsensitive, locale: nil))
    }
    private static func strip(_ expression: NSRegularExpression, _ value: String) -> String {
        expression.stringByReplacingMatches(in: value, range: NSRange(value.startIndex...,in:value), withTemplate: "")
    }
    private static func money(_ text: String, line: Int, inline: Bool) -> Money? {
        let value = strip(deliveryNote, text)
        guard let match = price.firstMatch(in: value, range: NSRange(value.startIndex...,in:value)) else { return nil }
        let str = value as NSString
        let first = str.substring(with: match.range(at: 1)), second = str.substring(with: match.range(at: 2))
        guard first.isEmpty || second.isEmpty else { return nil }
        let token = str.substring(with: match.range(at: 3)).replacingOccurrences(of: ",", with: "")
        guard ReceiptDraft.validAmount(token), let number = Decimal(string: token, locale: Locale(identifier:"en_US_POSIX")) else { return nil }
        let parts = NSDecimalNumber(decimal: number).stringValue.components(separatedBy: ".")
        let cents = String(((parts.count > 1 ? parts[1] : "") + "00").prefix(2))
        let sign = first + second
        return Money(value: parts[0] + "." + cents, sign: sign.isEmpty ? 0 : sign == "+" ? 1 : -1, line: line, inline: inline)
    }
    private static func amounts(_ labels: [String], in page: ScreenshotBillLayout) -> [Money] {
        var values: [Money] = []
        for (i, raw) in page.compact.enumerated() {
            let row = raw.hasPrefix("共") ? strip(leadingCount, raw) : raw
            guard let label = labels.first(where: row.hasPrefix) else { continue }
            let suffix = strip(deliveryNote, String(row.dropFirst(label.count))).trimmingCharacters(in: CharacterSet(charactersIn: ":："))
            if let found = money(suffix, line: i, inline: true) { values.append(found) }
            else if suffix.isEmpty, i + 1 < page.compact.count, let found = money(page.compact[i+1], line: i+1, inline: false) { values.append(found) }
        }
        return values
    }
    private static func labeled(_ labels: [String], in page: ScreenshotBillLayout) -> Money? {
        let rows = amounts(labels, in: page)
        return Set(rows.map(\.value)).count == 1 ? rows.first : nil
    }
    private static func header(in page: ScreenshotBillLayout, unsigned: Bool) -> Money? {
        // A signed headline is eligible only in a financial detail page, before its metadata.
        var found: [Money] = []
        for (i, row) in page.compact.prefix(12).enumerated() {
            if ["付款方式","支付方式","交易单号","交易时间","账户余额","可用余额","交易后余额","订单号","余额","月度汇总"].contains(where: row.hasPrefix) { break }
            if let value = money(row, line: i, inline: true), value.sign != 0 || (unsigned && (row.contains("¥") || row.contains("."))) { found.append(value) }
        }
        return found.count == 1 ? found.first : nil
    }
    private static func transactionDate(_ page: ScreenshotBillLayout) -> String? {
        let labels = ["支付时间","付款时间","交易时间","入账时间","到账时间","交易日期"]
        for (i, raw) in page.lines.enumerated() {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            guard let label = labels.first(where: trimmed.hasPrefix) else { continue }
            var remainder = String(trimmed.dropFirst(label.count)).trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ":：")))
            if remainder.isEmpty && i + 1 < page.lines.count { remainder = page.lines[i+1] }
            let source = label + remainder
            if let m = datePattern.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)) {
                let string = source as NSString
                let nums = (1...5).compactMap { Int(string.substring(with: m.range(at: $0))) }
                guard nums.count == 5 else { continue }
                let date = String(format: "%04d-%02d-%02dT%02d:%02d",nums[0],nums[1],nums[2],nums[3],nums[4])
                if ReceiptDraft.validDate(date) { return date }
            }
        }
        return nil
    }
}
