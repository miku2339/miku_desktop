import AVFoundation
import AppKit
import Foundation

/// Plays a short hum you prepared yourself (an original melody, for example made with VOCALOID)
/// from ~/Library/Application Support/MikuDesktop/Hums. The app ships no clips: with the folder
/// empty, humming stays text only. Clips never leave this Mac.
@MainActor
final class HumPlayer: NSObject, AVAudioPlayerDelegate {
    static let shared = HumPlayer()

    enum Event: Equatable {
        case started(duration: TimeInterval)
        /// Finished, stopped or failed to play.
        case ended
    }

    var onEvent: ((Event) -> Void)?

    private let folder: URL
    private var player: AVAudioPlayer?
    private var lastClip: URL?

    init(folder: URL? = nil) {
        self.folder = folder ?? HumText.defaultFolder
        super.init()
    }

    var isPlaying: Bool { player?.isPlaying == true }

    /// Usable clips: audio files, small enough and short enough to be a hum.
    func clips() -> [URL] {
        HumText.candidateFiles(in: folder).filter { url in
            guard let player = try? AVAudioPlayer(contentsOf: url) else { return false }
            return player.duration > 0.2 && player.duration <= HumText.maximumSeconds
        }
    }

    /// Plays one clip, not the same as last time when there's a choice. False if there is none.
    @discardableResult
    func play() -> Bool {
        stop()
        let available = clips()
        guard !available.isEmpty else { return false }
        let choices = available.count > 1 ? available.filter { $0 != lastClip } : available
        guard let clip = choices.randomElement(),
              let player = try? AVAudioPlayer(contentsOf: clip) else { return false }
        player.delegate = self
        guard player.prepareToPlay(), player.play() else { return false }
        self.player = player
        lastClip = clip
        onEvent?(.started(duration: player.duration))
        return true
    }

    func stop() {
        guard let player else { return }
        player.stop()
        player.delegate = nil
        self.player = nil
        onEvent?(.ended)
    }

    /// Creates the folder if needed and shows it in Finder.
    func revealFolder() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        MainActor.assumeIsolated { finished(player) }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        MainActor.assumeIsolated { finished(player) }
    }

    private func finished(_ finishedPlayer: AVAudioPlayer) {
        guard finishedPlayer === player else { return }
        player = nil
        onEvent?(.ended)
    }
}
