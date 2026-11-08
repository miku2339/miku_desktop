import Foundation

struct AppUpdateVersion: Comparable {
    let components: [Int]

    init?(_ value: String) {
        let number = value.hasPrefix("v") ? String(value.dropFirst()) : value
        let parts = number.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var values: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.utf8.allSatisfy({ (48...57).contains($0) }),
                  part.count == 1 || part.first != "0", let value = Int(part) else { return nil }
            values.append(value)
        }
        components = values
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.components.lexicographicallyPrecedes(rhs.components)
    }
}

struct AppUpdateRelease: Equatable {
    let version: String
    let tag: String
    let pageURL: URL
}

enum AppUpdateResult: Equatable {
    case available(AppUpdateRelease)
    case upToDate
    case noRelease
}

enum AppUpdateError: Error {
    case invalidCurrentVersion
    case invalidResponse
    case httpStatus(Int)
}

enum AppUpdateSchedule {
    static let enabledKey = "updates.automaticEnabled"
    static let lastCheckKey = "updates.lastCheck"

    static func shouldCheck(defaults: UserDefaults, now: Date = Date()) -> Bool {
        let enabled = defaults.object(forKey: enabledKey) as? Bool ?? true
        guard enabled else { return false }
        guard let last = defaults.object(forKey: lastCheckKey) as? Double else { return true }
        let elapsed = now.timeIntervalSince1970 - last
        return elapsed < 0 || elapsed >= 24 * 60 * 60
    }

    static func markChecked(defaults: UserDefaults, now: Date = Date()) {
        defaults.set(now.timeIntervalSince1970, forKey: lastCheckKey)
    }
}

/// Checks public release metadata only. User data and the installed app are never changed.
final class AppUpdateChecker {
    typealias Transport = (URLRequest) async throws -> (Data, URLResponse)
    static let endpoint = URL(string: "https://api.github.com/repos/miku2339/miku_desktop/releases/latest")!
    private static let repositoryPath = "/miku2339/miku_desktop/releases/"
    private let transport: Transport

    init(transport: Transport? = nil) {
        if let transport {
            self.transport = transport
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 15
            configuration.timeoutIntervalForResource = 20
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            configuration.urlCredentialStorage = nil
            configuration.urlCache = nil
            let session = URLSession(configuration: configuration, delegate: AppUpdateRedirectBlocker(), delegateQueue: nil)
            self.transport = { request in try await session.data(for: request) }
        }
    }

    func check(currentVersion: String) async throws -> AppUpdateResult {
        guard let current = AppUpdateVersion(currentVersion) else { throw AppUpdateError.invalidCurrentVersion }
        var request = URLRequest(url: Self.endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("MikuDesktop-UpdateCheck/1.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await transport(request)
        guard let http = response as? HTTPURLResponse, http.url == Self.endpoint else { throw AppUpdateError.invalidResponse }
        if http.statusCode == 404 { return .noRelease }
        guard http.statusCode == 200 else { throw AppUpdateError.httpStatus(http.statusCode) }
        guard data.count <= 1024 * 1024 else { throw AppUpdateError.invalidResponse }
        let release: Release
        do {
            release = try JSONDecoder().decode(Release.self, from: data)
        } catch {
            throw AppUpdateError.invalidResponse
        }
        guard !release.draft, !release.prerelease else { return .noRelease }
        guard let version = AppUpdateVersion(release.tag_name),
              let page = Self.officialURL(release.html_url, suffix: "tag/" + release.tag_name) else {
            throw AppUpdateError.invalidResponse
        }
        guard release.assets.contains(where: { asset in
            ["MikuDesktop-macOS.zip", "Miku Desktop (Public).zip", "Miku.Desktop.Public.zip"].contains(asset.name)
                && asset.state == "uploaded" && asset.size > 0
                && Self.officialURL(asset.browser_download_url, suffix: "download/" + release.tag_name + "/" + asset.name) != nil
        }) else { return .noRelease }
        guard version > current else { return .upToDate }
        return .available(AppUpdateRelease(version: release.tag_name.hasPrefix("v") ? String(release.tag_name.dropFirst()) : release.tag_name,
                                           tag: release.tag_name, pageURL: page))
    }

    private static func officialURL(_ value: String, suffix: String) -> URL? {
        guard let url = URL(string: value), let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "https", parts.host == "github.com", parts.user == nil, parts.password == nil,
              parts.port == nil, parts.query == nil, parts.fragment == nil,
              parts.path == repositoryPath + suffix else { return nil }
        return url
    }

    private struct Release: Decodable {
        let tag_name: String
        let html_url: String
        let draft: Bool
        let prerelease: Bool
        let assets: [Asset]
    }

    private struct Asset: Decodable {
        let name: String
        let state: String
        let size: Int
        let browser_download_url: String
    }
}

/// The fixed GitHub API endpoint does not need redirects.
final class AppUpdateRedirectBlocker: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
