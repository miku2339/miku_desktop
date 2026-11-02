import Foundation

@MainActor
final class MikuTrainingActivity {
    static let shared = MikuTrainingActivity()

    private struct Snapshot: Encodable {
        let version = 1
        let active: Bool
        let updated_at: TimeInterval
        let pid: Int32
    }

    private let location: URL
    private var timer: Timer?
    private var voiceCallActive = false

    init(location: URL? = nil) {
        self.location = location ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MikuTraining/runtime/voice-call-state.json")
    }

    func start() {
        guard timer == nil else { return }
        publish()
        let timer = Timer(timeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.publish() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func setVoiceCallActive(_ active: Bool) {
        voiceCallActive = active
        publish()
    }

    func publish() {
        do {
            try FileManager.default.createDirectory(
                at: location.deletingLastPathComponent(), withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let snapshot = Snapshot(
                active: voiceCallActive, updated_at: Date().timeIntervalSince1970,
                pid: ProcessInfo.processInfo.processIdentifier
            )
            try JSONEncoder().encode(snapshot).write(to: location, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: location.path)
        } catch {
            // Missing or stale state keeps the training runner paused.
        }
    }
}
