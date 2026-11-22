import AppIntents
import CryptoKit
import Foundation
import ReceiptCore
import SwiftUI
import UniformTypeIdentifiers

struct ReviewIndependentScreenshotIntent: AppIntent {
    static let title: LocalizedStringResource = "识别并核对独立账本截图"
    static let description = IntentDescription("先把截图保存在本机，再用独立账本识别并核对小票。")
    static var openAppWhenRun: Bool { false }
    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresAuthentication }
    @Parameter(title: "账单截图", supportedContentTypes: [.jpeg]) var screenshot: IntentFile
    @Parameter(title: "截图中的文字", default: "") var extractedText: String

    func perform() async throws -> some IntentResult & ShowsSnippetIntent {
        let jpeg = screenshot.data
        let job = try ScreenshotInbox.save(jpeg, ocr: extractedText)
        try await ScreenshotInbox.begin(job.id, text: extractedText, jpeg: jpeg, fresh: job.fresh)
        return .result(snippetIntent: try await ReceiptSnippetIntent.openScreenshot(job.id))
    }
}

struct ContinueIndependentScreenshotIntent: AppIntent {
    static let title: LocalizedStringResource = "继续上张截图记账"
    static var openAppWhenRun: Bool { false }
    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresAuthentication }
    func perform() async throws -> some IntentResult & ShowsSnippetIntent {
        guard let id = try ScreenshotInbox.latest() else { throw ReceiptError.message("本机没有待核对的截图。") }
        let card = try await ScreenshotInbox.continueReview(id)
        return .result(snippetIntent: try await ReceiptSnippetIntent.openScreenshot(card))
    }
}

/// A button updates the existing paper. It does not return another snippet.
struct ReviewScreenshotPaperIntent: AppIntent {
    static let title: LocalizedStringResource = "核对截图小票"
    static var isDiscoverable: Bool { false }
    static var openAppWhenRun: Bool { false }
    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresAuthentication }
    @Parameter(title: "截图任务") var jobID: String
    @Parameter(title: "确认记账", default: false) var confirm: Bool
    @Parameter(title: "应用内显示", default: false) var inApp: Bool
    init() {}
    init(_ id: String, confirm: Bool = false, inApp: Bool = false) {
        jobID = id; self.confirm = confirm; self.inApp = inApp
    }
    func perform() async throws -> some IntentResult {
        let state = try await ScreenshotInbox.session.review(jobID)
        if confirm, let card = state.card {
            try await ReceiptStore.shared.confirm(card, prepareTear: true, matching: state.preview)
            await ReceiptMotionDriver.start(card, motion: .tearing, refresh: ReceiptMotionDriver.refresh(inApp: inApp))
        }
        return .result()
    }
}

