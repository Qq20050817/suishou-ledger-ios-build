#if os(macOS)
import Foundation
import XCTest
@testable import ReceiptCore

final class ScreenshotJobTransferTests: XCTestCase {
    @MainActor
    func testSavedFileCanFinishUploadingAfterSixSecondsAndBeQueriedAgain() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let body = dir.appendingPathComponent("saved.json")
        let large = dir.appendingPathComponent("large.json")
        let port = dir.appendingPathComponent("port")
        let id = "ios:2026-01-01:" + String(repeating: "a", count: 64)
        let json = try JSONSerialization.data(withJSONObject: ["request_id": id, "fixture": String(repeating: "x", count: 12_000)])
        try json.write(to: body)
        let secondID = "ios:2026-01-01:" + String(repeating: "b", count: 64)
        try JSONSerialization.data(withJSONObject: ["request_id": secondID, "fixture": String(repeating: "x", count: 240_000)]).write(to: large)

        let fixture = Process()
        fixture.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        fixture.arguments = ["-c", #"""
        import hashlib, json, pathlib, re, sys, time
        from http.server import BaseHTTPRequestHandler, HTTPServer
        from urllib.parse import urlsplit, parse_qs
        body, large, port = map(pathlib.Path, sys.argv[1:])
        saved = body.read_bytes()
        job = json.loads(saved)['request_id']
        whole = large.read_bytes()
        second = json.loads(whole)['request_id']
        digest = hashlib.sha256(whole).hexdigest()
        received = bytearray()
        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args): pass
            def check_request(self):
                url = urlsplit(self.path)
                return (url.path == '/api/native/screenshot-jobs' and parse_qs(url.query).get('id') in ([job], [second])
                        and self.headers.get('Origin') == 'http://127.0.0.1:' + str(self.server.server_port)
                        and self.headers.get('Cookie') == 'ledger_session=fixture')
            def reply(self, code, result=None):
                response = json.dumps(result or {}).encode()
                self.send_response(code)
                self.send_header('Content-Length', str(len(response)))
                self.end_headers()
                self.wfile.write(response)
            def do_GET(self):
                params = parse_qs(urlsplit(self.path).query)
                if not self.check_request(): self.reply(400); return
                if params['id'] == [job]:
                    self.reply(200 if self.server.accepted else 404); return
                if params.get('upload_sha256') != [digest]: self.reply(400); return
                if not received: self.reply(404); return
                self.reply(200,{'state':'uploading','offset':len(received),'total':len(whole)})
            def do_PUT(self):
                match = re.fullmatch(r'bytes (\d+)-(\d+)/(\d+)', self.headers.get('Content-Range',''))
                if not match or not self.check_request() or self.headers.get('X-Upload-SHA256') != digest:
                    self.reply(400); return
                start,end,total = map(int,match.groups())
                count = int(self.headers['Content-Length'])
                part = self.rfile.read(count)
                if start != len(received) or total != len(whole) or count > 16384 or part != whole[start:end+1]:
                    self.reply(400); return
                if start and not self.server.interrupted:
                    self.server.interrupted = True
                    self.reply(503); return
                received.extend(part)
                self.reply(202, {'state':'pending'} if received == whole else
                           {'state':'uploading','offset':len(received),'total':len(whole)})
            def do_POST(self):
                size = int(self.headers.get('Content-Length', 0))
                data = bytearray()
                while len(data) < size:
                    chunk = self.rfile.read(min(30_000, size - len(data)))
                    if not chunk: break
                    data.extend(chunk)
                    time.sleep(0.1)
                time.sleep(7)
                self.server.accepted = self.check_request() and data == saved and self.headers.get('Content-Type') == 'application/json'
                self.reply(202 if self.server.accepted else 400)
        server = HTTPServer(('127.0.0.1', 0), Handler)
        server.accepted = False
        server.interrupted = False
        port.write_text(str(server.server_port))
        server.serve_forever()
        """#, body.path, large.path, port.path]
        try fixture.run()
        defer { if fixture.isRunning { fixture.terminate() } }
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: port.path) { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let portNumber = try String(contentsOf: port, encoding: .utf8)
        let origin = try XCTUnwrap(URL(string: "http://127.0.0.1:" + portNumber))
        let (_, missing) = try await ScreenshotJobTransfer.send(origin: origin, id: id, cookie: "fixture")
        XCTAssertEqual(missing.statusCode, 404)
        let started = ContinuousClock.now
        let (_, accepted) = try await ScreenshotJobTransfer.send(origin: origin, id: id, cookie: "fixture", uploadFile: body)
        XCTAssertGreaterThan(started.duration(to: .now), .seconds(6))
        XCTAssertEqual(accepted.statusCode, 202)
        let (_, ready) = try await ScreenshotJobTransfer.send(origin: origin, id: id, cookie: "fixture")
        XCTAssertEqual(ready.statusCode, 200)
        let (_, interrupted) = try await ScreenshotJobTransfer.send(origin: origin, id: secondID, cookie: "fixture",
                                                                   uploadFile: large, finishInForeground: true)
        XCTAssertEqual(interrupted.statusCode, 503)
        let (response, resumed) = try await ScreenshotJobTransfer.send(origin: origin, id: secondID, cookie: "fixture",
                                                                      uploadFile: large, finishInForeground: true)
        XCTAssertEqual(resumed.statusCode, 202)
        XCTAssertEqual(try JSONDecoder().decode([String: String].self, from: response)["state"], "pending")
    }
}
#endif
