import Foundation

enum MikuSpeechAuthorization {
    enum AuthorizationError: Error, Equatable {
        case untrustedServiceURL
    }

    static let officialEndpoint = "https://miku-tts.qimake.si"

    static func protectedRequest(url: URL, token: String) throws -> URLRequest {
        guard isOfficialServiceURL(url) else {
            throw AuthorizationError.untrustedServiceURL
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    static func validateServiceEndpoint(_ url: URL) throws {
        guard isOfficialServiceURL(url), url.path.isEmpty || url.path == "/" else {
            throw AuthorizationError.untrustedServiceURL
        }
    }

    static func isOfficialServiceURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https"
            && url.host?.lowercased() == "miku-tts.qimake.si"
            && (url.port == nil || url.port == 443)
            && url.user == nil
            && url.password == nil
            && url.query == nil
            && url.fragment == nil
    }
}
