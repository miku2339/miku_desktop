import CryptoKit
import Foundation
import LocalAuthentication
import MachO
import Security

#if canImport(DeviceCheck)
import DeviceCheck
#endif

enum MikuLocalTTSAuthorizationError: Error, Equatable {
    case invalidFormat(String)
    case authorizationDenied(String)
    case secureEnclaveUnavailable
    case keychainFailure(OSStatus)
    case signingNotReady(String)
    case appAttestUnavailable
}

enum MikuLocalTTSProtocol {
    static let product = "miku-four-language-gpt-sovits"
    static let maximumLeaseLifetime: Int64 = 3_600

    private static let deviceDomain = Data("MIKU-LOCAL-TTS-DEVICE-v1\0".utf8)
    private static let proofDomain = Data("MIKU-LOCAL-TTS-PROOF-v1\0".utf8)
    private static let leaseDomain = Data("MIKU-LOCAL-TTS-LEASE-v1\0".utf8)
    private static let keyDomain = Data("MIKU-LOCAL-TTS-KEY-v1\0".utf8)
    private static let attestDomain = Data("MIKU-LOCAL-TTS-ATTEST-v1\0".utf8)

    enum Operation: String {
        case enroll
        case renew
    }

    struct ProofPayload: Equatable {
        let operation: Operation
        let challengeID: String
        let nonce: String
        let deviceID: String
        let releaseID: String
        let signingPublicKey: String
        let agreementPublicKey: String
        let activationToken: String?

        func canonicalData() throws -> Data {
            var fields: [String: CanonicalJSON.Value] = [
                "v": .integer(1),
                "op": .string(operation.rawValue),
                "challenge_id": .string(challengeID),
                "nonce": .string(nonce),
                "device_id": .string(deviceID),
                "release_id": .string(releaseID),
                "signing_public_key": .string(signingPublicKey),
                "agreement_public_key": .string(agreementPublicKey),
            ]
            switch (operation, activationToken) {
            case (.enroll, let token?):
                fields["activation_token"] = .string(token)
            case (.renew, nil):
                break
            default:
                throw MikuLocalTTSAuthorizationError.invalidFormat("activation_token 與 op 不符")
            }
            try Self.validateBaseFields(self)
            return try CanonicalJSON.encode(.object(fields))
        }

        private static func validateBaseFields(_ value: ProofPayload) throws {
            try Base64URL.decode(value.challengeID, exactLength: 32)
            try Base64URL.decode(value.nonce, exactLength: 32)
            if let activationToken = value.activationToken {
                try Base64URL.decode(activationToken, exactLength: 32)
            }
            let signing = try Base64URL.decode(value.signingPublicKey, exactLength: 65)
            let agreement = try Base64URL.decode(value.agreementPublicKey, exactLength: 65)
            guard signing.first == 4, agreement.first == 4 else {
                throw MikuLocalTTSAuthorizationError.invalidFormat("P-256 公鑰不是 X9.63 uncompressed 格式")
            }
            do {
                _ = try P256.Signing.PublicKey(x963Representation: signing)
                _ = try P256.KeyAgreement.PublicKey(x963Representation: agreement)
            } catch {
                throw MikuLocalTTSAuthorizationError.invalidFormat("P-256 公鑰無效")
            }
            guard value.releaseID.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$"#, options: .regularExpression) != nil else {
                throw MikuLocalTTSAuthorizationError.invalidFormat("release_id 無效")
            }
            guard value.deviceID == MikuLocalTTSProtocol.deviceID(signingPublicKey: signing, agreementPublicKey: agreement) else {
                throw MikuLocalTTSAuthorizationError.invalidFormat("device_id 與公鑰不符")
            }
        }
    }

    static func deviceID(signingPublicKey: Data, agreementPublicKey: Data) -> String {
        var material = deviceDomain
        material.append(signingPublicKey)
        material.append(agreementPublicKey)
        return SHA256.hash(data: material).map { String(format: "%02x", $0) }.joined()
    }

    static func proofMessage(_ payload: ProofPayload) throws -> Data {
        var message = proofDomain
        message.append(try payload.canonicalData())
        return message
    }

    static func appAttestClientDataHash(payload: ProofPayload, proofDER: Data) throws -> Data {
        var message = attestDomain
        message.append(try payload.canonicalData())
        message.append(0)
        message.append(proofDER)
        return Data(SHA256.hash(data: message))
    }

    static func leaseMessage(rawPayload: Data) -> Data {
        var message = leaseDomain
        message.append(rawPayload)
        return message
    }

    static func keyContext(
        deviceID: String,
        releaseID: String,
        manifestSHA256: String,
        leaseID: String
    ) -> Data {
        var context = keyDomain
        for (index, value) in [deviceID, releaseID, manifestSHA256, leaseID].enumerated() {
            context.append(Data(value.utf8))
            if index < 3 { context.append(0) }
        }
        return context
    }
}

