import Foundation
import Security
import Network
import SwiftUI
import WebKit
import ReceiptCore

@MainActor
final class IndependentLedgerModel: ObservableObject {
    static let origin = URL(string: "https://ledger-sync.xiaokai123.de5.net")!
    @Published private(set) var ledger = OfflineLedger()
    @Published private(set) var syncing = false
    @Published private(set) var signedIn = false
    @Published var message = ""
    private let file: OfflineLedgerFile
    private var writable = false
    private var cookie: String?
    private let network = NWPathMonitor()
    private let transport = URLSession(configuration: .ephemeral, delegate: NoLedgerRedirects(), delegateQueue: nil)

    init() {
        let base = FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0]
        file = OfflineLedgerFile(url:base.appendingPathComponent("IndependentLedger/ledger-v1.json"))
        do { ledger = try file.load(); writable = true }
        catch { message = "本机账本暂时无法读取，解锁设备后请重新打开。" }
        cookie = Self.savedCookie()
        signedIn = cookie != nil
        network.pathUpdateHandler = { [weak self] path in
            if path.status == .satisfied { Task { @MainActor [weak self] in await self?.sync() } }
        }
        network.start(queue:DispatchQueue(label:"ledger.network"))
    }

    private func persist(_ next: OfflineLedger) throws {
        guard writable else { throw CocoaError(.fileReadNoPermission) }
        try file.save(next); ledger = next
    }
    func record(_ entry: StandaloneEntry) -> Bool {
        do {
            var next=ledger;next.record(entry);try persist(next)
            message="已保存到本机";Task { await sync() };return true
        } catch { message="本机保存失败，请检查可用空间后重试。";return false }
    }

    func signIn(_ password: String) async -> Bool {
        guard !syncing else { return false }
        do {
            let result = try await send("/api/ledger/session", method:"POST", body:JSONEncoder().encode(["password":password]))
            guard let field=result.1.value(forHTTPHeaderField:"Set-Cookie"),
                  let value=HTTPCookie.cookies(withResponseHeaderFields:["Set-Cookie":field],for:Self.origin)
                    .first(where:{$0.name=="ledger_session"})?.value else { throw URLError(.userAuthenticationRequired) }
            try Self.storeCookie(value); cookie=value; signedIn=true
            await sync();return true
        } catch { message = Self.describe(error);return false }
    }
    func sync() async {
        guard writable, cookie != nil, !syncing else { return }
        syncing=true;defer{syncing=false}
        do {
            let initial=try await fetchSnapshot()
            try ledger.validate(initial)
            if ledger.remote == nil {
                var bound=ledger;try bound.accept(initial,acknowledged:[]);try persist(bound)
            }
            let pending=ledger.pending
            var sent=Set<String>()
            for item in pending {
                var obj=try JSONSerialization.jsonObject(with:JSONEncoder().encode(item)) as? [String:Any] ?? [:]
                obj["ledgerID"]=initial.ledgerID
                let value=try await send("/api/native/entries",method:"POST",body:JSONSerialization.data(withJSONObject:obj))
                let ack=try JSONDecoder().decode(Ack.self,from:value.0)
                guard ack.id==item.id else { throw URLError(.cannotParseResponse) }
                sent.insert(item.id)
            }
            let final = pending.isEmpty ? initial : try await fetchSnapshot()
            guard initial.ledgerID==final.ledgerID else { throw IndependentLedgerError.differentLedger }
            var next=ledger;try next.accept(final,acknowledged:sent);try persist(next)
            message=next.pending.isEmpty ? "已同步" : "有新记录等待同步"
        } catch { message=Self.describe(error) }
    }
    private struct Ack: Decodable { let id:String }
    private func fetchSnapshot() async throws -> LedgerSnapshot {
        let result=try await send("/api/native/snapshot")
        return try JSONDecoder().decode(LedgerSnapshot.self,from:result.0)
    }
    private func send(_ path:String, method:String="GET", body:Data?=nil) async throws -> (Data,HTTPURLResponse) {
        var request=URLRequest(url:Self.origin.appendingPathComponent(String(path.dropFirst())))
        request.httpMethod=method;request.timeoutInterval=25;request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpShouldHandleCookies=false;request.setValue(Self.origin.absoluteString,forHTTPHeaderField:"Origin")
        if let cookie { request.setValue("ledger_session="+cookie,forHTTPHeaderField:"Cookie") }
        if let body { request.httpBody=body;request.setValue("application/json",forHTTPHeaderField:"Content-Type") }
        let (bytes,response)=try await transport.data(for:request)
        guard let http=response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        if http.statusCode==401 {
            if path != "/api/ledger/session" { cookie=nil;signedIn=false;SecItemDelete(Self.keyQuery as CFDictionary) }
            throw URLError(.userAuthenticationRequired)
        }
        if http.statusCode==409 { throw IndependentLedgerError.differentLedger }
        guard (200..<300).contains(http.statusCode) else { throw URLError(.badServerResponse) }
        return (bytes,http)
    }
    private static var keyQuery:[String:Any] {
        [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:"net.xiaokai.ledger.sync",kSecAttrAccount as String:"owner-session"]
    }
    static func savedCookie()->String? {
        var query=keyQuery;query[kSecReturnData as String]=true
        var item:CFTypeRef?;guard SecItemCopyMatching(query as CFDictionary,&item)==errSecSuccess,let raw=item as? Data else {return nil}
        return String(data:raw,encoding:.utf8)
    }
    private static func storeCookie(_ value:String)throws {
        let attrs=[kSecValueData as String:Data(value.utf8),kSecAttrAccessible as String:kSecAttrAccessibleWhenUnlockedThisDeviceOnly] as [String:Any]
        let status=SecItemUpdate(keyQuery as CFDictionary,attrs as CFDictionary)
        if status==errSecItemNotFound {
            var q=keyQuery;for (key,val) in attrs {q[key]=val}
            guard SecItemAdd(q as CFDictionary,nil)==errSecSuccess else {throw CocoaError(.fileWriteNoPermission)}
        } else if status != errSecSuccess {throw CocoaError(.fileWriteNoPermission)}
    }
    static func describe(_ error:Error)->String {
        if error is IndependentLedgerError {return "同步账本或记录版本不一致，待同步记录已保存在本机。"}
        if (error as? URLError)?.code == .userAuthenticationRequired {return "请检查独立账本密码，重新连接同步。"}
        return "同步暂未完成。本机账目已保留，网络恢复后会重试。"
    }
}
final class NoLedgerRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session:URLSession, task:URLSessionTask, willPerformHTTPRedirection response:HTTPURLResponse,
                    newRequest request:URLRequest, completionHandler:@escaping @Sendable (URLRequest?)->Void) { completionHandler(nil) }
}


