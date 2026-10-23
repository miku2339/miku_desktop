import CryptoKit
import Foundation
import LocalAuthentication

private enum TestFailure: Error {
    case assertion(String)
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw TestFailure.assertion(message) }
}

private func expectThrows(_ message: String, _ body: () throws -> Void) throws {
    do {
        try body()
        throw TestFailure.assertion(message)
    } catch is TestFailure {
        throw TestFailure.assertion(message)
    } catch { }
}

private final class MemoryClockStore: MikuLeaseClockStateStore {
    var state: MikuLeaseClockState?
    func load() throws -> MikuLeaseClockState? { state }
    func save(_ state: MikuLeaseClockState) throws { self.state = state }
}

private struct LeaseFixture {
    let signingKey: Curve25519.Signing.PrivateKey
    let agreementKey: MikuSoftwareAgreementPrivateKey
    let deviceID: String
    let releaseID = "release-1"
    let manifest = String(repeating: "a", count: 64)
    let challengeID = Base64URL.encode(Data(repeating: 0x43, count: 32))
    let leaseID = Base64URL.encode(Data(repeating: 0x4C, count: 32))
    let dek = Data(repeating: 0xD3, count: 32)

    init() throws {
        signingKey = Curve25519.Signing.PrivateKey()
        agreementKey = MikuSoftwareAgreementPrivateKey(key: P256.KeyAgreement.PrivateKey())
        let signingDeviceKey = P256.Signing.PrivateKey().publicKey.x963Representation
        deviceID = MikuLocalTTSProtocol.deviceID(
            signingPublicKey: signingDeviceKey,
            agreementPublicKey: agreementKey.publicKeyX963
        )
    }

    func verifier() throws -> MikuLeaseVerifier {
        try MikuLeaseVerifier(rawTrustedKeys: [signingKey.publicKey.rawRepresentation])
    }

    func makeEnvelope(
        deviceID: String? = nil,
        releaseID: String? = nil,
        manifest: String? = nil,
        challengeID: String? = nil,
        leaseID: String? = nil,
        issuedAt: Int64 = 1_000,
        expiresAt: Int64 = 4_600,
        sign: Bool = true,
        kid: String? = nil
    ) throws -> Data {
        let deviceID = deviceID ?? self.deviceID
        let releaseID = releaseID ?? self.releaseID
        let manifest = manifest ?? self.manifest
        let challengeID = challengeID ?? self.challengeID
        let leaseID = leaseID ?? self.leaseID
        let ephemeral = P256.KeyAgreement.PrivateKey()
        let salt = Data(repeating: 0x53, count: 32)
        let nonceData = Data(repeating: 0x4E, count: 12)
        let context = MikuLocalTTSProtocol.keyContext(
            deviceID: deviceID,
            releaseID: releaseID,
            manifestSHA256: manifest,
            leaseID: leaseID
        )
        let secret = try ephemeral.sharedSecretFromKeyAgreement(
            with: P256.KeyAgreement.PublicKey(x963Representation: agreementKey.publicKeyX963)
        )
        let wrappingKey = secret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: salt,
            sharedInfo: context,
            outputByteCount: 32
        )
        let sealed = try AES.GCM.seal(
            dek,
            using: wrappingKey,
            nonce: AES.GCM.Nonce(data: nonceData),
            authenticating: context
        )
        var ciphertextAndTag = sealed.ciphertext
        ciphertextAndTag.append(sealed.tag)
        let payload: CanonicalJSON.Value = .object([
            "v": .integer(1),
            "product": .string(MikuLocalTTSProtocol.product),
            "device_id": .string(deviceID),
            "release_id": .string(releaseID),
            "manifest_sha256": .string(manifest),
            "challenge_id": .string(challengeID),
            "lease_id": .string(leaseID),
            "issued_at": .integer(issuedAt),
            "expires_at": .integer(expiresAt),
            "key_envelope": .object([
                "alg": .string("P256-HKDF-SHA256-A256GCM"),
                "ephemeral_public_key": .string(Base64URL.encode(ephemeral.publicKey.x963Representation)),
                "salt": .string(Base64URL.encode(salt)),
                "nonce": .string(Base64URL.encode(nonceData)),
                "ciphertext": .string(Base64URL.encode(ciphertextAndTag)),
            ]),
        ])
        let rawPayload = try CanonicalJSON.encode(payload)
        var signature = try signingKey.signature(for: MikuLocalTTSProtocol.leaseMessage(rawPayload: rawPayload))
        if !sign { signature[0] ^= 1 }
        let realKid = SHA256.hash(data: signingKey.publicKey.rawRepresentation)
            .prefix(8).map { String(format: "%02x", $0) }.joined()
        return try CanonicalJSON.encode(.object([
            "signature": .string(Base64URL.encode(signature)),
            "payload": .string(Base64URL.encode(rawPayload)),
            "kid": .string(kid ?? realKid),
        ]))
    }

    func verify(_ envelope: Data, now: Int64 = 1_000) throws -> MikuVerifiedLease {
        try verifier().verifyAndUnwrap(
            envelopeData: envelope,
            agreementKey: agreementKey,
            expectedDeviceID: deviceID,
            expectedReleaseID: releaseID,
            expectedManifestSHA256: manifest,
            expectedChallengeID: challengeID,
            now: now
        )
    }
}

