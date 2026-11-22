import Foundation

public enum ReceiptError: Error, LocalizedError, Sendable {
    case message(String)
    case rejected(String)
    public var errorDescription: String? {
        switch self { case .message(let text), .rejected(let text): return text }
    }
}

public enum ReceiptService: Sendable {
    case original, independent

    var api: URL {
        switch self {
        case .original: return URL(string: "https://ledger-api.xiaokai123.de5.net/api/recognize")!
        case .independent: return URL(string: "https://ledger-sync.xiaokai123.de5.net/api/recognize")!
        }
    }

    var confirmation: URL {
        switch self {
        case .original: return URL(string: "https://ledger.xiaokai123.de5.net/confirm")!
        case .independent: return URL(string: "https://ledger-sync.xiaokai123.de5.net/confirm")!
        }
    }

    init?(host: String?) {
        switch host?.lowercased() {
        case "ledger-sync.xiaokai123.de5.net": self = .independent
        case "ledger.xiaokai123.de5.net", "suishou-ledger-0726.qq2301796536.chatgpt.site": self = .original
        default: return nil
        }
    }
}

/// A server-issued draft capability. It is parsed as data and never opened.
public struct DraftReference: Sendable, Equatable {
    public let service: ReceiptService
    public let id: String
    public let token: String
    public init(url: URL) throws {
        guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false),
              c.scheme == "https", let service = ReceiptService(host: c.host),
              c.port == nil || c.port == 443, c.user == nil, c.password == nil,
              c.path == "/confirm", c.fragment == nil else {
            throw ReceiptError.message("识别结果地址无效，请重新运行截图记账。")
        }
        let ids = (c.queryItems ?? []).filter { $0.name == "id" }
        let tokens = (c.queryItems ?? []).filter { $0.name == "token" }
        guard ids.count == 1, tokens.count == 1,
              let id = ids.first?.value, UUID(uuidString: id) != nil,
              let token = tokens.first?.value,
              // The server's sha256 helper returns 32 bytes as unpadded
              // base64url (43 characters), not a 64-character hex digest.
              // Retain hex compatibility; actual authorization stays server-side.
              token.range(of: "\\A(?:[A-Za-z0-9_-]{43}|[0-9a-fA-F]{64})\\z", options: .regularExpression) != nil else {
            throw ReceiptError.message("小票凭据缺失或格式不完整，请重新运行截图记账。")
        }
        self.service = service
        self.id = id
        self.token = token
    }
}

public enum TransactionKind: String, Codable, Sendable {
    case expense, income, refund, transfer, unknown
    public var categories: [String] {
        switch self {
        case .expense: return ["餐饮", "购物", "交通", "医疗", "娱乐", "宠物", "人情", "通讯", "订阅", "工作", "旅行", "其他"]
        case .income: return ["工资", "奖金", "红包"]
        case .refund: return ["退款"]
        case .transfer: return ["转账"]
        case .unknown: return []
        }
    }
}

public struct RefundCandidate: Codable, Sendable, Identifiable {
    public var id: String
    public var occurredAt: String
    public var amount: String
    public var remainingAmount: String
    public var merchant: String
    public var product: String
    public var paymentAccount: String
}

public struct RefundMatches: Codable, Sendable {
    public var candidates: [RefundCandidate]
}

public struct ReceiptDraft: Codable, Sendable {
    public var id: String
    public var transactionType: TransactionKind
    public var amount: String
    public var currency: String
    public var category: String
    public var merchant: String
    public var product: String
    public var platform: String
    public var paymentAccount: String
    public var receiptAccount: String
    public var occurredAt: String
    public var budgetIncluded: Bool
    public var budgetMonth: String?
    public var externalOrderReference: String
    public var originalTransactionId: String
    public var requiresManualReview: Bool
    public var refundMatch: RefundMatches?

    public var account: String {
        transactionType == .income || transactionType == .refund ? receiptAccount : paymentAccount
    }

    public func validate() throws {
        guard transactionType != .unknown else {
            throw ReceiptError.message("交易类型尚未识别清楚，请重新截图。")
        }
        guard Self.validAmount(amount) else {
            throw ReceiptError.message("请填写大于零、最多两位小数的金额。")
        }
        guard transactionType.categories.contains(category) else {
            throw ReceiptError.message("请选择分类。")
        }
        guard Self.validDate(occurredAt) else {
            throw ReceiptError.message("请核对日期，格式为 2026-11-13T12:30。")
        }
        if transactionType == .expense, let month = budgetMonth, !month.isEmpty {
            guard Self.validMonth(month) else { throw ReceiptError.message("预算月份格式应为 2026-11。") }
        }
        if transactionType == .refund {
            guard let original = refundMatch?.candidates.first(where: { $0.id == originalTransactionId }),
                  let remaining = Decimal(string: original.remainingAmount, locale: Locale(identifier: "en_US_POSIX")),
                  let refund = Decimal(string: amount, locale: Locale(identifier: "en_US_POSIX")), refund <= remaining else {
                throw ReceiptError.message("请明确选择原订单，并核对可退款余额。")
            }
        }
    }