enum Base64URL {
    static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    @discardableResult
    static func decode(_ text: String, exactLength: Int? = nil, maximumCharacters: Int = 8_192) throws -> Data {
        guard !text.isEmpty, text.utf8.count <= maximumCharacters,
              text.unicodeScalars.allSatisfy({ $0.isASCII }),
              text.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil,
              !text.contains("=") else {
            throw MikuLocalTTSAuthorizationError.invalidFormat("base64url 必須是無 padding ASCII")
        }
        let remainder = text.utf8.count % 4
        guard remainder != 1 else {
            throw MikuLocalTTSAuthorizationError.invalidFormat("base64url 長度無效")
        }
        var standard = text.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        if remainder != 0 { standard.append(String(repeating: "=", count: 4 - remainder)) }
        guard let decoded = Data(base64Encoded: standard), encode(decoded) == text else {
            throw MikuLocalTTSAuthorizationError.invalidFormat("非 canonical base64url")
        }
        if let exactLength, decoded.count != exactLength {
            throw MikuLocalTTSAuthorizationError.invalidFormat("base64url byte 長度不符")
        }
        return decoded
    }
}

enum CanonicalJSON {
    indirect enum Value: Equatable {
        case object([String: Value])
        case string(String)
        case integer(Int64)
    }

    static func encode(_ value: Value) throws -> Data {
        Data(try encodeString(value).utf8)
    }

    static func decodeCanonical(_ data: Data, maximumBytes: Int = 8_192) throws -> Value {
        let value = try decode(data, maximumBytes: maximumBytes)
        guard try encode(value) == data else {
            throw MikuLocalTTSAuthorizationError.invalidFormat("JSON 不是 canonical 格式")
        }
        return value
    }

    static func decode(_ data: Data, maximumBytes: Int = 8_192) throws -> Value {
        guard !data.isEmpty, data.count <= maximumBytes else {
            throw MikuLocalTTSAuthorizationError.invalidFormat("JSON 大小無效")
        }
        var parser = Parser(data: data)
        return try parser.parse()
    }

    private static func encodeString(_ value: Value) throws -> String {
        switch value {
        case .integer(let number):
            return String(number)
        case .string(let text):
            var result = "\""
            for scalar in text.unicodeScalars {
                guard scalar.isASCII else {
                    throw MikuLocalTTSAuthorizationError.invalidFormat("協定 JSON 字串必須是 ASCII")
                }
                switch scalar.value {
                case 0x22: result += "\\\""
                case 0x5C: result += "\\\\"
                case 0x08: result += "\\b"
                case 0x09: result += "\\t"
                case 0x0A: result += "\\n"
                case 0x0C: result += "\\f"
                case 0x0D: result += "\\r"
                case 0x00...0x1F, 0x7F...0xFFFF:
                    result += String(format: "\\u%04x", scalar.value)
                default:
                    result.unicodeScalars.append(scalar)
                }
            }
            return result + "\""
        case .object(let object):
            let entries = try object.keys.sorted().map { key in
                try encodeString(.string(key)) + ":" + encodeString(object[key]!)
            }
            return "{" + entries.joined(separator: ",") + "}"
        }
    }

    private struct Parser {
        let bytes: [UInt8]
        var index = 0

        init(data: Data) { bytes = Array(data) }

        mutating func parse() throws -> Value {
            skipWhitespace()
            let value = try parseValue()
            skipWhitespace()
            guard index == bytes.count else { throw invalid() }
            return value
        }

        mutating func parseValue() throws -> Value {
            guard index < bytes.count else { throw invalid() }
            if bytes[index] == 0x7B { return try parseObject() }
            if bytes[index] == 0x22 { return .string(try parseString()) }
            return .integer(try parseInteger())
        }

        mutating func parseObject() throws -> Value {
            index += 1
            var result: [String: Value] = [:]
            skipWhitespace()
            if consume(0x7D) { return .object(result) }
            while true {
                guard consume(0x22) else { throw invalid() }
                index -= 1
                let key = try parseString()
                skipWhitespace()
                guard result[key] == nil, consume(0x3A) else { throw invalid() }
                skipWhitespace()
                result[key] = try parseValue()
                skipWhitespace()
                if consume(0x7D) { return .object(result) }
                guard consume(0x2C) else { throw invalid() }
                skipWhitespace()
            }
        }

