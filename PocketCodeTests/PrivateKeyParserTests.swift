import XCTest
import Crypto
import NIOSSH
@testable import PocketCode

final class PrivateKeyParserTests: XCTestCase {
    /// Public key (OpenSSH "type base64") derived from what we parsed.
    private func publicKey(_ k: ParsedPrivateKey) -> String? {
        let nio: NIOSSHPrivateKey
        switch k {
        case .ed25519(let key): nio = NIOSSHPrivateKey(ed25519Key: key)
        case .p256(let key): nio = NIOSSHPrivateKey(p256Key: key)
        case .p384(let key): nio = NIOSSHPrivateKey(p384Key: key)
        case .p521(let key): nio = NIOSSHPrivateKey(p521Key: key)
        case .rsa: return nil
        }
        return String(openSSHPublicKey: nio.publicKey)
    }

    private func assertParses(_ pem: String, pass: String = "", expect type: String, pub: String?,
                              file: StaticString = #filePath, line: UInt = #line) {
        do {
            let k = try PrivateKeyParser.parse(pem, passphrase: pass)
            XCTAssertEqual(k.typeName, type, file: file, line: line)
            if let pub { XCTAssertEqual(publicKey(k), pub, "parsed key doesn't match its .pub", file: file, line: line) }
        } catch {
            XCTFail("\(type): \(error)", file: file, line: line)
        }
    }

    private func assertFails(_ pem: String, pass: String = "", _ expected: PrivateKeyError,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try PrivateKeyParser.parse(pem, passphrase: pass), file: file, line: line) {
            XCTAssertEqual($0 as? PrivateKeyError, expected, file: file, line: line)
        }
    }

    func testECDSAOpenSSH() {
        assertParses(KeyFixtures.p256, expect: "ECDSA P-256", pub: KeyFixtures.p256Pub)
        assertParses(KeyFixtures.p384, expect: "ECDSA P-384", pub: KeyFixtures.p384Pub)
        assertParses(KeyFixtures.p521, expect: "ECDSA P-521", pub: KeyFixtures.p521Pub)
    }

    func testECDSAPEM() {
        assertParses(KeyFixtures.p256pem, expect: "ECDSA P-256", pub: KeyFixtures.p256pemPub)
    }

    func testEncryptedEd25519() {
        assertParses(KeyFixtures.edenc, pass: KeyFixtures.passphrase, expect: "ED25519", pub: KeyFixtures.edencPub)
        assertFails(KeyFixtures.edenc, pass: "nope", .wrongPassphrase)
    }

    func testRSA() {
        assertParses(KeyFixtures.rsa, expect: "RSA", pub: nil)
        assertParses(KeyFixtures.rsaenc, pass: KeyFixtures.passphrase, expect: "RSA", pub: nil)
    }

    func testClearErrors() {
        assertFails(KeyFixtures.p256enc, pass: KeyFixtures.passphrase, .encryptedECDSA)
        assertFails(KeyFixtures.rsapem, .pkcs1RSA)
        assertFails("hello", .unrecognized)
    }

    func testMangledECDSAStillParses() {
        let mangled = KeyFixtures.p384.replacingOccurrences(of: "-----", with: "—–").replacingOccurrences(of: "\n", with: " ")
        assertParses(mangled, expect: "ECDSA P-384", pub: KeyFixtures.p384Pub)
        let mangledPEM = KeyFixtures.p256pem.replacingOccurrences(of: "\n", with: "\r\n")
        assertParses(mangledPEM, expect: "ECDSA P-256", pub: KeyFixtures.p256pemPub)
    }
}
