import Foundation
import Crypto
import Citadel

/// A private key the SSH layer can authenticate with.
enum ParsedPrivateKey {
    case ed25519(Curve25519.Signing.PrivateKey)
    case rsa(Insecure.RSA.PrivateKey)
    case p256(P256.Signing.PrivateKey)
    case p384(P384.Signing.PrivateKey)
    case p521(P521.Signing.PrivateKey)

    var typeName: String {
        switch self {
        case .ed25519: return "ED25519"
        case .rsa: return "RSA"
        case .p256: return "ECDSA P-256"
        case .p384: return "ECDSA P-384"
        case .p521: return "ECDSA P-521"
        }
    }

    func authMethod(username: String) -> SSHAuthenticationMethod {
        switch self {
        case .ed25519(let k): return .ed25519(username: username, privateKey: k)
        case .rsa(let k): return .rsa(username: username, privateKey: k)
        case .p256(let k): return .p256(username: username, privateKey: k)
        case .p384(let k): return .p384(username: username, privateKey: k)
        case .p521(let k): return .p521(username: username, privateKey: k)
        }
    }
}

enum PrivateKeyError: LocalizedError, Equatable {
    case unrecognized
    case wrongPassphrase
    case encryptedECDSA
    case encryptedPEM
    case pkcs1RSA
    case unsupportedType(String)

    var errorDescription: String? {
        switch self {
        case .unrecognized:
            return "Could not read the private key. Paste the whole key including the -----BEGIN … PRIVATE KEY----- and -----END … PRIVATE KEY----- lines."
        case .wrongPassphrase:
            return "The passphrase for this private key is wrong (or the key is damaged)."
        case .encryptedECDSA:
            return "Passphrase-protected ECDSA keys aren't supported yet. Remove the passphrase with “ssh-keygen -p -f <key>”, or use an ed25519 key."
        case .encryptedPEM:
            return "This is an old-style encrypted PEM key. Convert it with “ssh-keygen -p -f <key>” (which rewrites it in OpenSSH format) and paste it again."
        case .pkcs1RSA:
            return "This RSA key is in the old PEM format. Convert it with “ssh-keygen -p -f <key>” (which rewrites it in OpenSSH format) and paste it again."
        case .unsupportedType(let t):
            return "Keys of type “\(t)” aren't supported. Use ed25519, ECDSA or RSA."
        }
    }
}

enum PrivateKeyParser {
    static func parse(_ raw: String, passphrase: String) throws -> ParsedPrivateKey {
        if raw.contains("Proc-Type:") && raw.contains("ENCRYPTED") { throw PrivateKeyError.encryptedPEM }
        let pem = normalizedPEM(raw)
        let pass = passphrase.isEmpty ? nil : Data(passphrase.utf8)
        guard let label = pemLabel(pem) else { throw PrivateKeyError.unrecognized }

        switch label {
        case "OPENSSH PRIVATE KEY":
            let info = try OpenSSHContainer(pem: pem)
            switch info.keyType {
            case "ssh-ed25519":
                do { return .ed25519(try Curve25519.Signing.PrivateKey(sshEd25519: pem, decryptionKey: pass)) }
                catch { throw info.isEncrypted ? PrivateKeyError.wrongPassphrase : PrivateKeyError.unrecognized }
            case "ssh-rsa":
                do { return .rsa(try Insecure.RSA.PrivateKey(sshRsa: pem, decryptionKey: pass)) }
                catch { throw info.isEncrypted ? PrivateKeyError.wrongPassphrase : PrivateKeyError.unrecognized }
            case "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521":
                if info.isEncrypted { throw PrivateKeyError.encryptedECDSA }
                return try info.ecdsaKey()
            default:
                throw PrivateKeyError.unsupportedType(info.keyType)
            }
        case "EC PRIVATE KEY", "PRIVATE KEY":
            // SEC1 / PKCS#8 PEM (e.g. `ssh-keygen -m PEM -t ecdsa`). CryptoKit validates the curve.
            if let k = try? P256.Signing.PrivateKey(pemRepresentation: pem) { return .p256(k) }
            if let k = try? P384.Signing.PrivateKey(pemRepresentation: pem) { return .p384(k) }
            if let k = try? P521.Signing.PrivateKey(pemRepresentation: pem) { return .p521(k) }
            // CryptoKit rejects the SEC1 files ssh-keygen/OpenSSL write; read the scalar ourselves.
            if label == "EC PRIVATE KEY", let k = sec1Key(pem) { return k }
            throw label == "PRIVATE KEY" ? PrivateKeyError.pkcs1RSA : PrivateKeyError.unrecognized
        case "RSA PRIVATE KEY":
            throw PrivateKeyError.pkcs1RSA
        case "ENCRYPTED PRIVATE KEY":
            throw PrivateKeyError.encryptedPEM
        default:
            throw PrivateKeyError.unsupportedType(label)
        }
    }

