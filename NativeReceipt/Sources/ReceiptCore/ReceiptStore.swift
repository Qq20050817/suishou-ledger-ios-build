import Foundation

/// The snippet view is read-only. Explicit button intents own every mutation.
/// Apple keeps the provider alive while its snippet is visible. If it is killed,
/// the card fails closed instead of persisting draft tokens to disk or intent parameters.
public actor ReceiptStore {
    public static let shared = ReceiptStore(client: LedgerClient())
    private struct Entry: Sendable {
        var snapshot: ReceiptSnapshot
        let client: any LedgerServing
        var reference: DraftReference?
        var undoCapability: UndoCapability?
        let createdAt: Date
        var motionID: String?
        var motionDeadline: Date?
        var didTear = false
        var localDraft: ReceiptDraft?
        var reviewLocalConfirmation = false
        var introClaimed = false
    }
    private var entries: [String: Entry] = [:]
    private var screenshotPresentation: (id: String, revision: String, showedPending: Bool)?
    private let client: any LedgerServing
    public init(client: any LedgerServing) { self.client = client }

    public func open(_ url: URL) async throws -> String {
        let reference = try DraftReference(url: url)
        // Reopening an existing draft retains edits and terminal/uncertain states.
        if let old = entries.first(where: { $0.value.reference == reference }) {
            return old.key
        }
        let scopedClient = client.scoped(to: reference.service)
        let draft = try await scopedClient.fetch(reference, order: nil)
        guard draft.transactionType != .unknown else { throw ReceiptError.message("交易类型不明确，请重新截图。") }
        // Recheck after the awaited fetch, in case a second invocation loaded it.
        if let old = entries.first(where: { $0.value.reference == reference }) { return old.key }
        let cardID = UUID().uuidString
        entries[cardID] = Entry(snapshot: ReceiptSnapshot(cardID: cardID, draft: Self.normalize(draft)), client: scopedClient, reference: reference, createdAt: Date())
        prune()
        return cardID
    }

    private static func normalize(_ draft: ReceiptDraft) -> ReceiptDraft {
        var normalized = draft
        if normalized.budgetMonth == nil { normalized.budgetMonth = String(draft.occurredAt.prefix(7)) }
        if !draft.transactionType.categories.contains(draft.category) {
            normalized.category = draft.transactionType == .refund ? "退款" : draft.transactionType == .transfer ? "转账" : ""
        }
        // The server's suggestion is never treated as the user's refund selection.
        if normalized.transactionType == .refund { normalized.originalTransactionId = "" }
        return normalized
    }

    /// A screenshot owns one editable paper from capture to confirmation. A local draft has no write capability.
    public func openScreenshot(_ id: String, preview: ScreenshotReceiptPreview, captured: Date) {
        prune()
        guard entries[id] == nil else { return }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm"
        let date = preview.occurredAt ?? formatter.string(from: captured)
        let receives = preview.transactionType == .income || preview.transactionType == .refund
        let draft = ReceiptDraft(id: "", transactionType: preview.transactionType,
            amount: preview.amount ?? "", currency: "CNY", category: preview.category ?? "",
            merchant: preview.merchant ?? "", product: preview.product ?? "", platform: preview.platform ?? "",
            paymentAccount: receives ? "" : preview.account ?? "", receiptAccount: receives ? preview.account ?? "" : "",
            occurredAt: date, budgetIncluded: preview.transactionType == .expense,
            budgetMonth: String(date.prefix(7)), externalOrderReference: "", originalTransactionId: "",
            requiresManualReview: false)
        var paper = ReceiptSnapshot(cardID: id, draft: draft)
        paper.awaitingScreenshot = true
        entries[id] = Entry(snapshot: paper, client: client.scoped(to: .independent),
                            createdAt: Date(), localDraft: draft)
    }

    public func bindScreenshot(_ id: String, to url: URL) async throws {
        let ref = try DraftReference(url: url)
        guard ref.service == .independent, let entry = entries[id] else { throw ReceiptError.message("这张截图的小票已关闭。") }
        if entry.reference == ref { return }
        guard entry.snapshot.phase == .ready, entry.localDraft != nil else { return }
        let fetched = try await entry.client.fetch(ref, order: nil)
        guard fetched.id == ref.id, fetched.transactionType != .unknown else { throw ReceiptError.message("账本返回的小票资料不完整。") }
        guard var current = entries[id], current.snapshot.phase == .ready, let base = current.localDraft else { return }
        guard !entries.contains(where: { $0.key != id && $0.value.reference == ref }) else {
            throw ReceiptError.message("这张小票已在另一张卡片中打开，请回原卡片核对。")
        }
        let local = current.snapshot.draft
        var remote = Self.normalize(fetched)
        if remote.transactionType == base.transactionType && remote.currency == base.currency {
            // An incomplete recognition reply can supplement a local receipt without blanking visible evidence.
            for field in [\ReceiptDraft.merchant, \.product, \.platform, \.category, \.paymentAccount, \.receiptAccount] where remote[keyPath: field].isEmpty {
                remote[keyPath: field] = base[keyPath: field]
            }
        }
        for field in [\ReceiptDraft.amount, \.merchant, \.product, \.occurredAt] where local[keyPath: field] != base[keyPath: field] {
            remote[keyPath: field] = local[keyPath: field]
        }
        if remote.transactionType == base.transactionType {
            for field in [\ReceiptDraft.category, \.paymentAccount, \.receiptAccount] where local[keyPath: field] != base[keyPath: field] {
                remote[keyPath: field] = local[keyPath: field]
            }
            if local.budgetIncluded != base.budgetIncluded { remote.budgetIncluded = local.budgetIncluded }
            if local.budgetMonth != base.budgetMonth { remote.budgetMonth = local.budgetMonth }
        }
        // A tap on an older rendering must not authorize a changed amount, type, account or date.
        current.reviewLocalConfirmation = fetched.requiresManualReview || remote.transactionType != local.transactionType ||
            remote.currency != local.currency || Decimal(string: remote.amount) != Decimal(string: local.amount) ||
            remote.merchant != local.merchant || remote.product != local.product || remote.category != local.category ||
            remote.account != local.account || remote.receiptAccount != local.receiptAccount ||
            remote.occurredAt != local.occurredAt || remote.budgetMonth != local.budgetMonth ||
            remote.budgetIncluded != local.budgetIncluded
        current.snapshot.draft = remote
        current.snapshot.awaitingScreenshot = false
        current.snapshot.message = ""
        current.reference = ref
        current.localDraft = nil
        entries[id] = current
    }

    public func screenshotStatus(_ id: String, _ text: String) {
        guard entries[id]?.snapshot.awaitingScreenshot == true, entries[id]?.snapshot.phase == .ready else { return }
        entries[id]?.snapshot.message = text
    }

    /// Only an explicit Continue may open a separate live draft after the local preview was closed.
    /// Old buttons stay attached to the closed card. Opening a draft only reads it.
    public func resumeClosedScreenshot(_ id: String, lookup: @Sendable () async throws -> URL) async throws -> String? {
        guard (try? snapshot(id))?.closedLocalPreview == true, entries[id]?.reference == nil else { return nil }
        let url = try await lookup()
        guard try DraftReference(url: url).service == .independent else {
            throw ReceiptError.message("请在独立账本核对这张小票。")
        }
        return try await open(url)
    }

    public func demo() throws -> String {
        let json = #"{"id":"00000000-0000-4000-8000-000000000001","transactionType":"expense","amount":"23.00","currency":"CNY","category":"餐饮","merchant":"街角便利店","product":"零食与饮品","platform":"支付宝","paymentAccount":"支付宝余额","receiptAccount":"","occurredAt":"2026-11-13T21:06","budgetIncluded":true,"budgetMonth":"2026-11","externalOrderReference":"","originalTransactionId":"","requiresManualReview":false}"#
        let draft = try JSONDecoder().decode(ReceiptDraft.self, from: Data(json.utf8))
        let id = UUID().uuidString
        var snapshot = ReceiptSnapshot(cardID: id, draft: draft)
        snapshot.isDemo = true
        entries[id] = Entry(snapshot: snapshot, client: client, reference: nil, createdAt: Date())
        prune()
        return id
    }

    public func snapshot(_ id: String) throws -> ReceiptSnapshot {
        guard let entry = entries[id], Date().timeIntervalSince(entry.createdAt) < 3600 else {
            throw ReceiptError.message("这张小票已关闭或过期，请重新运行截图记账。")
        }
        var snapshot = entry.snapshot
        if let deadline = entry.motionDeadline, Date() > deadline, snapshot.motion != .idle || snapshot.completionPending {
            // Rendering remains read-only; a suspended animation must never trap
            // the person on a blank or disabled card.
            snapshot.motion = .idle; snapshot.paperProgress = 1; snapshot.completionPending = false
        }
        return snapshot
    }

    public func panel(_ id: String, _ panel: ReceiptPanel, page: Int = 0) throws {
        try change(id) { s in
            if panel != .summary {
                if (s.panel == .amount && panel != .amount) ||
                    (s.inlineEditor.map { !["date", "budgetMonth"].contains($0) } ?? false) {
                    s.message = "请先完成或放弃当前修改"; return
                }
            }
            if panel == .amount, s.panel != .amount {
                s.amountInput = s.draft.amount; s.replaceAmountInput = true
            }
            s.inlineEditor = nil; s.textInput = ""
            s.panel = panel; s.page = max(0, page); s.message = ""
        }
    }

    /// Commit a choice and collapse its editor inside the same receipt.
    public func chooseInline(_ id: String, panel: ReceiptPanel, value: String) throws {
        try change(id) { s in
            switch panel {
            case .category:
                guard s.draft.transactionType.categories.contains(value) else { throw ReceiptError.message("分类无效。") }
                s.draft.category = value
            case .account:
                guard !value.isEmpty, value.count <= 100 else { return }
                if s.draft.transactionType == .income || s.draft.transactionType == .refund { s.draft.receiptAccount = value }
                else { s.draft.paymentAccount = value }
            case .destination:
                guard !value.isEmpty, value.count <= 100 else { return }
                s.draft.receiptAccount = value
            case .refunds:
                guard s.draft.refundMatch?.candidates.contains(where: { $0.id == value }) == true else { return }
                s.draft.originalTransactionId = value
            default: return
            }
            if s.panel == panel { s.panel = .summary }
            s.message = ""
        }
    }

    public func setNote(_ id: String, value: String) throws {
        try change(id) { s in
            guard value.count <= 300 else { return }
            s.note = value; s.message = ""
            if s.inlineEditor == "note" { s.inlineEditor = nil; s.textInput = "" }
        }
    }

    public func adjustDate(_ id: String, component: String, offset: Int) throws {
        guard [-1, 1].contains(offset) else { throw ReceiptError.message("日期调整无效。") }
        try change(id) { s in
            let units: [String: Calendar.Component] = ["year": .year, "month": .month, "day": .day, "hour": .hour, "minute": .minute, "budget": .month]
            guard let unit = units[component] else { return }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
            formatter.dateFormat = component == "budget" ? "yyyy-MM-dd" : "yyyy-MM-dd'T'HH:mm"
            formatter.isLenient = false
            let raw = component == "budget" ? (s.draft.budgetMonth ?? String(s.draft.occurredAt.prefix(7))) + "-01" : s.draft.occurredAt
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = formatter.timeZone
            guard let date = formatter.date(from: raw), let updated = calendar.date(byAdding: unit, value: offset, to: date) else { return }
            let value = formatter.string(from: updated)
            if component == "budget" { s.draft.budgetMonth = String(value.prefix(7)) }
            else if ReceiptDraft.validDate(value) { s.draft.occurredAt = value }
            s.message = ""
        }
    }

    /// The host supports intent-backed buttons, not a free-form TextField/IME.
    /// Preserve buffered editing using custom Pinyin/character buttons; no requestValue.
    public func textAction(_ id: String, operation: String, value: String = "") async throws {
        if operation == "done" {
            let s = try snapshot(id)
            guard let editor = s.inlineEditor, editor != "date" else { return }
            guard s.pinyinInput.isEmpty else {
                try change(id) { $0.message = "请先选择中文候选词，或清除拼音" }; return
            }
            do {
                if editor == "order" { try await lookupOrder(id, query: s.textInput) }
                else if let field = ReceiptField(rawValue: editor) { try edit(id, field: field, value: s.textInput) }
                try change(id) { $0.inlineEditor = nil; $0.textInput = ""; $0.pinyinInput = ""; $0.textSession = ""; $0.panel = editor == "order" ? .refunds : .summary }
            } catch {
                try change(id) { $0.message = error.localizedDescription }
            }
            return
        }
        try change(id) { s in
            switch operation {
            case "open":
                guard ReceiptField(rawValue: value) != nil || value == "order" else { return }
                if s.inlineEditor == value { s.inlineEditor = nil; s.textInput = ""; s.pinyinInput = ""; s.textSession = ""; s.message = ""; return }
                if s.panel == .amount ||
                    (s.inlineEditor.map { !["date", "budgetMonth"].contains($0) } ?? false) {
                    s.message = "请先完成或放弃当前修改"; return
                }
                s.panel = .summary; s.amountInput = ""
                s.inlineEditor = value; s.characterPage = 0; s.message = ""
                s.textSession = UUID().uuidString; s.pinyinInput = ""; s.candidatePage = 0; s.uppercase = false
                s.keyboardMode = value == "order" ? .numbers : .pinyin
                s.keyboardAlphabet = value == "order" ? .english : .pinyin
                switch value {
                case "product": s.textInput = s.draft.product
                case "merchant": s.textInput = s.draft.merchant
                case "note": s.textInput = s.note
                case "account": s.textInput = s.draft.account
                case "destination": s.textInput = s.draft.receiptAccount
                default: s.textInput = ""
                }
            case "cancel": s.inlineEditor = nil; s.textInput = ""; s.pinyinInput = ""; s.textSession = ""; s.message = ""
            case "clear": s.textInput = ""; s.pinyinInput = ""; s.candidatePage = 0
            case "backspace": s.textInput = String(s.textInput.dropLast())
            case "characters":
                guard s.inlineEditor != nil else { return }
                s.characterPage = ReceiptTextKeyboard.nextPage(page: s.characterPage, order: s.inlineEditor == "order")
            case "key", "phrase":
                guard s.inlineEditor != nil, s.inlineEditor != "date" else { return }
                guard s.textInput.count + value.count <= (s.inlineEditor == "note" ? 300 : 100) else { s.message = "内容已达到长度上限"; return }
                if operation == "key" {
                    guard value.count == 1, "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789 -_./@".contains(value) else { return }
                }
                s.textInput += value
            default: return
            }
        }
    }

    public func keyboardAction(_ id: String, session: String, operation: String, value: String = "") throws {
        try change(id) { s in
            guard s.textSession == session, !session.isEmpty,
                  let field = s.inlineEditor, !["date", "budgetMonth"].contains(field) else { return }
            s.message = ""
            switch operation {
            case "key":
                if s.keyboardMode == .pinyin {
                    guard value.count == 1, "abcdefghijklmnopqrstuvwxyz'".contains(value) else { return }
                    guard s.pinyinInput.count < 48 else { s.message = "请先选字，再继续输入"; return }
                    if value == "'", s.pinyinInput.isEmpty || s.pinyinInput.hasSuffix("'") { return }
                    s.pinyinInput += value; s.candidatePage = 0
                } else {
                    guard value.count == 1, "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-/:;()¥&@\"，。？！'._+%#*!?".contains(value) else { return }
                    Self.appendText(value, to: &s)
                }
            case "backspace":
                if !s.pinyinInput.isEmpty { s.pinyinInput.removeLast(); s.candidatePage = 0 }
                else { s.textInput = String(s.textInput.dropLast()) }
            case "clear": s.textInput = ""; s.pinyinInput = ""; s.candidatePage = 0
            case "clearComposition": s.pinyinInput = ""; s.candidatePage = 0
            case "space":
                if s.pinyinInput.isEmpty { Self.appendText(" ", to: &s) }
                else if let first = s.pinyinCandidates.first { Self.acceptCandidate(first, in: &s) }
                else { s.message = "未找到候选词，请检查拼音" }
            case "mode":
                guard s.pinyinInput.isEmpty else { s.message = "请先选字，或点 × 清除拼音"; return }
                let mode: ReceiptKeyboardMode?
                if value == "numbers" { mode = s.keyboardMode == .numbers ? s.keyboardAlphabet : .numbers }
                else if value == "toggle" { mode = s.keyboardMode == .pinyin ? .english : .pinyin }
                else { mode = ReceiptKeyboardMode(rawValue: value) }
                if let mode { s.keyboardMode = mode; if mode != .numbers { s.keyboardAlphabet = mode } }
            case "shift": s.uppercase.toggle()
            case "page":
                guard let offset = Int(value), [-1, 1].contains(offset) else { return }
                s.candidatePage = min(max(0, s.candidatePage + offset), max(0, (s.pinyinCandidates.count - 1) / 3))
            default: return
            }
        }
    }

    public func choosePinyin(_ id: String, session: String, composition: String, text: String, consumed: Int) throws {
        try change(id) { s in
            guard s.textSession == session, !session.isEmpty, s.inlineEditor != nil,
                  s.pinyinInput == composition,
                  let candidate = s.pinyinCandidates.first(where: { $0.text == text && $0.consumed == consumed }) else { return }
            s.message = ""; Self.acceptCandidate(candidate, in: &s)
        }
    }

    private static func appendText(_ value: String, to s: inout ReceiptSnapshot) {
        guard s.textInput.count + value.count <= (s.inlineEditor == "note" ? 300 : 100) else {
            s.message = "内容已达到长度上限"; return
        }
        s.textInput += value
    }

    private static func acceptCandidate(_ candidate: PinyinCandidate, in s: inout ReceiptSnapshot) {
        let before = s.textInput.count
        appendText(candidate.text, to: &s)
        if s.textInput.count > before {
            s.pinyinInput = String(s.pinyinInput.dropFirst(candidate.consumed)); s.candidatePage = 0
        }
    }

    /// Each key is a fully parameterized button intent, never a requestValue prompt.
    /// Edits stay in a separate buffer until Done, and never make an API request.
    public func amountKey(_ id: String, key: String) throws {
        try change(id) { s in
            guard s.panel == .amount else { return } // Ignore a delayed key after Done.
            s.message = ""
            switch key {
            case "cancel": s.panel = .summary; s.amountInput = ""; return
            case "done":
                let input = s.amountInput.hasSuffix(".") ? String(s.amountInput.dropLast()) : s.amountInput
                guard ReceiptDraft.validAmount(input) else {
                    s.message = "请输入大于 0 的金额"; return
                }
                let parts = input.split(separator: ".", omittingEmptySubsequences: false)
                let cents = parts.count == 2 ? String(parts[1]) : ""
                s.draft.amount = String(parts[0]) + "." + cents.padding(toLength: 2, withPad: "0", startingAt: 0)
                s.panel = .summary; s.amountInput = ""; return
            case "clear": s.amountInput = "0"; s.replaceAmountInput = true; return
            case "backspace":
                s.replaceAmountInput = false
                s.amountInput = String(s.amountInput.dropLast())
                if s.amountInput.isEmpty { s.amountInput = "0" }
                return
            case ".":
                if s.replaceAmountInput { s.amountInput = "0"; s.replaceAmountInput = false }
                if !s.amountInput.contains(".") { s.amountInput += "." }
                return
            default:
                guard key.count == 1, "0123456789".contains(key) else { throw ReceiptError.message("金额按键无效。") }
                if s.replaceAmountInput { s.amountInput = ""; s.replaceAmountInput = false }
                let parts = s.amountInput.split(separator: ".", omittingEmptySubsequences: false)
                if parts.count == 2, parts[1].count >= 2 { return }
                if !s.amountInput.contains("."), s.amountInput.count >= 12 { return }
                if s.amountInput == "0" { s.amountInput = "" }
                s.amountInput += key
            }
        }
    }

    /// Motion is cosmetic and generation-scoped; repeated rendering never starts it.
    public func beginMotion(_ id: String, _ motion: ReceiptMotion) throws -> String? {
        let s = try snapshot(id)
        guard s.motion == .idle else { return nil }
        if motion == .printing {
            guard s.phase == .ready, s.panel == .summary, s.inlineEditor == nil else { return nil }
        } else if motion == .tearing {
            guard s.phase == .saved, entries[id]?.didTear == false else { return nil }
            entries[id]?.didTear = true
        } else { return nil }
        let generation = UUID().uuidString
        entries[id]?.motionID = generation
        entries[id]?.motionDeadline = Date().addingTimeInterval(5)
        entries[id]?.snapshot.continuousFeed = false
        entries[id]?.snapshot.motion = motion
        entries[id]?.snapshot.paperProgress = 0
        return generation
    }

    /// Arm only an explicit user presentation. Re-rendering the same revision cannot replay the sound.
    public func prepareScreenshotFeed(_ id: String) throws -> String? {
        screenshotPresentation = nil
        if let entry = entries[id], entry.snapshot.continuousFeed, !entry.introClaimed,
           try snapshot(id).motion == .printing { return entry.motionID }
        guard let generation = try beginMotion(id, .printing) else { return nil }
        entries[id]?.introClaimed = false
        entries[id]?.snapshot.continuousFeed = true
        return generation
    }

    public func claimScreenshotFeed(_ id: String, generation: String) -> Bool {
        guard let entry = entries[id], entry.motionID == generation, entry.snapshot.continuousFeed,
              !entry.introClaimed, (try? snapshot(id).motion) == .printing else { return false }
        entries[id]?.introClaimed = true
        return true
    }

    public func openScreenshotSnippet(_ id: String) throws -> String {
        let revision = try prepareScreenshotFeed(id) ?? UUID().uuidString
        screenshotPresentation = (id, revision, false)
        return revision
    }

    /// Capture the pending frame and its subscription together so a fast reply cannot slip between them.
    public func screenshotSnippetFrame(_ id: String, revision: String) throws -> ReceiptSnapshot {
        let frame = try snapshot(id)
        if screenshotPresentation?.id == id, screenshotPresentation?.revision == revision {
            screenshotPresentation?.showedPending = frame.awaitingScreenshot && frame.phase == .ready
        }
        return frame
    }

    /// Only the retained pending snippet may refresh when its draft is hydrated. Upload progress never claims this.
    public func takeHydratedSnippetRefresh(_ id: String) -> Bool {
        guard let presentation = screenshotPresentation, presentation.id == id, presentation.showedPending,
              let entry = entries[id], entry.snapshot.phase == .ready,
              entry.reference != nil, !entry.snapshot.awaitingScreenshot else { return false }
        screenshotPresentation = nil
        return true
    }

    @discardableResult public func advanceMotion(_ id: String, generation: String, progress: Double, completing: Bool = true) throws -> Bool {
        let s = try snapshot(id)
        guard entries[id]?.motionID == generation, s.motion != .idle else { return false }
        guard progress.isFinite, progress >= s.paperProgress else { return false }
        entries[id]?.snapshot.paperProgress = min(1, max(0, progress))
        if progress >= 1 && completing {
            entries[id]?.snapshot.motion = .idle
            entries[id]?.snapshot.completionPending = false
            entries[id]?.motionID = nil
            entries[id]?.motionDeadline = nil
        }
        return true
    }

    public func edit(_ id: String, field: ReceiptField, value: String) throws {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count <= (field == .note ? 300 : 100) else { throw ReceiptError.message("内容太长，请简短填写。") }
        if field == .amount, !ReceiptDraft.validAmount(value) { throw ReceiptError.message("金额需要大于零，最多两位小数。") }
        if field == .date, !ReceiptDraft.validDate(value) { throw ReceiptError.message("日期格式应为 2026-11-13T12:30。") }
        if field == .budgetMonth, !ReceiptDraft.validMonth(value) { throw ReceiptError.message("预算月份格式应为 2026-11。") }
        try change(id) { s in
            switch field {
            case .amount: s.draft.amount = value
            case .product: s.draft.product = value
            case .merchant: s.draft.merchant = value
            case .note: s.note = value
            case .account:
                if s.draft.transactionType == .income || s.draft.transactionType == .refund { s.draft.receiptAccount = value }
                else { s.draft.paymentAccount = value }
            case .destination: s.draft.receiptAccount = value
            case .date: s.draft.occurredAt = value
            case .budgetMonth: s.draft.budgetMonth = value
            }
            s.message = ""; s.panel = .summary
        }
    }

    public func choose(_ id: String, value: String) throws {
        try change(id) { s in
            switch s.panel {
            case .category:
                guard s.draft.transactionType.categories.contains(value) else { throw ReceiptError.message("分类无效。") }
                s.draft.category = value
            case .account:
                if s.draft.transactionType == .income || s.draft.transactionType == .refund { s.draft.receiptAccount = value }
                else { s.draft.paymentAccount = value }
            case .destination: s.draft.receiptAccount = value
            case .refunds:
                guard s.draft.refundMatch?.candidates.contains(where: { $0.id == value }) == true else {
                    throw ReceiptError.message("原订单不在当前候选列表中。")
                }
                s.draft.originalTransactionId = value
            default: return
            }
            s.panel = .summary; s.message = ""
        }
    }

    public func toggleBudget(_ id: String) throws {
        try change(id) { s in
            guard s.draft.transactionType == .expense else { return }
            s.draft.budgetIncluded.toggle()
        }
    }

    public func lookupOrder(_ id: String, query: String) async throws {
        let current = try snapshot(id)
        guard !current.locked, current.draft.transactionType == .refund,
              query.range(of: "^[A-Za-z0-9-]{4,80}$", options: .regularExpression) != nil,
              let entry = entries[id], let reference = entry.reference else { throw ReceiptError.message("请输入完整订单号或后四位。") }
        let result = try await entry.client.fetch(reference, order: query)
        // Preserve all edits and recheck the write lock after the network await.
        try change(id) { s in
            s.draft.refundMatch = result.refundMatch
            s.draft.originalTransactionId = ""
            s.panel = .refunds; s.page = 0
            s.message = result.refundMatch?.candidates.isEmpty == false ? "" : "没有找到匹配的原订单。"
        }
    }

    public func confirm(_ id: String, prepareTear: Bool = false, fromLocalPaper: Bool = false, matching preview: ScreenshotReceiptPreview? = nil, onSaving: @Sendable () async -> Void = {}) async throws {
        var s = try snapshot(id)
        guard !s.locked else { return }
        if s.awaitingScreenshot {
            screenshotStatus(id, "账本还未返回草稿，你的修改已保留在这张小票上。")
            return
        }
        if fromLocalPaper, entries[id]?.reviewLocalConfirmation == true {
            try change(id) { $0.message = "账本补全了小票，请核对后确认。" }
            return
        }
        if let preview, !preview.matches(s.draft) {
            try change(id) { $0.message = "完整小票已取回，请核对后确认。" }
            return
        }
        guard s.panel != .amount, s.inlineEditor == nil else {
            try change(id) { $0.message = "请先完成当前修改" }; return
        }
        do { try s.draft.validate() }
        catch { try change(id) { $0.message = error.localizedDescription; $0.panel = .summary }; return }
        guard let entry = entries[id] else { throw ReceiptError.message("小票已关闭。") }
        let payload = try entry.reference.map { try ConfirmationPayload(snapshot: s, reference: $0) }
        s.phase = .saving; s.panel = .summary; s.message = ""; s.undoRestored = false
        entries[id]?.snapshot = s // Set before any await: a second confirmation cannot write.
        await onSaving()
        do {
            if let payload {
                let grant = try await entry.client.confirmWithUndo(payload)
                entries[id]?.undoCapability = grant
                entries[id]?.snapshot.undoDeadline = grant?.expiresAt
            }
            else if !s.isDemo { throw ReceiptError.message("账单凭据已失效。") }
            if s.isDemo { entries[id]?.snapshot.undoDeadline = Date().addingTimeInterval(30).timeIntervalSince1970 * 1000 }
            entries[id]?.snapshot.phase = .saved
            entries[id]?.snapshot.completionPending = prepareTear
            if prepareTear { entries[id]?.motionDeadline = Date().addingTimeInterval(5) }
        } catch ReceiptError.rejected(let message) {
            entries[id]?.snapshot.phase = .ready
            entries[id]?.snapshot.message = message
        } catch {
            // A network failure can occur AFTER the server commits. Do not auto-retry,
            // show a success animation, or offer a second write with an uncertain outcome.
            entries[id]?.snapshot.phase = .uncertain
            entries[id]?.snapshot.message = "保存结果暂未确认，请先核对账本，避免重复记账。"
        }
    }

    public func undo(_ id: String) async throws {
        let s = try snapshot(id)
        guard s.canUndo else {
            if s.phase == .saved, s.motion == .idle {
                entries[id]?.snapshot.undoDeadline = nil
                entries[id]?.snapshot.message = "快速撤销已过期，可以到流水修改"
            }
            return
        }
        entries[id]?.snapshot.phase = .undoing
        do {
            if !s.isDemo {
                guard let entry = entries[id], let grant = entry.undoCapability else { throw ReceiptError.rejected("撤销凭据已失效。") }
                let reference = try await entry.client.undo(grant)
                guard reference.service == entry.reference?.service else { throw ReceiptError.message("撤销凭据的账本不一致。") }
                entries[id]?.reference = reference
                entries[id]?.snapshot.draft.id = reference.id
            }
            entries[id]?.snapshot.phase = .ready
            entries[id]?.snapshot.undoDeadline = nil
            entries[id]?.snapshot.message = ""
            entries[id]?.snapshot.undoRestored = true
            entries[id]?.snapshot.motion = .idle
            entries[id]?.snapshot.completionPending = false
            entries[id]?.didTear = false
            entries[id]?.undoCapability = nil
        } catch ReceiptError.rejected(let message) {
            entries[id]?.snapshot.phase = .saved
            entries[id]?.snapshot.undoDeadline = nil
            entries[id]?.snapshot.message = message
        } catch {
            entries[id]?.snapshot.phase = .undoUncertain
            entries[id]?.snapshot.message = "撤销结果待核对，请点下方按钮再次核对"
        }
    }

    public func cancel(_ id: String) async throws {
        let s = try snapshot(id)
        guard !s.locked else { return }
        entries[id]?.snapshot.phase = .cancelling
        do {
            if let entry = entries[id], let reference = entry.reference { try await entry.client.cancel(reference) }
            entries[id]?.snapshot.phase = .cancelled
        } catch {
            entries[id]?.snapshot.phase = .ready
            entries[id]?.snapshot.message = "取消请求未完成，可以关闭卡片；关闭不会自动入账。"
        }
    }

    private func change(_ id: String, _ update: (inout ReceiptSnapshot) throws -> Void) throws {
        var s = try snapshot(id)
        guard !s.locked else { throw ReceiptError.message("这张小票正在处理或已经结束。") }
        try update(&s)
        entries[id]?.snapshot = s
    }

    private func prune() {
        entries = entries.filter { Date().timeIntervalSince($0.value.createdAt) < 3600 }
        // Never evict an active request; tokens otherwise live only in process memory.
    }
}