        mutating func parseString() throws -> String {
            guard consume(0x22) else { throw invalid() }
            var scalars: [UnicodeScalar] = []
            while index < bytes.count {
                let byte = bytes[index]
                index += 1
                if byte == 0x22 { return String(String.UnicodeScalarView(scalars)) }
                if byte == 0x5C {
                    guard index < bytes.count else { throw invalid() }
                    let escape = bytes[index]
                    index += 1
                    switch escape {
                    case 0x22: scalars.append("\"")
                    case 0x5C: scalars.append("\\")
                    case 0x62: scalars.append("\u{8}")
                    case 0x74: scalars.append("\t")
                    case 0x6E: scalars.append("\n")
                    case 0x66: scalars.append("\u{c}")
                    case 0x72: scalars.append("\r")
                    case 0x75:
                        guard index + 4 <= bytes.count,
                              let value = UInt32(String(decoding: bytes[index..<(index + 4)], as: UTF8.self), radix: 16),
                              let scalar = UnicodeScalar(value), !(0xD800...0xDFFF).contains(value) else { throw invalid() }
                        scalars.append(scalar)
                        index += 4
                    default: throw invalid()
                    }
                } else {
                    guard byte >= 0x20, byte < 0x80 else { throw invalid() }
                    scalars.append(UnicodeScalar(byte))
                }
            }
            throw invalid()
        }

        mutating func parseInteger() throws -> Int64 {
            let start = index
            if consume(0x2D) { }
            guard index < bytes.count else { throw invalid() }
            if consume(0x30) {
                guard index == bytes.count || !(0x30...0x39).contains(bytes[index]) else { throw invalid() }
            } else {
                guard (0x31...0x39).contains(bytes[index]) else { throw invalid() }
                repeat { index += 1 } while index < bytes.count && (0x30...0x39).contains(bytes[index])
            }
            guard let value = Int64(String(decoding: bytes[start..<index], as: UTF8.self)) else { throw invalid() }
            return value
        }

        mutating func consume(_ byte: UInt8) -> Bool {
            guard index < bytes.count, bytes[index] == byte else { return false }
            index += 1
            return true
        }

        mutating func skipWhitespace() {
            while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) {
                index += 1
            }
        }

        func invalid() -> MikuLocalTTSAuthorizationError {
            .invalidFormat("無效或不支援的 JSON")
        }
    }
}

protocol MikuAgreementPrivateKey {
    var publicKeyX963: Data { get }
    func sharedSecret(with peerX963: Data) throws -> SharedSecret
}

struct MikuSoftwareAgreementPrivateKey: MikuAgreementPrivateKey {
    let key: P256.KeyAgreement.PrivateKey
    var publicKeyX963: Data { key.publicKey.x963Representation }
    func sharedSecret(with peerX963: Data) throws -> SharedSecret {
        try key.sharedSecretFromKeyAgreement(with: P256.KeyAgreement.PublicKey(x963Representation: peerX963))
    }
}

struct MikuSecureEnclaveAgreementPrivateKey: MikuAgreementPrivateKey {
    let key: SecureEnclave.P256.KeyAgreement.PrivateKey
    var publicKeyX963: Data { key.publicKey.x963Representation }
    func sharedSecret(with peerX963: Data) throws -> SharedSecret {
        try key.sharedSecretFromKeyAgreement(with: P256.KeyAgreement.PublicKey(x963Representation: peerX963))
    }
}

struct MikuDeviceIdentity {
    let signingPublicKey: String
    let agreementPublicKey: String
    let deviceID: String
}

final class MikuSecureEnclaveDeviceKeys {
    private let signingKey: SecureEnclave.P256.Signing.PrivateKey
    private let agreementKey: SecureEnclave.P256.KeyAgreement.PrivateKey

    init(service: String = "com.qimake.MikuDesktop.local-tts.keys") throws {
        guard SecureEnclave.isAvailable else {
            throw MikuLocalTTSAuthorizationError.secureEnclaveUnavailable
        }
        let context = LAContext()
        context.interactionNotAllowed = true
        signingKey = try Self.loadOrCreateSigning(service: service, context: context)
        agreementKey = try Self.loadOrCreateAgreement(service: service, context: context)
    }

    var identity: MikuDeviceIdentity {
        let signing = signingKey.publicKey.x963Representation
        let agreement = agreementKey.publicKey.x963Representation
        return MikuDeviceIdentity(
            signingPublicKey: Base64URL.encode(signing),
            agreementPublicKey: Base64URL.encode(agreement),
            deviceID: MikuLocalTTSProtocol.deviceID(signingPublicKey: signing, agreementPublicKey: agreement)
        )
    }

    func signProof(_ payload: MikuLocalTTSProtocol.ProofPayload) throws -> Data {
        try signingKey.signature(for: MikuLocalTTSProtocol.proofMessage(payload)).derRepresentation
    }

