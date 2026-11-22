import AppIntents
import SwiftUI
import ReceiptCore

/// Reads a server capability as data; it does not navigate to the supplied URL.
struct ReviewReceiptIntent: AppIntent {
    static let title: LocalizedStringResource = "核对识别结果"
    static let description = IntentDescription("在快捷指令的原生小票卡片中核对并确认，不打开网页或 App 页面。")
    static var openAppWhenRun: Bool { false }
    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresAuthentication }
    @Parameter(title: "识别结果地址") var resultURL: URL

    func perform() async throws -> some IntentResult & ShowsSnippetIntent {
        let id = try await ReceiptStore.shared.open(resultURL)
        await ReceiptMotionDriver.start(id, motion: .printing)
        return .result(snippetIntent: ReceiptSnippetIntent(cardID: id))
    }
}

struct PreviewReceiptIntent: AppIntent {
    static let title: LocalizedStringResource = "预览互动小票"
    static let description = IntentDescription("体验原生小票的选择和确认动效，不联网、不写入账本。")
    static var openAppWhenRun: Bool { false }
    func perform() async throws -> some IntentResult & ShowsSnippetIntent {
        let id = try await ReceiptStore.shared.demo()
        await ReceiptMotionDriver.start(id, motion: .printing)
        return .result(snippetIntent: ReceiptSnippetIntent(cardID: id))
    }
}

struct ReceiptSnippetIntent: SnippetIntent {
    static let title: LocalizedStringResource = "随手账小票"
    static var openAppWhenRun: Bool { false }
    @Parameter(title: "卡片") var cardID: String
    @Parameter(title: "显示版本", default: "initial") var revision: String
    init() {}
    init(cardID: String, revision: String = "initial") { self.cardID = cardID; self.revision = revision }

    static func openScreenshot(_ id: String) async throws -> Self {
        return Self(cardID: id, revision: try await ReceiptStore.shared.openScreenshotSnippet(id))
    }

    func perform() async throws -> some IntentResult & ShowsSnippetView {
        if revision != "initial" {
            await ReceiptMotionDriver.presentScreenshot(cardID, generation: revision)
        }
        return .result(view: ReceiptSnippetView(snapshot: try? await ReceiptStore.shared.screenshotSnippetFrame(cardID, revision: revision)))
    }
}

struct ReceiptPanelIntent: AppIntent {
    static let title: LocalizedStringResource = "选择小票信息"
    static var isDiscoverable: Bool { false }
    static var openAppWhenRun: Bool { false }
    @Parameter(title: "卡片") var cardID: String
    @Parameter(title: "选项") var panel: String
    @Parameter(title: "页码") var page: Int
    init() {}
    init(_ id: String, _ panel: ReceiptPanel, page: Int = 0) { cardID = id; self.panel = panel.rawValue; self.page = page }
    func perform() async throws -> some IntentResult {
        guard let panel = ReceiptPanel(rawValue: panel) else { throw ReceiptError.message("选项无效。") }
        try await ReceiptStore.shared.panel(cardID, panel, page: page)
        return .result()
    }
}

struct ReceiptChoiceIntent: AppIntent {
    static let title: LocalizedStringResource = "使用小票选项"
    static var isDiscoverable: Bool { false }
    static var openAppWhenRun: Bool { false }
    @Parameter(title: "卡片") var cardID: String
    @Parameter(title: "内容") var value: String
    init() {}
    init(_ id: String, _ value: String) { cardID = id; self.value = value }
    func perform() async throws -> some IntentResult {
        try await ReceiptStore.shared.choose(cardID, value: value)
        return .result()
    }
}

