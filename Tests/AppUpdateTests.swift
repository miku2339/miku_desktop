import Foundation

@main
struct AppUpdateTests {
    static func main() async throws {
        var checks = 0
        func check(_ condition: Bool, _ message: String = "") {
            precondition(condition, message)
            checks += 1
        }

        func fixture(tag: String = "v1.2.10", page: String? = nil, draft: Bool = false, prerelease: Bool = false,
                     assets: [[String: Any]]? = nil) throws -> Data {
            let name = "MikuDesktop-macOS.zip"
            return try JSONSerialization.data(withJSONObject: [
                "tag_name": tag,
                "html_url": page ?? "https://github.com/miku2339/miku_desktop/releases/tag/\(tag)",
                "draft": draft, "prerelease": prerelease,
                "assets": assets ?? [["name": name, "state": "uploaded", "size": 100,
                                       "browser_download_url": "https://github.com/miku2339/miku_desktop/releases/download/\(tag)/\(name)"]]
            ])
        }

        func checker(_ data: Data, status: Int = 200, responseURL: URL = AppUpdateChecker.endpoint) -> AppUpdateChecker {
            AppUpdateChecker { request in
                check(request.url == AppUpdateChecker.endpoint)
                check(request.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json")
                check(request.value(forHTTPHeaderField: "X-GitHub-Api-Version") == "2022-11-28")
                check(request.value(forHTTPHeaderField: "User-Agent") == "MikuDesktop-UpdateCheck/1.0")
                check(request.value(forHTTPHeaderField: "Authorization") == nil)
                check(request.value(forHTTPHeaderField: "Cookie") == nil)
                return (data, HTTPURLResponse(url: responseURL, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!)
            }
        }

        func rejects(_ checker: AppUpdateChecker, version: String = "1.2.9") async -> Bool {
            do {
                _ = try await checker.check(currentVersion: version)
                return false
            } catch { return true }
        }

        let available = try await checker(fixture()).check(currentVersion: "1.2.9")
        if case let .available(release) = available {
            check(release.version == "1.2.10")
            check(release.tag == "v1.2.10")
            check(release.pageURL.absoluteString == "https://github.com/miku2339/miku_desktop/releases/tag/v1.2.10")
        } else { preconditionFailure("New stable release was missed") }
        check(try await checker(fixture()).check(currentVersion: "1.2.10") == .upToDate)
        check(try await checker(fixture()).check(currentVersion: "v2.0.0") == .upToDate)
        check(try await checker(fixture(tag: "2.0.0")).check(currentVersion: "1.99.99") != .upToDate)
        check(try await checker(fixture(draft: true)).check(currentVersion: "1.2.9") == .noRelease)
        check(try await checker(fixture(prerelease: true)).check(currentVersion: "1.2.9") == .noRelease)
        check(try await checker(Data(), status: 404).check(currentVersion: "1.2.9") == .noRelease)
        check(try await checker(fixture(assets: [])).check(currentVersion: "1.2.9") == .noRelease)

        for value in ["", "1.2", "1.2.3.4", "1..3", "01.2.3", "1.2.3-beta", "1.2.3+build", "-1.2.3", "1.2.９", "999999999999999999999.2.3"] {
            check(AppUpdateVersion(value) == nil, value)
            check(await rejects(checker(try fixture(tag: value))), value)
        }
        let neverRequested = AppUpdateChecker { _ in preconditionFailure("Invalid current version requested the network") }
        check(await rejects(neverRequested, version: "broken"))

        for url in [
            "http://github.com/miku2339/miku_desktop/releases/tag/v1.2.10",
            "https://evil.example/miku2339/miku_desktop/releases/tag/v1.2.10",
            "https://github.com.evil.example/miku2339/miku_desktop/releases/tag/v1.2.10",
            "https://user:pass@github.com/miku2339/miku_desktop/releases/tag/v1.2.10",
            "https://github.com:443/miku2339/miku_desktop/releases/tag/v1.2.10",
            "https://github.com/other/miku_desktop/releases/tag/v1.2.10",
            "https://github.com/miku2339/miku_desktop/releases/tag/v1.2.10?next=other",
            "https://github.com/miku2339/miku_desktop/releases/tag/v1.2.10#other",
            "https://github.com/miku2339/miku_desktop/releases/tag/v9.0.0"
        ] { check(await rejects(checker(try fixture(page: url))), url) }

        let assetBase: [String: Any] = ["name": "MikuDesktop-macOS.zip", "state": "uploaded", "size": 100,
                                       "browser_download_url": "https://github.com/miku2339/miku_desktop/releases/download/v1.2.10/MikuDesktop-macOS.zip"]
        for (key, value) in [("name", "source.zip" as Any), ("state", "new" as Any), ("size", 0 as Any),
                             ("browser_download_url", "https://evil.example/MikuDesktop-macOS.zip" as Any)] {
            var asset = assetBase
            asset[key] = value
            check(try await checker(fixture(assets: [asset])).check(currentVersion: "1.2.9") == .noRelease)
        }
        let publicName = "Miku Desktop (Public).zip"
        let publicAsset: [String: Any] = ["name": publicName, "state": "uploaded", "size": 100,
                                         "browser_download_url": "https://github.com/miku2339/miku_desktop/releases/download/v1.2.10/Miku%20Desktop%20(Public).zip"]
        if case .available = try await checker(fixture(assets: [publicAsset])).check(currentVersion: "1.2.9") {
            check(true)
        } else { preconditionFailure("Public ZIP with encoded spaces was missed") }

        check(await rejects(checker(Data(), status: 429)))
        check(await rejects(checker(Data(), status: 503)))
        check(await rejects(checker(Data("not json".utf8))))
        check(await rejects(checker(Data("[]".utf8))))
        check(await rejects(checker(Data(repeating: 32, count: 1024 * 1024 + 1))))
        check(await rejects(checker(try fixture(), responseURL: URL(string: "https://evil.example/")!)))
        let offline = AppUpdateChecker { _ in throw URLError(.notConnectedToInternet) }
        do {
            _ = try await offline.check(currentVersion: "1.2.9")
            preconditionFailure("Network failure was hidden")
        } catch let error as URLError {
            check(error.code == .notConnectedToInternet)
        }

        let session = URLSession(configuration: .ephemeral)
        let task = session.dataTask(with: AppUpdateChecker.endpoint)
        var redirected = true
        AppUpdateRedirectBlocker().urlSession(session, task: task,
            willPerformHTTPRedirection: HTTPURLResponse(url: AppUpdateChecker.endpoint, statusCode: 302, httpVersion: nil, headerFields: nil)!,
            newRequest: URLRequest(url: URL(string: "https://evil.example/")!)) { request in redirected = request != nil }
        check(!redirected)
        session.invalidateAndCancel()

        let suite = "MikuDesktop.AppUpdateTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("original nickname", forKey: "nickname")
        defaults.set("ja", forKey: "interfaceLanguage")
        defaults.set(false, forKey: "memoryEnabled")
        let original = defaults.persistentDomain(forName: suite)!
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        check(AppUpdateSchedule.shouldCheck(defaults: defaults, now: now))
        AppUpdateSchedule.markChecked(defaults: defaults, now: now)
        check(!AppUpdateSchedule.shouldCheck(defaults: defaults, now: now.addingTimeInterval(86_399)))
        check(AppUpdateSchedule.shouldCheck(defaults: defaults, now: now.addingTimeInterval(86_400)))
        check(AppUpdateSchedule.shouldCheck(defaults: defaults, now: now.addingTimeInterval(-100)))
        defaults.set(false, forKey: AppUpdateSchedule.enabledKey)
        check(!AppUpdateSchedule.shouldCheck(defaults: defaults, now: now.addingTimeInterval(2 * 86_400)))
        let preserved = defaults.persistentDomain(forName: suite)!.filter {
            $0.key != AppUpdateSchedule.enabledKey && $0.key != AppUpdateSchedule.lastCheckKey
        }
        check(NSDictionary(dictionary: preserved).isEqual(to: original))
        print("AppUpdate: \(checks) checks passed")
    }
}