    var agreementPrivateKey: MikuAgreementPrivateKey {
        MikuSecureEnclaveAgreementPrivateKey(key: agreementKey)
    }

    private static func loadOrCreateSigning(service: String, context: LAContext) throws -> SecureEnclave.P256.Signing.PrivateKey {
        if let data = try KeychainStore.read(service: service, account: "p256-signing-reference") {
            return try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: data, authenticationContext: context)
        }
        let key = try SecureEnclave.P256.Signing.PrivateKey(accessControl: try privateKeyAccessControl(), authenticationContext: context)
        try KeychainStore.write(key.dataRepresentation, service: service, account: "p256-signing-reference")
        return key
    }

    private static func loadOrCreateAgreement(service: String, context: LAContext) throws -> SecureEnclave.P256.KeyAgreement.PrivateKey {
        if let data = try KeychainStore.read(service: service, account: "p256-agreement-reference") {
            return try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: data, authenticationContext: context)
        }
        let key = try SecureEnclave.P256.KeyAgreement.PrivateKey(accessControl: try privateKeyAccessControl(), authenticationContext: context)
        try KeychainStore.write(key.dataRepresentation, service: service, account: "p256-agreement-reference")
        return key
    }

    private static func privateKeyAccessControl() throws -> SecAccessControl {
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            .privateKeyUsage,
            &error
        ) else {
            throw error!.takeRetainedValue() as Error
        }
        return access
    }
}

enum KeychainStore {
    static func read(service: String, account: String) throws -> Data? {
        var query = baseQuery(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let item = result as? [String: Any] else {
            throw MikuLocalTTSAuthorizationError.keychainFailure(status)
        }
        guard item[kSecAttrAccessible as String] as? String == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String,
              let data = item[kSecValueData as String] as? Data else {
            throw MikuLocalTTSAuthorizationError.authorizationDenied("Keychain item 不是 WhenUnlockedThisDeviceOnly")
        }
        return data
    }

    static func write(_ data: Data, service: String, account: String) throws {
        var query = baseQuery(service: service, account: account)
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
        if try read(service: service, account: account) != nil {
            let update: [String: Any] = [kSecValueData as String: data]
            let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
            guard status == errSecSuccess else {
                throw MikuLocalTTSAuthorizationError.keychainFailure(status)
            }
            return
        }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw MikuLocalTTSAuthorizationError.keychainFailure(addStatus)
        }
    }

    private static func baseQuery(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
    }
}

struct MikuLeasePayload: Equatable {
    let deviceID: String
    let releaseID: String
    let manifestSHA256: String
    let challengeID: String
    let leaseID: String
    let issuedAt: Int64
    let expiresAt: Int64
    let ephemeralPublicKey: Data
    let salt: Data
    let nonce: Data
    let ciphertextAndTag: Data
}

struct MikuVerifiedLease {
    let payload: MikuLeasePayload
    let dek: Data
}

struct MikuLeaseVerifier {
    private let trustedKeys: [String: Curve25519.Signing.PublicKey]

    static func production() throws -> MikuLeaseVerifier {
        // 正式 pin 必須編入已簽署程式；未設定時維持 fail-closed。
        let pinnedRawKeys: [Data] = []
        return try MikuLeaseVerifier(rawTrustedKeys: pinnedRawKeys)
    }

    init(rawTrustedKeys: [Data]) throws {
        var keys: [String: Curve25519.Signing.PublicKey] = [:]
        for raw in rawTrustedKeys {
            guard raw.count == 32 else {
                throw MikuLocalTTSAuthorizationError.invalidFormat("Ed25519 公鑰長度無效")
            }
            let kid = SHA256.hash(data: raw).prefix(8).map { String(format: "%02x", $0) }.joined()
            guard keys[kid] == nil else {
                throw MikuLocalTTSAuthorizationError.invalidFormat("重複 lease key id")
            }
            keys[kid] = try Curve25519.Signing.PublicKey(rawRepresentation: raw)
        }
        trustedKeys = keys
    }

