import Foundation

@main
struct MikuSpeechAuthorizationTests {
    static func main() throws {
        let token = "test-token-placeholder"
        for value in [
            "https://miku-tts.qimake.si/api/session",
            "https://miku-tts.qimake.si:443/api/jobs/0123456789abcdef0123456789abcdef/audio"
        ] {
            let request = try MikuSpeechAuthorization.protectedRequest(
                url: try url(value),
                token: token
            )
            precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(token)")
        }

        let rejected = [
            "http://127.0.0.1:9882/api/session",
            "http://localhost:9882/api/session",
            "https://example.com/api/session",
            "https://miku-tts.qimake.si.example.com/api/session",
            "https://voice.miku-tts.qimake.si/api/session",
            "https://user@miku-tts.qimake.si/api/session",
            "https://miku-tts.qimake.si:80/api/session",
            "https://miku-tts.qimake.si:444/api/session",
            "https://miku-tts.qimake.si/api/session?next=local",
            "https://miku-tts.qimake.si/api/session#local"
        ]
        for value in rejected {
            do {
                _ = try MikuSpeechAuthorization.protectedRequest(url: try url(value), token: token)
                preconditionFailure("Untrusted URL was accepted: \(value)")
            } catch MikuSpeechAuthorization.AuthorizationError.untrustedServiceURL {
                continue
            }
        }

        for value in [
            "https://miku-tts.qimake.si",
            "https://miku-tts.qimake.si:443/"
        ] {
            try MikuSpeechAuthorization.validateServiceEndpoint(try url(value))
        }
        for value in [
            "http://127.0.0.1:9882",
            "http://localhost:9882",
            "https://miku-tts.qimake.si/api",
            "https://miku-tts.qimake.si?mode=local"
        ] {
            do {
                try MikuSpeechAuthorization.validateServiceEndpoint(try url(value))
                preconditionFailure("Untrusted endpoint was accepted: \(value)")
            } catch MikuSpeechAuthorization.AuthorizationError.untrustedServiceURL {
                continue
            }
        }

        print("PASS: speech authorization checks")
    }

    private static func url(_ value: String) throws -> URL {
        guard let url = URL(string: value) else {
            throw TestError.invalidFixture
        }
        return url
    }

    private enum TestError: Error {
        case invalidFixture
    }
}
