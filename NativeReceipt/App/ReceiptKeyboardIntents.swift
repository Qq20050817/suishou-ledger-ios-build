import AppIntents
import ReceiptCore

struct ReceiptKeyboardIntent: AppIntent {
    static let title: LocalizedStringResource = "小票键盘输入"
    static var isDiscoverable: Bool { false }
    static var openAppWhenRun: Bool { false }
    @Parameter(title: "卡片") var cardID: String
    @Parameter(title: "编辑会话") var session: String
    @Parameter(title: "操作") var operation: String
    @Parameter(title: "按键") var key: String
    init() {}
    init(_ snapshot: ReceiptSnapshot, _ operation: String, _ key: String = "_") {
        cardID = snapshot.cardID; session = snapshot.textSession; self.operation = operation; self.key = key
    }
    func perform() async throws -> some IntentResult {
        try await ReceiptStore.shared.keyboardAction(cardID, session: session, operation: operation, value: key)
        return .result()
    }
}

struct ReceiptPinyinChoiceIntent: AppIntent {
    static let title: LocalizedStringResource = "输入中文候选词"
    static var isDiscoverable: Bool { false }
    static var openAppWhenRun: Bool { false }
    @Parameter(title: "卡片") var cardID: String
    @Parameter(title: "编辑会话") var session: String
    @Parameter(title: "拼音") var composition: String
    @Parameter(title: "候选词") var text: String
    @Parameter(title: "已用拼音长度") var consumed: Int
    init() {}
    init(_ snapshot: ReceiptSnapshot, _ candidate: PinyinCandidate) {
        cardID = snapshot.cardID; session = snapshot.textSession; composition = snapshot.pinyinInput
        text = candidate.text; consumed = candidate.consumed
    }
    func perform() async throws -> some IntentResult {
        try await ReceiptStore.shared.choosePinyin(cardID, session: session, composition: composition, text: text, consumed: consumed)
        return .result()
    }
}
