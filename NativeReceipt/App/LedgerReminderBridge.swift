import Foundation
import WebKit
import UserNotifications
import ReceiptCore

/// The trusted ledger can synchronize local reminders; no push credential,
/// foreground navigation or automatic financial entry is involved.
@MainActor @objc(LedgerReminderBridge)
final class LedgerReminderBridge: NSObject, WKScriptMessageHandlerWithReply {
    private var syncing = false
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage, replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
        let origin = message.frameInfo.securityOrigin
        let path = message.frameInfo.request.url?.path ?? ""
        guard message.frameInfo.isMainFrame, origin.protocol == "https",
              ["ledger-sync.xiaokai123.de5.net", "ledger.xiaokai123.de5.net", "suishou-ledger-0726.qq2301796536.chatgpt.site"].contains(origin.host),
              origin.port == 0 || origin.port == 443,
              path == "/ledger" || path.hasPrefix("/ledger/"),
              let body = message.body as? [String: Any], let items = body["items"] as? [[String: Any]] else {
            replyHandler(nil, "提醒请求无效"); return
        }
        guard !syncing else { replyHandler(["message": "提醒正在同步，请稍后再试"], nil); return }
        syncing = true
        Task { @MainActor in
            defer { syncing = false }
            do {
                let data = try JSONSerialization.data(withJSONObject: items)
                let schedule = try ReceiptReminder.schedule(data: data)
                let center = UNUserNotificationCenter.current()
                var settings = await center.notificationSettings()
                if settings.authorizationStatus == .notDetermined && body["requestPermission"] as? Bool == true {
                    _ = try await center.requestAuthorization(options: [.alert, .sound])
                    settings = await center.notificationSettings()
                }
                guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
                    replyHandler(["message": "手机通知尚未开启，可在系统设置中允许随手账通知。"], nil); return
                }
                // Replace this app feature's pending schedule only. Keep every
                // other notification intact, including those already delivered.
                let pending = await center.pendingNotificationRequests()
                center.removePendingNotificationRequests(withIdentifiers: pending.filter { $0.identifier.hasPrefix("ledger.recurring.") }.map(\.identifier))
                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
                for item in schedule {
                    let content = UNMutableNotificationContent()
                    content.title = "固定支出提醒 · " + item.title
                    content.body = "预计 \(item.dueDate) 扣款 ¥\(item.amount)。实际扣款后再记账。"
                    content.sound = .default
                    let date = Date(timeIntervalSince1970: item.remindAt / 1000)
                    var components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
                    components.timeZone = calendar.timeZone
                    let request = UNNotificationRequest(identifier: item.identifier, content: content, trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false))
                    try await center.add(request)
                }
                replyHandler(["message": "已同步最近 \(schedule.count) 次手机提醒；打开账本时会继续更新。"], nil)
            } catch {
                replyHandler(["message": "提醒未全部同步，请再次点击开启手机提醒。"], nil)
            }
        }
    }
}