@MainActor @objc(LedgerWebAccount)
final class LedgerWebAccount: NSObject {
    @objc(prepareIn:completion:)
    static func prepare(in store: WKHTTPCookieStore, completion: @escaping (Bool) -> Void) {
        let origin = IndependentLedgerModel.origin
        guard let value = IndependentLedgerModel.savedCookie(),
              let cookie = HTTPCookie(properties: [.name: "ledger_session", .value: value, .path: "/",
                  .originURL: origin, .secure: "TRUE", HTTPCookiePropertyKey("HttpOnly"): "TRUE"]) else {
            completion(false)
            return
        }
        Task { @MainActor in
            let config = URLSessionConfiguration.ephemeral
            config.httpCookieStorage = nil
            let session = URLSession(configuration: config, delegate: NoLedgerRedirects(), delegateQueue: nil)
            defer { session.finishTasksAndInvalidate() }
            var req = URLRequest(url: origin.appendingPathComponent("api/native/account-status"))
            req.httpShouldHandleCookies = false
            req.timeoutInterval = 3
            req.setValue("ledger_session=" + value, forHTTPHeaderField: "Cookie")
            struct Status: Decodable { let production: Bool }
            if let (data,response) = try? await session.data(for: req), (response as? HTTPURLResponse)?.statusCode == 200,
               (try? JSONDecoder().decode(Status.self, from: data).production) == true {
                await store.setCookie(cookie)
                completion(true)
            } else { completion(false) }
        }
    }
}
