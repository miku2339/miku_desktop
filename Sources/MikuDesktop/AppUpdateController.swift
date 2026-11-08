import AppKit

@MainActor
final class AppUpdateController {
    var onChange: (() -> Void)?
    private(set) var availableRelease: AppUpdateRelease?
    private(set) var isChecking = false

    private let checker = AppUpdateChecker()
    private let defaults = UserDefaults.standard
    private var timer: Timer?
    private var startupTask: Task<Void, Never>?
    private var checkTask: Task<Void, Never>?
    private var presentWhenFinished = false

    var menuTitle: String {
        if isChecking { return L10n.text("appUpdateChecking") }
        if let release = availableRelease { return L10n.format("appUpdateAvailable", release.version) }
        return L10n.text("appUpdateCheck")
    }

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 60 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkAutomaticallyIfDue() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        startupTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            guard !Task.isCancelled else { return }
            self?.checkAutomaticallyIfDue()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        startupTask?.cancel()
        checkTask?.cancel()
    }

    func checkAutomaticallyIfDue() {
        guard AppUpdateSchedule.shouldCheck(defaults: defaults) else { return }
        check(presentResult: false)
    }

    func checkManually() {
        check(presentResult: true)
    }

    private func check(presentResult: Bool) {
        if presentResult { presentWhenFinished = true }
        guard !isChecking else { return }
        isChecking = true
        AppUpdateSchedule.markChecked(defaults: defaults)
        onChange?()
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        checkTask = Task { [weak self] in
            guard let self else { return }
            let result: Result<AppUpdateResult, Error>
            do {
                result = .success(try await checker.check(currentVersion: version))
            } catch {
                result = .failure(error)
            }
            guard !Task.isCancelled else { return }
            if case let .success(update) = result {
                if case let .available(release) = update {
                    availableRelease = release
                } else {
                    availableRelease = nil
                }
            }
            isChecking = false
            checkTask = nil
            let shouldPresent = presentWhenFinished
            presentWhenFinished = false
            onChange?()
            if shouldPresent { present(result, currentVersion: version) }
        }
    }

    private func present(_ result: Result<AppUpdateResult, Error>, currentVersion: String) {
        let alert = NSAlert()
        switch result {
        case let .success(.available(release)):
            alert.messageText = L10n.format("appUpdateAvailable", release.version)
            alert.informativeText = L10n.text("appUpdateKeepsData")
            alert.addButton(withTitle: L10n.text("appUpdateDownload"))
            alert.addButton(withTitle: L10n.text("appUpdateLater"))
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(release.pageURL) }
            return
        case .success(.upToDate):
            alert.messageText = L10n.text("appUpdateCurrent")
            alert.informativeText = L10n.format("appUpdateInstalledVersion", currentVersion)
        case .success(.noRelease):
            alert.messageText = L10n.text("appUpdateNoRelease")
            alert.informativeText = L10n.text("appUpdateNoReleaseDetail")
        case .failure:
            alert.messageText = L10n.text("appUpdateFailed")
            alert.informativeText = L10n.text("appUpdateRetry")
        }
        alert.addButton(withTitle: L10n.text("appUpdateOK"))
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
