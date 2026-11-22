import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(CryptoKit)
import CryptoKit
#endif

public enum ScreenshotJobTransfer {
    private static let partSize = 16 * 1024
    private struct ProgressReply: Decodable {
        let state: String?
        let offset: Int?
        let total: Int?
    }

    // Polls share the same HTTPS connection. Credentials stay on each request.
    private static let transport: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.timeoutIntervalForRequest = 45
        config.timeoutIntervalForResource = 120
        return URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
    }()

    public static func send(origin: URL, id: String, cookie: String, uploadFile: URL? = nil,
                            finishInForeground: Bool = false) async throws -> (Data, HTTPURLResponse) {
        let session = transport
        let endpoint = origin.appendingPathComponent("api/native/screenshot-jobs")
            .appending(queryItems: [URLQueryItem(name: "id", value: id)])
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: uploadFile == nil ? 10 : 45)
        request.httpShouldHandleCookies = false
        request.setValue(origin.absoluteString, forHTTPHeaderField: "Origin")
        request.setValue("ledger_session=" + cookie, forHTTPHeaderField: "Cookie")
        guard let file = uploadFile else { return try http(await session.data(for: request)) }

        #if canImport(CryptoKit)
        let body = try Data(contentsOf: file, options: .mappedIfSafe)
        if body.count > partSize {
            return try await sendParts(body, request: request, session: session, finishInForeground: finishInForeground)
        }
        #endif
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return try http(await session.upload(for: request, fromFile: file))
    }

    private static func http(_ result: (Data, URLResponse)) throws -> (Data, HTTPURLResponse) {
        guard let response = result.1 as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (result.0, response)
    }

    #if canImport(CryptoKit)
    private static func sendParts(_ body: Data, request: URLRequest, session: URLSession,
                                  finishInForeground: Bool) async throws -> (Data, HTTPURLResponse) {
        let digest = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
        var probe = request
        guard let url = request.url else { throw URLError(.badURL) }
        probe.url = url.appending(queryItems: [URLQueryItem(name: "upload_sha256", value: digest)])
        probe.timeoutInterval = 12
        let initial = try http(await session.data(for: probe))
        var offset = 0
        if initial.1.statusCode != 404 {
            let previous = try? JSONDecoder().decode(ProgressReply.self, from: initial.0)
            if initial.1.statusCode == 200, previous?.state == "uploading",
               let next = previous?.offset, previous?.total == body.count,
               next >= 0, next <= body.count, next == body.count || next % partSize == 0 {
                // A full temporary upload can still be waiting for queue capacity.
                offset = next == body.count ? ((body.count - 1) / partSize) * partSize : next
            } else if initial.1.statusCode != 200 || previous?.state != "failed" {
                return initial
            }
        }
        let started = ContinuousClock.now
        var part = request
        part.httpMethod = "PUT"
        part.timeoutInterval = 22
        part.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        part.setValue(digest, forHTTPHeaderField: "X-Upload-SHA256")
        while offset < body.count {
            let end = min(offset + partSize, body.count)
            part.setValue("bytes \(offset)-\(end - 1)/\(body.count)", forHTTPHeaderField: "Content-Range")
            let answer = try http(await session.upload(for: part, from: body.subdata(in: offset..<end)))
            let progress = try? JSONDecoder().decode(ProgressReply.self, from: answer.0)
            guard (answer.1.statusCode == 202 || answer.1.statusCode == 409),
                  progress?.state == "uploading" else { return answer }
            guard progress?.total == body.count, let next = progress?.offset,
                  next >= 0, next < body.count, next % partSize == 0, next != offset else {
                throw URLError(.cannotParseResponse)
            }
            if !finishInForeground && started.duration(to: .now) >= .seconds(7) { return answer }
            if next < offset { return answer }
            offset = next
        }
        throw URLError(.cannotParseResponse)
    }
    #endif
}