    func verifyAndUnwrap(
        envelopeData: Data,
        agreementKey: MikuAgreementPrivateKey,
        expectedDeviceID: String,
        expectedReleaseID: String,
        expectedManifestSHA256: String,
        expectedChallengeID: String,
        now: Int64
    ) throws -> MikuVerifiedLease {
        let envelope = try object(try CanonicalJSON.decode(envelopeData))
        try requireExactKeys(envelope, ["kid", "payload", "signature"])
        let kid = try string(envelope, "kid")
        guard kid.utf8.count == 16, let signingKey = trustedKeys[kid] else {
            throw MikuLocalTTSAuthorizationError.authorizationDenied("lease kid 不受信任")
        }
        let rawPayload = try Base64URL.decode(try string(envelope, "payload"), maximumCharacters: 8_192)
        let signature = try Base64URL.decode(try string(envelope, "signature"), exactLength: 64, maximumCharacters: 128)
        guard signingKey.isValidSignature(signature, for: MikuLocalTTSProtocol.leaseMessage(rawPayload: rawPayload)) else {
            throw MikuLocalTTSAuthorizationError.authorizationDenied("lease 簽章無效")
        }
        let fields = try object(try CanonicalJSON.decodeCanonical(rawPayload))
        try requireExactKeys(fields, [
            "v", "product", "device_id", "release_id", "manifest_sha256", "challenge_id",
            "lease_id", "issued_at", "expires_at", "key_envelope",
        ])
        guard try integer(fields, "v") == 1, try string(fields, "product") == MikuLocalTTSProtocol.product else {
            throw MikuLocalTTSAuthorizationError.invalidFormat("lease 版本或產品無效")
        }
        try requireEqual(fields, "device_id", expectedDeviceID)
        try requireEqual(fields, "release_id", expectedReleaseID)
        try requireEqual(fields, "manifest_sha256", expectedManifestSHA256)
        try requireEqual(fields, "challenge_id", expectedChallengeID)
        guard expectedManifestSHA256.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil else {
            throw MikuLocalTTSAuthorizationError.invalidFormat("manifest_sha256 無效")
        }
        try Base64URL.decode(expectedChallengeID, exactLength: 32)
        let leaseID = try string(fields, "lease_id")
        try Base64URL.decode(leaseID, exactLength: 32)
        let issuedAt = try integer(fields, "issued_at")
        let expiresAt = try integer(fields, "expires_at")
        let (leaseLifetime, leaseLifetimeOverflow) = expiresAt.subtractingReportingOverflow(issuedAt)
        guard !leaseLifetimeOverflow, leaseLifetime > 0,
              leaseLifetime <= MikuLocalTTSProtocol.maximumLeaseLifetime else {
            throw MikuLocalTTSAuthorizationError.authorizationDenied("lease TTL 超出限制")
        }
        guard now >= issuedAt, now < expiresAt else {
            throw MikuLocalTTSAuthorizationError.authorizationDenied("lease 尚未生效或已過期")
        }

        let keyEnvelope = try object(fields["key_envelope"] ?? invalidValue())
        try requireExactKeys(keyEnvelope, ["alg", "ephemeral_public_key", "salt", "nonce", "ciphertext"])
        guard try string(keyEnvelope, "alg") == "P256-HKDF-SHA256-A256GCM" else {
            throw MikuLocalTTSAuthorizationError.invalidFormat("key envelope 演算法無效")
        }
        let ephemeral = try Base64URL.decode(try string(keyEnvelope, "ephemeral_public_key"), exactLength: 65)
        guard ephemeral.first == 4 else {
            throw MikuLocalTTSAuthorizationError.invalidFormat("ephemeral P-256 公鑰格式無效")
        }
        let salt = try Base64URL.decode(try string(keyEnvelope, "salt"), exactLength: 32)
        let nonce = try Base64URL.decode(try string(keyEnvelope, "nonce"), exactLength: 12)
        let combined = try Base64URL.decode(try string(keyEnvelope, "ciphertext"), exactLength: 48)
        let context = MikuLocalTTSProtocol.keyContext(
            deviceID: expectedDeviceID,
            releaseID: expectedReleaseID,
            manifestSHA256: expectedManifestSHA256,
            leaseID: leaseID
        )
        let secret = try agreementKey.sharedSecret(with: ephemeral)
        let wrappingKey = secret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: salt,
            sharedInfo: context,
            outputByteCount: 32
        )
        let sealed = try AES.GCM.SealedBox(
            nonce: AES.GCM.Nonce(data: nonce),
            ciphertext: combined.dropLast(16),
            tag: combined.suffix(16)
        )
        let dek: Data
        do {
            dek = try AES.GCM.open(sealed, using: wrappingKey, authenticating: context)
        } catch {
            throw MikuLocalTTSAuthorizationError.authorizationDenied("key envelope 無法由此裝置解開")
        }
        guard dek.count == 32 else {
            throw MikuLocalTTSAuthorizationError.invalidFormat("DEK 長度無效")
        }
        return MikuVerifiedLease(
            payload: MikuLeasePayload(
                deviceID: expectedDeviceID,
                releaseID: expectedReleaseID,
                manifestSHA256: expectedManifestSHA256,
                challengeID: expectedChallengeID,
                leaseID: leaseID,
                issuedAt: issuedAt,
                expiresAt: expiresAt,
                ephemeralPublicKey: ephemeral,
                salt: salt,
                nonce: nonce,
                ciphertextAndTag: combined
            ),
            dek: dek
        )
    }

    private func requireEqual(_ object: [String: CanonicalJSON.Value], _ name: String, _ expected: String) throws {
        guard try string(object, name) == expected else {
            throw MikuLocalTTSAuthorizationError.authorizationDenied("lease \(name) 綁定不符")
        }
    }

    private func requireExactKeys(_ object: [String: CanonicalJSON.Value], _ names: Set<String>) throws {
        guard Set(object.keys) == names else {
            throw MikuLocalTTSAuthorizationError.invalidFormat("欄位缺漏或包含未知欄位")
        }
    }

    private func object(_ value: CanonicalJSON.Value) throws -> [String: CanonicalJSON.Value] {
        guard case .object(let object) = value else {
            throw MikuLocalTTSAuthorizationError.invalidFormat("JSON 必須是 object")
        }
        return object
    }

    private func string(_ object: [String: CanonicalJSON.Value], _ name: String) throws -> String {
        guard case .string(let value)? = object[name] else {
            throw MikuLocalTTSAuthorizationError.invalidFormat("\(name) 格式無效")
        }
        return value
    }

    private func integer(_ object: [String: CanonicalJSON.Value], _ name: String) throws -> Int64 {
        guard case .integer(let value)? = object[name] else {
            throw MikuLocalTTSAuthorizationError.invalidFormat("\(name) 格式無效")
        }
        return value
    }

    private func invalidValue() -> CanonicalJSON.Value { .string("") }
}