    /// Rebuilds the BEGIN/END lines and the base64 body, so a key whose dashes were mangled
    /// by smart punctuation, or that lost its line breaks when pasted, still parses.
    /// OpenSSH bodies are wrapped at 70 columns, PEM at 64 (CryptoKit's PEM reader insists).
    static func normalizedPEM(_ raw: String) -> String {
        let text = raw.replacingOccurrences(of: "\r", with: "")
        guard let begin = text.range(of: "BEGIN "),
              let keyWord = text.range(of: "KEY", range: begin.upperBound..<text.endIndex)
        else { return raw.trimmingCharacters(in: .whitespacesAndNewlines) }
        let label = String(text[begin.upperBound..<keyWord.upperBound]).trimmingCharacters(in: .whitespaces)
        guard label.hasSuffix("PRIVATE KEY"), label.count < 40,
              let end = text.range(of: "END " + label, range: keyWord.upperBound..<text.endIndex)
        else { return raw.trimmingCharacters(in: .whitespacesAndNewlines) }
        // Skip whatever dash look-alikes trail the BEGIN label before the body starts.
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=")
        let body = String(text[keyWord.upperBound..<end.lowerBound].unicodeScalars.filter { allowed.contains($0) })
        let width = label == "OPENSSH PRIVATE KEY" ? 70 : 64
        var lines: [String] = []
        var i = body.startIndex
        while i < body.endIndex {
            let j = body.index(i, offsetBy: width, limitedBy: body.endIndex) ?? body.endIndex
            lines.append(String(body[i..<j]))
            i = j
        }
        return (["-----BEGIN \(label)-----"] + lines + ["-----END \(label)-----"]).joined(separator: "\n")
    }

    /// ECPrivateKey ::= SEQUENCE { version INTEGER (1), privateKey OCTET STRING, [0] params, [1] publicKey }.
    /// The curve follows from the scalar length (SEC1 fixes it at ceil(bits/8)).
    static func sec1Key(_ pem: String) -> ParsedPrivateKey? {
        let b64 = pem.split(separator: "\n").filter { !$0.hasPrefix("-----") }.joined()
        guard let der = Data(base64Encoded: b64) else { return nil }
        var r = DERReader(der)
        guard let seq = r.next(tag: 0x30) else { return nil }
        var inner = DERReader(seq)
        guard let version = inner.next(tag: 0x02), version == Data([1]), let d = inner.next(tag: 0x04) else { return nil }
        switch d.count {
        case 32: return (try? P256.Signing.PrivateKey(rawRepresentation: d)).map { .p256($0) }
        case 48: return (try? P384.Signing.PrivateKey(rawRepresentation: d)).map { .p384($0) }
        case 66: return (try? P521.Signing.PrivateKey(rawRepresentation: d)).map { .p521($0) }
        default: return nil
        }
    }

    static func pemLabel(_ pem: String) -> String? {
        guard pem.hasPrefix("-----BEGIN "), let close = pem.range(of: "-----", range: pem.index(pem.startIndex, offsetBy: 11)..<pem.endIndex)
        else { return nil }
        return String(pem[pem.index(pem.startIndex, offsetBy: 11)..<close.lowerBound])
    }
}