    public static func validAmount(_ text: String) -> Bool {
        guard text.range(of: "^[0-9]{1,12}(\\.[0-9]{1,2})?$", options: .regularExpression) != nil,
              let value = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")) else { return false }
        return value > 0
    }

    public static func validMonth(_ text: String) -> Bool {
        text.range(of: "^[0-9]{4}-(0[1-9]|1[0-2])$", options: .regularExpression) != nil
    }

    public static func validDate(_ text: String) -> Bool {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "Asia/Shanghai")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm"
        f.isLenient = false
        guard let d = f.date(from: text) else { return false }
        return f.string(from: d) == text
    }
}

public enum ReceiptPhase: String, Sendable { case ready, saving, saved, cancelling, cancelled, uncertain, undoing, undoUncertain }
public enum ReceiptPanel: String, Sendable { case summary, amount, category, account, destination, refunds, more }
public enum ReceiptMotion: String, Sendable { case idle, printing, tearing }
public enum ReceiptMotionTiming {
    public static let feedDuration = 2.4
    public static let feedFrames = 10
    public static let tearDuration = 0.8
}
public enum ReceiptField: String, Sendable { case amount, product, merchant, note, account, destination, date, budgetMonth }

/// Two rows at a time fit the system snippet without an extra keyboard sheet.
public enum ReceiptTextKeyboard {
    private static let groups = ["", "0123456789", "ABCDEFGHIJKL", "MNOPQRSTUVWX", "YZ- "]
    public static func keys(page: Int, order: Bool) -> [String] {
        let index = order && page == 0 ? 1 : min(max(page, 0), groups.count - 1)
        return Array(groups[index]).map(String.init)
    }
    public static func nextPage(page: Int, order: Bool) -> Int {
        let current = order && page == 0 ? 1 : min(max(page, 0), groups.count - 1)
        let next = (current + 1) % groups.count
        return order && next == 0 ? 1 : next
    }
    public static func nextLabel(page: Int, order: Bool) -> String {
        ["常用词", "数字", "A–L", "M–X", "YZ / 符号"][nextPage(page: page, order: order)]
    }
}

public struct ReceiptSnapshot: Sendable {
    public let cardID: String
    public var draft: ReceiptDraft
    public var note: String = ""
    public var phase: ReceiptPhase = .ready
    public var panel: ReceiptPanel = .summary
    public var page: Int = 0
    public var message: String = ""
    public var isDemo: Bool = false
    public var awaitingScreenshot = false
    public var continuousFeed = false
    public var amountInput: String = ""
    public var replaceAmountInput = true
    public var inlineEditor: String? = nil
    public var textInput = ""
    public var characterPage = 0
    public var textSession = ""
    public var keyboardMode: ReceiptKeyboardMode = .pinyin
    public var keyboardAlphabet: ReceiptKeyboardMode = .pinyin
    public var uppercase = false
    public var pinyinInput = ""
    public var candidatePage = 0
    public var completionPending = false
    public var undoRestored = false
    public var undoDeadline: Double? = nil
    public var canUndo: Bool { phase == .undoUncertain || (phase == .saved && motion == .idle && !completionPending && (undoDeadline ?? 0) > Date().timeIntervalSince1970 * 1000) }
    public var pinyinCandidates: [PinyinCandidate] { PinyinEngine.shared.candidates(pinyinInput) }
    public var closedLocalPreview: Bool { phase == .cancelled && awaitingScreenshot }
    public var showsCompletion: Bool { (phase == .saved && !completionPending && motion != .tearing) || phase == .cancelled || phase == .undoUncertain || phase == .undoing }
    public var motion: ReceiptMotion = .idle
    public var paperProgress: Double = 1
    public var locked: Bool { phase != .ready || motion != .idle }
}

public struct ConfirmationPayload: Encodable, Sendable {
    public let id: String
    public let token: String
    public let transactionType: TransactionKind
    public let amount: String
    public let currency: String
    public let category: String
    public let merchant: String
    public let product: String
    public let note: String
    public let userRemark: String
    public let platform: String
    public let paymentAccount: String
    public let receiptAccount: String
    public let occurredAt: String
    public let budgetIncluded: Bool
    public let budgetMonth: String?
    public let externalOrderReference: String
    public let originalTransactionId: String

    public init(snapshot: ReceiptSnapshot, reference: DraftReference) throws {
        let d = snapshot.draft
        try d.validate()
        guard d.id == reference.id else { throw ReceiptError.message("账单凭据不匹配。") }
        id = d.id; token = reference.token; transactionType = d.transactionType
        amount = d.amount; currency = d.currency; category = d.category
        merchant = d.merchant; product = d.product; note = d.product; userRemark = snapshot.note
        platform = d.platform; paymentAccount = d.paymentAccount; receiptAccount = d.receiptAccount
        occurredAt = d.occurredAt; budgetIncluded = d.transactionType == .expense && d.budgetIncluded
        budgetMonth = d.budgetMonth; externalOrderReference = d.externalOrderReference
        originalTransactionId = d.originalTransactionId
    }
}
