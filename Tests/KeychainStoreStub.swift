import Foundation

#if AIMCP_TEST_KEYCHAIN_STUB
enum KeychainStore {
    static func read(service: String, account: String) throws -> Data? { nil }
    static func write(_ data: Data, service: String, account: String) throws {}
}
#endif