struct MikuLeaseClockState: Codable, Equatable {
    let version: Int
    let bootID: String
    let acceptedWallTime: Int64
    let acceptedContinuousNanoseconds: UInt64
    let expiresAt: Int64
    let leaseID: String
    let acceptedIssuedAt: Int64
    let highWaterIssuedAt: Int64
}

protocol MikuLeaseClockStateStore {
    func load() throws -> MikuLeaseClockState?
    func save(_ state: MikuLeaseClockState) throws
}

struct MikuKeychainLeaseClockStateStore: MikuLeaseClockStateStore {
    let service: String
    let account: String

    init(service: String = "com.qimake.MikuDesktop.local-tts.clock", account: String = "lease-clock-anchor") {
        self.service = service
        self.account = account
    }

    func load() throws -> MikuLeaseClockState? {
        guard let data = try KeychainStore.read(service: service, account: account) else { return nil }
        return try JSONDecoder().decode(MikuLeaseClockState.self, from: data)
    }

    func save(_ state: MikuLeaseClockState) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try KeychainStore.write(try encoder.encode(state), service: service, account: account)
    }
}

@MainActor
struct MikuLeaseClock {
    let store: MikuLeaseClockStateStore

    func acceptOnline(
        _ lease: MikuLeasePayload,
        wallTime: Int64,
        bootID: String,
        continuousNanoseconds: UInt64
    ) throws {
        guard wallTime >= lease.issuedAt, wallTime < lease.expiresAt else {
            throw MikuLocalTTSAuthorizationError.authorizationDenied("lease 尚未生效或已過期")
        }
        let (leaseLifetime, leaseLifetimeOverflow) = lease.expiresAt.subtractingReportingOverflow(lease.issuedAt)
        guard !leaseLifetimeOverflow, leaseLifetime > 0,
              leaseLifetime <= MikuLocalTTSProtocol.maximumLeaseLifetime else {
            throw MikuLocalTTSAuthorizationError.authorizationDenied("lease TTL 超出限制")
        }
        let previous = try store.load()
        if let previous {
            guard lease.leaseID != previous.leaseID else {
                throw MikuLocalTTSAuthorizationError.authorizationDenied("相同 lease 不可重建 clock anchor")
            }
            guard lease.issuedAt > previous.highWaterIssuedAt else {
                throw MikuLocalTTSAuthorizationError.authorizationDenied("lease issued_at 未高於 high-water")
            }
        }
        try store.save(MikuLeaseClockState(
            version: 1,
            bootID: bootID,
            acceptedWallTime: wallTime,
            acceptedContinuousNanoseconds: continuousNanoseconds,
            expiresAt: lease.expiresAt,
            leaseID: lease.leaseID,
            acceptedIssuedAt: lease.issuedAt,
            highWaterIssuedAt: lease.issuedAt
        ))
    }