/// Minimal reader for the `openssh-key-v1` container: enough to learn the key type and
/// whether it is encrypted, and to decode unencrypted ECDSA keys (which Citadel can't parse).
struct OpenSSHContainer {
    let cipher: String
    let keyType: String
    private let privateSection: Data
    var isEncrypted: Bool { cipher != "none" }

    init(pem: String) throws {
        let b64 = pem.split(separator: "\n").filter { !$0.hasPrefix("-----") }.joined()
        guard let data = Data(base64Encoded: b64) else { throw PrivateKeyError.unrecognized }
        var r = SSHReader(data)
        let magic = Data("openssh-key-v1\0".utf8)
        guard try r.bytes(magic.count) == magic else { throw PrivateKeyError.unrecognized }
        cipher = try r.string()
        _ = try r.string() // kdf name
        _ = try r.blob()   // kdf options
        guard try r.uint32() == 1 else { throw PrivateKeyError.unrecognized } // one key per file
        var pub = SSHReader(try r.blob())
        keyType = try pub.string()
        privateSection = try r.blob()
    }

    func ecdsaKey() throws -> ParsedPrivateKey {
        var r = SSHReader(privateSection)
        guard try r.uint32() == r.uint32() else { throw PrivateKeyError.unrecognized } // check ints
        guard try r.string() == keyType else { throw PrivateKeyError.unrecognized }
        _ = try r.string() // curve name
        _ = try r.blob()   // public point
        let scalar = try r.blob()
        do {
            switch keyType {
            case "ecdsa-sha2-nistp256": return .p256(try P256.Signing.PrivateKey(rawRepresentation: Self.fixed(scalar, 32)))
            case "ecdsa-sha2-nistp384": return .p384(try P384.Signing.PrivateKey(rawRepresentation: Self.fixed(scalar, 48)))
            default: return .p521(try P521.Signing.PrivateKey(rawRepresentation: Self.fixed(scalar, 66)))
            }
        } catch { throw PrivateKeyError.unrecognized }
    }

    /// SSH mpints carry a leading 0x00 when the top bit is set and drop leading zeros otherwise.
    static func fixed(_ mpint: Data, _ size: Int) -> Data {
        let trimmed = mpint.drop { $0 == 0 }
        return Data(repeating: 0, count: max(size - trimmed.count, 0)) + trimmed
    }
}

struct SSHReader {
    private let data: Data
    private var offset: Int
    init(_ data: Data) { self.data = data; offset = data.startIndex }

    mutating func bytes(_ n: Int) throws -> Data {
        guard n >= 0, offset + n <= data.endIndex else { throw PrivateKeyError.unrecognized }
        defer { offset += n }
        return data[offset..<offset + n]
    }
    mutating func uint32() throws -> UInt32 { try bytes(4).reduce(0) { $0 << 8 | UInt32($1) } }
    mutating func blob() throws -> Data { try bytes(Int(uint32())) }
    mutating func string() throws -> String { String(decoding: try blob(), as: UTF8.self) }
}

/// Just enough DER to walk a SEC1 key: definite-length TLVs, short or long form.
struct DERReader {
    private let data: Data
    private var offset: Int
    init(_ data: Data) { self.data = data; offset = data.startIndex }

    mutating func next(tag: UInt8) -> Data? {
        guard offset + 2 <= data.endIndex, data[offset] == tag else { return nil }
        var i = offset + 1
        var len = Int(data[i]); i += 1
        if len & 0x80 != 0 {
            let n = len & 0x7F
            guard n > 0, n <= 4, i + n <= data.endIndex else { return nil }
            len = data[i..<i + n].reduce(0) { $0 << 8 | Int($1) }
            i += n
        }
        guard i + len <= data.endIndex else { return nil }
        offset = i + len
        return data[i..<i + len]
    }
}
