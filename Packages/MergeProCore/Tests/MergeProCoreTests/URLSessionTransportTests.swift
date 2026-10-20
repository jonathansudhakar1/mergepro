import Foundation
import XCTest
import MergeProCore

@MainActor
final class URLSessionTransportTests: XCTestCase {
    /// Actual loopback HTTP redirect proves URLSession delegate behavior, rather than
    /// assuming that an injected transport strips headers or disables automatic redirects.
    func testRealSessionReturnsRedirectToClientWithoutFollowingIt() async throws {
        let server = Process()
        server.executableURL = URL(fileURLWithPath:"/usr/bin/python3")
        server.arguments = ["-u","-c", """
        from http.server import BaseHTTPRequestHandler, HTTPServer
        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args): pass
            def do_GET(self):
                if self.path == '/start':
                    self.send_response(302)
                    self.send_header('Location', 'http://127.0.0.1:%d/finished' % self.server.server_port)
                else: self.send_response(200)
                self.send_header('Content-Length', '0')
                self.end_headers()
        server = HTTPServer(('127.0.0.1', 0), Handler)
        print(server.server_port, flush=True)
        server.serve_forever()
        """]
        let output = Pipe(); server.standardOutput = output; server.standardError = Pipe()
        try server.run()
        defer { server.terminate(); server.waitUntilExit() }
        let portText = String(decoding:output.fileHandleForReading.availableData,as:UTF8.self).trimmingCharacters(in:.whitespacesAndNewlines)
        let port = try XCTUnwrap(Int(portText))
        let response = try await URLSessionGitHubTransport().send(URLRequest(url:URL(string:"http://127.0.0.1:\(port)/start")!))
        XCTAssertEqual(response.status,302)
        XCTAssertEqual(response.header("Location"),"http://127.0.0.1:\(port)/finished")
    }
}