struct ReceiptEditIntent: AppIntent {
    static let title: LocalizedStringResource = "修改小票内容"
    static var isDiscoverable: Bool { false }
    static var openAppWhenRun: Bool { false }
    @Parameter(title: "卡片") var cardID: String
    @Parameter(title: "字段") var field: String
    @Parameter(title: "新内容") var value: String?
    init() {}
    init(_ id: String, _ field: ReceiptField) { cardID = id; self.field = field.rawValue }
    func perform() async throws -> some IntentResult {
        guard let field = ReceiptField(rawValue: field) else { throw ReceiptError.message("字段无效。") }
        if field == .amount, value == nil {
            // Retain compatibility with any previously rendered amount button.
            try await ReceiptStore.shared.panel(cardID, .amount)
            return .result()
        }
        if let value { try await ReceiptStore.shared.edit(cardID, field: field, value: value) }
        else { try await ReceiptStore.shared.textAction(cardID, operation: "open", value: field == .budgetMonth ? "date" : field.rawValue) }
        return .result()
    }
}

struct ReceiptBudgetIntent: AppIntent {
    static let title: LocalizedStringResource = "切换计入预算"
    static var isDiscoverable: Bool { false }
    static var openAppWhenRun: Bool { false }
    @Parameter(title: "卡片") var cardID: String
    init() {}
    init(_ id: String) { cardID = id }
    func perform() async throws -> some IntentResult {
        try await ReceiptStore.shared.toggleBudget(cardID)
        return .result()
    }
}

struct ReceiptOrderIntent: AppIntent {
    static let title: LocalizedStringResource = "查找退款原订单"
    static var isDiscoverable: Bool { false }
    static var openAppWhenRun: Bool { false }
    @Parameter(title: "卡片") var cardID: String
    @Parameter(title: "完整订单号或后四位") var order: String?
    init() {}
    init(_ id: String) { cardID = id }
    func perform() async throws -> some IntentResult {
        if let order { try await ReceiptStore.shared.lookupOrder(cardID, query: order) }
        else { try await ReceiptStore.shared.textAction(cardID, operation: "open", value: "order") }
        return .result()
    }
}

struct ReceiptConfirmIntent: AppIntent {
    static let title: LocalizedStringResource = "确认入账"
    static var isDiscoverable: Bool { false }
    static var openAppWhenRun: Bool { false }
    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresAuthentication }
    @Parameter(title: "卡片") var cardID: String
    @Parameter(title: "应用内显示", default: false) var inApp: Bool
    @Parameter(title: "从本机小票确认", default: false) var fromLocalPaper: Bool
    init() {}
    init(_ id: String, inApp: Bool = false, fromLocalPaper: Bool = false) {
        cardID = id; self.inApp = inApp; self.fromLocalPaper = fromLocalPaper
    }
    func perform() async throws -> some IntentResult {
        if fromLocalPaper, try await ReceiptStore.shared.snapshot(cardID).awaitingScreenshot {
            let state = try await ScreenshotInbox.session.review(cardID)
            if state.card == nil {
                await ReceiptStore.shared.screenshotStatus(cardID, state.message)
                return .result()
            }
        }
        let refresh = ReceiptMotionDriver.refresh(inApp: inApp)
        try await ReceiptStore.shared.confirm(cardID, prepareTear: true, fromLocalPaper: fromLocalPaper, onSaving: refresh)
        // Save acknowledgement and pending tear are atomic. The same retained
        // snippet refreshes once when this button finishes; never present a new one.
        await ReceiptMotionDriver.start(cardID, motion: .tearing, refresh: refresh)
        return .result()
    }
}

struct ReceiptAmountKeyIntent: AppIntent {
    static let title: LocalizedStringResource = "小票金额按键"
    static var isDiscoverable: Bool { false }
    static var openAppWhenRun: Bool { false }
    @Parameter(title: "卡片") var cardID: String
    @Parameter(title: "按键") var key: String
    init() {}
    init(_ id: String, _ key: String) { cardID = id; self.key = key }
    func perform() async throws -> some IntentResult {
        try await ReceiptStore.shared.amountKey(cardID, key: key)
        return .result()
    }
}

