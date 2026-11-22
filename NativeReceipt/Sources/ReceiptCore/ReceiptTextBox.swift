import Foundation

public struct ReceiptTextBox: Sendable {
    let text: String
    let left: Double
    let top: Double
    let height: Double
    public init(text: String, left: Double, top: Double, height: Double) {
        self.text = text; self.left = left; self.top = top; self.height = height
    }
    private var middle: Double { top + height * 0.5 }

    public static func rows(_ boxes: [Self]) -> String {
        var rows: [[Self]] = []
        for box in boxes.filter({ $0.height > 0 && !$0.text.isEmpty }).sorted(by: { $0.middle < $1.middle }) {
            if let anchor = rows.last?.first,
               abs(anchor.middle - box.middle) <= 0.52 * min(anchor.height, box.height) {
                rows[rows.count - 1].append(box)
            } else { rows.append([box]) }
        }
        return rows.map { row in
            row.sorted(by: { $0.left < $1.left }).map(\.text).joined(separator: " ")
        }.joined(separator: "\n")
    }
}
