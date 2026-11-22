import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public protocol LedgerServing: Sendable {
    func scoped(to service: ReceiptService) -> any LedgerServing
    func fetch(_ reference: DraftReference, order: String?) async throws -> ReceiptDraft
    func confirm(_ payload: ConfirmationPayload) async throws
    func confirmWithUndo(_ payload: ConfirmationPayload) async throws -> UndoCapability?
    func undo(_ capability: UndoCapability) async throws -> DraftReference
    func cancel(_ reference: DraftReference) async throws
}

/// Do not follow redirects with a draft capability or share browser cookies.
final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

public final class LedgerClient: LedgerServing, @unchecked Sendable {
    private let session: URLSession
    private let service: ReceiptService
    private init(service: ReceiptService, session: URLSession) {
        self.service = service
        self.session = session
    }

    public func scoped(to service: ReceiptService) -> any LedgerServing {
        LedgerClient(service: service, session: session)
    }

    public init() {
        service = .original
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 25
        config.timeoutIntervalForResource = 30
        config.httpShouldSetCookies = false
        config.urlCache = nil
        session = URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
    }

    public func fetch(_ reference: DraftReference, order: String? = nil) async throws -> ReceiptDraft {
        var request = URLRequest(url: url(reference, order: order))
        request.httpMethod = "GET"
        let data = try await send(request)
        let draft = try JSONDecoder().decode(ReceiptDraft.self, from: data)
        guard draft.id == reference.id, draft.transactionType != .unknown else {
            throw ReceiptError.message("交易类型或账单信息不明确，请重新截图。")
        }
        return draft
    }

    public func confirm(_ payload: ConfirmationPayload) async throws {
        _ = try await confirmWithUndo(payload)
    }
    public func confirmWithUndo(_ payload: ConfirmationPayload) async throws -> UndoCapability? {
        var request = URLRequest(url: service.api)
        request.httpMethod = "PATCH"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(payload)
        let data = try await send(request)
        struct Result: Decodable { let ok: Bool; let result: String; let undo: UndoCapability? }
        let result = try JSONDecoder().decode(Result.self, from: data)
        guard result.ok, result.result == "success" else { throw ReceiptError.message("服务未确认保存结果。") }
        return result.undo
    }
    public func undo(_ capability: UndoCapability) async throws -> DraftReference {
        var request = URLRequest(url: service.api.appendingPathComponent("undo"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(capability)
        struct Result: Decodable { struct Draft: Decodable { let id: String; let token: String }; let ok: Bool; let draft: Draft? }
        let result = try JSONDecoder().decode(Result.self, from: await send(request))
        guard result.ok, let draft = result.draft else { throw ReceiptError.message("撤销结果暂未确认。") }
        var components = URLComponents(url: service.confirmation, resolvingAgainstBaseURL: false)!
        components.queryItems = [.init(name: "id", value: draft.id), .init(name: "token", value: draft.token)]
        return try DraftReference(url: components.url!)
    }

    public func cancel(_ reference: DraftReference) async throws {
        var request = URLRequest(url: url(reference))
        request.httpMethod = "DELETE"
        _ = try await send(request)
    }

    private func url(_ reference: DraftReference, order: String? = nil) -> URL {
        var c = URLComponents(url: service.api, resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "id", value: reference.id), URLQueryItem(name: "token", value: reference.token)]
        if let order { c.queryItems?.append(URLQueryItem(name: "orderReference", value: order)) }
        return c.url!
    }

    private func send(_ source: URLRequest) async throws -> Data {
        var request = source
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ReceiptError.message("服务响应无效。") }
        guard (200...299).contains(http.statusCode) else {
            // Do not echo URLs, tokens or raw response bodies into system dialogs.
            let message: String
            switch http.statusCode {
            case 400: message = "信息校验未通过，请核对金额、分类和原订单。"
            case 401, 403: message = "当前凭据无法访问这张小票。"
            case 404, 410: message = "草稿已处理或过期，请先核对账本，避免重复记账。"
            case 409: message = "账单已修改、关联退款或撤销已过期，请到流水核对。"
            case 429: message = "请求较多，请稍后再试。"
            default: message = "记账服务暂时无法完成请求。"
            }
            if [400, 401, 403, 409, 429].contains(http.statusCode) { throw ReceiptError.rejected(message) }
            throw ReceiptError.message(message)
        }
        return data
    }
}

public struct UndoCapability: Codable, Sendable {
    public let id: String
    public let token: String
    public let expiresAt: Double
    public init(id: String, token: String, expiresAt: Double) { self.id = id; self.token = token; self.expiresAt = expiresAt }
}

public extension LedgerServing {
    func scoped(to service: ReceiptService) -> any LedgerServing { self }
    func confirmWithUndo(_ payload: ConfirmationPayload) async throws -> UndoCapability? {
        try await confirm(payload); return nil
    }
    func undo(_ capability: UndoCapability) async throws -> DraftReference {
        throw ReceiptError.rejected("当前服务暂不支持撤销。")
    }
}