struct ReceiptPrintIntent: AppIntent {
    static let title: LocalizedStringResource = "重播小票出纸"
    static var isDiscoverable: Bool { false }
    static var openAppWhenRun: Bool { false }
    @Parameter(title: "卡片") var cardID: String
    @Parameter(title: "应用内显示", default: false) var inApp: Bool
    init() {}
    init(_ id: String, inApp: Bool = false) { cardID = id; self.inApp = inApp }
    func perform() async throws -> some IntentResult {
        await ReceiptMotionDriver.start(cardID, motion: .printing, refresh: ReceiptMotionDriver.refresh(inApp: inApp))
        return .result()
    }
}

struct ReceiptCancelIntent: AppIntent {
    static let title: LocalizedStringResource = "取消这张小票"
    static var isDiscoverable: Bool { false }
    static var openAppWhenRun: Bool { false }
    @Parameter(title: "卡片") var cardID: String
    init() {}
    init(_ id: String) { cardID = id }
    func perform() async throws -> some IntentResult {
        try await ReceiptStore.shared.cancel(cardID)
        return .result()
    }
}


struct ReceiptInlineChoiceIntent: AppIntent {
    static let title: LocalizedStringResource = "选择小票内容"
    static var isDiscoverable: Bool { false }
    static var openAppWhenRun: Bool { false }
    @Parameter(title: "卡片") var cardID: String
    @Parameter(title: "选项") var panel: String
    @Parameter(title: "内容") var value: String
    init() {}
    init(_ id: String, _ panel: ReceiptPanel, _ value: String) { cardID = id; self.panel = panel.rawValue; self.value = value }
    func perform() async throws -> some IntentResult {
        if let panel = ReceiptPanel(rawValue: panel) { try await ReceiptStore.shared.chooseInline(cardID, panel: panel, value: value) }
        return .result()
    }
}

struct ReceiptTextActionIntent: AppIntent {
    static let title: LocalizedStringResource = "在小票内编辑"
    static var isDiscoverable: Bool { false }
    static var openAppWhenRun: Bool { false }
    @Parameter(title: "卡片") var cardID: String
    @Parameter(title: "操作") var operation: String
    @Parameter(title: "内容") var value: String
    init() {}
    init(_ id: String, _ operation: String, _ value: String = "_") { cardID = id; self.operation = operation; self.value = value }
    func perform() async throws -> some IntentResult {
        try await ReceiptStore.shared.textAction(cardID, operation: operation, value: value)
        return .result()
    }
}

struct ReceiptNoteIntent: AppIntent {
    static let title: LocalizedStringResource = "选择备注"
    static var isDiscoverable: Bool { false }
    static var openAppWhenRun: Bool { false }
    @Parameter(title: "卡片") var cardID: String
    @Parameter(title: "备注") var value: String
    init() {}
    init(_ id: String, _ value: String) { cardID = id; self.value = value.isEmpty ? "__clear_note__" : value }
    func perform() async throws -> some IntentResult {
        try await ReceiptStore.shared.setNote(cardID, value: value == "__clear_note__" ? "" : value)
        return .result()
    }
}

struct ReceiptDateAdjustIntent: AppIntent {
    static let title: LocalizedStringResource = "调整小票日期"
    static var isDiscoverable: Bool { false }
    static var openAppWhenRun: Bool { false }
    @Parameter(title: "卡片") var cardID: String
    @Parameter(title: "部分") var component: String
    @Parameter(title: "增减") var offset: Int
    init() {}
    init(_ id: String, _ component: String, _ offset: Int) { cardID = id; self.component = component; self.offset = offset }
    func perform() async throws -> some IntentResult {
        try await ReceiptStore.shared.adjustDate(cardID, component: component, offset: offset)
        return .result()
    }
}

struct ReceiptUndoIntent: AppIntent {
    static let title: LocalizedStringResource = "撤销刚才的记账"
    static var isDiscoverable: Bool { false }
    static var openAppWhenRun: Bool { false }
    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresAuthentication }
    @Parameter(title: "卡片") var cardID: String
    init() {}
    init(_ id: String) { cardID = id }
    func perform() async throws -> some IntentResult {
        try await ReceiptStore.shared.undo(cardID)
        return .result()
    }
}
