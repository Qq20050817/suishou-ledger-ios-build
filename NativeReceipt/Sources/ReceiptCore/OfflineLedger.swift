import Foundation

public struct StandaloneEntry: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let occurredAt: Int64
    public let kind: String
    public let cents: Int64
    public let category: String
    public let merchant: String?
    public let note: String?
    public let included: Bool
    public let budgetMonth: String?
    public let originalID: String?
    public let currency: String
    public let hasReceipt: Bool

    public init(id: String = UUID().uuidString.lowercased(), occurredAt: Int64, kind: String, cents: Int64,
                category: String, merchant: String? = nil, note: String? = nil, included: Bool,
                budgetMonth: String? = nil, originalID: String? = nil, currency: String = "CNY", hasReceipt: Bool = false) {
        self.id = id; self.occurredAt = occurredAt; self.kind = kind; self.cents = cents; self.category = category
        self.merchant = merchant; self.note = note; self.included = included; self.budgetMonth = budgetMonth
        self.originalID = originalID; self.currency = currency; self.hasReceipt = hasReceipt
    }
    public var date: Date { Date(timeIntervalSince1970: Double(occurredAt) / 1000) }
}

public struct StandaloneBudget: Codable, Equatable, Sendable {
    public let month: String
    public let cents: Int64
    public init(month: String, cents: Int64) { self.month = month; self.cents = cents }
}
public struct LedgerSnapshot: Codable, Equatable, Sendable {
    public let version: Int
    public let ledgerID: String
    public let entries: [StandaloneEntry]
    public let budgets: [StandaloneBudget]
    public init(version: Int = 1, ledgerID: String, entries: [StandaloneEntry], budgets: [StandaloneBudget]) {
        self.version = version; self.ledgerID = ledgerID; self.entries = entries; self.budgets = budgets
    }
}
public enum IndependentLedgerError: Error { case differentLedger, unsupportedVersion }

public struct OfflineLedger: Codable, Sendable {
    public private(set) var remote: LedgerSnapshot?
    public private(set) var pending: [StandaloneEntry] = []
    public private(set) var lastSync: Date?
    public init() {}
    public var entries: [StandaloneEntry] {
        let acknowledged = Set((remote?.entries ?? []).map(\.id))
        return ((remote?.entries ?? []) + pending.filter { !acknowledged.contains($0.id) })
            .sorted { ($0.occurredAt,$0.id) > ($1.occurredAt,$1.id) }
    }
    public mutating func record(_ row: StandaloneEntry) { pending.append(row) }
    public func validate(_ snapshot: LedgerSnapshot) throws {
        guard snapshot.version == 1 else { throw IndependentLedgerError.unsupportedVersion }
        if let id = remote?.ledgerID, id != snapshot.ledgerID { throw IndependentLedgerError.differentLedger }
    }
    public mutating func accept(_ snapshot: LedgerSnapshot, acknowledged: Set<String>, now: Date = Date()) throws {
        try validate(snapshot)
        remote = snapshot; lastSync = now
        pending.removeAll { acknowledged.contains($0.id) }
    }
    public func transactions(in month: String) -> [StandaloneEntry] { entries.filter { Self.month(of: $0.date) == month } }
    public func budget(in month: String) -> (limit: Int64?, used: Int64) {
        let limit = remote?.budgets.filter { $0.month <= month }.max { $0.month < $1.month }?.cents
        let all = entries
        let expenses = all.filter { row in
            guard row.kind == "expense", row.included, (row.budgetMonth ?? Self.month(of:row.date)) == month else { return false }
            let c = row.category.precomposedStringWithCompatibilityMapping.filter { !$0.isWhitespace }
            return !["额外支出","预算外支出","额外消费","预算外消费"].contains { c.contains($0) }
        }
        let expenseIDs = Set(expenses.map(\.id))
        let refunds = all.filter { $0.kind == "refund" && $0.originalID.map(expenseIDs.contains) == true }
        return (limit, max(0, expenses.reduce(0) { $0 + $1.cents } - refunds.reduce(0) { $0 + $1.cents }))
    }
    public static func month(of date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let c = calendar.dateComponents([.year,.month], from:date)
        return String(format:"%04d-%02d",c.year ?? 0,c.month ?? 0)
    }
    public static func amount(_ input: String) -> Int64? {
        let value = input.trimmingCharacters(in:.whitespacesAndNewlines)
        guard value.range(of: #"^[0-9]{1,9}(\.[0-9]{1,2})?$"#,options:.regularExpression) != nil else { return nil }
        let parts = value.split(separator:".")
        guard let major = Int64(parts[0]) else { return nil }
        let small = parts.count == 2 ? Int64((String(parts[1]) + "0").prefix(2)) ?? 0 : 0
        let cents = major * 100 + small
        return cents > 0 ? cents : nil
    }
}

public struct OfflineLedgerFile: Sendable {
    public let url: URL
    public init(url:URL) { self.url = url }
    public func load() throws -> OfflineLedger {
        // An unreadable existing ledger must never be replaced with an empty one.
        do { return try JSONDecoder().decode(OfflineLedger.self, from:Data(contentsOf:url)) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError { return OfflineLedger() }
    }
    public func save(_ value: OfflineLedger) throws {
        try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
        #if os(iOS)
        try JSONEncoder().encode(value).write(to:url,options:[.atomic,.completeFileProtection])
        #else
        try JSONEncoder().encode(value).write(to:url,options:.atomic)
        #endif
    }
}