    func authorizeOffline(
        _ lease: MikuLeasePayload,
        bootID: String,
        continuousNanoseconds: UInt64
    ) throws {
        guard let state = try store.load(), state.version == 1 else {
            throw MikuLocalTTSAuthorizationError.authorizationDenied("缺少 lease clock anchor，必須連線")
        }
        guard state.bootID == bootID else {
            throw MikuLocalTTSAuthorizationError.authorizationDenied("重開機後必須連線")
        }
        guard state.leaseID == lease.leaseID,
              state.acceptedIssuedAt == lease.issuedAt,
              state.expiresAt == lease.expiresAt,
              lease.issuedAt >= state.highWaterIssuedAt else {
            throw MikuLocalTTSAuthorizationError.authorizationDenied("lease 與 clock anchor 不符")
        }
        guard continuousNanoseconds >= state.acceptedContinuousNanoseconds else {
            throw MikuLocalTTSAuthorizationError.authorizationDenied("continuous clock 回退")
        }
        let (lifetime, lifetimeOverflow) = state.expiresAt.subtractingReportingOverflow(state.acceptedWallTime)
        guard !lifetimeOverflow, lifetime > 0,
              lifetime <= MikuLocalTTSProtocol.maximumLeaseLifetime else {
            throw MikuLocalTTSAuthorizationError.authorizationDenied("lease 已過期")
        }
        let elapsed = continuousNanoseconds - state.acceptedContinuousNanoseconds
        let (limit, limitOverflow) = UInt64(lifetime).multipliedReportingOverflow(by: 1_000_000_000)
        guard !limitOverflow else {
            throw MikuLocalTTSAuthorizationError.authorizationDenied("lease clock anchor 無效")
        }
        guard elapsed < limit else {
            throw MikuLocalTTSAuthorizationError.authorizationDenied("lease 已由 continuous clock 判定過期")
        }
    }

    static func currentContinuousNanoseconds() -> UInt64 {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        let ticks = mach_continuous_time()
        let product = ticks.multipliedFullWidth(by: UInt64(info.numer))
        let (nanoseconds, _) = UInt64(info.denom).dividingFullWidth(product)
        return nanoseconds
    }

    static func currentBootID() throws -> String {
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 1 else {
            throw MikuLocalTTSAuthorizationError.authorizationDenied("無法讀取 boot identity")
        }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.bootsessionuuid", &buffer, &size, nil, 0) == 0 else {
            throw MikuLocalTTSAuthorizationError.authorizationDenied("無法讀取 boot identity")
        }
        let value = String(cString: buffer)
        guard !value.isEmpty else {
            throw MikuLocalTTSAuthorizationError.authorizationDenied("boot identity 為空")
        }
        return value
    }
}

struct MikuSigningReadinessGate {
    struct Requirement {
        let teamID: String
        let identifier: String
    }

    static func checkCurrentApplication(_ requirement: Requirement) throws {
        let codeRequirement = try makeCodeRequirement(requirement)
        var current: SecCode?
        guard SecCodeCopySelf([], &current) == errSecSuccess, let current else {
            throw MikuLocalTTSAuthorizationError.signingNotReady("無法取得 current code")
        }
        let dynamicFlags = SecCSFlags(rawValue: kSecCSStrictValidate)
        guard SecCodeCheckValidity(current, dynamicFlags, codeRequirement) == errSecSuccess else {
            throw MikuLocalTTSAuthorizationError.signingNotReady("current code signature 無效")
        }
        var currentStatic: SecStaticCode?
        guard SecCodeCopyStaticCode(current, [], &currentStatic) == errSecSuccess, let currentStatic else {
            throw MikuLocalTTSAuthorizationError.signingNotReady("無法取得 current static code")
        }
        try validate(staticCode: currentStatic, requirement: requirement, codeRequirement: codeRequirement)

        guard Bundle.main.bundleURL.pathExtension == "app" else {
            throw MikuLocalTTSAuthorizationError.signingNotReady("必須由 .app bundle 啟動")
        }
        var embedded: SecStaticCode?
        let status = SecStaticCodeCreateWithPath(Bundle.main.bundleURL as CFURL, [], &embedded)
        guard status == errSecSuccess, let embedded else {
            throw MikuLocalTTSAuthorizationError.signingNotReady("無法取得 embedded static code")
        }
        try validate(staticCode: embedded, requirement: requirement, codeRequirement: codeRequirement)
    }