private func testBase64AndCanonicalJSON() throws {
    let data = Data([0xFB, 0xFF, 0x00])
    let encoded = Base64URL.encode(data)
    try expect(encoded == "-_8A", "base64url encode")
    let decoded = try Base64URL.decode(encoded)
    try expect(decoded == data, "base64url round trip")
    try expectThrows("padding 必須被拒絕") { _ = try Base64URL.decode("-_8A=") }
    try expectThrows("錯誤尾 bits 必須被拒絕") { _ = try Base64URL.decode("AB") }
    try expectThrows("空值必須被拒絕") { _ = try Base64URL.decode("") }

    let canonical = try CanonicalJSON.encode(.object([
        "z": .string("/") , "a": .integer(1), "escaped": .string("\n"),
    ]))
    try expect(String(decoding: canonical, as: UTF8.self) == #"{"a":1,"escaped":"\n","z":"/"}"#, "canonical JSON")
    _ = try CanonicalJSON.decodeCanonical(canonical)
    try expectThrows("非排序 JSON 必須被拒絕") {
        _ = try CanonicalJSON.decodeCanonical(Data(#"{"z":"/","a":1,"escaped":"\n"}"#.utf8))
    }
    try expectThrows("重複 key 必須被拒絕") {
        _ = try CanonicalJSON.decode(Data(#"{"a":1,"a":2}"#.utf8))
    }
    try expectThrows("slash escape 必須被拒絕為 canonical") {
        _ = try CanonicalJSON.decodeCanonical(Data(#"{"a":"\/"}"#.utf8))
    }
}

private func proofFixture() throws -> (payload: MikuLocalTTSProtocol.ProofPayload, proof: Data) {
    let signing = try P256.Signing.PrivateKey(rawRepresentation: Data(repeating: 1, count: 32))
    let agreement = try P256.KeyAgreement.PrivateKey(rawRepresentation: Data(repeating: 2, count: 32))
    let signingPublic = signing.publicKey.x963Representation
    let agreementPublic = agreement.publicKey.x963Representation
    let payload = MikuLocalTTSProtocol.ProofPayload(
        operation: .enroll,
        challengeID: Base64URL.encode(Data(repeating: 0x11, count: 32)),
        nonce: Base64URL.encode(Data(repeating: 0x22, count: 32)),
        deviceID: MikuLocalTTSProtocol.deviceID(signingPublicKey: signingPublic, agreementPublicKey: agreementPublic),
        releaseID: "release-1",
        signingPublicKey: Base64URL.encode(signingPublic),
        agreementPublicKey: Base64URL.encode(agreementPublic),
        activationToken: Base64URL.encode(Data(repeating: 0x33, count: 32))
    )
    let proof = try signing.signature(for: MikuLocalTTSProtocol.proofMessage(payload)).derRepresentation
    return (payload, proof)
}

private func testProof() throws {
    let fixture = try proofFixture()
    let publicKey = try P256.Signing.PublicKey(
        x963Representation: Base64URL.decode(fixture.payload.signingPublicKey, exactLength: 65)
    )
    let signature = try P256.Signing.ECDSASignature(derRepresentation: fixture.proof)
    let proofMessage = try MikuLocalTTSProtocol.proofMessage(fixture.payload)
    try expect(publicKey.isValidSignature(signature, for: proofMessage), "proof signature")
    let attestHash = try MikuLocalTTSProtocol.appAttestClientDataHash(payload: fixture.payload, proofDER: fixture.proof)
    try expect(attestHash.count == 32, "App Attest hash")
    let raw = String(decoding: try fixture.payload.canonicalData(), as: UTF8.self)
    try expect(raw.hasPrefix(#"{"activation_token":"#), "proof key ordering")
    try expect(raw.contains(#""v":1}"#), "proof version")
}

private func testLeaseVerification() throws {
    let fixture = try LeaseFixture()
    let verified = try fixture.verify(fixture.makeEnvelope())
    try expect(verified.dek == fixture.dek, "DEK round trip")
    try expect(verified.payload.expiresAt - verified.payload.issuedAt == 3_600, "lease TTL")

    try expectThrows("簽章竄改") { _ = try fixture.verify(fixture.makeEnvelope(sign: false)) }
    try expectThrows("錯誤 kid") { _ = try fixture.verify(fixture.makeEnvelope(kid: String(repeating: "0", count: 16))) }
    try expectThrows("錯誤 device") {
        _ = try fixture.verify(fixture.makeEnvelope(deviceID: String(repeating: "b", count: 64)))
    }
    try expectThrows("錯誤 release") { _ = try fixture.verify(fixture.makeEnvelope(releaseID: "other")) }
    try expectThrows("錯誤 manifest") {
        _ = try fixture.verify(fixture.makeEnvelope(manifest: String(repeating: "b", count: 64)))
    }
    try expectThrows("錯誤 challenge") {
        _ = try fixture.verify(fixture.makeEnvelope(challengeID: Base64URL.encode(Data(repeating: 0x99, count: 32))) )
    }
    try expectThrows("超過一小時") { _ = try fixture.verify(fixture.makeEnvelope(expiresAt: 4_601)) }
    try expectThrows("已過期") { _ = try fixture.verify(fixture.makeEnvelope(), now: 4_600) }
    try expectThrows("尚未生效") { _ = try fixture.verify(fixture.makeEnvelope(issuedAt: 1_001), now: 1_000) }
}

@MainActor
private func testClockAnchor() throws {
    let currentBootID = try MikuLeaseClock.currentBootID()
    try expect(!currentBootID.isEmpty, "boot session UUID")
    try expect(MikuLeaseClock.currentContinuousNanoseconds() > 0, "mach_continuous_time")
    let fixture = try LeaseFixture()
    let lease = try fixture.verify(fixture.makeEnvelope()).payload
    let store = MemoryClockStore()
    let clock = MikuLeaseClock(store: store)
    try expectThrows("缺少 anchor") {
        try clock.authorizeOffline(lease, bootID: "boot-a", continuousNanoseconds: 100)
    }
    try clock.acceptOnline(lease, wallTime: 1_100, bootID: "boot-a", continuousNanoseconds: 1_000)
    try clock.authorizeOffline(lease, bootID: "boot-a", continuousNanoseconds: 2_000)
    try expectThrows("continuous clock 回退") {
        try clock.authorizeOffline(lease, bootID: "boot-a", continuousNanoseconds: 999)
    }
    try expectThrows("same boot monotonic 過期") {
        try clock.authorizeOffline(lease, bootID: "boot-a", continuousNanoseconds: 3_500_000_001_000)
    }
    let originalAnchor = store.state
    try expectThrows("wall clock 回退不可重設相同 lease anchor") {
        try clock.acceptOnline(
            lease,
            wallTime: 1_000,
            bootID: "boot-a",
            continuousNanoseconds: 3_500_000_001_000
        )
    }
    try expect(store.state == originalAnchor, "相同 lease 重放不可修改 anchor")
    try expectThrows("相同 lease 重放後仍維持 monotonic 過期") {
        try clock.authorizeOffline(lease, bootID: "boot-a", continuousNanoseconds: 3_500_000_001_000)
    }
    let sameIssuedID = Base64URL.encode(Data(repeating: 0x59, count: 32))
    let sameIssued = try fixture.verify(fixture.makeEnvelope(leaseID: sameIssuedID), now: 1_000).payload
    try expectThrows("同 issued_at 的不同 lease 仍屬重放") {
        try clock.acceptOnline(sameIssued, wallTime: 1_100, bootID: "boot-a", continuousNanoseconds: 2_000)
    }
    try expect(store.state == originalAnchor, "同 issued_at 重放不可修改 anchor")
    try expectThrows("重開機 fail-closed") {
        try clock.authorizeOffline(lease, bootID: "boot-b", continuousNanoseconds: 10)
    }
    try expectThrows("重開機不可重用同一 lease") {
        try clock.acceptOnline(lease, wallTime: 1_200, bootID: "boot-b", continuousNanoseconds: 10)
    }

    let newerID = Base64URL.encode(Data(repeating: 0x5A, count: 32))
    let newer = try fixture.verify(fixture.makeEnvelope(leaseID: newerID, issuedAt: 1_200, expiresAt: 4_800), now: 1_200).payload
    try clock.acceptOnline(newer, wallTime: 1_200, bootID: "boot-b", continuousNanoseconds: 10)
    let older = try fixture.verify(fixture.makeEnvelope(issuedAt: 1_100, expiresAt: 4_700), now: 1_100).payload
    try expectThrows("high-water 回退") {
        try clock.acceptOnline(older, wallTime: 1_300, bootID: "boot-b", continuousNanoseconds: 20)
    }
}

private func testSecureEnclaveWhenAvailable() throws {
    guard SecureEnclave.isAvailable else {
        print("⏭️ Secure Enclave：此機不可用，硬體測試已跳過")
        return
    }
    var accessError: Unmanaged<CFError>?
    guard let access = SecAccessControlCreateWithFlags(
        nil,
        kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        .privateKeyUsage,
        &accessError
    ) else { throw accessError!.takeRetainedValue() as Error }
    let context = LAContext()
    context.interactionNotAllowed = true
    let signing = try SecureEnclave.P256.Signing.PrivateKey(accessControl: access, authenticationContext: context)
    let message = Data("secure-enclave-test".utf8)
    let signature = try signing.signature(for: message)
    try expect(signing.publicKey.isValidSignature(signature, for: message), "Secure Enclave sign/verify")

    let agreement = try SecureEnclave.P256.KeyAgreement.PrivateKey(accessControl: access, authenticationContext: context)
    let peer = P256.KeyAgreement.PrivateKey()
    let first = try agreement.sharedSecretFromKeyAgreement(with: peer.publicKey)
    let second = try peer.sharedSecretFromKeyAgreement(with: agreement.publicKey)
    try expect(first.withUnsafeBytes { Data($0) } == second.withUnsafeBytes { Data($0) }, "Secure Enclave ECDH")
    print("✅ Secure Enclave：硬體 Signing／KeyAgreement 實測通過")
}

private func testBackendSecureEnclaveInterop() throws {
    guard SecureEnclave.isAvailable else {
        print("⏭️ Python↔Swift SE interop：Secure Enclave 不可用")
        return
    }
    guard let helper = ProcessInfo.processInfo.environment["MIKU_BACKEND_INTEROP_HELPER"],
          let temporaryDirectory = ProcessInfo.processInfo.environment["MIKU_TEST_TEMP_DIR"] else {
        throw TestFailure.assertion("缺少 backend interop helper")
    }
    let context = LAContext()
    context.interactionNotAllowed = true
    var accessError: Unmanaged<CFError>?
    guard let access = SecAccessControlCreateWithFlags(
        nil,
        kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        .privateKeyUsage,
        &accessError
    ) else { throw accessError!.takeRetainedValue() as Error }
    let signing = try SecureEnclave.P256.Signing.PrivateKey(accessControl: access, authenticationContext: context)
    let agreement = try SecureEnclave.P256.KeyAgreement.PrivateKey(accessControl: access, authenticationContext: context)
    let signingPublic = signing.publicKey.x963Representation
    let agreementPublic = agreement.publicKey.x963Representation
    let deviceID = MikuLocalTTSProtocol.deviceID(signingPublicKey: signingPublic, agreementPublicKey: agreementPublic)
    let releaseID = "interop-release"
    let manifest = String(repeating: "c", count: 64)
    let stateDirectory = temporaryDirectory + "/authority"
    let prepareInput = temporaryDirectory + "/prepare-input.json"
    let prepareOutput = temporaryDirectory + "/prepare-output.json"
    try JSONSerialization.data(withJSONObject: [
        "device_id": deviceID,
        "release_id": releaseID,
        "manifest_sha256": manifest,
        "signing_public_key": Base64URL.encode(signingPublic),
        "agreement_public_key": Base64URL.encode(agreementPublic),
    ], options: [.sortedKeys]).write(to: URL(fileURLWithPath: prepareInput))
    try runInteropHelper(helper, stateDirectory, "prepare", prepareInput, prepareOutput)
    let prepared = try readJSONObject(prepareOutput)
    let challengeID = prepared["challenge_id"] as! String
    let nonce = prepared["nonce"] as! String
    let activationToken = prepared["activation_token"] as! String
    let serverPublicKey = try Base64URL.decode(prepared["server_public_key"] as! String, exactLength: 32)
    let expectedDEKHash = prepared["dek_sha256"] as! String
    let payload = MikuLocalTTSProtocol.ProofPayload(
        operation: .enroll,
        challengeID: challengeID,
        nonce: nonce,
        deviceID: deviceID,
        releaseID: releaseID,
        signingPublicKey: Base64URL.encode(signingPublic),
        agreementPublicKey: Base64URL.encode(agreementPublic),
        activationToken: activationToken
    )
    let proof = try signing.signature(for: MikuLocalTTSProtocol.proofMessage(payload)).derRepresentation
    let grantInput = temporaryDirectory + "/grant-input.json"
    let grantOutput = temporaryDirectory + "/grant-output.json"
    try JSONSerialization.data(withJSONObject: [
        "v": 1,
        "op": "enroll",
        "challenge_id": challengeID,
        "nonce": nonce,
        "device_id": deviceID,
        "release_id": releaseID,
        "signing_public_key": Base64URL.encode(signingPublic),
        "agreement_public_key": Base64URL.encode(agreementPublic),
        "activation_token": activationToken,
        "proof": Base64URL.encode(proof),
        "attestation": ["test_only": "mock"],
    ], options: [.sortedKeys]).write(to: URL(fileURLWithPath: grantInput))
    try runInteropHelper(helper, stateDirectory, "grant", grantInput, grantOutput)
    let granted = try readJSONObject(grantOutput)
    let lease = granted["lease"] as! [String: Any]
    let leaseData = try JSONSerialization.data(withJSONObject: lease, options: [.sortedKeys])
    let verified = try MikuLeaseVerifier(rawTrustedKeys: [serverPublicKey]).verifyAndUnwrap(
        envelopeData: leaseData,
        agreementKey: MikuSecureEnclaveAgreementPrivateKey(key: agreement),
        expectedDeviceID: deviceID,
        expectedReleaseID: releaseID,
        expectedManifestSHA256: manifest,
        expectedChallengeID: challengeID,
        now: 1_700_000_000
    )
    let actualHash = SHA256.hash(data: verified.dek).map { String(format: "%02x", $0) }.joined()
    try expect(actualHash == expectedDEKHash, "Python backend lease 的 DEK hash 不符")
    print("✅ Python backend↔Swift：硬體 proof、lease、SE 解封互通通過")
}

private func runInteropHelper(
    _ helper: String,
    _ stateDirectory: String,
    _ mode: String,
    _ input: String,
    _ output: String
) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["python3", helper, stateDirectory, mode, input, output]
    let errorPipe = Pipe()
    process.standardOutput = Pipe()
    process.standardError = errorPipe
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        let error = String(decoding: errorPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        throw TestFailure.assertion("backend interop helper 失敗：\(error)")
    }
}

private func readJSONObject(_ path: String) throws -> [String: Any] {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw TestFailure.assertion("interop JSON 格式錯誤")
    }
    return object
}

private func testFailClosedRuntimeGates() throws {
    try expectThrows("未 pin 公鑰必須拒絕") {
        let fixture = try LeaseFixture()
        _ = try MikuLeaseVerifier.production().verifyAndUnwrap(
            envelopeData: fixture.makeEnvelope(),
            agreementKey: fixture.agreementKey,
            expectedDeviceID: fixture.deviceID,
            expectedReleaseID: fixture.releaseID,
            expectedManifestSHA256: fixture.manifest,
            expectedChallengeID: fixture.challengeID,
            now: 1_000
        )
    }
    let productionRequirement = MikuSigningReadinessGate.Requirement(
        teamID: "ABCDE12345",
        identifier: "com.qimake.MikuDesktop"
    )
    _ = try MikuSigningReadinessGate.makeCodeRequirement(productionRequirement)
    try expectThrows("CLI 測試 binary 不符合正式簽署 gate") {
        try MikuSigningReadinessGate.checkCurrentApplication(productionRequirement)
    }
    try expectThrows("簽署 requirement 參數不可注入") {
        try MikuSigningReadinessGate.checkCurrentApplication(.init(teamID: #"A" or true"#, identifier: "com.qimake.MikuDesktop"))
    }
    if #available(macOS 27.0, *) {
        try expect(!MikuAppAttestClient().isSupported, "CLI 不應支援 App Attest")
        print("✅ App Attest：CLI isSupported=false，未呼叫 Apple API")
    }
}

private func writeProofInteropFixture(to path: String) throws {
    let fixture = try proofFixture()
    let object: [String: Any] = [
        "canonical_payload": Base64URL.encode(try fixture.payload.canonicalData()),
        "proof": Base64URL.encode(fixture.proof),
        "payload": [
            "v": 1,
            "op": fixture.payload.operation.rawValue,
            "challenge_id": fixture.payload.challengeID,
            "nonce": fixture.payload.nonce,
            "device_id": fixture.payload.deviceID,
            "release_id": fixture.payload.releaseID,
            "signing_public_key": fixture.payload.signingPublicKey,
            "agreement_public_key": fixture.payload.agreementPublicKey,
            "activation_token": fixture.payload.activationToken!,
        ],
    ]
    try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: URL(fileURLWithPath: path), options: .atomic)
}

@main
private enum MikuLocalTTSAuthorizationTests {
    @MainActor
    static func main() throws {
        let arguments = CommandLine.arguments
        if arguments.count == 3, arguments[1] == "--write-proof-fixture" {
            try writeProofInteropFixture(to: arguments[2])
            return
        }
        try testBase64AndCanonicalJSON()
        try testProof()
        try testLeaseVerification()
        try testClockAnchor()
        try testSecureEnclaveWhenAvailable()
        try testBackendSecureEnclaveInterop()
        try testFailClosedRuntimeGates()
        print("✅ Miku Local TTS Authorization：全部 targeted tests 通過")
    }
}
