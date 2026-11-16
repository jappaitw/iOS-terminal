import XCTest
import Crypto
@testable import PocketCode

final class KeyNormalizationTests: XCTestCase {
    /// A throwaway ed25519 key generated only for this test (never used anywhere).
    static let key = """
    -----BEGIN OPENSSH PRIVATE KEY-----
    b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
    QyNTUxOQAAACBOx72Gc4Ele7miHfOhA+aN1dAhhcKWK+tFqon+KiwI7wAAAJh83YwAfN2M
    AAAAAAtzc2gtZWQyNTUxOQAAACBOx72Gc4Ele7miHfOhA+aN1dAhhcKWK+tFqon+KiwI7w
    AAAEBv72noz/BST089GJortIGzYgI/GKzkqiyMBLxBPJQc5k7HvYZzgSV7uaId86ED5o3V
    0CGFwpYr60Wqif4qLAjvAAAAFHBvY2tldGNvZGUtdW5pdC10ZXN0AQ==
    -----END OPENSSH PRIVATE KEY-----
    """

    private func parses(_ s: String) -> Bool {
        (try? Curve25519.Signing.PrivateKey(sshEd25519: SSHConnection.normalizedOpenSSHKey(s))) != nil
    }

    func testCleanKeyParses() { XCTAssertTrue(parses(Self.key)) }

    func testSmartDashesAreRepaired() {
        // iOS smart punctuation turns "-----" into em/en dashes.
        let mangled = Self.key.replacingOccurrences(of: "-----", with: "—–")
        XCTAssertTrue(parses(mangled))
    }

    func testLostLineBreaksAndCRLF() {
        let oneLine = Self.key.replacingOccurrences(of: "\n", with: " ")
        XCTAssertTrue(parses(oneLine))
        XCTAssertTrue(parses(Self.key.replacingOccurrences(of: "\n", with: "\r\n")))
    }

    func testOutputShape() {
        let out = SSHConnection.normalizedOpenSSHKey("  " + Self.key + "\n\n")
        let lines = out.split(separator: "\n")
        XCTAssertEqual(lines.first, "-----BEGIN OPENSSH PRIVATE KEY-----")
        XCTAssertEqual(lines.last, "-----END OPENSSH PRIVATE KEY-----")
        XCTAssertTrue(lines.dropFirst().dropLast().allSatisfy { $0.count <= 70 })
    }

    func testNonOpenSSHInputIsOnlyTrimmed() {
        XCTAssertEqual(SSHConnection.normalizedOpenSSHKey("  not a key \n"), "not a key")
    }
}