enum ScreenshotInbox {
    static let session = ScreenshotReviewSession()
    struct Payload: Codable {
        let receipt_base64: String
        let receipt_mime_type: String
        let extracted_text: String
        let request_id: String
    }
    private struct Reply: Decodable { let state: String?; let url: URL?; let error: String? }
    private static func location() throws -> URL {
        let parent = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = parent.appendingPathComponent("IndependentLedger/ScreenshotInbox", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var url = dir
        var attributes = URLResourceValues(); attributes.isExcludedFromBackup = true
        try url.setResourceValues(attributes)
        return dir
    }
    private static func files() throws -> [URL] {
        let items = try FileManager.default.contentsOfDirectory(at: location(), includingPropertiesForKeys: [.contentModificationDateKey])
        return items.filter { $0.pathExtension == "json" }
    }
    private static func valid(_ id: String) -> Bool {
        id.range(of: #"\Aios:\d{4}-\d{2}-\d{2}:[0-9a-f]{64}\z"#, options: .regularExpression) != nil
    }
    private static func date(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }
    static func latest() throws -> String? {
        try files().filter { Date().timeIntervalSince(date($0)) < 86400 }
            .max { date($0) < date($1) }?.deletingPathExtension().lastPathComponent
    }
    static func save(_ jpeg: Data, ocr: String) throws -> (id: String, fresh: Bool) {
        guard jpeg.count >= 4, jpeg.count <= 8*1024*1024, jpeg.prefix(3).elementsEqual([0xff,0xd8,0xff]) else {
            throw ReceiptError.message("请选择 8 MB 以内的 JPEG 截图。")
        }
        for file in try files() where Date().timeIntervalSince(date(file)) >= 86400 {
            try? FileManager.default.removeItem(at: file)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy-MM-dd"
        let id = "ios:" + formatter.string(from: Date()) + ":" + SHA256.hash(data: jpeg).map { String(format: "%02x", $0) }.joined()
        let path = try location().appendingPathComponent(id + ".json")
        if FileManager.default.fileExists(atPath: path.path) { return (id, false) }
        let body = Payload(receipt_base64: jpeg.base64EncodedString(), receipt_mime_type: "image/jpeg",
                           extracted_text: String(ocr.prefix(8000)), request_id: id)
        try JSONEncoder().encode(body).write(to: path, options: [.atomic,.completeFileProtection])
        return (id, true)
    }

    static func begin(_ id: String, text: String? = nil, jpeg: Data? = nil, fresh: Bool = false) async throws {
        guard valid(id) else { throw ReceiptError.message("截图任务无效。") }
        let file = try location().appendingPathComponent(id + ".json")
        let captured = date(file)
        guard Date().timeIntervalSince(captured) < 86400 else {
            throw ReceiptError.message("本机暂存的截图已过期，请重新截图。")
        }
        let preview: ScreenshotReceiptPreview
        if let previous = await session.state(id), (try? await ReceiptStore.shared.snapshot(id)) != nil {
            preview = previous.preview
        } else {
            let stored = text == nil || jpeg == nil ? try JSONDecoder().decode(Payload.self, from: Data(contentsOf: file)) : nil
            let quick = ScreenshotReceiptPreview(text: text ?? stored?.extracted_text ?? "")
            if quick.paidOnOneLine && quick.merchant != nil && quick.product != nil {
                preview = quick
            } else if let image = jpeg ?? stored.flatMap({ Data(base64Encoded: $0.receipt_base64) }),
                      let rows = try? await Task.detached(priority: .userInitiated, operation: { try ScreenshotImageText.rows(in: image) }).value,
                      !rows.isEmpty {
                // Merge independently readable fields. Inconsistent payment evidence still needs review.
                preview = ScreenshotReceiptPreview(spatialText: rows, fallback: quick)
            } else { preview = quick }
        }
        await ReceiptStore.shared.openScreenshot(id, preview: preview, captured: captured)
        await session.begin(id, preview: preview) {
            try await resolve(id, file: file, fresh: fresh)
        }
    }

    static func continueReview(_ id: String) async throws -> String {
        guard valid(id) else { throw ReceiptError.message("截图任务无效。") }
        if let card = try await ReceiptStore.shared.resumeClosedScreenshot(id, lookup: {
            guard let cookie = await IndependentLedgerModel.savedCookie() else {
                throw ReceiptError.message("请先在随手账登录独立账本，再继续核对。")
            }
            let (data, http) = try await ScreenshotJobTransfer.send(origin: IndependentLedgerModel.origin, id: id, cookie: cookie)
            if http.statusCode == 401 || http.statusCode == 403 { throw ReceiptError.message("请在随手账重新登录独立账本。") }
            let reply = try? JSONDecoder().decode(Reply.self, from: data)
            if reply?.state == "pending" || reply?.state == "uploading" { throw ReceiptError.message("截图仍在处理，稍后再点「继续上张截图记账」。") }
            guard http.statusCode == 200, reply?.state == "ready", let url = reply?.url else {
                throw ReceiptError.message("暂时没有可打开的草稿，请查看待核对小票。")
            }
            return url
        }) { return card }
        try await begin(id)
        return id
    }

    private static func resolve(_ id: String, file: URL, fresh: Bool) async throws -> String {
        guard let cookie = await IndependentLedgerModel.savedCookie() else {
            throw ReceiptError.message("请先在随手账登录独立账本，再继续核对。")
        }
        let origin = await IndependentLedgerModel.origin
        // A fresh upload probes the resumable job first, so a later retry finds an existing draft.
        var upload = fresh
        var submitted = false
        var transientRetries = 0
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(100))
        var delay = 450
        repeat {
            try Task.checkCancellation()
            do {
                let (bytes, http) = try await ScreenshotJobTransfer.send(
                    origin: origin, id: id, cookie: cookie, uploadFile: upload ? file : nil,
                    finishInForeground: true)
                let reply = try? JSONDecoder().decode(Reply.self, from: bytes)
                if !upload && !submitted && (http.statusCode == 404 || reply?.state == "failed") {
                    upload = true
                    continue
                }
                switch http.statusCode {
                case 401, 403: throw ReceiptError.message("请在随手账重新登录独立账本，再继续核对。")
                case 413: throw ReceiptError.message("截图超过服务允许的大小，请重新截取账单。")
                case 429: throw ReceiptError.message("账本正在处理其他截图，请稍后继续核对。")
                case 503 where reply?.error == "history_preview": throw ReceiptError.message("账本暂时只读，原图已保存在本机。")
                case 200..<300: break
                case 409 where reply?.state == "uploading": break
                default: throw ReceiptError.message("账本暂时无法读取小票（HTTP \(http.statusCode)）。原图已保存在本机。")
                }
                switch reply?.state {
                case "ready":
                    guard let url = reply?.url, (try? DraftReference(url: url).service) == .independent else {
                        throw ReceiptError.message("账本返回的小票地址无效。")
                    }
                    try await ReceiptStore.shared.bindScreenshot(id, to: url)
                    if await ReceiptStore.shared.takeHydratedSnippetRefresh(id) { ReceiptSnippetIntent.reload() }
                    return id
                case "pending":
                    submitted = true
                    upload = false
                case "uploading":
                    upload = true
                default:
                    throw ReceiptError.message("识别暂未完成，原图已保存在本机。")
                }
            } catch let error as URLError {
                if error.code == .cancelled { throw CancellationError() }
                guard transientRetries < 2 else { throw ReceiptError.message("暂时连不上账本，原图已保存在本机。") }
                transientRetries += 1
            }
            try await Task.sleep(for: .milliseconds(delay))
            delay = min(delay * 2, 2000)
        } while clock.now < deadline
        throw ReceiptError.message("完整小票仍在准备，稍后可继续核对这张截图。")
    }
}
