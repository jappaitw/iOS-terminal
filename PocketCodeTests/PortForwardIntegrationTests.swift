import XCTest
import Citadel
import Crypto
import NIOSSH
@testable import PocketCode

/// End-to-end check of LocalPortForward against a real sshd. Skipped unless run with
///   TEST_RUNNER_PC_SSH_KEY=<path to OpenSSH private key>  TEST_RUNNER_PC_SSH_USER=<user>
///   TEST_RUNNER_PC_SSH_PORT=<sshd port>  TEST_RUNNER_PC_HTTP_PORT=<port of an HTTP server on the sshd host>
/// (see docs/RELEASE.md). The sshd and HTTP server must listen on 127.0.0.1.
final class PortForwardIntegrationTests: XCTestCase {
    func testForwardReachesServerOnHost() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let keyPath = env["PC_SSH_KEY"], let user = env["PC_SSH_USER"],
              let sshPort = env["PC_SSH_PORT"].flatMap(Int.init), let httpPort = env["PC_HTTP_PORT"].flatMap(Int.init)
        else { throw XCTSkip("no test sshd configured") }

        let key = try PrivateKeyParser.parse(try String(contentsOfFile: keyPath), passphrase: "")
        let client = try await SSHClient.connect(host: "127.0.0.1", port: sshPort,
                                                 authenticationMethod: key.authMethod(username: user),
                                                 hostKeyValidator: .acceptAnything(), reconnect: .never)
        let localPort = httpPort + 1
        let forward = try await LocalPortForward.start(client: client, localPort: localPort, remotePort: httpPort)
        defer { forward.stop() }

        // Two sequential requests: each one is its own tunnelled connection.
        for path in ["/", "/callback?code=abc"] {
            let (data, response) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(localPort)\(path)")!)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200, path)
            XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("PORT_FORWARD_OK"), path)
        }
        try await client.close()
    }
}
