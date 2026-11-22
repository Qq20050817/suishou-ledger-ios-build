import Foundation

public struct ReceiptReminder: Decodable, Sendable {
    public let id: String
    public let title: String
    public let amount: String
    public let dueDate: String
    public let remindAt: Double
    public var identifier: String { "ledger.recurring." + id }
    public static func schedule(data: Data, now: Date = Date()) throws -> [ReceiptReminder] {
        guard data.count <= 262144 else { throw ReceiptError.message("提醒数量过多。") }
        let items = try JSONDecoder().decode([ReceiptReminder].self, from: data)
        guard items.count <= 600 else { throw ReceiptError.message("提醒数量过多。") }
        let current = now.timeIntervalSince1970 * 1000
        var seen = Set<String>()
        return items.filter {
            !$0.id.isEmpty && $0.id.count <= 100 && !$0.title.isEmpty && $0.title.count <= 80 &&
            ReceiptDraft.validAmount($0.amount) && ReceiptDraft.validDate($0.dueDate + "T09:00") &&
            $0.remindAt.isFinite && $0.remindAt > current && $0.remindAt <= current + 6 * 366 * 86400000 &&
            seen.insert($0.identifier).inserted
        }.sorted { $0.remindAt < $1.remindAt }.prefix(60).map { $0 }
    }
}