    static func makeCodeRequirement(_ requirement: Requirement) throws -> SecRequirement {
        guard requirement.teamID.range(of: #"^[A-Z0-9]{10}$"#, options: .regularExpression) != nil,
              requirement.identifier.range(
                of: #"^[A-Za-z0-9][A-Za-z0-9.-]{0,254}$"#,
                options: .regularExpression
              ) != nil else {
            throw MikuLocalTTSAuthorizationError.signingNotReady("Team ID 或 identifier 格式無效")
        }
        let expression = """
        anchor apple generic and identifier "\(requirement.identifier)" and \
        certificate leaf[subject.OU] = "\(requirement.teamID)" and \
        certificate leaf[field.1.2.840.113635.100.6.1.13] exists
        """
        var codeRequirement: SecRequirement?
        let status = SecRequirementCreateWithString(expression as CFString, [], &codeRequirement)
        guard status == errSecSuccess, let codeRequirement else {
            throw MikuLocalTTSAuthorizationError.signingNotReady("無法建立 Developer ID requirement")
        }
        return codeRequirement
    }

    private static func validate(
        staticCode: SecStaticCode,
        requirement: Requirement,
        codeRequirement: SecRequirement
    ) throws {
        let staticFlags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures)
        guard SecStaticCodeCheckValidity(staticCode, staticFlags, codeRequirement) == errSecSuccess else {
            throw MikuLocalTTSAuthorizationError.signingNotReady("code signature 無效")
        }
        var rawInfo: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &rawInfo) == errSecSuccess,
              let info = rawInfo as? [String: Any] else {
            throw MikuLocalTTSAuthorizationError.signingNotReady("無法讀取 code signature")
        }
        guard info[kSecCodeInfoTeamIdentifier as String] as? String == requirement.teamID,
              info[kSecCodeInfoIdentifier as String] as? String == requirement.identifier else {
            throw MikuLocalTTSAuthorizationError.signingNotReady("Team ID 或 identifier 不符")
        }
        let flags = (info[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        let adHocFlag: UInt32 = 0x0000_0002
        let hardenedRuntimeFlag: UInt32 = 0x0001_0000
        guard flags & adHocFlag == 0,
              flags & hardenedRuntimeFlag != 0 else {
            throw MikuLocalTTSAuthorizationError.signingNotReady("必須使用非 ad-hoc Hardened Runtime 簽署")
        }
        let entitlements = info[kSecCodeInfoEntitlementsDict as String] as? [String: Any] ?? [:]
        for forbidden in [
            "com.apple.security.get-task-allow",
            "com.apple.security.cs.disable-library-validation",
            "com.apple.security.cs.allow-dyld-environment-variables",
            "com.apple.security.cs.allow-unsigned-executable-memory",
        ] where entitlements[forbidden] as? Bool == true {
            throw MikuLocalTTSAuthorizationError.signingNotReady("包含不允許的 entitlement：\(forbidden)")
        }
    }
}

#if canImport(DeviceCheck)
@available(macOS 27.0, *)
final class MikuAppAttestClient {
    private let service = DCAppAttestService.shared

    var isSupported: Bool {
        Bundle.main.bundleURL.pathExtension == "app" && service.isSupported
    }

    func generateKey() async throws -> String {
        guard isSupported else { throw MikuLocalTTSAuthorizationError.appAttestUnavailable }
        return try await withCheckedThrowingContinuation { continuation in
            service.generateKey { keyID, error in
                if let keyID { continuation.resume(returning: keyID) }
                else { continuation.resume(throwing: error ?? MikuLocalTTSAuthorizationError.appAttestUnavailable) }
            }
        }
    }

    func attest(keyID: String, clientDataHash: Data) async throws -> [String: String] {
        guard isSupported else { throw MikuLocalTTSAuthorizationError.appAttestUnavailable }
        let object = try await withCheckedThrowingContinuation { continuation in
            service.attestKey(keyID, clientDataHash: clientDataHash) { data, error in
                if let data { continuation.resume(returning: data) }
                else { continuation.resume(throwing: error ?? MikuLocalTTSAuthorizationError.appAttestUnavailable) }
            }
        }
        return try opaqueObject(keyID: keyID, object: object)
    }

    func assertion(keyID: String, clientDataHash: Data) async throws -> [String: String] {
        guard isSupported else { throw MikuLocalTTSAuthorizationError.appAttestUnavailable }
        let object = try await withCheckedThrowingContinuation { continuation in
            service.generateAssertion(keyID, clientDataHash: clientDataHash) { data, error in
                if let data { continuation.resume(returning: data) }
                else { continuation.resume(throwing: error ?? MikuLocalTTSAuthorizationError.appAttestUnavailable) }
            }
        }
        return try opaqueObject(keyID: keyID, object: object)
    }

    private func opaqueObject(keyID: String, object: Data) throws -> [String: String] {
        guard let decodedKeyID = Data(base64Encoded: keyID), decodedKeyID.base64EncodedString() == keyID else {
            throw MikuLocalTTSAuthorizationError.invalidFormat("Apple App Attest key ID 無效")
        }
        return ["key_id": Base64URL.encode(decodedKeyID), "object": Base64URL.encode(object)]
    }
}
#endif
